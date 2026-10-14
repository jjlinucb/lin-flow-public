//! Meeting notes on disk: one folder per meeting under `notes/`, in the same files both current
//! apps write, so a note opens in either app and in any text editor.
//!
//! `note.json` (metadata), `transcript.jsonl` (segments as they land, then rewritten from the
//! audio once the meeting ends, the live version kept as `transcript-live.jsonl`), `notes.md`
//! (what was typed), `summary.md`, `running-notes.md`, `questions.json` (Ask Claude),
//! `events.log` (gaps, restarts, failures), and the audio as `audio-mic.wav` and
//! `audio-system.wav`.

use crate::fsutil::write_atomic;
use crate::{json, wav};
use chrono::{DateTime, Duration, Local, SecondsFormat, Utc};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

fn ser_date<S: Serializer>(d: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str(&d.to_rfc3339_opts(SecondsFormat::Secs, true))
}

fn de_date<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
    let s = String::deserialize(d)?;
    DateTime::parse_from_rfc3339(&s).map(|t| t.with_timezone(&Utc)).map_err(serde::de::Error::custom)
}

fn ser_opt_date<S: Serializer>(d: &Option<DateTime<Utc>>, s: S) -> Result<S::Ok, S::Error> {
    match d {
        Some(d) => ser_date(d, s),
        None => s.serialize_none(),
    }
}

fn de_opt_date<'de, D: Deserializer<'de>>(d: D) -> Result<Option<DateTime<Utc>>, D::Error> {
    let s: Option<String> = Option::deserialize(d)?;
    match s {
        Some(s) => DateTime::parse_from_rfc3339(&s).map(|t| Some(t.with_timezone(&Utc))).map_err(serde::de::Error::custom),
        None => Ok(None),
    }
}

/// Seconds-precision now: Swift's ISO 8601 decoder refuses fractions.
pub fn now() -> DateTime<Utc> {
    DateTime::from_timestamp(Utc::now().timestamp(), 0).unwrap()
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeetingNote {
    pub id: String,
    pub title: String,
    #[serde(serialize_with = "ser_date", deserialize_with = "de_date")]
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none", serialize_with = "ser_opt_date", deserialize_with = "de_opt_date")]
    pub ended_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub duration_seconds: f64,
    #[serde(default = "yes")]
    pub used_microphone: bool,
    #[serde(default = "yes")]
    pub used_system_audio: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary_model: Option<String>,
    /// Set once the transcript was rewritten from the saved audio.
    #[serde(default, skip_serializing_if = "Option::is_none", serialize_with = "ser_opt_date", deserialize_with = "de_opt_date")]
    pub transcribed_from_audio_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcript_model: Option<String>,
    /// The app did not stop this recording; the next launch closed it from what was on disk.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recovered: Option<bool>,
}

fn yes() -> bool {
    true
}

impl MeetingNote {
    pub fn new(title: &str) -> MeetingNote {
        MeetingNote {
            id: crate::history::new_id(),
            title: title.to_string(),
            created_at: now(),
            ended_at: None,
            duration_seconds: 0.0,
            used_microphone: true,
            used_system_audio: true,
            summary_model: None,
            transcribed_from_audio_at: None,
            transcript_model: None,
            recovered: None,
        }
    }

    /// "Meeting Oct 2, 9:34 AM", the default title, in local time.
    pub fn default_title(at: DateTime<Local>) -> String {
        format!("Meeting {}", at.format("%b %-d, %-I:%M %p"))
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TranscriptSegment {
    pub id: String,
    /// Seconds from the start of the note.
    pub start: f64,
    pub end: f64,
    /// "You" (microphone) or "Others" (system audio).
    pub speaker: String,
    pub text: String,
}

impl TranscriptSegment {
    pub fn new(start: f64, end: f64, speaker: &str, text: &str) -> Self {
        TranscriptSegment { id: crate::history::new_id(), start, end, speaker: speaker.into(), text: text.into() }
    }

    pub fn timestamp_label(&self) -> String {
        clock(self.start)
    }
}

/// "1:05", or "1:02:05" past an hour.
pub fn clock(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, (s % 3600) / 60, s % 60)
    } else {
        format!("{}:{:02}", s / 60, s % 60)
    }
}

/// The transcript as readable lines, "[3:05] You: ...", as the summarizer and the export use it.
pub fn transcript_text(segments: &[TranscriptSegment], timestamps: bool) -> String {
    segments
        .iter()
        .map(|s| if timestamps { format!("[{}] {}: {}", s.timestamp_label(), s.speaker, s.text) } else { format!("{}: {}", s.speaker, s.text) })
        .collect::<Vec<_>>()
        .join("\n")
}

/// A question asked about a meeting and Claude's answer (`questions.json`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionTurn {
    pub question: String,
    pub answer: String,
    #[serde(serialize_with = "ser_date", deserialize_with = "de_date")]
    pub asked_at: DateTime<Utc>,
}

