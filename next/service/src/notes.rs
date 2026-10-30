//! Everything done to a meeting note outside the recording itself: which model writes notes,
//! the pass over the recording, summaries, the recap, asking about a meeting, renaming, relabeling the
//! speakers, deleting.

use crate::context::Context;
use crate::engine::{self, SlotRecognizer};
use crate::events::{Event, NoteEvent, Toast, ToastAction};
use linflow_core::llm::{self, Ollama};
use linflow_core::meeting::detect::Recap;
use linflow_core::meeting::summary::{self, Kind, NoteModel};
use linflow_core::meeting::tracker::Tracker;
use linflow_core::audio_export::{self, Format};
use linflow_core::notes::{follow_title, transcript_text, AudioExportRecord, MeetingNote, QuestionTurn, TranscriptSegment};
use std::collections::{HashSet, VecDeque};
use std::path::Path;
use std::sync::{Arc, Mutex};

/// The local model every meeting uses, through Ollama. Nothing from a meeting leaves the
/// computer (John, 2026-10-30): his work calls must never reach Claude, and he wants no split
/// between work and personal calls, so Claude is out for meetings altogether, saved key or not.
/// The default model is the bigger one; a computer that only has the small one uses it.
pub fn local_model(ctx: &Context) -> Result<Ollama, String> {
    pick_local(&ctx.settings(), ctx.net.clone())
}

/// The small model was the default until 2026-10-30, and every settings save wrote it down, so
/// a saved "qwen2.5:3b" is the old default rather than a choice: it moves up to the bigger
/// model once that is pulled.
fn pick_local(s: &linflow_core::settings::Settings, net: Arc<dyn linflow_core::net::Transport>) -> Result<Ollama, String> {
    let saved = s.ollama_model.trim();
    let default = saved.is_empty() || saved == llm::OLLAMA_MODEL || saved == llm::OLLAMA_SMALL_MODEL;
    let first = if default { llm::OLLAMA_MODEL } else { saved };
    let chosen = Ollama::new(&s.ollama_host, first, net.clone());
    let Some(why) = chosen.check() else { return Ok(chosen) };
    if default {
        let small = Ollama::new(&s.ollama_host, llm::OLLAMA_SMALL_MODEL, net);
        if small.check().is_none() {
            return Ok(small);
        }
    }
    Err(why)
}

/// The model for running notes and the call tracker.
pub fn running_notes_model(ctx: &Context) -> Result<Box<dyn NoteModel + Send>, String> {
    local_model(ctx).map(|m| Box::new(m) as Box<dyn NoteModel + Send>)
}

/// The model for summaries, recaps and questions.
pub fn summary_model(ctx: &Context) -> Result<Box<dyn NoteModel + Send>, String> {
    local_model(ctx).map(|m| Box::new(m) as Box<dyn NoteModel + Send>).map_err(|why| format!("No model to write notes with: {}", lower_first(&why)))
}

