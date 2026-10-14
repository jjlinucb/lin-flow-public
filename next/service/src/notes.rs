//! Everything done to a meeting note outside the recording itself: which model writes notes,
//! the pass over the recording, summaries, the recap, asking Claude, renaming, relabeling the
//! speakers, deleting.

use crate::context::Context;
use crate::engine::{self, SlotRecognizer};
use crate::events::{Event, NoteEvent, Toast, ToastAction};
use linflow_core::llm::{self, Claude, Ollama};
use linflow_core::meeting::detect::Recap;
use linflow_core::meeting::summary::{self, Kind, NoteModel};
use linflow_core::notes::{transcript_text, MeetingNote, QuestionTurn, TranscriptSegment};
use std::collections::{HashSet, VecDeque};
use std::sync::{Arc, Mutex};

/// The model for running notes: the local one, since they run every minute and Claude costs
/// money per call; Claude when there is no local model, so the Mac has running notes at all
/// until an on-device model is wired in. None, with the reason, when neither is there.
pub fn running_notes_model(ctx: &Context) -> Result<Box<dyn NoteModel + Send>, String> {
    let s = ctx.settings();
    let ollama = Ollama::new(&s.ollama_host, &s.ollama_model, ctx.net.clone());
    let local = ollama.check();
    if local.is_none() {
        return Ok(Box::new(ollama));
    }
    if let Some(claude) = Claude::from_saved_key(ctx.net.clone()) {
        return Ok(Box::new(claude));
    }
    Err(local.unwrap_or_default())
}

/// The model for summaries, recaps and questions: Claude once a key is saved, since it reads a
/// whole meeting at once; the local model otherwise.
pub fn summary_model(ctx: &Context) -> Result<Box<dyn NoteModel + Send>, String> {
    if let Some(claude) = Claude::from_saved_key(ctx.net.clone()) {
        return Ok(Box::new(claude));
    }
    let s = ctx.settings();
    let ollama = Ollama::new(&s.ollama_host, &s.ollama_model, ctx.net.clone());
    match ollama.check() {
        None => Ok(Box::new(ollama)),
        Some(why) => Err(format!("No model to write notes with. Save a Claude key (scripts/setup-claude.sh), or {}", lower_first(&why))),
    }
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
}

impl NoteWork {
    pub fn new(ctx: Arc<Context>) -> Arc<NoteWork> {
        Arc::new(NoteWork { ctx, transcribing: Mutex::new(None), queue: Mutex::new(VecDeque::new()), summarizing: Mutex::new(HashSet::new()), asking: Mutex::new(HashSet::new()) })
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

    /// One question about a note to Claude, with the transcript so far, John's notes and the
    /// questions before it. The answer is saved with the note.
    pub fn ask(self: &Arc<Self>, id: &str, question: &str) {
        let q = question.trim().to_string();
        if q.is_empty() || !self.asking.lock().unwrap().insert(id.to_string()) {
            return;
        }
        let me = self.clone();
        let id = id.to_string();
        std::thread::spawn(move || {
            match Claude::from_saved_key(me.ctx.net.clone()) {
                None => me.error("Save a Claude key first: run scripts/setup-claude.sh once."),
                Some(client) => {
                    let title = me.ctx.notes.load(&id).map(|n| n.title).unwrap_or_else(|| "Meeting".into());
                    let transcript = transcript_text(&me.ctx.notes.transcript(&id), true);
                    let notes = me.ctx.notes.notes_text(&id);
                    let mut turns = me.ctx.notes.questions(&id);
                    let prompt = llm::questions::prompt(&title, &transcript, &notes, &turns, &q);
                    match client.ask(llm::questions::SYSTEM, &prompt, 1024) {
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

    pub fn is_asking(&self, id: &str) -> bool {
        self.asking.lock().unwrap().contains(id)
    }
}

/// Renames a note. An empty title keeps the old one.
pub fn rename(ctx: &Context, id: &str, title: &str) -> Result<MeetingNote, String> {
    let mut note = ctx.notes.load(id).ok_or("That meeting is gone.")?;
    let title = title.trim();
    if title.is_empty() || title == note.title {
        return Ok(note);
    }
    note.title = title.to_string();
    ctx.notes.save(&note).map_err(|e| e.to_string())?;
    ctx.emit(Event::Note { event: NoteEvent::Listed });
    Ok(note)
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
