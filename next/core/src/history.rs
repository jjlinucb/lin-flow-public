//! `history.jsonl`: one dictation per line, in the shape both current apps write, so the file
//! moves between all three computers and the new app unchanged: camelCase keys, an ISO 8601 UTC
//! timestamp with whole seconds (Swift's `.iso8601` refuses fractions), an uppercase UUID, and
//! no key for a missing value. One WAV per dictation sits in `recordings/`.

use crate::fsutil::write_atomic;
use chrono::{DateTime, Duration, Local, NaiveDate, SecondsFormat, TimeZone, Utc};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::HashSet;
use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    #[serde(default)]
    pub id: String,
    #[serde(serialize_with = "ser_date", deserialize_with = "de_date")]
    pub timestamp: DateTime<Utc>,
    #[serde(default)]
    pub raw: String,
    pub text: String,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub audio_seconds: f64,
    #[serde(default)]
    pub inference_seconds: f64,
    /// File name inside `recordings/`, when the audio was kept.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_file: Option<String>,
    /// The text before a transform rewrote it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub original: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transform: Option<String>,
    /// How the take was made: the microphone, how long after the key the first audio came, how
    /// noisy the room was, and the app it went to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_device: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub first_audio_seconds: Option<f64>,
    #[serde(rename = "snrDB", default, skip_serializing_if = "Option::is_none")]
    pub snr_db: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub noise_floor: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
}

fn ser_date<S: Serializer>(d: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str(&d.to_rfc3339_opts(SecondsFormat::Secs, true))
}

fn de_date<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
    let s = String::deserialize(d)?;
    DateTime::parse_from_rfc3339(&s).map(|t| t.with_timezone(&Utc)).map_err(serde::de::Error::custom)
}

pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}

impl HistoryEntry {
    pub fn new(raw: &str, text: &str, model: &str, audio_seconds: f64, inference_seconds: f64) -> Self {
        HistoryEntry {
            id: new_id(),
            timestamp: Utc::now().with_nanosecond_zero(),
            raw: raw.to_string(),
            text: text.to_string(),
            model: model.to_string(),
            audio_seconds,
            inference_seconds,
            audio_file: None,
            original: None,
            transform: None,
            input_device: None,
            first_audio_seconds: None,
            snr_db: None,
            noise_floor: None,
            app: None,
        }
    }

    /// Words as the window counts them: runs between whitespace and newlines.
    pub fn word_count(&self) -> usize {
        crate::learn::words(&self.text).len()
    }

    /// Rows written before ids existed get a stable synthetic one, the same as the Mac's.
    pub fn legacy_id(timestamp: &DateTime<Utc>, text: &str) -> String {
        let mut h: u64 = 5381;
        for b in text.bytes() {
            h = h.wrapping_mul(33).wrapping_add(b as u64);
        }
        format!("legacy-{}-{}", timestamp.timestamp_millis(), h)
    }
}

trait NoNanos {
    fn with_nanosecond_zero(self) -> Self;
}

impl NoNanos for DateTime<Utc> {
    fn with_nanosecond_zero(self) -> Self {
        Utc.timestamp_opt(self.timestamp(), 0).single().unwrap_or(self)
    }
}

/// The history file and its recordings folder.
#[derive(Clone, Debug)]
pub struct History {
    pub file: PathBuf,
    pub recordings: PathBuf,
}

impl History {
    pub fn new(data_dir: &Path) -> Self {
        History { file: data_dir.join("history.jsonl"), recordings: data_dir.join("recordings") }
    }

    /// Oldest first. A row that does not parse is skipped, not fatal.
    pub fn all(&self) -> Vec<HistoryEntry> {
        let Ok(text) = fs::read_to_string(&self.file) else { return vec![] };
        parse(&text)
    }

    /// Newest first.
    pub fn recent(&self, n: usize) -> Vec<HistoryEntry> {
        let all = self.all();
        all.into_iter().rev().take(n).collect()
    }