/// The notes folder.
#[derive(Clone, Debug)]
pub struct NotesStore {
    pub dir: PathBuf,
}

impl NotesStore {
    pub fn new(data_dir: &Path) -> Self {
        NotesStore { dir: data_dir.join("notes") }
    }

    pub fn folder(&self, id: &str) -> PathBuf {
        self.dir.join(id)
    }
    pub fn transcript_path(&self, id: &str) -> PathBuf {
        self.folder(id).join("transcript.jsonl")
    }
    pub fn live_transcript_path(&self, id: &str) -> PathBuf {
        self.folder(id).join("transcript-live.jsonl")
    }
    pub fn notes_path(&self, id: &str) -> PathBuf {
        self.folder(id).join("notes.md")
    }
    pub fn summary_path(&self, id: &str) -> PathBuf {
        self.folder(id).join("summary.md")
    }
    pub fn running_notes_path(&self, id: &str) -> PathBuf {
        self.folder(id).join("running-notes.md")
    }
    pub fn questions_path(&self, id: &str) -> PathBuf {
        self.folder(id).join("questions.json")
    }
    pub fn events_path(&self, id: &str) -> PathBuf {
        self.folder(id).join("events.log")
    }
    /// "mic" or "system".
    pub fn audio_path(&self, id: &str, source: &str) -> PathBuf {
        self.folder(id).join(format!("audio-{source}.wav"))
    }

    pub fn has_audio(&self, id: &str) -> bool {
        ["mic", "system"].iter().any(|s| self.audio_path(id, s).exists())
    }

    /// Newest first.
    pub fn list(&self) -> Vec<MeetingNote> {
        let Ok(dirs) = fs::read_dir(&self.dir) else { return vec![] };
        let mut notes: Vec<MeetingNote> = dirs.flatten().filter_map(|d| self.load_from(&d.path())).collect();
        notes.sort_by_key(|n| std::cmp::Reverse(n.created_at));
        notes
    }

    fn load_from(&self, folder: &Path) -> Option<MeetingNote> {
        serde_json::from_str(&fs::read_to_string(folder.join("note.json")).ok()?).ok()
    }

    pub fn load(&self, id: &str) -> Option<MeetingNote> {
        self.load_from(&self.folder(id))
    }

    pub fn create(&self, title: &str) -> std::io::Result<MeetingNote> {
        let note = MeetingNote::new(title);
        self.save(&note)?;
        Ok(note)
    }

    /// Pretty-printed with sorted keys, as the Mac writes it.
    pub fn save(&self, note: &MeetingNote) -> std::io::Result<()> {
        let text = json::pretty_sorted(note).map_err(std::io::Error::other)?;
        write_atomic(&self.folder(&note.id).join("note.json"), text.as_bytes())
    }

    /// Deleting is one gesture from the list, so it goes to the Trash or Recycle Bin, which the
    /// shell supplies, and is erased only where there is nowhere to move it.
    pub fn delete(&self, id: &str, trash: impl Fn(&Path) -> std::io::Result<()>) -> std::io::Result<()> {
        let folder = self.folder(id);
        if !folder.exists() {
            return Ok(());
        }
        trash(&folder).or_else(|_| fs::remove_dir_all(&folder))
    }

