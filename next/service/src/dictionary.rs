//! The dictionary on disk: `vocab.txt`, `replacements.txt` and the suggestions waiting for a
//! click in `pending-corrections.json`. Read again whenever a file changes, whoever changed it
//! (the window, the learner, the shared-dictionary sync), so nothing has to tell anyone.

use crate::events::{Event, Sink, Toast, ToastAction};
use linflow_core::fsutil::write_atomic;
use linflow_core::learn::{self, LearnMode, Outcome};
use linflow_core::settings::{CleanupLevel, Settings};
use linflow_core::text::glossary::{self, Replacement};
use linflow_core::text::TextCleaner;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

pub const PENDING_FILE: &str = "pending-corrections.json";

#[derive(Default)]
struct Cache {
    terms: Vec<String>,
    rules: Vec<Replacement>,
    pending: Vec<Replacement>,
    stamps: [Option<SystemTime>; 3],
    loaded: bool,
}

pub struct Dictionary {
    vocab: PathBuf,
    replacements: PathBuf,
    pending: PathBuf,
    cache: Mutex<Cache>,
    events: Sink,
}

fn stamp(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path).and_then(|m| m.modified()).ok()
}

/// What learning from one edit came to, for the toast.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Learned {
    pub outcome: Outcome,
    pub declined: Option<(String, String)>,
}

impl Dictionary {
    pub fn new(data_dir: &Path, events: Sink) -> Dictionary {
        let d = Dictionary {
            vocab: data_dir.join("vocab.txt"),
            replacements: data_dir.join("replacements.txt"),
            pending: data_dir.join(PENDING_FILE),
            cache: Mutex::new(Cache::default()),
            events,
        };
        if !d.vocab.exists() {
            let _ = std::fs::create_dir_all(data_dir);
            let _ = write_atomic(&d.vocab, glossary::seed_file().as_bytes());
        }
        d
    }

    fn with<T>(&self, f: impl FnOnce(&Cache) -> T) -> T {
        let mut c = self.cache.lock().unwrap();
        let now = [stamp(&self.vocab), stamp(&self.replacements), stamp(&self.pending)];
        if !c.loaded || now != c.stamps {
            let vocab = std::fs::read_to_string(&self.vocab).ok();
            c.terms = glossary::terms_or_defaults(vocab.as_deref());
            c.rules = std::fs::read_to_string(&self.replacements).map(|t| glossary::parse_replacements(&t)).unwrap_or_default();
            c.pending = std::fs::read_to_string(&self.pending).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
            c.stamps = now;
            c.loaded = true;
        }
        f(&c)
    }

    pub fn terms(&self) -> Vec<String> {
        self.with(|c| c.terms.clone())
    }

    pub fn rules(&self) -> Vec<Replacement> {
        self.with(|c| c.rules.clone())
    }

    pub fn pending(&self) -> Vec<Replacement> {
        self.with(|c| c.pending.clone())
    }

    /// The cleanup pass at the settings' level: the dictionary, spoken commands, numbers.
    pub fn clean(&self, raw: &str, settings: &Settings) -> String {
        if settings.cleanup_level == CleanupLevel::None {
            return raw.to_string();
        }
        self.cleaner(settings, settings.spoken_commands).clean(raw)
    }

    /// A cleaner for this dictionary. Meetings pass `spoken_commands` false: "question mark" in
    /// a meeting is a phrase, not a command.
    pub fn cleaner(&self, settings: &Settings, spoken_commands: bool) -> TextCleaner {
        let (terms, rules) = self.with(|c| (c.terms.clone(), c.rules.clone()));
        let mut cleaner = TextCleaner::new(terms, rules);
        cleaner.spoken_commands = spoken_commands;
        cleaner.numbers_as_digits = settings.numbers_as_digits;
        cleaner
    }

    fn changed(&self) {
        (self.events)(Event::DictionaryChanged);
    }

    fn save_terms(&self, terms: &[String]) -> std::io::Result<()> {
        write_atomic(&self.vocab, glossary::terms_file(terms).as_bytes())?;
        self.changed();
        Ok(())
    }

    fn save_rules(&self, rules: &[Replacement]) -> std::io::Result<()> {
        let existing = std::fs::read_to_string(&self.replacements).unwrap_or_default();
        write_atomic(&self.replacements, glossary::replacements_file(rules, &existing).as_bytes())?;
        self.changed();
        Ok(())
    }

    fn save_pending(&self, list: &[Replacement]) -> std::io::Result<()> {
        let text = linflow_core::json::pretty_sorted(list).map_err(std::io::Error::other)?;
        write_atomic(&self.pending, text.as_bytes())?;
        self.changed();
        Ok(())
    }

    pub fn add_term(&self, term: &str) -> std::io::Result<()> {
        let term = term.trim();
        if term.is_empty() {
            return Ok(());
        }
        let mut terms = self.terms();
        if terms.iter().any(|t| linflow_core::text::unicode::swift_eq(t, term)) {
            return Ok(());
        }
        terms.push(term.to_string());
        self.save_terms(&terms)
    }

    pub fn remove_term(&self, term: &str) -> std::io::Result<()> {
        let terms: Vec<String> = self.terms().into_iter().filter(|t| t != term).collect();
        self.save_terms(&terms)
    }