    /// Appends one row. A hand-edited file may lack its final newline; two rows are never glued.
    pub fn append(&self, entry: &HistoryEntry) -> std::io::Result<()> {
        if let Some(dir) = self.file.parent() {
            fs::create_dir_all(dir)?;
        }
        let mut line = serde_json::to_string(entry).map_err(std::io::Error::other)?;
        line.push('\n');
        let mut f = OpenOptions::new().create(true).read(true).append(true).open(&self.file)?;
        let len = f.metadata()?.len();
        if len > 0 {
            let mut last = [0u8; 1];
            f.seek(SeekFrom::Start(len - 1))?;
            f.read_exact(&mut last)?;
            if last[0] != b'\n' {
                f.write_all(b"\n")?;
            }
        }
        f.write_all(line.as_bytes())
    }

    pub fn write_all(&self, entries: &[HistoryEntry]) -> std::io::Result<()> {
        let mut out = String::new();
        for e in entries {
            out.push_str(&serde_json::to_string(e).map_err(std::io::Error::other)?);
            out.push('\n');
        }
        write_atomic(&self.file, out.as_bytes())
    }

    /// Update only: an entry deleted while it was being transcribed again stays deleted.
    pub fn update(&self, entry: &HistoryEntry) -> std::io::Result<bool> {
        let mut entries = self.all();
        let Some(i) = entries.iter().position(|e| e.id == entry.id) else { return Ok(false) };
        entries[i] = entry.clone();
        self.write_all(&entries)?;
        Ok(true)
    }

    pub fn delete(&self, id: &str) -> std::io::Result<()> {
        let entries = self.all();
        if let Some(audio) = entries.iter().find(|e| e.id == id).and_then(|e| e.audio_file.clone()) {
            let _ = fs::remove_file(self.recordings.join(audio));
        }
        let kept: Vec<HistoryEntry> = entries.into_iter().filter(|e| e.id != id).collect();
        self.write_all(&kept)
    }

    pub fn audio_path(&self, entry: &HistoryEntry) -> Option<PathBuf> {
        let p = self.recordings.join(entry.audio_file.as_ref()?);
        p.exists().then_some(p)
    }

    /// Drops recordings older than the retention window; the rows stay, Play just goes. Zero
    /// days keeps no audio at all. Files no row points at go too once past the window, though
    /// anything from the last minute may still be in flight.
    pub fn prune_recordings(&self, days: u32, now: DateTime<Utc>) -> std::io::Result<()> {
        let cutoff = if days > 0 { now - Duration::days(days as i64) } else { DateTime::<Utc>::MAX_UTC };
        let mut entries = self.all();
        let mut changed = false;
        for e in entries.iter_mut() {
            if e.timestamp < cutoff {
                if let Some(f) = e.audio_file.take() {
                    let _ = fs::remove_file(self.recordings.join(f));
                    changed = true;
                }
            }
        }
        if changed {
            self.write_all(&entries)?;
        }
        let referenced: HashSet<String> = entries.iter().filter_map(|e| e.audio_file.clone()).collect();
        let orphan_cutoff = cutoff.min(now - Duration::seconds(60));
        if let Ok(dir) = fs::read_dir(&self.recordings) {
            for f in dir.flatten() {
                let path = f.path();
                let name = f.file_name().to_string_lossy().to_string();
                if path.extension().is_none_or(|x| x != "wav") || referenced.contains(&name) {
                    continue;
                }
                let modified: DateTime<Utc> = f.metadata().and_then(|m| m.modified()).map(DateTime::from).unwrap_or(DateTime::<Utc>::MIN_UTC);
                if modified < orphan_cutoff {
                    let _ = fs::remove_file(path);
                }
            }
        }
        Ok(())
    }
}

/// Rows from the file's text. Split on "\n" only: U+2028 inside a transcript is not a row break.
/// Duplicate ids (identical legacy rows) get a "-2", "-3" so every row stays addressable.
pub fn parse(text: &str) -> Vec<HistoryEntry> {
    let mut seen = HashSet::new();
    text.split('\n')
        .filter(|l| !l.is_empty())
        .filter_map(|line| {
            let mut e: HistoryEntry = serde_json::from_str(line).ok()?;
            if e.id.is_empty() {
                e.id = HistoryEntry::legacy_id(&e.timestamp, &e.text);
            }
            let base = e.id.clone();
            let mut id = base.clone();
            let mut n = 2;
            while seen.contains(&id) {
                id = format!("{base}-{n}");
                n += 1;
            }
            seen.insert(id.clone());
            e.id = id;
            Some(e)
        })
        .collect()
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    pub count: usize,
    pub total_words: usize,
    /// Words per minute of speech, over dictations longer than a second.
    pub words_per_minute: usize,
    /// Consecutive days ending today (or yesterday) with at least one dictation.
    pub streak_days: usize,
}