    fn append_line(path: &Path, text: &str) -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        OpenOptions::new().create(true).append(true).open(path)?.write_all(text.as_bytes())
    }

    pub fn append_segment(&self, id: &str, segment: &TranscriptSegment) -> std::io::Result<()> {
        let mut line = json::compact(segment).map_err(std::io::Error::other)?;
        line.push('\n');
        Self::append_line(&self.transcript_path(id), &line)
    }

    /// One dated line in the note's `events.log`: starts and stops, gaps filled with silence,
    /// source restarts, write failures, recoveries.
    pub fn append_event(&self, id: &str, text: &str) -> std::io::Result<()> {
        Self::append_line(&self.events_path(id), &format!("{} {}\n", Local::now().format("%Y-%m-%d %H:%M:%S"), text))
    }

    pub fn events(&self, id: &str) -> String {
        fs::read_to_string(self.events_path(id)).unwrap_or_default()
    }

    /// Oldest first, by start.
    pub fn transcript(&self, id: &str) -> Vec<TranscriptSegment> {
        read_segments(&self.transcript_path(id))
    }

    /// Replaces the transcript with one made from the saved audio. The first time, the live one
    /// is kept beside it as `transcript-live.jsonl`: nothing is thrown away.
    pub fn replace_transcript(&self, id: &str, segments: &[TranscriptSegment], model: &str) -> std::io::Result<()> {
        let main = self.transcript_path(id);
        let live = self.live_transcript_path(id);
        if main.exists() && !live.exists() {
            fs::rename(&main, &live)?;
        }
        let mut out = String::new();
        for s in segments {
            out.push_str(&json::compact(s).map_err(std::io::Error::other)?);
            out.push('\n');
        }
        write_atomic(&main, out.as_bytes())?;
        if let Some(mut note) = self.load(id) {
            note.transcribed_from_audio_at = Some(now());
            note.transcript_model = Some(model.to_string());
            self.save(&note)?;
        }
        self.append_event(id, &format!("transcript rewritten from the audio: {} segments ({model})", segments.len()))
    }

    pub fn notes_text(&self, id: &str) -> String {
        fs::read_to_string(self.notes_path(id)).unwrap_or_default()
    }
    pub fn save_notes_text(&self, id: &str, text: &str) -> std::io::Result<()> {
        write_atomic(&self.notes_path(id), text.as_bytes())
    }
    pub fn summary(&self, id: &str) -> Option<String> {
        fs::read_to_string(self.summary_path(id)).ok()
    }
    pub fn save_summary(&self, id: &str, text: &str) -> std::io::Result<()> {
        write_atomic(&self.summary_path(id), text.as_bytes())
    }
    pub fn running_notes(&self, id: &str) -> String {
        fs::read_to_string(self.running_notes_path(id)).unwrap_or_default()
    }
    pub fn append_running_notes(&self, id: &str, markdown: &str) -> std::io::Result<()> {
        if markdown.is_empty() {
            return Ok(());
        }
        Self::append_line(&self.running_notes_path(id), markdown)
    }
    pub fn questions(&self, id: &str) -> Vec<QuestionTurn> {
        fs::read_to_string(self.questions_path(id)).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
    }
    pub fn save_questions(&self, id: &str, turns: &[QuestionTurn]) -> std::io::Result<()> {
        write_atomic(&self.questions_path(id), json::pretty(turns).map_err(std::io::Error::other)?.as_bytes())
    }

    /// Closes notes the app never stopped: a crash, a force quit, a dead battery. Repairs the WAV
    /// headers from the file sizes, takes the duration from the longest track or the last
    /// transcript line, and stamps an approximate end. A note created but never recorded is left
    /// alone. Run once at launch, before anything records.
    pub fn recover_unfinished(&self) -> Vec<MeetingNote> {
        let mut recovered = Vec::new();
        for mut note in self.list().into_iter().filter(|n| n.ended_at.is_none()) {
            let mut duration: f64 = 0.0;
            let mut had_audio = false;
            for source in ["mic", "system"] {
                let path = self.audio_path(&note.id, source);
                if !path.exists() {
                    continue;
                }
                had_audio = true;
                let _ = wav::repair_header(&path);
                duration = duration.max(wav::duration(&path).unwrap_or(0.0));
            }
            let last_line = self.transcript(&note.id).last().map_or(0.0, |s| s.end);
            duration = duration.max(last_line);
            if !had_audio && last_line <= 0.0 {
                continue;
            }
            note.duration_seconds = duration;
            note.ended_at = Some(note.created_at + Duration::milliseconds((duration * 1000.0) as i64));
            note.recovered = Some(true);
            if self.save(&note).is_ok() {
                let _ = self.append_event(&note.id, &format!("recovered after an unclean stop with {} s of audio", duration as i64));
                recovered.push(note);
            }
        }
        recovered
    }

    /// Everything about a note as one Markdown document.
    pub fn markdown(&self, note: &MeetingNote) -> String {
        let mut md = format!("# {}\n\n", note.title);
        md.push_str(&note.created_at.with_timezone(&Local).format("%A, %B %-d, %Y at %-I:%M %p").to_string());
        if note.duration_seconds > 0.0 {
            md.push_str(&format!(" · {} min", (note.duration_seconds / 60.0) as i64));
        }
        md.push_str("\n\n");
        if let Some(summary) = self.summary(&note.id).filter(|s| !s.trim().is_empty()) {
            md.push_str(&format!("## Summary\n\n{}\n\n", summary.trim()));
        }
        let notes = self.notes_text(&note.id);
        if !notes.trim().is_empty() {
            md.push_str(&format!("## My notes\n\n{}\n\n", notes.trim()));
        }
        let running = self.running_notes(&note.id);
        if !running.trim().is_empty() {
            md.push_str(&format!("## Running notes\n\n{}\n\n", running.trim()));
        }
        let segments = self.transcript(&note.id);
        if !segments.is_empty() {
            md.push_str(&format!("## Transcript\n\n{}\n", transcript_text(&segments, true)));
        }
        md
    }
}

