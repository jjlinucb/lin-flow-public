//! Hold to talk: the key, the microphone, the model, the cleanup, the paste. The Swift app's
//! DictationController, step for step, minus transforms and snippets, which the rebuild drops.
//!
//! Three threads, so a key press is never queued behind a transcription still running: the
//! talk key's own (it only hands the press on), the audio thread (opens and closes the
//! microphone, in order), and the work thread (the model, the cleanup, the paste, the history).

use crate::context::Context;
use crate::engine::{self, EngineSlot};
use crate::events::{DictationState, Event, Toast, ToastAction};
use crate::readback::Readback;
use linflow_core::audio::{self, peak, SAMPLE_RATE, SAMPLE_RATE_F};
use linflow_core::history::{self, HistoryEntry};
use linflow_core::models;
use linflow_core::repair::SilentStreak;
use linflow_platform::mic::Microphone;
use linflow_platform::{App, Sound};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Accidental taps shorter than this are ignored.
pub const MINIMUM_CLIP_SECONDS: f64 = 0.35;
/// Below this peak the clip is silence.
pub const SILENCE_PEAK: f32 = 0.01;
/// How long the dictation sits on the clipboard before John's own goes back.
pub const RESTORE_AFTER: Duration = Duration::from_millis(400);

enum Cmd {
    Press(Instant),
    Release,
}

struct Job {
    samples: Vec<f32>,
    target: Option<App>,
    device: Option<String>,
    first_audio: Option<f64>,
}

pub struct Dictation {
    ctx: Arc<Context>,
    readback: Arc<Readback>,
    state: Mutex<DictationState>,
    commands: Mutex<Sender<Cmd>>,
    pending_model: Mutex<Option<String>>,
    /// Takes sent to the work thread and not yet finished. Only the last one returns to Idle.
    queued: Mutex<usize>,
    pub hotkey_failed: AtomicBool,
    /// While Settings listens for a new talk key, a press does nothing.
    suspended: AtomicBool,
    test_audio: Option<std::path::PathBuf>,
}

/// Whitespace only counts as nothing: both engines return a space or a newline, not "", when
/// they hear no words.
pub fn is_blank(s: &str) -> bool {
    s.trim().is_empty()
}

/// Whisper primed with the glossary sometimes recites it over near-silent audio. VAD catches
/// almost all of that; this catches the rest.
pub fn looks_like_prompt_echo(text: &str, glossary: &[String], peak: f32) -> bool {
    if peak >= 0.05 || text.is_empty() {
        return false;
    }
    let known: std::collections::HashSet<String> = glossary.iter().flat_map(|t| t.to_lowercase().split(' ').map(String::from).collect::<Vec<_>>()).collect();
    let words: Vec<String> = text
        .to_lowercase()
        .split(|c: char| !c.is_alphanumeric() && c != '.')
        .map(|w| w.trim_matches(|c: char| !c.is_alphanumeric()).to_string())
        .filter(|w| !w.is_empty())
        .collect();
    !words.is_empty() && words.len() <= 8 && words.iter().all(|w| known.contains(w))
}

/// Whether an audio error is the computer's audio service being wedged rather than a missing
/// device: the Mac's "not running" status, or Windows' audio service being down.
pub fn looks_stuck(error: &str) -> bool {
    let e = error.to_lowercase();
    ["1937010544", "notrunning", "not running", "0x88890010", "-2004287472", "service_not_running"].iter().any(|k| e.contains(k))
}

fn rounded(x: f64, places: f64) -> f64 {
    (x * places).round() / places
}

impl Dictation {
    pub fn new(ctx: Arc<Context>, readback: Arc<Readback>) -> Arc<Dictation> {
        let (tx, rx) = mpsc::channel();
        let d = Arc::new(Dictation {
            ctx,
            readback,
            state: Mutex::new(DictationState::Loading("model".into())),
            commands: Mutex::new(tx),
            pending_model: Mutex::new(None),
            queued: Mutex::new(0),
            hotkey_failed: AtomicBool::new(false),
            suspended: AtomicBool::new(false),
            test_audio: std::env::var_os("LINFLOW_TEST_AUDIO").map(Into::into),
        });
        let (work_tx, work_rx) = mpsc::channel::<Job>();
        let a = d.clone();
        std::thread::Builder::new().name("linflow.audio".into()).spawn(move || a.audio_loop(rx, work_tx)).expect("audio thread");
        let w = d.clone();
        std::thread::Builder::new().name("linflow.work".into()).spawn(move || w.work_loop(work_rx)).expect("work thread");
        d
    }