pub fn stats<Tz: TimeZone>(entries: &[HistoryEntry], now: DateTime<Tz>) -> Stats {
    let tz = now.timezone();
    let mut s = Stats { count: entries.len(), ..Stats::default() };
    let (mut words, mut minutes) = (0.0, 0.0);
    for e in entries {
        let w = e.word_count();
        s.total_words += w;
        if e.audio_seconds > 1.0 {
            words += w as f64;
            minutes += e.audio_seconds / 60.0;
        }
    }
    s.words_per_minute = if minutes > 0.0 { (words / minutes).round() as usize } else { 0 };
    let days: HashSet<NaiveDate> = entries.iter().map(|e| e.timestamp.with_timezone(&tz).date_naive()).collect();
    let mut day = now.date_naive();
    if !days.contains(&day) {
        day = day.pred_opt().unwrap();
    }
    while days.contains(&day) {
        s.streak_days += 1;
        day = day.pred_opt().unwrap();
    }
    s
}

pub fn stats_now(entries: &[HistoryEntry]) -> Stats {
    stats(entries, Local::now())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    #[test]
    fn reads_the_macs_rows_and_writes_the_same_shape() {
        let row = r#"{"audioSeconds":2.5,"id":"ABC","inferenceSeconds":0.1,"model":"parakeet","raw":"hi","text":"Hi.","timestamp":"2026-09-06T17:51:29Z"}"#;
        let e = &parse(row)[0];
        assert_eq!(e.text, "Hi.");
        let out = serde_json::to_string(e).unwrap();
        assert!(out.contains(r#""timestamp":"2026-09-06T17:51:29Z""#));
        assert!(!out.contains("audioFile"), "a missing value has no key");
        assert_eq!(parse(&out)[0], *e);
    }

    #[test]
    fn legacy_rows_get_distinct_ids() {
        let row = r#"{"text":"Same.","timestamp":"2026-09-06T17:51:29Z"}"#;
        let rows = parse(&format!("{row}\n{row}\n"));
        assert_eq!(rows.len(), 2);
        assert_ne!(rows[0].id, rows[1].id);
        let ms = DateTime::parse_from_rfc3339("2026-09-06T17:51:29Z").unwrap().timestamp_millis();
        assert!(rows[0].id.starts_with(&format!("legacy-{ms}-")));
    }

    #[test]
    fn append_never_glues_rows() {
        let dir = tempdir();
        let h = History::new(&dir);
        fs::write(&h.file, r#"{"text":"A.","timestamp":"2026-09-06T17:51:29Z"}"#).unwrap();
        h.append(&HistoryEntry::new("b", "B.", "m", 1.0, 0.1)).unwrap();
        assert_eq!(h.all().len(), 2);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn streak_counts_back_from_yesterday() {
        let now = Utc.with_ymd_and_hms(2026, 10, 2, 12, 0, 0).unwrap();
        let mk = |d: u32| HistoryEntry { timestamp: Utc.with_ymd_and_hms(2026, 10, d, 12, 0, 0).unwrap(), ..HistoryEntry::new("", "a b", "", 2.0, 0.0) };
        assert_eq!(stats(&[mk(1)], now).streak_days, 1);
        assert_eq!(stats(&[mk(1), mk(1)], now).count, 2);
        assert_eq!(stats(&[mk(2), mk(1)], now).streak_days, 2);
        assert_eq!(stats(&[mk(2)], now).words_per_minute, 60);
    }

    pub(crate) fn tempdir() -> PathBuf {
        let d = std::env::temp_dir().join(format!("linflow-test-{}", new_id()));
        fs::create_dir_all(&d).unwrap();
        d
    }
}