pub fn read_segments(path: &Path) -> Vec<TranscriptSegment> {
    let Ok(text) = fs::read_to_string(path) else { return vec![] };
    let mut segs: Vec<TranscriptSegment> = text.split('\n').filter(|l| !l.is_empty()).filter_map(|l| serde_json::from_str(l).ok()).collect();
    segs.sort_by(|a, b| a.start.partial_cmp(&b.start).unwrap_or(std::cmp::Ordering::Equal));
    segs
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_macs_note_and_writes_the_same_shape() {
        let dir = crate::history::tests::tempdir();
        let store = NotesStore::new(&dir);
        let id = "37413F03-7F54-479B-AAC4-B3564C536CB4";
        // As the Mac app wrote it, byte for byte.
        let mac = r#"{
  "createdAt" : "2026-09-30T17:24:02Z",
  "durationSeconds" : 1762.4754419326782,
  "endedAt" : "2026-09-30T17:30:22Z",
  "id" : "37413F03-7F54-479B-AAC4-B3564C536CB4",
  "summaryModel" : "Apple Intelligence (on-device)",
  "title" : "Meeting Sep 30, 10:24 AM",
  "transcribedFromAudioAt" : "2026-10-03T00:17:13Z",
  "transcriptModel" : "Parakeet · parakeet-tdt-0.6b-v3-q8_0",
  "usedMicrophone" : true,
  "usedSystemAudio" : true
}"#;
        fs::create_dir_all(store.folder(id)).unwrap();
        fs::write(store.folder(id).join("note.json"), mac).unwrap();
        let note = store.load(id).unwrap();
        assert_eq!(note.title, "Meeting Sep 30, 10:24 AM");
        store.save(&note).unwrap();
        assert_eq!(fs::read_to_string(store.folder(id).join("note.json")).unwrap(), mac);
        let mut bare = note.clone();
        bare.summary_model = None;
        assert!(!json::pretty_sorted(&bare).unwrap().contains("summaryModel"), "no key for a missing value");
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn replacing_the_transcript_keeps_the_live_one() {
        let dir = crate::history::tests::tempdir();
        let store = NotesStore::new(&dir);
        let note = store.create("Standup").unwrap();
        store.append_segment(&note.id, &TranscriptSegment::new(1.0, 2.0, "You", "live")).unwrap();
        store.replace_transcript(&note.id, &[TranscriptSegment::new(1.0, 2.0, "You", "better")], "Parakeet").unwrap();
        assert_eq!(store.transcript(&note.id)[0].text, "better");
        assert_eq!(read_segments(&store.live_transcript_path(&note.id))[0].text, "live");
        assert_eq!(store.load(&note.id).unwrap().transcript_model.as_deref(), Some("Parakeet"));
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn an_unfinished_note_is_closed_from_its_audio() {
        let dir = crate::history::tests::tempdir();
        let store = NotesStore::new(&dir);
        let note = store.create("Crash").unwrap();
        let mut w = wav::WavWriter::create(&store.audio_path(&note.id, "mic"), 16_000, false).unwrap();
        for _ in 0..50 {
            w.append(&[0.1; 1000]).unwrap();
        }
        std::mem::forget(w);
        let recovered = store.recover_unfinished();
        assert_eq!(recovered.len(), 1);
        assert_eq!(recovered[0].duration_seconds, 3.125);
        assert_eq!(recovered[0].recovered, Some(true));
        assert!(store.recover_unfinished().is_empty(), "closed once");
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn labels() {
        assert_eq!(clock(65.0), "1:05");
        assert_eq!(clock(3725.0), "1:02:05");
    }
}