    pub fn add_rule(&self, from: &str, to: &str) -> std::io::Result<()> {
        let (from, to) = (from.trim(), to.trim());
        if from.is_empty() || to.is_empty() {
            return Ok(());
        }
        let candidate = Replacement::new(from, to);
        let mut rules: Vec<Replacement> = self.rules().into_iter().filter(|r| r.id() != candidate.id()).collect();
        rules.push(candidate);
        self.save_rules(&rules)
    }

    pub fn remove_rule(&self, from: &str) -> std::io::Result<()> {
        let id = Replacement::new(from, "").id();
        let rules: Vec<Replacement> = self.rules().into_iter().filter(|r| r.id() != id).collect();
        self.save_rules(&rules)
    }

    /// Accepts a suggestion into the corrections, and takes it off the waiting list.
    pub fn accept(&self, from: &str, to: &str) -> std::io::Result<()> {
        let candidate = Replacement::learned(from, to);
        let rules = self.rules();
        if !rules.iter().any(|r| r.id() == candidate.id()) {
            let mut all = rules;
            all.push(candidate.clone());
            self.save_rules(&all)?;
        }
        self.dismiss(from)
    }

    pub fn dismiss(&self, from: &str) -> std::io::Result<()> {
        let id = Replacement::new(from, "").id();
        let list: Vec<Replacement> = self.pending().into_iter().filter(|r| r.id() != id).collect();
        self.save_pending(&list)
    }

    /// One edit, through the learning setting: rules written, suggestions queued, and a toast
    /// saying so. Dictation lands in some other app with the window shut, so without the toast a
    /// learned rule exists only as a line in the log.
    pub fn learn(&self, wrote: &str, now: &str, mode: LearnMode) -> Learned {
        let (rules, pending) = self.with(|c| (c.rules.clone(), c.pending.clone()));
        let d = learn::decide(wrote, now, mode, &rules, &pending);
        if let Some(r) = &d.save_rules {
            if let Err(e) = self.save_rules(r) {
                log::warn!("learning: could not save the corrections: {e}");
            }
        }
        if let Some(p) = &d.save_pending {
            if let Err(e) = self.save_pending(p) {
                log::warn!("learning: could not save the suggestions: {e}");
            }
        }
        for r in &d.outcome.added {
            log::info!("learned correction: {} => {}", r.from, r.to);
        }
        for r in &d.outcome.suggested {
            log::info!("suggested correction: {} => {}", r.from, r.to);
        }
        if let Some(toast) = learned_toast(&d.outcome) {
            (self.events)(Event::Toast { toast });
        } else if let Some((from, to)) = &d.declined {
            log::info!("declined correction: {from} => {to} (too far apart to learn on its own)");
            let toast = Toast::new(format!("Add “{from}” → “{to}”?"), "Not sure enough to add it alone. Click to add.")
                .seconds(12.0)
                .on_click(ToastAction::AddRule { from: from.clone(), to: to.clone() });
            (self.events)(Event::Toast { toast });
        } else if d.outcome.is_empty() {
            log::info!("readback: edit seen but nothing learnable in it");
        }
        Learned { outcome: d.outcome, declined: d.declined }
    }
}

/// The two lines a learning outcome becomes, as the Mac's toast words them.
pub fn learned_toast(outcome: &Outcome) -> Option<Toast> {
    let added = !outcome.added.is_empty();
    let list = if added { &outcome.added } else { &outcome.suggested };
    let first = list.first()?;
    let total = outcome.added.len() + outcome.suggested.len();
    let more = if total > 1 { format!("  +{} more", total - 1) } else { String::new() };
    let title = format!("{}: “{}” → “{}”{more}", if added { "Learned" } else { "Suggested" }, first.from, first.to);
    let detail = if added { "Used from now on. Click to change it in the Dictionary." } else { "Not applied yet. Click to confirm it in the Dictionary." };
    Some(Toast::new(title, detail).seconds(8.0).on_click(ToastAction::OpenDictionary))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("linflow-dict-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn learns_writes_and_rereads_the_files() {
        let dir = scratch("learn");
        let events: Sink = Arc::new(|_| {});
        let d = Dictionary::new(&dir, events);
        assert!(!d.terms().is_empty(), "a fresh folder is seeded");
        let l = d.learn("Ask K Wynn E D F about it.", "Ask kkwinedf about it.", LearnMode::Auto);
        assert_eq!(l.outcome.added, vec![Replacement::learned("K Wynn E D F", "kkwinedf")]);
        assert!(d.rules().iter().any(|r| r.to == "kkwinedf"));
        assert_eq!(d.clean("ask k wynn e d f", &Settings::default()), "Ask kkwinedf.");
        // A suggestion waits, and accepting it moves it into the corrections.
        let l = d.learn("See you Thursday.", "See you Friday.", LearnMode::Auto);
        assert_eq!(l.outcome.suggested.len(), 1);
        assert_eq!(d.pending().len(), 1);
        d.accept("Thursday", "Friday").unwrap();
        assert!(d.pending().is_empty());
        assert!(d.rules().iter().any(|r| r.from == "Thursday"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_toast_says_what_was_learned() {
        let o = Outcome { added: vec![Replacement::learned("wisper", "Wispr")], suggested: vec![] };
        let t = learned_toast(&o).unwrap();
        assert_eq!(t.title, "Learned: “wisper” → “Wispr”");
    }
}
