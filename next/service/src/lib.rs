//! Lin Flow running, minus its windows: dictation, the readback of hand edits, the meeting
//! recorder, meeting detection and sync, wired to the platform layer. Whatever draws it (the
//! Tauri app, or a test) passes a `Sink` for events and calls the methods below; every method
//! returns quickly, and anything slow runs on a thread of its own.

pub mod context;
pub mod detect;
pub mod dictation;
pub mod dictionary;
pub mod engine;
pub mod events;
pub mod logging;
pub mod meeting;
pub mod notes;
pub mod readback;
pub mod sync;

pub use context::Context;
pub use events::{DictationState, Event, NoteEvent, Sink, Toast, ToastAction};

use linflow_core::history::{self, HistoryEntry};
use linflow_core::hotkey::{Hotkey, HotkeyRecorder, Platform, Recorded, Signal};
use linflow_core::models;
use linflow_core::notes::{MeetingNote, QuestionTurn, TranscriptSegment};
use linflow_core::settings::Settings;
use linflow_core::text::glossary::Replacement;
use linflow_platform::HotkeyListener;
use serde::Serialize;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StatsView {
    pub count: usize,
    pub total_words: i64,
    pub words_per_minute: usize,
    pub streak_days: i64,
    /// "Every computer: 1,204 here, 380 on LAPTOP-02", once shared totals are on.
    pub caption: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DictionaryView {
    pub terms: Vec<String>,
    pub rules: Vec<Replacement>,
    pub pending: Vec<Replacement>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NoteDetail {
    pub note: MeetingNote,
    pub segments: Vec<TranscriptSegment>,
    pub my_notes: String,
    pub summary: String,
    pub running_notes: String,
    pub questions: Vec<QuestionTurn>,
    pub has_audio: bool,
    pub recording: bool,
    pub elapsed: f64,
    pub busy: Option<String>,
    pub asking: bool,
    pub speakers: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelView {
    pub id: String,
    pub label: String,
    pub installed: bool,
    pub size_mb: u32,
    pub note: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsView {
    pub settings: Settings,
    pub hotkey: String,
    pub hotkey_label: String,
    pub hotkey_presets: Vec<(String, String)>,
    pub models: Vec<ModelView>,
    pub claude_ready: bool,
    pub sync_status: String,
    pub data_dir: String,
    pub log_path: String,
    pub trusted: bool,
    pub platform: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusView {
    pub phase: String,
    pub label: String,
    pub hotkey_label: String,
    pub model: Option<String>,
    pub recording_note: Option<String>,
    pub elapsed: Option<f64>,
}

pub struct Service {
    pub ctx: Arc<Context>,
    pub dictation: Arc<dictation::Dictation>,
    pub readback: Arc<readback::Readback>,
    pub work: Arc<notes::NoteWork>,
    pub meetings: Arc<meeting::Meetings>,
    pub sync: Arc<sync::Sync>,
    pub detection: Arc<detect::Detection>,
    hotkey: Arc<Mutex<Option<HotkeyListener>>>,
}

impl Service {
    /// Starts everything: the stores, the threads, the talk key, the model. `events` is called
    /// from many threads.
    pub fn start(events: Sink) -> Arc<Service> {
        let ctx = Context::new(linflow_core::paths::data_dir(), events);
        log::info!("Lin Flow Next starting; data in {}", ctx.data_dir.display());
        let settings = ctx.settings();
        let _ = ctx.history.prune_recordings(settings.audio_retention_days, chrono::Utc::now());
        let readback = readback::Readback::new(ctx.clone());
        let dictation = dictation::Dictation::new(ctx.clone(), readback.clone());
        let work = notes::NoteWork::new(ctx.clone());
        let meetings = meeting::Meetings::new(ctx.clone(), work.clone());
        let sync = sync::Sync::start(ctx.clone());
        let detection = detect::Detection::start(ctx.clone(), meetings.clone());
        let svc = Arc::new(Service { ctx: ctx.clone(), dictation: dictation.clone(), readback, work: work.clone(), meetings, sync, detection, hotkey: Arc::new(Mutex::new(None)) });

        // Notes the app never stopped (a crash, a force quit) are closed, and their recording
        // gets the whole-file pass it missed.
        for note in ctx.notes.recover_unfinished() {
            log::info!("notes: recovered {} ({} s)", note.id, note.duration_seconds as u64);
            if settings.keep_meeting_audio && settings.transcribe_after_meeting && ctx.notes.has_audio(&note.id) {
                work.transcribe_from_audio(&note.id, false);
            }
        }
        svc.start_hotkey();
        dictation.load_model(&settings.model_id);
        svc
    }

    /// The talk key, retried every 3 s until the OS lets it watch the keyboard: on the Mac that
    /// waits for John's Accessibility and Input Monitoring grant.
    fn start_hotkey(self: &Arc<Self>) {
        // Headless checks drive press and release themselves and must not watch John's keyboard.
        if std::env::var_os("LINFLOW_NO_HOTKEY").is_some() {
            log::info!("LINFLOW_NO_HOTKEY set: no talk key");
            return;
        }
        let me = self.clone();
        std::thread::Builder::new()
            .name("linflow.hotkey-start".into())
            .spawn(move || {
                let mut logged = false;
                loop {
                    let d = me.dictation.clone();
                    let on_signal: linflow_platform::OnSignal = Arc::new(move |s| match s {
                        Signal::Press => d.press(),
                        Signal::Release => d.release(),
                        Signal::None => {}
                    });
                    match HotkeyListener::start(me.ctx.hotkey(), on_signal) {
                        Ok(l) => {
                            *me.hotkey.lock().unwrap() = Some(l);
                            log::info!("talk key: {}", me.ctx.hotkey().label(Platform::current()));
                            if me.dictation.hotkey_failed.swap(false, std::sync::atomic::Ordering::Relaxed) && me.ctx.engine.is_loaded() {
                                me.dictation.set_state(DictationState::Idle);
                            }
                            return;
                        }
                        Err(e) => {
                            if !logged {
                                log::error!("{e}");
                                logged = true;
                            }
                            me.dictation.hotkey_failed.store(true, std::sync::atomic::Ordering::Relaxed);
                            me.dictation.set_state(DictationState::Error("no keyboard access".into()));
                            std::thread::sleep(Duration::from_secs(3));
                        }
                    }
                }
            })
            .ok();
    }

    /// Closes an open meeting cleanly and frees the model. Called once, at quit.
    pub fn shutdown(&self) {
        self.meetings.stop(true);
        *self.hotkey.lock().unwrap() = None;
        self.ctx.engine.set(None);
        log::logger().flush();
    }

    pub fn status(&self) -> StatusView {
        let s = self.dictation.state();
        StatusView {
            phase: s.phase().into(),
            label: s.label(),
            hotkey_label: self.ctx.hotkey().label(Platform::current()),
            model: self.ctx.engine.describe().map(|(m, _)| m),
            recording_note: self.meetings.recording_id(),
            elapsed: self.meetings.elapsed(),
        }
    }

    // MARK: talk key

    pub fn set_hotkey(&self, raw: &str) -> Result<(), String> {
        let key = Hotkey::parse(raw, Platform::current()).ok_or("That is not a key Lin Flow can use.")?;
        self.ctx.update_settings(|s| s.hotkey = key.raw_value(Platform::current()));
        if let Some(l) = self.hotkey.lock().unwrap().as_ref() {
            l.set_hotkey(key.clone());
        }
        log::info!("talk key set to {}", key.label(Platform::current()));
        Ok(())
    }

    /// Settings' Record button: the next key, keys or mouse button pressed becomes the talk key.
    /// Escape on its own cancels. The answer arrives as `Event::HotkeyRecorded`.
    pub fn record_hotkey(self: &Arc<Self>) {
        let guard = self.hotkey.lock().unwrap();
        let Some(listener) = guard.as_ref() else {
            self.ctx.emit(Event::HotkeyRecorded { raw: None, label: None });
            return;
        };
        self.dictation.suspend(true);
        let escape = if Platform::current() == Platform::Mac { 53 } else { 0x1B };
        let mut recorder = HotkeyRecorder::default();
        let me = self.clone();
        listener.set_recorder(Some(Box::new(move |event| {
            match recorder.handle(event, escape) {
                Recorded::Pending => true,
                done => {
                    // Off the listener's thread: it holds the lock the recorder is cleared under.
                    let me = me.clone();
                    std::thread::spawn(move || me.finish_recording(done));
                    true
                }
            }
        })));
    }

    pub fn cancel_record_hotkey(self: &Arc<Self>) {
        self.finish_recording(Recorded::Cancelled);
    }

    fn finish_recording(self: &Arc<Self>, done: Recorded) {
        if let Some(l) = self.hotkey.lock().unwrap().as_ref() {
            l.set_recorder(None);
        }
        self.dictation.suspend(false);
        match done {
            Recorded::Done(key) => {
                let raw = key.raw_value(Platform::current());
                let label = key.label(Platform::current());
                let _ = self.set_hotkey(&raw);
                self.ctx.emit(Event::HotkeyRecorded { raw: Some(raw), label: Some(label) });
            }
            _ => self.ctx.emit(Event::HotkeyRecorded { raw: None, label: None }),
        }
    }

    // MARK: settings

    pub fn settings_view(&self) -> SettingsView {
        let p = Platform::current();
        let installed: Vec<String> = models::installed().iter().map(|p| models::id_from_path(p)).collect();
        let mut views: Vec<ModelView> = models::KNOWN
            .iter()
            .map(|m| ModelView {
                id: m.id.into(),
                label: format!("{} · {}", if m.engine == models::EngineKind::Parakeet { "Parakeet" } else { "Whisper" }, m.id),
                installed: installed.iter().any(|i| i == m.id),
                size_mb: m.size_mb,
                note: m.note.into(),
            })
            .collect();
        let extra: Vec<String> = installed.iter().filter(|i| !views.iter().any(|v| &v.id == *i)).cloned().collect();
        for id in extra {
            views.push(ModelView { label: id.clone(), id, installed: true, size_mb: 0, note: String::new() });
        }
        let key = self.ctx.hotkey();
        let mut presets: Vec<(String, String)> = Hotkey::presets(p).iter().map(|h| (h.raw_value(p), h.label(p))).collect();
        if !presets.iter().any(|(r, _)| *r == key.raw_value(p)) {
            presets.push((key.raw_value(p), key.label(p)));
        }
        SettingsView {
            settings: self.ctx.settings(),
            hotkey: key.raw_value(p),
            hotkey_label: key.label(p),
            hotkey_presets: presets,
            models: views,
            claude_ready: linflow_core::llm::load_claude_key().is_some(),
            sync_status: self.sync.status(),
            data_dir: self.ctx.data_dir.display().to_string(),
            log_path: logging::path().display().to_string(),
            trusted: linflow_platform::trusted(false),
            platform: if p == Platform::Mac { "mac".into() } else { "windows".into() },
        }
    }

    /// Saves new settings and applies what changed: the talk key, the model.
    pub fn set_settings(self: &Arc<Self>, new: Settings) {
        let old = self.ctx.settings();
        self.ctx.update_settings(|s| *s = new.clone());
        if new.hotkey != old.hotkey && !new.hotkey.is_empty() {
            let _ = self.set_hotkey(&new.hotkey);
        }
        if new.model_id != old.model_id {
            self.dictation.load_model(&new.model_id);
        }
        if new.audio_retention_days != old.audio_retention_days {
            let _ = self.ctx.history.prune_recordings(new.audio_retention_days, chrono::Utc::now());
        }
    }

    /// Asks the OS for the grant the talk key needs, showing its dialog.
    pub fn request_access(&self) -> bool {
        linflow_platform::trusted(true)
    }

    // MARK: dictations

    /// Newest first.
    pub fn history(&self) -> Vec<HistoryEntry> {
        let mut all = self.ctx.history.all();
        all.reverse();
        all
    }

    pub fn stats(&self) -> StatsView {
        let entries = self.ctx.history.all();
        let local = history::stats_now(&entries);
        let mut view = StatsView { count: local.count, total_words: local.total_words as i64, words_per_minute: local.words_per_minute, streak_days: local.streak_days as i64, caption: None };
        if let Some(c) = self.sync.combined() {
            if c.computers() > 1 {
                view.total_words = c.words;
                view.streak_days = c.streak_days as i64;
                view.caption = Some(c.breakdown());
            }
        }
        view
    }

    pub fn delete_entry(&self, id: &str) -> Result<(), String> {
        self.ctx.history.delete(id).map_err(|e| e.to_string())?;
        self.ctx.emit(Event::HistoryChanged);
        Ok(())
    }

    pub fn edit_entry(&self, id: &str, text: &str) -> Result<(), String> {
        self.dictation.edit(id, text)
    }

    pub fn retry_entry(&self, id: &str) -> Result<HistoryEntry, String> {
        self.dictation.retry(id)
    }

    pub fn audio_path(&self, id: &str) -> Option<String> {
        let entry = self.ctx.history.all().into_iter().find(|e| e.id == id)?;
        self.ctx.history.audio_path(&entry).map(|p| p.display().to_string())
    }

    // MARK: dictionary

    pub fn dictionary(&self) -> DictionaryView {
        let d = &self.ctx.dictionary;
        DictionaryView { terms: d.terms(), rules: linflow_core::text::glossary::display_order(&d.rules()), pending: d.pending() }
    }

    // MARK: notes

    pub fn notes(&self) -> Vec<MeetingNote> {
        self.ctx.notes.list()
    }

    pub fn note(&self, id: &str) -> Option<NoteDetail> {
        let note = self.ctx.notes.load(id)?;
        let segments = self.ctx.notes.transcript(id);
        let recording = self.meetings.recording_id().as_deref() == Some(id);
        Some(NoteDetail {
            speakers: notes::speakers(&segments),
            my_notes: self.ctx.notes.notes_text(id),
            summary: self.ctx.notes.summary(id).unwrap_or_default(),
            running_notes: self.ctx.notes.running_notes(id),
            questions: self.ctx.notes.questions(id),
            has_audio: self.ctx.notes.has_audio(id),
            elapsed: if recording { self.meetings.elapsed().unwrap_or(0.0) } else { note.duration_seconds },
            busy: self.work.busy(id).map(String::from),
            asking: self.work.is_asking(id),
            recording,
            segments,
            note,
        })
    }

    pub fn create_note(&self) -> Result<MeetingNote, String> {
        let note = self.ctx.notes.create(&MeetingNote::default_title(chrono::Local::now())).map_err(|e| e.to_string())?;
        self.ctx.emit(Event::Note { event: NoteEvent::Listed });
        Ok(note)
    }

    pub fn start_note(self: &Arc<Self>, id: Option<&str>, app: Option<&str>) -> Result<String, String> {
        self.meetings.start(id, app)
    }

    pub fn stop_note(self: &Arc<Self>) -> Option<String> {
        self.meetings.stop(false)
    }

    pub fn rename_note(&self, id: &str, title: &str) -> Result<MeetingNote, String> {
        notes::rename(&self.ctx, id, title)
    }

    pub fn relabel_speaker(&self, id: &str, from: &str, to: &str) -> Result<(), String> {
        notes::relabel(&self.ctx, id, from, to)
    }

    pub fn save_my_notes(&self, id: &str, text: &str) -> Result<(), String> {
        self.ctx.notes.save_notes_text(id, text).map_err(|e| e.to_string())
    }

    /// Deletes notes to the system's trash (the Mac's Trash, Windows' Recycle Bin) through the
    /// `trash` the app passes, so a mistaken delete can be undone from the Finder or Explorer.
    pub fn delete_notes(&self, ids: &[String], trash: &dyn Fn(&std::path::Path) -> std::io::Result<()>) -> Result<(), String> {
        let recording = self.meetings.recording_id();
        for id in ids {
            if recording.as_deref() == Some(id.as_str()) {
                return Err("Stop the recording first.".into());
            }
            self.ctx.notes.delete(id, trash).map_err(|e| e.to_string())?;
        }
        self.ctx.emit(Event::Note { event: NoteEvent::Listed });
        Ok(())
    }

    pub fn summarize(&self, id: &str) {
        self.work.summarize(id, false);
    }

    pub fn recap(&self, id: &str, minutes: f64) {
        self.work.recap(id, minutes);
    }

    pub fn ask(&self, id: &str, question: &str) {
        self.work.ask(id, question);
    }

    pub fn transcribe_again(&self, id: &str) -> Result<(), String> {
        if self.meetings.recording_id().as_deref() == Some(id) {
            return Err("Stop the recording first.".into());
        }
        self.work.transcribe_from_audio(id, false);
        Ok(())
    }

    pub fn note_markdown(&self, id: &str) -> Option<String> {
        let note = self.ctx.notes.load(id)?;
        Some(self.ctx.notes.markdown(&note))
    }

    // MARK: toasts

    /// What clicking a toast asked for. Returns a window section to show, if any.
    pub fn toast_action(self: &Arc<Self>, action: ToastAction) -> Option<String> {
        match action {
            ToastAction::OpenDictionary => Some("dictionary".into()),
            ToastAction::AddRule { from, to } => {
                if let Err(e) = self.ctx.dictionary.accept(&from, &to) {
                    log::warn!("could not add {from} => {to}: {e}");
                }
                None
            }
            ToastAction::RecordMeeting { app, .. } => match self.meetings.start(None, Some(&app)) {
                Ok(id) => Some(format!("note:{id}")),
                Err(e) => {
                    self.ctx.toast(Toast::new("Could not start the note", e).warning());
                    None
                }
            },
            ToastAction::KeepRecording => {
                self.detection.keep_recording();
                None
            }
            ToastAction::StopNote => {
                self.detection.keep_recording();
                self.meetings.stop(false).map(|id| format!("note:{id}"))
            }
            ToastAction::RepairAudio => {
                match linflow_core::repair::write_script(&self.ctx.data_dir, cfg!(windows)) {
                    Ok(path) => Some(format!("open:{}", path.display())),
                    Err(e) => {
                        log::error!("audio repair: {e}");
                        None
                    }
                }
            }
            ToastAction::OpenNote { id } => Some(format!("note:{id}")),
        }
    }
}
