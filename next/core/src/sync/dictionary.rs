//! One dictionary across every computer.
//!
//! `vocab.txt` and `replacements.txt` stay the files the app reads, and stay hand-editable. What
//! is shared is one row per term and per rule in the table `dictionary_entries`. A deletion is a
//! row marked deleted, so it reaches the computers that still have the entry instead of being
//! brought back by them.
//!
//! Each computer keeps `dictionary-sync.json`: every entry as it last agreed with the table. A
//! sync compares three things for each entry: the local files, that record, and the table. What
//! differs from the record locally is this computer's change and is sent; what differs in the
//! table is another computer's and is taken. When both changed the same entry, this computer's is
//! sent and wins, so the last computer to sync a change wins. `updated_at` is only ever compared
//! for equality, so the computers' clocks do not have to agree.
//!
//! The table keys a row on its lowercase text, byte for byte, while the apps count "Café"
//! composed and decomposed as one entry. So a change is written to the row the table already
//! holds for its entry, under that row's own key, and a new entry is keyed on its composed
//! spelling. Writing a decomposed re-add under its own key once made a second row, and the
//! old deleted one won: the word vanished again (the sync law in core/tests/laws.rs).

use super::SyncConfig;
use crate::fsutil::write_atomic;
use crate::net::{problem, HttpRequest, Transport};
use crate::text::glossary::{self, Replacement};
use crate::text::unicode::{lowercased, swift_eq, swift_key, trim_ws};
use chrono::{DateTime, Utc};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};

pub const TABLE: &str = "dictionary_entries";
pub const PAGE_SIZE: usize = 1000;
pub const BATCH_SIZE: usize = 500;
/// How often the app syncs with nothing else asking it to, so a word added on another computer
/// arrives while this one sits unused.
pub const INTERVAL_SECONDS: u64 = 600;
pub const STATE_FILE: &str = "dictionary-sync.json";
/// More deletions than this in one sync, when they are also most of what this computer had, look
/// like a file emptied by accident rather than words removed one by one.
pub const DELETION_LIMIT: usize = 5;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    Term,
    Rule,
}

impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Kind::Term => "term",
            Kind::Rule => "rule",
        }
    }

    fn parse(s: &str) -> Option<Kind> {
        match s {
            "term" => Some(Kind::Term),
            "rule" => Some(Kind::Rule),
            _ => None,
        }
    }
}

/// One term, or one "heard => meant" rule, as the table holds it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub kind: Kind,
    /// The term, or the rule's left side, as written.
    pub text: String,
    /// The rule's right side. Empty for a term.
    pub target: String,
    pub learned: bool,
    pub deleted: bool,
    /// As the table wrote it. Empty before it has been sent.
    pub updated_at: String,
}

impl Entry {
    pub fn term(text: &str) -> Entry {
        Entry { kind: Kind::Term, text: text.into(), target: String::new(), learned: false, deleted: false, updated_at: String::new() }
    }

    pub fn rule(r: &Replacement) -> Entry {
        Entry { kind: Kind::Rule, text: r.from.clone(), target: r.to.clone(), learned: r.learned, deleted: false, updated_at: String::new() }
    }

    /// The table's key: a term and a rule's left side are one entry whatever their case.
    pub fn key(&self) -> String {
        lowercased(&self.text)
    }

    /// The key a new row is written under: the lowercase text, composed.
    pub fn new_row_key(&self) -> String {
        swift_key(&self.key())
    }

    /// Canonically equivalent spellings are one entry, as they are in Swift's dictionaries.
    pub fn id(&self) -> String {
        swift_key(&format!("{}|{}", self.kind.name(), self.key()))
    }

    /// Equal apart from when it was written.
    pub fn same_content(&self, other: &Entry) -> bool {
        self.kind == other.kind && swift_eq(&self.text, &other.text) && swift_eq(&self.target, &other.target) && self.learned == other.learned && self.deleted == other.deleted
    }

