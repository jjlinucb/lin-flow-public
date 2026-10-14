//! Shared word totals: one number across every computer, instead of one per computer.
//!
//! What leaves the machine is one row per computer per day: its name, the date and three counts.
//! Transcripts, audio, the dictionary and app names never do. Each row is rebuilt from the local
//! `history.jsonl` and sent whole, so a retry or a double send can only write the same numbers
//! again, and the other computers' rows come back from the same table.

use super::SyncConfig;
use crate::history::HistoryEntry;
use crate::net::{problem, HttpRequest, Transport};
use chrono::{DateTime, Datelike, NaiveDate, TimeZone, Utc};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap, HashSet};

pub const TABLE: &str = "daily_totals";
pub const PAGE_SIZE: usize = 1000;
/// Rows per upsert. A first send is a few hundred days at most; this keeps each request small.
pub const BATCH_SIZE: usize = 500;

/// One computer's dictation totals for one local calendar day. This, and nothing else, is sent.
#[derive(Clone, Debug, PartialEq)]
pub struct DayTotal {
    pub device: String,
    pub day: String,
    pub words: i64,
    pub dictations: i64,
    pub audio_seconds: f64,
}

impl DayTotal {
    pub fn is_empty(&self) -> bool {
        self.words == 0 && self.dictations == 0 && self.audio_seconds == 0.0
    }