fn lower_first(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_lowercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

/// Work on notes that runs off the window's thread: one pass over a recording at a time, the
/// rest queued, and one summary per note at a time.
pub struct NoteWork {
    ctx: Arc<Context>,
    transcribing: Mutex<Option<String>>,
    queue: Mutex<VecDeque<(String, bool)>>,
    summarizing: Mutex<HashSet<String>>,
    asking: Mutex<HashSet<String>>,
    saving_audio: Mutex<HashSet<String>>,
}

impl NoteWork {
    pub fn new(ctx: Arc<Context>) -> Arc<NoteWork> {
        Arc::new(NoteWork { ctx, transcribing: Mutex::new(None), queue: Mutex::new(VecDeque::new()), summarizing: Mutex::new(HashSet::new()), asking: Mutex::new(HashSet::new()), saving_audio: Mutex::new(HashSet::new()) })
    }

    fn status(&self, id: &str, text: Option<String>) {
        self.ctx.emit(Event::Note { event: NoteEvent::Status { id: id.into(), text } });
    }

    fn error(&self, text: impl Into<String>) {
        self.ctx.emit(Event::Note { event: NoteEvent::Error { text: text.into() } });
    }

    pub fn busy(&self, id: &str) -> Option<&'static str> {
        if self.transcribing.lock().unwrap().as_deref() == Some(id) {
            return Some("transcribing");
        }
        if self.summarizing.lock().unwrap().contains(id) {
            return Some("summarizing");
        }
        if self.saving_audio.lock().unwrap().contains(id) {
            return Some("saving audio");
        }
        None
    }

    /// Rebuilds a note's transcript from its saved audio, then, when `then_summarize`, writes the
    /// summary and shows the recap. Runs after every meeting; the window offers it again for any
    /// note with audio, which is how a better model later improves an old meeting.
    pub fn transcribe_from_audio(self: &Arc<Self>, id: &str, then_summarize: bool) {
        if !self.ctx.notes.has_audio(id) {
            self.error("This meeting has no saved audio to transcribe.");
            return;
        }
        {
            let mut cur = self.transcribing.lock().unwrap();
            if cur.is_some() {
                let mut q = self.queue.lock().unwrap();
                if cur.as_deref() != Some(id) && !q.iter().any(|(q, _)| q == id) {
                    q.push_back((id.to_string(), then_summarize));
                }
                return;
            }
            *cur = Some(id.to_string());
        }
        let me = self.clone();
        let id = id.to_string();
        std::thread::Builder::new()
            .name("linflow.transcribe".into())
            .spawn(move || {
                me.run_transcribe(&id, then_summarize);
                *me.transcribing.lock().unwrap() = None;
                let next = me.queue.lock().unwrap().pop_front();
                if let Some((next, s)) = next {
                    me.transcribe_from_audio(&next, s);
                }
            })
            .ok();
    }

    fn run_transcribe(self: &Arc<Self>, id: &str, then_summarize: bool) {
        // The model loads for a few seconds after launch; a recovered note waits for it.
        let mut waits = 0;
        while !self.ctx.engine.is_loaded() {
            self.status(id, Some("Waiting for the speech model…".into()));
            waits += 1;
            if waits > 90 {
                self.status(id, None);
                self.error("The speech model did not load, so the transcript was not rebuilt from the audio.");
                return;
            }
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
        self.status(id, Some("Reading the recording…".into()));
        let settings = self.ctx.settings();
        let mut rec = SlotRecognizer { slot: self.ctx.engine.clone(), options: engine::options(&settings, &self.ctx.dictionary.terms()) };
        let cleaner = self.ctx.dictionary.cleaner(&settings, false);
        let started = std::time::Instant::now();
        let me = self.clone();
        let note_id = id.to_string();
        let mut progress = move |p: &str| me.status(&note_id, Some(format!("From the recording: {p}")));
        match linflow_core::meeting::regions::transcribe_note(&self.ctx.notes, id, &mut rec, &cleaner, &mut progress) {
            // Resumed while the pass ran: the live lines since are newer than this, and the pass
            // after the next stop covers all of it.
            Ok(_) if self.ctx.notes.load(id).is_some_and(|n| n.ended_at.is_none()) => {
                log::info!("notes: {id} was resumed during the pass over its audio; that pass is set aside");
                self.status(id, None);
                return;
            }
            Ok(segments) => {
                let model = self.ctx.engine.describe().map(|(m, _)| m).unwrap_or_default();
                if let Err(e) = self.ctx.notes.replace_transcript(id, &segments, &model) {
                    self.error(format!("Could not save the transcript: {e}"));
                } else {
                    log::info!("notes: {id} transcribed from audio: {} segments in {:.1} s", segments.len(), started.elapsed().as_secs_f64());
                    self.ctx.emit(Event::Note { event: NoteEvent::Transcript { id: id.into() } });
                }
            }
            Err(e) => {
                log::error!("notes: transcribing {id} from audio: {e}");
                self.error(e);
            }
        }
        self.status(id, None);
        if then_summarize {
            self.summarize(id, true);
        }
    }

    /// The write-up: summary, decisions, action items, open questions. `recap_after` shows the
    /// end-of-call recap once it is written, the proof that both sides were heard.
    pub fn summarize(self: &Arc<Self>, id: &str, recap_after: bool) {
        let segments = self.ctx.notes.transcript(id);
        if segments.is_empty() {
            if recap_after {
                self.show_recap(id);
            } else {
                self.error("Nothing to summarize yet.");
            }
            return;
        }
        if !self.summarizing.lock().unwrap().insert(id.to_string()) {
            return;
        }
        let me = self.clone();
        let id = id.to_string();
        std::thread::Builder::new()
            .name("linflow.summary".into())
            .spawn(move || {
                match summary_model(&me.ctx) {
                    Ok(mut model) => {
                        let note = me.ctx.notes.load(&id);
                        let title = note.as_ref().map(|n| n.title.clone()).unwrap_or_else(|| "Meeting".into());
                        me.status(&id, Some("Summarizing…".into()));
                        let me2 = me.clone();
                        let id2 = id.clone();
                        let mut progress = move |p: &str| me2.status(&id2, Some(p.to_string()));
                        match summary::summarize(model.as_mut(), &transcript_text(&segments, true), &title, Kind::Meeting, &mut progress) {
                            Ok(text) => {
                                let _ = me.ctx.notes.save_summary(&id, &text);
                                if let Some(mut n) = me.ctx.notes.load(&id) {
                                    n.summary_model = Some(model.name());
                                    let _ = me.ctx.notes.save(&n);
                                }
                                me.ctx.emit(Event::Note { event: NoteEvent::Summary { id: id.clone(), text } });
                            }
                            Err(e) => me.error(e.to_string()),
                        }
                    }
                    Err(why) => {
                        if !recap_after {
                            me.error(why);
                        }
                    }
                }
                me.status(&id, None);
                me.summarizing.lock().unwrap().remove(&id);
                if recap_after {
                    me.show_recap(&id);
                }
            })
            .ok();
    }

    /// "What did I miss": a few bullets on the last `minutes`, put above the summary.
    pub fn recap(self: &Arc<Self>, id: &str, minutes: f64) {
        let segments = self.ctx.notes.transcript(id);
        let latest = segments.last().map(|s| s.end).unwrap_or(0.0);
        let recent: Vec<TranscriptSegment> = segments.into_iter().filter(|s| s.end >= latest - minutes * 60.0).collect();
        if recent.is_empty() {
            self.error("Nothing to summarize yet.");
            return;
        }
        if !self.summarizing.lock().unwrap().insert(id.to_string()) {
            return;
        }
        let me = self.clone();
        let id = id.to_string();
        std::thread::spawn(move || {
            match summary_model(&me.ctx) {
                Ok(mut model) => {
                    let title = me.ctx.notes.load(&id).map(|n| n.title).unwrap_or_else(|| "Meeting".into());
                    me.status(&id, Some("Catching up…".into()));
                    match summary::summarize(model.as_mut(), &transcript_text(&recent, true), &title, Kind::Recap, &mut |_| {}) {
                        Ok(text) => {
                            let previous = me.ctx.notes.summary(&id).unwrap_or_default();
                            let previous = if previous.starts_with("**Recap") { String::new() } else { previous };
                            let combined = format!("**Recap of the last {} minutes**\n\n{text}{}", minutes as u32, if previous.is_empty() { String::new() } else { format!("\n\n---\n\n{previous}") });
                            me.ctx.emit(Event::Note { event: NoteEvent::Summary { id: id.clone(), text: combined } });
                        }
                        Err(e) => me.error(e.to_string()),
                    }
                }
                Err(why) => me.error(why),
            }
            me.status(&id, None);
            me.summarizing.lock().unwrap().remove(&id);
        });
    }

    /// The end-of-call line: how long, how much each side spoke, what the summary found.
    pub fn show_recap(&self, id: &str) {
        let Some(note) = self.ctx.notes.load(id) else { return };
        let segments = self.ctx.notes.transcript(id);
        let summary = self.ctx.notes.summary(id);
        let sentence = Recap::of(note.duration_seconds, &segments, summary.as_deref()).sentence();
        log::info!("recap: {} {sentence}", note.title);
        self.ctx.emit(Event::Note { event: NoteEvent::Recap { id: id.into(), sentence: sentence.clone() } });
        let mut toast = Toast::new(format!("{} saved", note.title), sentence).seconds(12.0).on_click(ToastAction::OpenNote { id: id.into() });
        if segments.iter().all(|s| s.speaker != linflow_core::meeting::OTHERS) && note.used_system_audio {
            toast = toast.warning();
        }
        self.ctx.toast(toast);
    }

    /// One question about a note to the local model, with the newest stretch of the transcript
    /// that fits beside John's notes and the questions before it. The answer is saved with the
    /// note.
    pub fn ask(self: &Arc<Self>, id: &str, question: &str) {
        let q = question.trim().to_string();
        if q.is_empty() || !self.asking.lock().unwrap().insert(id.to_string()) {
            return;
        }
        let me = self.clone();
        let id = id.to_string();
        std::thread::spawn(move || {
            match summary_model(&me.ctx) {
                Err(why) => me.error(why),
                Ok(mut model) => {
                    let title = me.ctx.notes.load(&id).map(|n| n.title).unwrap_or_else(|| "Meeting".into());
                    let notes = me.ctx.notes.notes_text(&id);
                    let mut turns = me.ctx.notes.questions(&id);
                    // The local model's window holds the newest transcript and the latest
                    // questions; older questions drop out before the transcript gets short.
                    let mut earlier = &turns[turns.len().saturating_sub(3)..];
                    let room = |earlier: &[QuestionTurn]| model.window_characters().saturating_sub(llm::questions::prompt(&title, "", &notes, earlier, &q).len());
                    while !earlier.is_empty() && room(earlier) < 2_000 {
                        earlier = &earlier[1..];
                    }
                    let transcript = summary::tail(&transcript_text(&me.ctx.notes.transcript(&id), true), room(earlier).max(1_000));
                    let prompt = llm::questions::prompt(&title, &transcript, &notes, earlier, &q);
                    let request = summary::Request { instructions: llm::questions::SYSTEM.into(), prompt, max_tokens: 800, lists: vec![], greedy: false };
                    match model.complete(&request) {
                        Ok(answer) => {
                            turns.push(QuestionTurn { question: q.clone(), answer, asked_at: linflow_core::notes::now() });
                            let _ = me.ctx.notes.save_questions(&id, &turns);
                            me.ctx.emit(Event::Note { event: NoteEvent::Answer { id: id.clone() } });
                        }
                        Err(e) => {
                            log::error!("ask: {e}");
                            me.error(e.to_string());
                        }
                    }
                }
            }
            me.asking.lock().unwrap().remove(&id);
        });
    }

    /// Both sides of a meeting as one file at `to`, leveled and mixed (`audio_export`), with its
    /// progress as the note's status. The file is remembered on the note, so it takes the note's
    /// new title when the note is renamed.
    pub fn save_audio(&self, id: &str, to: &Path, format: Format) -> Result<(), String> {
        let note = self.ctx.notes.load(id).ok_or("That meeting is gone.")?;
        if !self.saving_audio.lock().unwrap().insert(id.to_string()) {
            return Err("This meeting's audio is already being saved.".into());
        }
        let started = std::time::Instant::now();
        let mut shown = -1;
        let result = audio_export::export_note(&self.ctx.notes.folder(id), &note.title, to, format, &mut |p| {
            let percent = (p * 100.0) as i32;
            if percent != shown {
                shown = percent;
                self.status(id, Some(format!("Saving audio… {percent}%")));
            }
        });
        self.saving_audio.lock().unwrap().remove(id);
        self.status(id, None);
        let r = result.map_err(|e| {
            log::error!("notes: saving the audio of {id}: {e}");
            format!("The audio was not saved: {e}")
        })?;
        let size = std::fs::metadata(to).map(|m| m.len()).unwrap_or(0);
        let gains: Vec<String> = r.gains.iter().map(|(k, g)| format!("{k} {g:+.1} dB")).collect();
        log::info!(
            "notes: {id} audio saved as {}, {:.0} s, {:.1} MB, {}, {} (call {:+.2} s from the mic), in {:.1} s",
            format.ext(),
            r.seconds,
            size as f64 / 1e6,
            gains.join(", "),
            r.coupling.name(),
            r.delay,
            started.elapsed().as_secs_f64()
        );
        if let Some(mut n) = self.ctx.notes.load(id) {
            let path = to.to_string_lossy().into_owned();
            let mut exports: Vec<AudioExportRecord> = n.audio_exports.take().unwrap_or_default().into_iter().filter(|e| e.path != path).collect();
            exports.push(AudioExportRecord { path, title: note.title.clone() });
            n.audio_exports = Some(exports);
            if n.title != note.title {
                follow(&mut n); // renamed while it saved
            }
            self.ctx.notes.save(&n).map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    pub fn is_saving_audio(&self, id: &str) -> bool {
        self.saving_audio.lock().unwrap().contains(id)
    }

    pub fn is_asking(&self, id: &str) -> bool {
        self.asking.lock().unwrap().contains(id)
    }
}

/// One writer at a time for `tracker.json`: the tracker's pass and John's ticks both write it,
/// and a pass takes seconds, so each reads the file again under this lock before it writes.
static TRACKER: Mutex<()> = Mutex::new(());

/// Changes a note's tracker, saves it and tells the window.
pub fn update_tracker(ctx: &Context, id: &str, change: impl FnOnce(&mut Tracker) -> bool) -> Result<Tracker, String> {
    let _one = TRACKER.lock().unwrap_or_else(|e| e.into_inner());
    let mut t = ctx.notes.tracker(id);
    if change(&mut t) {
        ctx.notes.save_tracker(id, &t).map_err(|e| e.to_string())?;
        ctx.emit(Event::Note { event: NoteEvent::Tracker { id: id.into(), tracker: t.clone() } });
    }
    Ok(t)
}

/// Ticks a tracker item off, or back on.
pub fn toggle_tracker(ctx: &Context, id: &str, item: &str) -> Result<Tracker, String> {
    update_tracker(ctx, id, |t| t.toggle(item))
}

/// Renames a note. An empty title keeps the old one.
pub fn rename(ctx: &Context, id: &str, title: &str) -> Result<MeetingNote, String> {
    let mut note = ctx.notes.load(id).ok_or("That meeting is gone.")?;
    let title = title.trim();
    if title.is_empty() || title == note.title {
        return Ok(note);
    }
    note.title = title.to_string();
    follow(&mut note);
    ctx.notes.save(&note).map_err(|e| e.to_string())?;
    ctx.emit(Event::Note { event: NoteEvent::Listed });
    Ok(note)
}

/// Renames the audio files saved from a note to its title (`follow_title`).
fn follow(note: &mut MeetingNote) {
    let Some(exports) = &note.audio_exports else { return };
    let moved = follow_title(exports, &note.title);
    if &moved != exports {
        let names: Vec<&str> = moved.iter().filter_map(|e| Path::new(&e.path).file_name()?.to_str()).collect();
        log::info!("notes: {} saved audio renamed to follow the title: {names:?}", note.id);
        note.audio_exports = Some(moved);
    }
}

/// Renames a speaker throughout a note's transcript: "Others" becomes "Dana" when only one
/// other person was on the call. The transcript file is rewritten whole; the audio is not
/// touched.
pub fn relabel(ctx: &Context, id: &str, from: &str, to: &str) -> Result<(), String> {
    let to = to.trim();
    if to.is_empty() || from == to {
        return Ok(());
    }
    let mut segments = ctx.notes.transcript(id);
    let mut changed = 0;
    for s in segments.iter_mut().filter(|s| s.speaker == from) {
        s.speaker = to.to_string();
        changed += 1;
    }
    if changed == 0 {
        return Ok(());
    }
    let mut out = String::new();
    for s in &segments {
        out.push_str(&linflow_core::json::compact(s).map_err(|e| e.to_string())?);
        out.push('\n');
    }
    linflow_core::fsutil::write_atomic(&ctx.notes.transcript_path(id), out.as_bytes()).map_err(|e| e.to_string())?;
    let _ = ctx.notes.append_event(id, &format!("speaker {from:?} renamed to {to:?} on {changed} lines"));
    ctx.emit(Event::Note { event: NoteEvent::Transcript { id: id.into() } });
    Ok(())
}

/// The speakers a note's transcript names, "You" and "Others" first.
pub fn speakers(segments: &[TranscriptSegment]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for s in segments {
        if !out.contains(&s.speaker) {
            out.push(s.speaker.clone());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::Sink;

    struct Tags(&'static str);
    impl linflow_core::net::Transport for Tags {
        fn send(&self, _: &linflow_core::net::HttpRequest) -> Result<linflow_core::net::HttpResponse, linflow_core::net::NetError> {
            Ok(linflow_core::net::HttpResponse { status: 200, body: format!(r#"{{"models":[{}]}}"#, self.0).into_bytes() })
        }
    }

    #[test]
    fn meetings_use_the_bigger_local_model_then_the_small_one() {
        let s = linflow_core::settings::Settings::default();
        let both = pick_local(&s, Arc::new(Tags(r#"{"name":"qwen2.5:3b"},{"name":"qwen2.5:7b"}"#))).unwrap();
        assert_eq!(both.model, "qwen2.5:7b");
        let small = pick_local(&s, Arc::new(Tags(r#"{"name":"qwen2.5:3b"}"#))).unwrap();
        assert_eq!(small.model, "qwen2.5:3b", "a computer without the 7b keeps working");
        let why = pick_local(&s, Arc::new(Tags(""))).err().unwrap_or_default();
        assert!(why.contains("ollama pull qwen2.5:7b"), "{why}");
        let old_default = linflow_core::settings::Settings { ollama_model: "qwen2.5:3b".into(), ..s.clone() };
        assert_eq!(pick_local(&old_default, Arc::new(Tags(r#"{"name":"qwen2.5:3b"},{"name":"qwen2.5:7b"}"#))).unwrap().model, "qwen2.5:7b", "the old default moves up");
        let chosen = linflow_core::settings::Settings { ollama_model: "llama3.2:3b".into(), ..s };
        assert!(pick_local(&chosen, Arc::new(Tags(r#"{"name":"qwen2.5:3b"}"#))).is_err(), "a model John chose is not swapped for another");
    }

    #[test]
    fn tracker_ticks_and_passes_both_land() {
        use linflow_core::meeting::tracker::{Item, Kind};
        let dir = std::env::temp_dir().join(format!("linflow-tracker-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let seen = Arc::new(Mutex::new(0));
        let s2 = seen.clone();
        let events: Sink = Arc::new(move |e| {
            if matches!(e, Event::Note { event: NoteEvent::Tracker { .. } }) {
                *s2.lock().unwrap() += 1;
            }
        });
        let ctx = Context::new(dir.clone(), events);
        let note = ctx.notes.create("Standup").unwrap();
        let item = |text: &str| Item { id: String::new(), kind: Kind::Question, at: 1.0, text: text.into(), detail: "Say when.".into(), done: false };
        update_tracker(&ctx, &note.id, |t| {
            t.add(vec![item("Can it land by Friday?")]);
            true
        })
        .unwrap();
        toggle_tracker(&ctx, &note.id, "q-1").unwrap();
        update_tracker(&ctx, &note.id, |t| {
            t.add(vec![item("Who owns the demo?")]);
            true
        })
        .unwrap();
        let t = ctx.notes.tracker(&note.id);
        assert_eq!(t.items.iter().map(|i| (i.id.as_str(), i.done)).collect::<Vec<_>>(), vec![("q-1", true), ("q-2", false)], "the tick survives the next pass");
        assert!(toggle_tracker(&ctx, &note.id, "q-9").is_ok(), "an unknown item changes nothing");
        assert_eq!(*seen.lock().unwrap(), 3);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn saved_audio_is_remembered_and_follows_a_rename() {
        let dir = std::env::temp_dir().join(format!("linflow-saveaudio-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let events: Sink = Arc::new(|_| {});
        let ctx = Context::new(dir.clone(), events);
        let note = ctx.notes.create("Meeting Oct 26, 1:34 PM").unwrap();
        let tone: Vec<f32> = (0..32_000).map(|i| 0.05 * (i as f32 * 0.07).sin()).collect();
        linflow_core::wav::write(&ctx.notes.audio_path(&note.id, "mic"), &tone, 16_000).unwrap();
        let out = dir.join("Meeting Oct 26, 1.34 PM.wav");
        NoteWork::new(ctx.clone()).save_audio(&note.id, &out, Format::Wav).unwrap();
        assert!(out.exists());
        rename(&ctx, &note.id, "Budget: Q4").unwrap();
        let moved = dir.join("Budget. Q4.wav");
        assert!(moved.exists() && !out.exists(), "the file takes the note's new title");
        let saved = ctx.notes.load(&note.id).unwrap().audio_exports.unwrap();
        assert_eq!(saved, vec![AudioExportRecord { path: moved.to_string_lossy().into_owned(), title: "Budget: Q4".into() }]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