    fn as_replacement(&self) -> Replacement {
        Replacement { from: self.text.clone(), to: self.target.clone(), learned: self.learned }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Merge {
    /// vocab.txt's terms and replacements.txt's rules after the sync, in file order, with what
    /// was taken from the table at the end.
    pub terms: Vec<String>,
    pub rules: Vec<Replacement>,
    /// This computer's changes, deletions as deleted rows. Not yet stamped.
    pub upload: Vec<Entry>,
    /// Other computers' changes that altered the files here.
    pub taken: Vec<Entry>,
    /// The agreed state, not counting `upload`: the table's answer to the upload adds those.
    pub snapshot: BTreeMap<String, Entry>,
    /// Local deletions not sent because too many went at once.
    pub refused_deletions: usize,
}

/// `snapshot` None means this computer has never synced with this project: the table's copy wins
/// wherever the two differ, and whatever only this computer has is sent. The same happens when a
/// file could not be read, which the caller passes as None, so an unreadable file can never send
/// deletions.
pub fn merge(terms: Option<&[String]>, rules: Option<&[Replacement]>, snapshot: Option<&BTreeMap<String, Entry>>, remote: &BTreeMap<String, Entry>) -> Merge {
    let mut local: BTreeMap<String, Entry> = BTreeMap::new();
    for t in terms.unwrap_or(&[]) {
        let e = Entry::term(t);
        local.entry(e.id()).or_insert(e);
    }
    for r in rules.unwrap_or(&[]) {
        let e = Entry::rule(r);
        local.entry(e.id()).or_insert(e);
    }

    let mut agreed = if terms.is_none() || rules.is_none() { None } else { snapshot };
    let mut refused = 0;
    if let Some(s) = agreed {
        // Counted per kind: an emptied vocab.txt must not hide behind a long replacements.txt.
        for kind in [Kind::Term, Kind::Rule] {
            let live: Vec<&Entry> = s.values().filter(|e| e.kind == kind && !e.deleted).collect();
            let gone = live.iter().filter(|e| !local.contains_key(&e.id())).count();
            if gone >= DELETION_LIMIT && gone * 2 > live.len() {
                refused += gone;
            }
        }
        if refused > 0 {
            agreed = None;
        }
    }

    let mut ids: Vec<String> = local.keys().cloned().collect();
    ids.extend(agreed.or(snapshot).map(|s| s.keys().cloned().collect::<Vec<_>>()).unwrap_or_default());
    ids.extend(remote.keys().cloned());
    ids.sort();
    ids.dedup();

    let mut final_: BTreeMap<String, Entry> = BTreeMap::new();
    let (mut upload, mut taken) = (vec![], vec![]);
    let mut snap = BTreeMap::new();
    for id in ids {
        let l = local.get(&id);
        let r = remote.get(&id);
        let mut result = l.cloned();
        if let Some(agreed) = agreed {
            let s = agreed.get(&id);
            let local_changed = match (l, s) {
                (Some(l), Some(s)) => s.deleted || !l.same_content(s),
                _ => l.is_some() || s.is_some_and(|s| !s.deleted),
            };
            let remote_changed = r.is_some_and(|r| s.is_none_or(|s| r.updated_at != s.updated_at || !r.same_content(s)));
            if local_changed {
                let mut mine = l.or(s).unwrap().clone();
                if l.is_none() {
                    mine.deleted = true;
                }
                match r {
                    Some(r) if r.same_content(&mine) => {
                        snap.insert(id.clone(), r.clone());
                    }
                    _ => upload.push(mine),
                }
            } else if let (true, Some(r)) = (remote_changed, r) {
                result = if r.deleted { None } else { Some(r.clone()) };
                snap.insert(id.clone(), r.clone());
            } else if let Some(r) = r {
                snap.insert(id.clone(), r.clone());
            } else if let Some(l) = l {
                // Gone from the table, most likely by hand in the dashboard: put it back.
                upload.push(l.clone());
            }
        } else if let Some(r) = r {
            if !l.is_some_and(|l| r.same_content(l)) {
                result = if r.deleted { None } else { Some(r.clone()) };
            }
            snap.insert(id.clone(), r.clone());
        } else if let Some(l) = l {
            upload.push(l.clone());
        }
        let changed_here = result.is_none() != l.is_none() || result.as_ref().is_some_and(|res| l.is_some_and(|l| !res.same_content(l)));
        if let Some(res) = result {
            final_.insert(id.clone(), res);
        }
        if changed_here {
            if let Some(r) = r {
                taken.push(r.clone());
            }
        }
    }

    // The files' own order, so a sync moves nothing; what arrived goes at the end, as a rule
    // learned here would.
    let (mut out_terms, mut out_rules) = (vec![], vec![]);
    let mut placed = HashSet::new();
    for t in terms.unwrap_or(&[]) {
        let id = Entry::term(t).id();
        if let Some(e) = final_.get(&id) {
            if placed.insert(id) {
                out_terms.push(e.text.clone());
            }
        }
    }
    for r in rules.unwrap_or(&[]) {
        let id = Entry::rule(r).id();
        if let Some(e) = final_.get(&id) {
            if placed.insert(id) {
                out_rules.push(e.as_replacement());
            }
        }
    }
    for (id, e) in &final_ {
        if placed.contains(id) {
            continue;
        }
        match e.kind {
            Kind::Term => out_terms.push(e.text.clone()),
            Kind::Rule => out_rules.push(e.as_replacement()),
        }
    }
    Merge { terms: out_terms, rules: out_rules, upload, taken, snapshot: snap, refused_deletions: refused }
}

/// `keys` holds the key each entry's row is stored under, by entry id, for the entries the table
/// has. Any other entry is a new row.
pub fn upsert_request(config: &SyncConfig, entries: &[Entry], keys: &BTreeMap<String, String>, now: DateTime<Utc>) -> HttpRequest {
    let stamp = now.to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let body: Vec<Value> = entries
        .iter()
        .map(|e| {
            let key = keys.get(&e.id()).cloned().unwrap_or_else(|| e.new_row_key());
            json!({"kind": e.kind.name(), "key": key, "text": e.text, "target": e.target, "learned": e.learned,
                   "deleted": e.deleted, "updated_at": stamp, "device": config.device})
        })
        .collect();
    // The rows come back as the table stored them, so the record holds the table's own
    // updated_at and the next sync can tell this write from a later one.
    let request = HttpRequest::post(format!("{}/{TABLE}?on_conflict=kind,key", config.rest_base()), crate::json::compact(&body).unwrap().into_bytes())
        .header("Content-Type", "application/json")
        .header("Prefer", "resolution=merge-duplicates,return=representation");
    config.authorize(request)
}

pub fn page_request(config: &SyncConfig, offset: usize, limit: usize) -> HttpRequest {
    config.authorize(HttpRequest::get(format!(
        "{}/{TABLE}?select=kind,key,text,target,learned,deleted,updated_at&order=kind.asc,key.asc&limit={limit}&offset={offset}",
        config.rest_base()
    )))
}

fn entry(o: &Value) -> Option<Entry> {
    let kind = Kind::parse(o.get("kind")?.as_str()?)?;
    let text = o.get("text")?.as_str()?;
    if trim_ws(text).is_empty() {
        return None;
    }
    let stamp = o.get("updated_at")?.as_str()?;
    Some(Entry {
        kind,
        text: text.into(),
        target: o.get("target").and_then(Value::as_str).unwrap_or("").into(),
        learned: o.get("learned").and_then(Value::as_bool).unwrap_or(false),
        deleted: o.get("deleted").and_then(Value::as_bool).unwrap_or(false),
        updated_at: stamp.into(),
    })
}

/// The entries in a list of rows, or None when the answer is not a list. A row that will not
/// read is skipped rather than failing the rest.
pub fn parse_rows(body: &[u8]) -> Option<Vec<Entry>> {
    parse_keyed_rows(body).map(|rows| rows.into_iter().map(|(e, _)| e).collect())
}

/// The same, with the key each row is stored under when the answer carries it.
pub fn parse_keyed_rows(body: &[u8]) -> Option<Vec<(Entry, Option<String>)>> {
    match serde_json::from_slice::<Value>(body) {
        Ok(Value::Array(rows)) => Some(rows.iter().filter_map(|o| entry(o).map(|e| (e, o.get("key").and_then(Value::as_str).map(String::from)))).collect()),
        _ => None,
    }
}

/// The record of what this computer last agreed with the table, or None when there is none for
/// this project.
pub fn read_state(path: &Path, project: &str) -> Option<BTreeMap<String, Entry>> {
    let o: Value = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    if o.get("project")?.as_str()? != project {
        return None;
    }
    Some(o.get("entries")?.as_array()?.iter().filter_map(entry).map(|e| (e.id(), e)).collect())
}

/// The record's text, pretty-printed with sorted keys as the Mac writes it.
pub fn state_file(entries: &BTreeMap<String, Entry>, project: &str) -> String {
    let rows: Vec<Value> = entries
        .values()
        .map(|e| json!({"kind": e.kind.name(), "text": e.text, "target": e.target, "learned": e.learned, "deleted": e.deleted, "updated_at": e.updated_at}))
        .collect();
    crate::json::pretty_sorted(&json!({"project": project, "entries": rows})).unwrap()
}

/// The files one sync works on.
#[derive(Clone, Debug)]
pub struct Files {
    pub vocab: PathBuf,
    pub replacements: PathBuf,
    pub state: PathBuf,
}

impl Files {
    pub fn in_dir(data_dir: &Path) -> Files {
        Files { vocab: data_dir.join("vocab.txt"), replacements: data_dir.join("replacements.txt"), state: data_dir.join(STATE_FILE) }
    }
}

/// What one sync did, for the log and for the window to reload the dictionary.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Report {
    pub files_changed: bool,
    pub lines: Vec<String>,
}

fn describe(entries: &[Entry]) -> String {
    if entries.is_empty() {
        return "nothing".into();
    }
    let names = entries.iter().take(5).map(|e| format!("{}{}", if e.deleted { "-" } else { "" }, e.text)).collect::<Vec<_>>().join(", ");
    if entries.len() > 5 {
        format!("{} ({names}, ...)", entries.len())
    } else {
        names
    }
}

/// One sync. Reads the whole table (a few hundred rows at most), merges, sends this computer's
/// changes, and only then writes the files and the record, so a failed send changes nothing here.
pub fn sync(config: &SyncConfig, files: &Files, net: &dyn Transport, now: DateTime<Utc>) -> Result<Report, String> {
    let vocab_text = std::fs::read_to_string(&files.vocab).ok();
    let rules_text = std::fs::read_to_string(&files.replacements).ok();
    let state = read_state(&files.state, &config.url);

    let mut remote = BTreeMap::new();
    let mut keys = BTreeMap::new();
    let mut offset = 0;
    for _ in 0..100 {
        let result = net.send(&page_request(config, offset, PAGE_SIZE));
        if let Some(why) = problem(&result, 20) {
            return Err(format!("dictionary: could not read the shared dictionary: {why}"));
        }
        let page = parse_keyed_rows(&result.unwrap().body).ok_or("dictionary: could not read the shared dictionary: the table did not answer with a list of rows")?;
        if page.is_empty() {
            break;
        }
        offset += page.len();
        // Two rows for one entry, left by an older version, read as the later one, and its key
        // is the one written to.
        for (e, key) in page {
            keys.insert(e.id(), key.unwrap_or_else(|| e.key()));
            remote.insert(e.id(), e);
        }
    }

    // A file that is not there yet reads as nothing. That is safe: None only ever takes from the
    // table, and an empty list with no record does the same.
    let terms = vocab_text.as_deref().map(glossary::parse_terms).or_else(|| (!files.vocab.exists()).then(Vec::new));
    let rules = rules_text.as_deref().map(glossary::parse_replacements).or_else(|| (!files.replacements.exists()).then(Vec::new));
    let m = merge(terms.as_deref(), rules.as_deref(), state.as_ref(), &remote);

    let mut stored = vec![];
    for batch in m.upload.chunks(BATCH_SIZE) {
        let result = net.send(&upsert_request(config, batch, &keys, now));
        if let Some(why) = problem(&result, 20) {
            return Err(format!("dictionary: could not send this computer's dictionary changes: {why}"));
        }
        stored.extend(parse_rows(&result.unwrap().body).unwrap_or_default());
    }

    let mut report = Report::default();
    let mut snapshot = m.snapshot.clone();
    for e in stored {
        snapshot.insert(e.id(), e);
    }
    // A file that is there but could not be read is never written over.
    let same_terms = |a: &[String], b: &[String]| a.len() == b.len() && a.iter().zip(b).all(|(x, y)| swift_eq(x, y));
    let same_rules = |a: &[Replacement], b: &[Replacement]| {
        a.len() == b.len() && a.iter().zip(b).all(|(x, y)| swift_eq(&x.from, &y.from) && swift_eq(&x.to, &y.to) && x.learned == y.learned)
    };
    let vocab_changed = terms.as_ref().map_or(!files.vocab.exists() && !m.terms.is_empty(), |t| !same_terms(&m.terms, t));
    let rules_changed = rules.as_ref().map_or(!files.replacements.exists() && !m.rules.is_empty(), |r| !same_rules(&m.rules, r));
    if vocab_changed || rules_changed {
        // The learner or the window may have saved a file while the table answered. Writing now
        // would undo that; the next sync takes it in instead, and loses nothing, since the record
        // is not saved either.
        if std::fs::read_to_string(&files.vocab).ok() != vocab_text || std::fs::read_to_string(&files.replacements).ok() != rules_text {
            report.lines.push("dictionary: a file changed while syncing; the next sync takes it in".into());
            return Ok(report);
        }
        if vocab_changed {
            write_atomic(&files.vocab, glossary::terms_file(&m.terms).as_bytes()).map_err(|e| e.to_string())?;
        }
        if rules_changed {
            write_atomic(&files.replacements, glossary::replacements_file(&m.rules, rules_text.as_deref().unwrap_or("")).as_bytes()).map_err(|e| e.to_string())?;
        }
        report.files_changed = true;
    }
    write_atomic(&files.state, state_file(&snapshot, &config.url).as_bytes()).map_err(|e| e.to_string())?;
    if m.refused_deletions > 0 {
        report.lines.push(format!(
            "dictionary: {} entries went missing here at once, so none was deleted anywhere and the shared copy was taken instead",
            m.refused_deletions
        ));
    }
    if !m.upload.is_empty() || !m.taken.is_empty() {
        report.lines.push(format!("dictionary: sent {}, took {} as {}", describe(&m.upload), describe(&m.taken), config.device));
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::totals::tests::FakeTable;

    fn config(device: &str) -> SyncConfig {
        SyncConfig { url: "https://x.supabase.co".into(), key: "sb_publishable_k".into(), device: device.into() }
    }

    fn machine(name: &str) -> (std::path::PathBuf, Files) {
        let dir = crate::history::tests::tempdir().join(name);
        std::fs::create_dir_all(&dir).unwrap();
        let files = Files::in_dir(&dir);
        (dir, files)
    }

    fn table() -> FakeTable {
        FakeTable { conflict: vec!["kind", "key"], max_rows: 1000, ..Default::default() }
    }

    #[test]
    fn a_word_added_on_one_computer_reaches_the_other_and_so_does_a_deletion() {
        let net = table();
        let (_a, mac) = machine("mac");
        let (_b, pc) = machine("pc");
        std::fs::write(&mac.vocab, "Parakeet\nLin Flow\n").unwrap();
        std::fs::write(&mac.replacements, "cloud code => Claude Code\n").unwrap();
        sync(&config("Mac"), &mac, &net, Utc::now()).unwrap();
        let report = sync(&config("DESK-01"), &pc, &net, Utc::now()).unwrap();
        assert!(report.files_changed);
        let terms = |f: &Files| {
            let mut t = glossary::parse_terms(&std::fs::read_to_string(&f.vocab).unwrap());
            t.sort();
            t
        };
        assert_eq!(terms(&pc), terms(&mac));
        assert!(std::fs::read_to_string(&pc.replacements).unwrap().contains("cloud code => Claude Code"));

        std::fs::write(&pc.vocab, "Parakeet\n").unwrap();
        sync(&config("DESK-01"), &pc, &net, Utc::now()).unwrap();
        sync(&config("Mac"), &mac, &net, Utc::now()).unwrap();
        assert_eq!(glossary::parse_terms(&std::fs::read_to_string(&mac.vocab).unwrap()), vec!["Parakeet".to_string()]);
    }

    #[test]
    fn a_correction_edited_on_one_computer_is_edited_on_the_other() {
        let net = table();
        let (_a, mac) = machine("mac-edit");
        let (_b, pc) = machine("pc-edit");
        std::fs::write(&mac.vocab, "Parakeet\n").unwrap();
        std::fs::write(&mac.replacements, "jaz mint => Jazmint\t# learned\nwisper => Wispr\n").unwrap();
        sync(&config("Mac"), &mac, &net, Utc::now()).unwrap();
        sync(&config("DESK-01"), &pc, &net, Utc::now()).unwrap();
        // The window's edit: both sides of the learned one, the right side of the other.
        std::fs::write(&mac.replacements, "Jazz Mint => Jasmine\t# learned\nwisper => Wispr Flow\n").unwrap();
        sync(&config("Mac"), &mac, &net, Utc::now()).unwrap();
        sync(&config("DESK-01"), &pc, &net, Utc::now()).unwrap();
        let mut rules = glossary::parse_replacements(&std::fs::read_to_string(&pc.replacements).unwrap());
        rules.sort_by(|a, b| a.from.cmp(&b.from));
        assert_eq!(rules, vec![Replacement::learned("Jazz Mint", "Jasmine"), Replacement::new("wisper", "Wispr Flow")]);
    }

    #[test]
    fn an_emptied_file_deletes_nothing_anywhere() {
        let net = table();
        let (_a, mac) = machine("mac2");
        let words: Vec<String> = (0..8).map(|i| format!("Term{i}")).collect();
        std::fs::write(&mac.vocab, words.join("\n")).unwrap();
        std::fs::write(&mac.replacements, "").unwrap();
        sync(&config("Mac"), &mac, &net, Utc::now()).unwrap();
        std::fs::write(&mac.vocab, "").unwrap();
        let report = sync(&config("Mac"), &mac, &net, Utc::now()).unwrap();
        assert!(report.lines.iter().any(|l| l.contains("went missing")));
        assert_eq!(glossary::parse_terms(&std::fs::read_to_string(&mac.vocab).unwrap()).len(), 8, "the shared copy came back");
        assert!(net.rows.lock().unwrap().iter().all(|r| r["deleted"] == false));
    }

    #[test]
    fn the_record_is_written_as_the_mac_writes_it() {
        let mut m = BTreeMap::new();
        let mut e = Entry::term("A/B");
        e.updated_at = "2026-10-01T00:00:00.000Z".into();
        m.insert(e.id(), e);
        assert_eq!(
            state_file(&m, "https://x.supabase.co"),
            "{\n  \"entries\" : [\n    {\n      \"deleted\" : false,\n      \"kind\" : \"term\",\n      \"learned\" : false,\n      \"target\" : \"\",\n      \"text\" : \"A\\/B\",\n      \"updated_at\" : \"2026-10-01T00:00:00.000Z\"\n    }\n  ],\n  \"project\" : \"https:\\/\\/x.supabase.co\"\n}"
        );
    }
}