    fn zeroed(&self) -> DayTotal {
        DayTotal { device: self.device.clone(), day: self.day.clone(), words: 0, dictations: 0, audio_seconds: 0.0 }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceTotal {
    pub device: String,
    pub words: i64,
    pub dictations: i64,
}

/// Every computer's rows added up, with this computer's taken from its own history rather than
/// the last copy the table sent back, so a dictation made a second ago is already in it.
#[derive(Clone, Debug, PartialEq)]
pub struct CombinedTotals {
    pub words: i64,
    pub dictations: i64,
    pub audio_seconds: f64,
    pub streak_days: u32,
    /// Most words first. A name that only ever sent zeros is not a computer and is left out.
    pub devices: Vec<DeviceTotal>,
    pub this_device: String,
}

impl CombinedTotals {
    pub fn computers(&self) -> usize {
        self.devices.len()
    }

    pub fn here(&self) -> Option<&DeviceTotal> {
        self.devices.iter().find(|d| d.device == self.this_device)
    }

    /// "Mac 20,110 · DESK-01 15,002 · LAPTOP-02 6,091"
    pub fn breakdown(&self) -> String {
        self.devices.iter().map(|d| format!("{} {}", d.device, grouped(d.words))).collect::<Vec<_>>().join(" · ")
    }
}

/// "2026-09-25": the calendar date of `at` in the given time zone.
pub fn day_string<Tz: TimeZone>(at: &DateTime<Utc>, tz: &Tz) -> String {
    let d = at.with_timezone(tz);
    format!("{:04}-{:02}-{:02}", d.year(), d.month(), d.day())
}

fn round2(x: f64) -> f64 {
    (x * 100.0).round() / 100.0
}

/// This computer's days, oldest first, one row per date with at least one dictation. Words are
/// `HistoryEntry::word_count`, the same count the Dictation tiles show.
pub fn from_history<Tz: TimeZone>(entries: &[HistoryEntry], device: &str, tz: &Tz) -> Vec<DayTotal> {
    let mut days: BTreeMap<String, (i64, i64, f64)> = BTreeMap::new();
    for e in entries {
        let t = days.entry(day_string(&e.timestamp, tz)).or_default();
        t.0 += e.word_count() as i64;
        t.1 += 1;
        t.2 += e.audio_seconds;
    }
    // Rounded so the same history always makes an equal row: "changed since it was sent" is
    // decided by comparing rows, and a sum of doubles is not worth a resend in its last digit.
    days.into_iter()
        .map(|(day, (words, dictations, audio))| DayTotal { device: device.into(), day, words, dictations, audio_seconds: round2(audio) })
        .collect()
}

pub fn combine(remote: &[DayTotal], local: &[DayTotal], device: &str, today: &str) -> CombinedTotals {
    let rows = remote.iter().filter(|r| r.device != device).chain(local.iter());
    let (mut words, mut dictations, mut audio) = (0i64, 0i64, 0.0f64);
    let mut active = HashSet::new();
    let mut per_device: HashMap<String, DeviceTotal> = HashMap::new();
    for r in rows {
        words += r.words;
        dictations += r.dictations;
        audio += r.audio_seconds;
        if r.dictations > 0 {
            active.insert(r.day.clone());
        }
        let d = per_device.entry(r.device.clone()).or_insert_with(|| DeviceTotal { device: r.device.clone(), words: 0, dictations: 0 });
        d.words += r.words;
        d.dictations += r.dictations;
    }
    let mut devices: Vec<DeviceTotal> = per_device.into_values().filter(|d| d.dictations > 0).collect();
    devices.sort_by(|a, b| b.words.cmp(&a.words).then_with(|| a.device.cmp(&b.device)));
    CombinedTotals { words, dictations, audio_seconds: round2(audio), streak_days: streak(&active, today), devices, this_device: device.into() }
}

/// Consecutive days with a dictation on any computer, ending today, or yesterday when today has
/// none yet.
pub fn streak(days: &HashSet<String>, today: &str) -> u32 {
    let mut day = today.to_string();
    if !days.contains(&day) {
        match previous_day(&day) {
            Some(d) => day = d,
            None => return 0,
        }
    }
    let mut n = 0;
    while days.contains(&day) {
        n += 1;
        match previous_day(&day) {
            Some(d) => day = d,
            None => break,
        }
    }
    n
}

fn previous_day(day: &str) -> Option<String> {
    let d = NaiveDate::parse_from_str(day, "%Y-%m-%d").ok()?;
    d.pred_opt().map(|p| p.format("%Y-%m-%d").to_string())
}

/// 20110 as "20,110".
pub fn grouped(n: i64) -> String {
    let digits = n.unsigned_abs().to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    if n < 0 {
        format!("-{out}")
    } else {
        out
    }
}

/// The rows to send: each day whose totals differ from what was sent, and zeros for a day that
/// was sent this run and has since gone from the history.
pub fn plan(local: &[DayTotal], sent: &HashMap<String, DayTotal>) -> Vec<DayTotal> {
    let mut rows: Vec<DayTotal> = local.iter().filter(|r| sent.get(&r.day) != Some(r)).cloned().collect();
    let present: HashSet<&str> = local.iter().map(|r| r.day.as_str()).collect();
    let mut gone: Vec<&DayTotal> = sent.values().filter(|r| !present.contains(r.day.as_str()) && !r.is_empty()).collect();
    gone.sort_by(|a, b| a.day.cmp(&b.day));
    rows.extend(gone.into_iter().map(DayTotal::zeroed));
    rows
}

pub fn upsert_request(config: &SyncConfig, rows: &[DayTotal], now: DateTime<Utc>) -> HttpRequest {
    let stamp = now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let body: Vec<Value> = rows
        .iter()
        .map(|r| json!({"device": r.device, "day": r.day, "words": r.words, "dictations": r.dictations, "audio_seconds": r.audio_seconds, "updated_at": stamp}))
        .collect();
    let request = HttpRequest::post(format!("{}/{TABLE}?on_conflict=device,day", config.rest_base()), crate::json::compact(&body).unwrap().into_bytes())
        .header("Content-Type", "application/json")
        .header("Prefer", "resolution=merge-duplicates,return=minimal");
    config.authorize(request)
}

pub fn page_request(config: &SyncConfig, offset: usize, limit: usize) -> HttpRequest {
    config.authorize(HttpRequest::get(format!(
        "{}/{TABLE}?select=device,day,words,dictations,audio_seconds&order=device.asc,day.asc&limit={limit}&offset={offset}",
        config.rest_base()
    )))
}

/// A number, zero when the key is missing, None when it holds something else.
fn number(v: Option<&Value>) -> Option<f64> {
    match v {
        None => Some(0.0),
        Some(Value::Number(n)) => n.as_f64(),
        Some(Value::Bool(b)) => Some(if *b { 1.0 } else { 0.0 }),
        Some(_) => None,
    }
}

/// The table's rows, or None when the answer is not a list. A row that will not read is skipped
/// rather than failing the rest.
pub fn parse_rows(body: &[u8]) -> Option<Vec<DayTotal>> {
    let Ok(Value::Array(rows)) = serde_json::from_slice::<Value>(body) else { return None };
    Some(
        rows.iter()
            .filter_map(|o| {
                let device = o.get("device")?.as_str().filter(|s| !s.is_empty())?;
                let day = o.get("day")?.as_str().filter(|s| !s.is_empty())?;
                let words = number(o.get("words"))?;
                let dictations = number(o.get("dictations"))?;
                let audio = number(o.get("audio_seconds"))?;
                Some(DayTotal { device: device.into(), day: day.into(), words: words as i64, dictations: dictations as i64, audio_seconds: audio })
            })
            .collect(),
    )
}

/// What the Settings pane says about the shared totals.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SyncStatus {
    pub on: bool,
    pub device: Option<String>,
    pub last_sync: Option<DateTime<Utc>>,
    pub error: Option<String>,
}

/// This computer's side of the totals, for the app's life. "Changed" is decided against what
/// this run has already sent, kept in memory: the first send after a launch is every day in the
/// history, which is also how a new computer backfills, and after that a dictation sends only
/// its own day. A day that vanishes from the history is sent as zeros. A day that is simply
/// absent is never zeroed: an app that launched against an empty or unreadable data folder must
/// not wipe what the table holds. Calls are made one at a time from one worker thread.
#[derive(Default)]
pub struct TotalsSync {
    sent: HashMap<String, DayTotal>,
    sent_for: Option<String>,
    remote: Vec<DayTotal>,
    remote_for: Option<String>,
    pub status: SyncStatus,
}

impl TotalsSync {
    pub fn new() -> Self {
        Self::default()
    }