    pub fn state(&self) -> DictationState {
        self.state.lock().map(|s| s.clone()).unwrap_or(DictationState::Idle)
    }

    pub fn set_state(&self, s: DictationState) {
        if let Ok(mut cur) = self.state.lock() {
            if *cur == s {
                return;
            }
            if !matches!(s, DictationState::Downloading(..)) {
                log::info!("state: {}", s.label());
            }
            *cur = s.clone();
        }
        self.ctx.emit(Event::state(&s));
    }

    /// Safe from any thread: the talk key calls it from its own, the pill's button from the UI.
    pub fn press(&self) {
        if self.suspended.load(Ordering::Relaxed) {
            return;
        }
        if let Ok(tx) = self.commands.lock() {
            let _ = tx.send(Cmd::Press(Instant::now()));
        }
    }

    pub fn release(&self) {
        if let Ok(tx) = self.commands.lock() {
            let _ = tx.send(Cmd::Release);
        }
    }

    pub fn suspend(&self, on: bool) {
        self.suspended.store(on, Ordering::Relaxed);
    }

    // MARK: the audio thread

    fn audio_loop(self: Arc<Self>, rx: Receiver<Cmd>, work: Sender<Job>) {
        let mut pressed = false;
        let mut mic: Option<Microphone> = None;
        let mut mic_opened_at = Instant::now();
        let mut key_at = Instant::now();
        let buffer: Arc<Mutex<Vec<f32>>> = Arc::new(Mutex::new(Vec::new()));
        let level = Arc::new(AtomicU32::new(0));
        let mut target: Option<App> = None;
        let mut streak = SilentStreak::default();
        loop {
            // While a take records, wake ten times a second to send the meter.
            let cmd = if pressed {
                match rx.recv_timeout(Duration::from_millis(100)) {
                    Ok(c) => c,
                    Err(RecvTimeoutError::Timeout) => {
                        self.ctx.emit(Event::Level { level: f32::from_bits(level.load(Ordering::Relaxed)) });
                        continue;
                    }
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            } else {
                match rx.recv() {
                    Ok(c) => c,
                    Err(_) => return,
                }
            };
            match cmd {
                Cmd::Press(at) => {
                    if pressed {
                        continue;
                    }
                    let state = self.state();
                    if !self.ctx.engine.is_loaded() || !matches!(state, DictationState::Idle | DictationState::Transcribing) {
                        self.ctx.sound(Sound::Error);
                        continue;
                    }
                    pressed = true;
                    key_at = at;
                    // The previous dictation's readback keeps running: two dictations into the
                    // same box inside 15 s is normal, and a fix to the first must still count.
                    target = linflow_platform::frontmost_app();
                    buffer.lock().unwrap().clear();
                    level.store(0, Ordering::Relaxed);
                    if self.test_audio.is_none() {
                        mic_opened_at = Instant::now();
                        match self.open_microphone(buffer.clone(), level.clone()) {
                            Ok(m) => mic = Some(m),
                            Err(e) => {
                                pressed = false;
                                log::error!("recorder: {e}");
                                let stuck = looks_stuck(&e);
                                if stuck {
                                    self.audio_stuck();
                                }
                                self.set_state(DictationState::Error(if stuck { "audio is stuck".into() } else { e }));
                                self.ctx.sound(Sound::Error);
                                let me = self.clone();
                                std::thread::spawn(move || {
                                    std::thread::sleep(Duration::from_secs(3));
                                    if matches!(me.state(), DictationState::Error(_)) && me.ctx.engine.is_loaded() && !me.hotkey_failed.load(Ordering::Relaxed) {
                                        me.set_state(DictationState::Idle);
                                    }
                                });
                                continue;
                            }
                        }
                    }
                    self.set_state(DictationState::Recording);
                    self.ctx.sound(Sound::Start);
                }
                Cmd::Release => {
                    if !pressed {
                        continue;
                    }
                    pressed = false;
                    let (device, first_audio) = match mic.take() {
                        Some(m) => {
                            let device = Some(m.device.clone());
                            let first = m.first_audio().map(|d| rounded((d + mic_opened_at.duration_since(key_at)).as_secs_f64(), 1000.0));
                            if let Some(f) = first {
                                log::info!("microphone: {}, first audio {f:.2}s after the key", m.device);
                            } else {
                                log::info!("microphone: {}, no audio arrived", m.device);
                            }
                            drop(m);
                            (device, first)
                        }
                        None => (None, None),
                    };
                    let mut samples = std::mem::take(&mut *buffer.lock().unwrap());
                    self.ctx.sound(Sound::Stop);
                    if let Some(path) = &self.test_audio {
                        samples = audio::load_samples(path).unwrap_or_default();
                    }
                    let seconds = samples.len() as f64 / SAMPLE_RATE_F;
                    let dead = audio::is_dead_microphone(&samples);
                    // A tap too short to judge neither adds to the streak nor breaks it.
                    let judged = samples.len() >= SAMPLE_RATE as usize / 2;
                    if self.test_audio.is_none() && judged && streak.record(dead) {
                        log::info!("audio stuck: a second take in a row of pure digital silence");
                        self.audio_stuck();
                        self.ctx.sound(Sound::Error);
                        self.set_state(DictationState::Idle);
                        continue;
                    }
                    if dead {
                        log::info!("dead microphone: {seconds:.1}s of pure digital silence from {}", device.as_deref().unwrap_or("the default input"));
                        self.ctx.sound(Sound::Error);
                        let name = device.clone().unwrap_or_else(|| "The microphone".into());
                        self.ctx.toast(Toast::new(format!("{name} sent only silence"), "Check that it is not muted, or pick another input in Sound settings.").warning().seconds(8.0));
                        self.set_state(DictationState::Idle);
                        continue;
                    }
                    if seconds < MINIMUM_CLIP_SECONDS || peak(&samples) < SILENCE_PEAK {
                        log::info!("dropped clip ({seconds:.2}s, peak {:.3})", peak(&samples));
                        self.set_state(DictationState::Idle);
                        continue;
                    }
                    {
                        let mut queued = self.queued.lock().unwrap();
                        *queued += 1;
                        self.set_state(DictationState::Transcribing);
                    }
                    let _ = work.send(Job { samples, target: target.take(), device, first_audio });
                }
            }
        }
    }

    /// A fresh stream per take already recovers from most device trouble. The stuck error gets
    /// one more try after a short pause, in case the audio service was only mid-switch.
    fn open_microphone(&self, buffer: Arc<Mutex<Vec<f32>>>, level: Arc<AtomicU32>) -> Result<Microphone, String> {
        let make = || {
            let buffer = buffer.clone();
            let level = level.clone();
            Box::new(move |chunk: &[f32]| {
                // Fast attack, slow decay, so the meter reads as speech rather than noise.
                let rms = audio::rms(chunk);
                let prev = f32::from_bits(level.load(Ordering::Relaxed));
                level.store(rms.max(prev * 0.75).to_bits(), Ordering::Relaxed);
                if let Ok(mut b) = buffer.lock() {
                    b.extend_from_slice(chunk);
                }
            }) as linflow_platform::OnChunk
        };
        match Microphone::start(make()) {
            Ok(m) => Ok(m),
            Err(e) if looks_stuck(&e) => {
                log::info!("microphone: {e}, trying once more");
                std::thread::sleep(Duration::from_millis(300));
                let m = Microphone::start(make())?;
                log::info!("microphone: the second try worked");
                Ok(m)
            }
            Err(e) => Err(e),
        }
    }

    fn audio_stuck(&self) {
        let what = if cfg!(windows) { "Windows audio looks stuck" } else { "The Mac's audio looks stuck" };
        self.ctx.toast(
            Toast::new(what, "Click to restart it. It asks for your password, and dictation works again a few seconds later.")
                .warning()
                .seconds(15.0)
                .on_click(ToastAction::RepairAudio),
        );
    }

    // MARK: the work thread

    fn work_loop(self: Arc<Self>, rx: Receiver<Job>) {
        for job in rx {
            self.process(job);
            // A take released while this one ran is still to come: the pill stays orange for it.
            let mut queued = self.queued.lock().unwrap();
            *queued = queued.saturating_sub(1);
            if *queued == 0 && matches!(self.state(), DictationState::Transcribing) {
                self.set_state(DictationState::Idle);
            }
        }
    }

    fn process(&self, job: Job) {
        let settings = self.ctx.settings();
        let terms = self.ctx.dictionary.terms();
        let options = engine::options(&settings, &terms);
        let id = history::new_id();
        let audio_file = (settings.audio_retention_days > 0).then(|| self.save_recording(&job.samples, &id)).flatten();
        let (mut result, mut model, kind) = match self.ctx.engine.transcribe(&job.samples, &options) {
            Ok(r) => r,
            Err(e) => {
                log::error!("transcribe failed: {e}");
                self.ctx.sound(Sound::Error);
                if let Some(f) = &audio_file {
                    let _ = std::fs::remove_file(self.ctx.history.recordings.join(f));
                }
                return;
            }
        };
        // A take that produced nothing is retried on the other engine kind before it is given
        // up on: in heavy babble Parakeet returns nothing where Whisper degrades (NOISE.md).
        if is_blank(&result.text) {
            if let Some(path) = models::rescue_model(kind, &models::installed()) {
                log::info!("empty transcript; retrying on {}", models::id_from_path(&path));
                if let Ok(mut second) = linflow_engine::load(&path) {
                    if let Ok(retry) = second.transcribe(&job.samples, &options) {
                        if !is_blank(&retry.text) {
                            log::info!("rescued by {}", models::id_from_path(&path));
                            model = second.model_id();
                            result = retry;
                        }
                    }
                }
            }
        }
        let raw = result.text.clone();
        let mut text = self.ctx.dictionary.clean(&raw, &settings);
        if looks_like_prompt_echo(&text, &terms, peak(&job.samples)) {
            log::info!("dropped prompt echo: {text}");
            text.clear();
        }
        let (snr, floor) = audio::snr_estimate(&job.samples, 30);
        log::info!(
            "{:.1}s audio -> {:.2}s {} | snr~{snr:.0}dB floor {floor:.4} | raw: {raw} | out: {text}",
            result.audio_seconds,
            result.inference_seconds,
            model
        );
        if text.is_empty() {
            if is_blank(&raw) {
                // The engine heard nothing in a clip that passed the gates, so there was speech
                // in it. Keep the recording for Retry, and make a sound: silence here looks
                // exactly like a broken talk key.
                log::info!("no transcript for a clip with speech in it; keeping the audio to retry");
                self.ctx.sound(Sound::Error);
            } else if let Some(f) = &audio_file {
                let _ = std::fs::remove_file(self.ctx.history.recordings.join(f));
            }
            return;
        }
        let to_paste = if settings.trailing_space && !text.ends_with('\n') { format!("{text} ") } else { text.clone() };
        if std::env::var_os("LINFLOW_NO_PASTE").is_some() {
            log::info!("LINFLOW_NO_PASTE set; not pasting: {to_paste}");
        } else {
            linflow_platform::paste(&to_paste, RESTORE_AFTER);
            // Then watch that field: a fix typed by hand becomes a dictionary correction.
            if settings.learn_corrections != linflow_core::learn::LearnMode::Off {
                if let Some(app) = linflow_platform::frontmost_app() {
                    self.readback.watch(&text, app.pid, &app.name, settings.learn_corrections);
                }
            }
        }
        let mut entry = HistoryEntry::new(&raw, &text, &model, result.audio_seconds, result.inference_seconds);
        entry.id = id;
        entry.audio_file = audio_file;
        entry.input_device = job.device;
        entry.first_audio_seconds = job.first_audio;
        // 99 means the estimate could not judge.
        entry.snr_db = (snr < 99.0).then(|| rounded(snr, 10.0));
        entry.noise_floor = Some(rounded(floor, 100_000.0));
        entry.app = job.target.map(|a| a.id).filter(|id| !id.is_empty());
        if let Err(e) = self.ctx.history.append(&entry) {
            log::error!("history: could not save the dictation: {e}");
        }
        self.ctx.emit(Event::Dictated { entry });
    }

    fn save_recording(&self, samples: &[f32], id: &str) -> Option<String> {
        let name = format!("{id}.wav");
        let _ = std::fs::create_dir_all(&self.ctx.history.recordings);
        match linflow_core::wav::write(&self.ctx.history.recordings.join(&name), samples, SAMPLE_RATE) {
            Ok(()) => Some(name),
            Err(e) => {
                log::warn!("could not keep the recording: {e}");
                None
            }
        }
    }

    // MARK: the model

    /// Switches models, downloading first when the file is not on disk yet.
    pub fn load_model(self: &Arc<Self>, id: &str) {
        self.ctx.update_settings(|s| s.model_id = id.to_string());
        *self.pending_model.lock().unwrap() = Some(id.to_string());
        let me = self.clone();
        let id = id.to_string();
        std::thread::Builder::new()
            .name("linflow.model".into())
            .spawn(move || me.load_blocking(&id))
            .ok();
    }

    fn still_wanted(&self, id: &str) -> bool {
        self.pending_model.lock().map(|p| p.as_deref() == Some(id)).unwrap_or(false)
    }

    fn load_blocking(self: &Arc<Self>, id: &str) {
        let settings = self.ctx.settings();
        if settings.use_vad && models::vad_model_path().is_none() {
            std::thread::spawn(|| {
                let dest = linflow_core::paths::models_dir().join(models::VAD_MODEL.file_name);
                if let Err(e) = linflow_core::net::download(models::VAD_MODEL.url, &dest, &mut |_| {}, &|| true) {
                    log::warn!("VAD model download failed: {e}");
                }
            });
        }
        let path = match models::locate(id) {
            Some(p) => p,
            None => {
                let Some(info) = models::info(id) else {
                    self.set_state(DictationState::Error(format!("unknown model {id}")));
                    return;
                };
                self.set_state(DictationState::Downloading(id.into(), 0.0));
                let dest = linflow_core::paths::models_dir().join(info.file_name);
                let me = self.clone();
                let wanted = id.to_string();
                let result = linflow_core::net::download(
                    info.url,
                    &dest,
                    &mut |p| {
                        if me.still_wanted(&wanted) {
                            me.set_state(DictationState::Downloading(wanted.clone(), p));
                        }
                    },
                    &|| self.still_wanted(id),
                );
                if let Err(e) = result {
                    if self.still_wanted(id) {
                        self.set_state(DictationState::Error(format!("download failed: {e}")));
                        self.ctx.sound(Sound::Error);
                    }
                    return;
                }
                dest
            }
        };
        if !self.still_wanted(id) {
            return;
        }
        self.set_state(DictationState::Loading(id.into()));
        match engine::load_warm(&path, &settings, &self.ctx.dictionary.terms()) {
            Ok(e) => {
                log::info!("ready: {}", e.display_name());
                if !self.still_wanted(id) {
                    return;
                }
                self.ctx.engine.set(Some(e));
                if self.hotkey_failed.load(Ordering::Relaxed) {
                    self.set_state(DictationState::Error("no keyboard access".into()));
                } else {
                    self.set_state(DictationState::Idle);
                }
                self.ctx.sound(Sound::Ready);
            }
            Err(e) => {
                log::error!("model load failed: {e}");
                self.set_state(DictationState::Error(e.to_string()));
                self.ctx.sound(Sound::Error);
            }
        }
    }

    /// Runs a saved dictation through the current model again: the Retry button.
    pub fn retry(&self, id: &str) -> Result<HistoryEntry, String> {
        let mut entry = self.ctx.history.all().into_iter().find(|e| e.id == id).ok_or("That dictation is gone.")?;
        let path = self.ctx.history.audio_path(&entry).ok_or("The audio for this dictation is gone.")?;
        let samples = audio::load_samples(&path)?;
        let settings = self.ctx.settings();
        let options = engine::options(&settings, &self.ctx.dictionary.terms());
        let (result, model, _) = self.ctx.engine.transcribe(&samples, &options).map_err(|e| e.to_string())?;
        entry.raw = result.text.clone();
        entry.text = self.ctx.dictionary.clean(&result.text, &settings);
        entry.original = None;
        entry.transform = None;
        entry.model = model;
        entry.inference_seconds = result.inference_seconds;
        self.ctx.history.update(&entry).map_err(|e| e.to_string())?;
        self.ctx.emit(Event::HistoryChanged);
        Ok(entry)
    }

    /// A dictation edited in the window: saved, and run through the learning setting.
    pub fn edit(&self, id: &str, text: &str) -> Result<(), String> {
        let mut entry = self.ctx.history.all().into_iter().find(|e| e.id == id).ok_or("That dictation is gone.")?;
        let wrote = std::mem::replace(&mut entry.text, text.to_string());
        if wrote == text {
            return Ok(());
        }
        self.ctx.history.update(&entry).map_err(|e| e.to_string())?;
        self.ctx.emit(Event::HistoryChanged);
        self.ctx.dictionary.learn(&wrote, text, self.ctx.settings().learn_corrections);
        Ok(())
    }
}

#[allow(dead_code)]
fn _slot_is_shared(_: &EngineSlot) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_echo_is_only_the_glossary_over_quiet_audio() {
        let g = vec!["Lin Flow".to_string(), "Parakeet".to_string()];
        assert!(looks_like_prompt_echo("Lin Flow, Parakeet.", &g, 0.02));
        assert!(!looks_like_prompt_echo("Lin Flow, Parakeet.", &g, 0.2), "loud audio is real speech");
        assert!(!looks_like_prompt_echo("Open Lin Flow now.", &g, 0.02));
    }

    #[test]
    fn stuck_audio_is_recognized_by_its_codes() {
        assert!(looks_stuck("The requested device is no longer available. 1937010544"));
        assert!(looks_stuck("AUDCLNT_E_SERVICE_NOT_RUNNING (0x88890010)"));
        assert!(!looks_stuck("No microphone is connected."));
    }
}