    /// Every computer's totals, or None before the first read has come back.
    pub fn combined<Tz: TimeZone>(&self, config: &SyncConfig, history: &[HistoryEntry], tz: &Tz, now: DateTime<Utc>) -> Option<CombinedTotals> {
        if self.remote_for.as_deref() != Some(config.identity().as_str()) {
            return None;
        }
        let local = from_history(history, &config.device, tz);
        Some(combine(&self.remote, &local, &config.device, &day_string(&now, tz)))
    }

    /// Sends the days that changed. Returns a line for the log, if anything happened worth one.
    pub fn push<Tz: TimeZone>(&mut self, config: &SyncConfig, history: &[HistoryEntry], tz: &Tz, now: DateTime<Utc>, net: &dyn Transport) -> Option<String> {
        if self.sent_for.as_deref() != Some(config.identity().as_str()) {
            self.sent.clear();
            self.sent_for = Some(config.identity());
        }
        let local = from_history(history, &config.device, tz);
        let rows = plan(&local, &self.sent);
        if rows.is_empty() {
            // Nothing to send is still news when the file has just appeared: the totals are on.
            if !self.status.on {
                self.status = SyncStatus { on: true, device: Some(config.device.clone()), last_sync: None, error: None };
            }
            return None;
        }
        let first = self.sent.is_empty();
        for batch in rows.chunks(BATCH_SIZE) {
            let result = net.send(&upsert_request(config, batch, now));
            if let Some(why) = problem(&result, 20) {
                return Some(self.fail(config, "could not send this computer's totals", &why));
            }
            for r in batch {
                if r.is_empty() {
                    self.sent.remove(&r.day);
                } else {
                    self.sent.insert(r.day.clone(), r.clone());
                }
            }
        }
        self.status = SyncStatus { on: true, device: Some(config.device.clone()), last_sync: Some(now), error: None };
        Some(if first {
            format!("shared totals: sent {} day{} as {}, the first send since Lin Flow started", rows.len(), if rows.len() == 1 { "" } else { "s" }, config.device)
        } else {
            format!("shared totals: sent {} as {}", rows.iter().map(|r| r.day.as_str()).collect::<Vec<_>>().join(", "), config.device)
        })
    }

    /// Reads every computer's rows. Page after page until one comes back empty: it does not stop
    /// at a short page, since the project's "max rows" setting can be lower than the page size. A
    /// hundred pages is a cap for a server that ignores offset.
    pub fn pull(&mut self, config: &SyncConfig, now: DateTime<Utc>, net: &dyn Transport) -> Option<String> {
        let mut rows: BTreeMap<String, DayTotal> = BTreeMap::new();
        let mut offset = 0;
        for _ in 0..100 {
            let result = net.send(&page_request(config, offset, PAGE_SIZE));
            if let Some(why) = problem(&result, 20) {
                return Some(self.fail(config, "could not read the shared totals", &why));
            }
            let Some(page) = parse_rows(&result.unwrap().body) else {
                return Some(self.fail(config, "could not read the shared totals", "the table did not answer with a list of rows"));
            };
            if page.is_empty() {
                break;
            }
            offset += page.len();
            // A row written by another computer mid-read can shift a page; the key keeps one copy.
            for r in page {
                rows.insert(format!("{}\n{}", r.device, r.day), r);
            }
        }
        self.remote = rows.into_values().collect();
        self.remote_for = Some(config.identity());
        self.status = SyncStatus { on: true, device: Some(config.device.clone()), last_sync: Some(now), error: None };
        None
    }

    fn fail(&mut self, config: &SyncConfig, what: &str, why: &str) -> String {
        self.status = SyncStatus { on: true, device: Some(config.device.clone()), last_sync: self.status.last_sync, error: Some(why.into()) };
        format!("shared totals: {what}: {why}")
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::net::{HttpResponse, NetError};
    use std::sync::Mutex;

    /// A PostgREST stand-in: upserts on the conflict columns, pages with offset and limit.
    #[derive(Default)]
    pub struct FakeTable {
        pub rows: Mutex<Vec<Value>>,
        pub requests: Mutex<Vec<HttpRequest>>,
        pub fail_with: Mutex<Option<u16>>,
        pub conflict: Vec<&'static str>,
        pub max_rows: usize,
    }

    impl Transport for FakeTable {
        fn send(&self, request: &HttpRequest) -> Result<HttpResponse, NetError> {
            self.requests.lock().unwrap().push(request.clone());
            if let Some(code) = *self.fail_with.lock().unwrap() {
                return Ok(HttpResponse { status: code, body: b"{\"message\":\"nope\"}".to_vec() });
            }
            let mut rows = self.rows.lock().unwrap();
            if request.method == "POST" {
                let incoming: Vec<Value> = serde_json::from_slice(request.body.as_ref().unwrap()).unwrap();
                for row in &incoming {
                    let same = |r: &Value| self.conflict.iter().all(|k| r[*k] == row[*k]);
                    match rows.iter_mut().find(|r| same(r)) {
                        Some(r) => *r = row.clone(),
                        None => rows.push(row.clone()),
                    }
                }
                let back = if request.header_value("Prefer").unwrap_or("").contains("representation") { serde_json::to_vec(&incoming).unwrap() } else { vec![] };
                return Ok(HttpResponse { status: 201, body: back });
            }
            let q = |name: &str| request.url.split(['?', '&']).find_map(|p| p.strip_prefix(&format!("{name}="))).and_then(|v| v.parse::<usize>().ok());
            let (offset, limit) = (q("offset").unwrap_or(0), q("limit").unwrap_or(usize::MAX).min(self.max_rows.max(1)));
            let page: Vec<Value> = rows.iter().skip(offset).take(limit).cloned().collect();
            Ok(HttpResponse { status: 200, body: serde_json::to_vec(&page).unwrap() })
        }
    }

    fn entry(text: &str, at: &str, audio: f64) -> HistoryEntry {
        let mut e = HistoryEntry::new(text, text, "m", audio, 0.1);
        e.timestamp = DateTime::parse_from_rfc3339(at).unwrap().with_timezone(&Utc);
        e
    }

    fn config(device: &str) -> SyncConfig {
        SyncConfig { url: "https://x.supabase.co".into(), key: "sb_publishable_k".into(), device: device.into() }
    }

    #[test]
    fn days_are_local_and_rows_round() {
        let tz = chrono::FixedOffset::west_opt(7 * 3600).unwrap();
        let h = vec![entry("one two three", "2026-10-02T06:59:00Z", 1.111), entry("four", "2026-10-02T07:01:00Z", 2.222)];
        let days = from_history(&h, "Mac", &tz);
        assert_eq!(days.iter().map(|d| (d.day.as_str(), d.words)).collect::<Vec<_>>(), vec![("2026-10-01", 3), ("2026-10-02", 1)]);
        assert_eq!(days[0].audio_seconds, 1.11);
    }

    #[test]
    fn three_computers_add_up_and_the_streak_crosses_them() {
        let tz = Utc;
        let net = FakeTable { conflict: vec!["device", "day"], max_rows: 2, ..Default::default() };
        let now = DateTime::parse_from_rfc3339("2026-10-02T12:00:00Z").unwrap().with_timezone(&Utc);
        for (device, day, words) in [("DESK-01", "2026-10-01", 10), ("LAPTOP-02", "2026-09-30", 5)] {
            let mut s = TotalsSync::new();
            let h = vec![entry(&vec!["w"; words].join(" "), &format!("{day}T10:00:00Z"), 1.0)];
            s.push(&config(device), &h, &tz, now, &net);
        }
        let mut mac = TotalsSync::new();
        let h = vec![entry("a b c", "2026-10-02T09:00:00Z", 1.0)];
        assert!(mac.push(&config("Mac"), &h, &tz, now, &net).unwrap().contains("first send"));
        assert_eq!(mac.push(&config("Mac"), &h, &tz, now, &net), None, "nothing changed, nothing sent");
        assert_eq!(mac.pull(&config("Mac"), now, &net), None);
        let c = mac.combined(&config("Mac"), &h, &tz, now).unwrap();
        assert_eq!((c.words, c.dictations, c.streak_days, c.computers()), (18, 3, 3, 3));
        assert_eq!(c.breakdown(), "DESK-01 10 · LAPTOP-02 5 · Mac 3");
    }

    #[test]
    fn a_deleted_day_is_sent_as_zeros_and_a_failure_is_reported() {
        let net = FakeTable { conflict: vec!["device", "day"], max_rows: 1000, ..Default::default() };
        let now = Utc::now();
        let mut s = TotalsSync::new();
        let h = vec![entry("a b", "2026-09-01T10:00:00Z", 1.0), entry("c", "2026-09-02T10:00:00Z", 1.0)];
        s.push(&config("Mac"), &h, &Utc, now, &net);
        s.push(&config("Mac"), &h[1..], &Utc, now, &net);
        let rows = net.rows.lock().unwrap().clone();
        assert_eq!(rows.iter().find(|r| r["day"] == "2026-09-01").unwrap()["words"], 0);
        let mut fresh = TotalsSync::new();
        assert_eq!(fresh.push(&config("Mac"), &[], &Utc, now, &net), None, "a launch on an empty history zeroes nothing");
        *net.fail_with.lock().unwrap() = Some(401);
        let line = s.pull(&config("Mac"), now, &net).unwrap();
        assert!(line.contains("HTTP 401"), "{line}");
        assert!(s.status.error.is_some());
    }

    #[test]
    fn rows_that_will_not_read_are_skipped() {
        let rows = parse_rows(br#"[{"device":"Mac","day":"2026-10-01","words":3},{"device":"","day":"x"},{"device":"A","day":"d","words":null}]"#).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].dictations, 0);
        assert!(parse_rows(b"{}").is_none());
        assert_eq!(grouped(20110), "20,110");
        assert_eq!(grouped(-1234567), "-1,234,567");
    }
}
