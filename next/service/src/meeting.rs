//! One meeting: the microphone (you) and what the computer plays (everyone else on the call)
//! captured side by side, each cut into pieces for the live transcript, the audio kept as WAV.
//! The Swift and C# MeetingRecorders, once.
//!
//! The recording is the product and the live transcript is a view of it, so:
//! - audio goes to disk as it arrives through a WAV writer whose header stays valid, so a crash
//!   costs at most the last second instead of the whole meeting;
//! - each track is kept on the note's clock: a slow start, a stall or a device switch is filled
//!   with silence, so "You" and "Others" line up in any editor and in the transcript;
//! - a source that stops delivering is restarted (the microphone when the input device changes,
//!   the call's audio when the output changes, either when nothing has arrived for 3 s), and one
//!   failing source never takes the other down with it;
//! - a second session on the same note appends to its audio instead of overwriting it.
//!
//! Every gap, restart and failure is also written to the note's events.log.

use crate::context::Context;
use crate::engine;
use crate::events::{Event, NoteEvent};
use crate::notes::{self, NoteWork};
use linflow_core::audio::{self, SAMPLE_RATE, SAMPLE_RATE_F};
use linflow_core::meeting::detect::Recording as Observed;
use linflow_core::meeting::live::{Cut, LiveSegmenter};
use linflow_core::meeting::running;
use linflow_core::meeting::tracker;
use linflow_core::meeting::{OTHERS, YOU};
use linflow_core::notes::{transcript_text, MeetingNote, TranscriptSegment};
use linflow_core::wav::WavWriter;
use linflow_platform::mic::Microphone;
use linflow_platform::SystemAudio;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// A source is stale when nothing has arrived for this long.
pub const STALE_AFTER: f64 = 3.0;
/// The live segmenter is fed in pieces of this many samples, 0.1 s, whatever size the device
/// delivers: its noise floor is tuned per chunk.
const FEED: usize = 1600;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    Mic,
    System,
}

impl Source {
    fn file(self) -> &'static str {
        match self {
            Source::Mic => "mic",
            Source::System => "system",
        }
    }

    fn speaker(self) -> &'static str {
        match self {
            Source::Mic => YOU,
            Source::System => OTHERS,
        }
    }
}

/// Zeros to insert before a chunk so the track catches up with the clock. Normal delivery
/// jitter is tens of milliseconds and must never pad; the first chunk of a session is pure
/// start-up latency, so it aligns more tightly.
pub fn shortfall(expected: usize, have: usize, first: bool) -> usize {
    let threshold = ((if first { 0.1 } else { 0.5 }) * SAMPLE_RATE_F) as usize;
    let deficit = expected.saturating_sub(have);
    if deficit > threshold {
        deficit
    } else {
        0
    }
}

fn stamp(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, (s % 3600) / 60, s % 60)
    } else {
        format!("{}:{:02}", s / 60, s % 60)
    }
}

enum Io {
    Chunk(Source, Vec<f32>, Instant),
    Stop(Sender<()>),
}

/// What the detector and the window read about a recording while it runs.
#[derive(Default)]
struct Live {
    mic_level: f32,
    system_level: f32,
    last_speech: Option<Instant>,
    mic_last_speech: Option<Instant>,
    mic_dead_since: Option<Instant>,
    system_dead_since: Option<Instant>,
}

struct Track {
    source: Source,
    segmenter: LiveSegmenter,
    writer: Option<WavWriter>,
    wanted: bool,
    pending: Vec<f32>,
    last_chunk_at: Option<Instant>,
    saw_first_chunk: bool,
    fed_this_session: usize,
    restart_at: Option<Instant>,
    restart_reason: String,
    last_restart_at: Option<Instant>,
    backoff: f64,
    failing: bool,
    write_failing: bool,
}

impl Track {
    fn new(source: Source) -> Track {
        Track {
            source,
            segmenter: LiveSegmenter::new(),
            writer: None,
            wanted: false,
            pending: Vec::new(),
            last_chunk_at: None,
            saw_first_chunk: false,
            fed_this_session: 0,
            restart_at: None,
            restart_reason: String::new(),
            last_restart_at: None,
            backoff: 2.0,
            failing: false,
            write_failing: false,
        }
    }
}

/// A recording in progress.
struct Active {
    note_id: String,
    app: Option<String>,
    started: Instant,
    previous: f64,
    io: Sender<Io>,
    io_thread: Option<std::thread::JoinHandle<()>>,
    decode_thread: Option<std::thread::JoinHandle<()>>,
    live: Arc<Mutex<Live>>,
    notes_stop: Arc<AtomicBool>,
    notes_thread: Option<std::thread::JoinHandle<()>>,
    tracker_thread: Option<std::thread::JoinHandle<()>>,
    _awake: Option<linflow_platform::AwakeGuard>,
}

pub struct Meetings {
    ctx: Arc<Context>,
    work: Arc<NoteWork>,
    active: Mutex<Option<Active>>,
}

/// The pieces one recording's threads share.
struct Session {
    ctx: Arc<Context>,
    note_id: String,
    /// Zero of the note's clock: this session's start, minus what was recorded before.
    session_start: Instant,
    previous: f64,
    live: Arc<Mutex<Live>>,
    decode: Sender<Option<(Source, Cut)>>,
}

impl Session {
    /// Seconds into the note: what earlier sessions recorded, plus this one so far. Counted from
    /// this session's start rather than back from now, since an Instant cannot reach before the
    /// computer's own clock began, and a long meeting resumed soon after a restart would.
    fn note_seconds(&self, at: Instant) -> f64 {
        self.previous + at.duration_since(self.session_start).as_secs_f64()
    }
}

impl Meetings {
    pub fn new(ctx: Arc<Context>, work: Arc<NoteWork>) -> Arc<Meetings> {
        Arc::new(Meetings { ctx, work, active: Mutex::new(None) })
    }

    pub fn recording_id(&self) -> Option<String> {
        self.active.lock().unwrap().as_ref().map(|a| a.note_id.clone())
    }

    pub fn recording_app(&self) -> Option<String> {
        self.active.lock().unwrap().as_ref().and_then(|a| a.app.clone())
    }

    pub fn elapsed(&self) -> Option<f64> {
        self.active.lock().unwrap().as_ref().map(|a| a.previous + a.started.elapsed().as_secs_f64())
    }

    /// What the detector needs to know about the recording, or None when nothing records.
    pub fn observed(&self) -> Option<Observed> {
        let guard = self.active.lock().unwrap();
        let a = guard.as_ref()?;
        let live = a.live.lock().unwrap();
        let now = Instant::now();
        let ago = |t: Option<Instant>, fallback: Instant| now.duration_since(t.unwrap_or(fallback)).as_secs_f64();
        Some(Observed {
            app: a.app.clone(),
            quiet_for: ago(live.last_speech, a.started),
            mic_dead_for: live.mic_dead_since.map_or(0.0, |t| now.duration_since(t).as_secs_f64()),
            system_dead_for: live.system_dead_since.map_or(0.0, |t| now.duration_since(t).as_secs_f64()),
            mic_spoke_ago: ago(live.mic_last_speech, a.started),
            seconds: a.previous + a.started.elapsed().as_secs_f64(),
        })
    }

    /// Starts recording `note_id`, or a new note when None. `app` is the call app it was offered
    /// for, so its end can be noticed.
    pub fn start(self: &Arc<Self>, note_id: Option<&str>, app: Option<&str>) -> Result<String, String> {
        let mut guard = self.active.lock().unwrap();
        if guard.is_some() {
            return Err("Another meeting is recording. Stop it first.".into());
        }
        if !self.ctx.engine.is_loaded() {
            return Err("The speech model is still loading.".into());
        }
        let settings = self.ctx.settings();
        let (use_mic, use_system) = (settings.meeting_uses_microphone, settings.meeting_uses_system_audio);
        if !use_mic && !use_system {
            return Err("Turn on the microphone, system audio, or both.".into());
        }
        let existing = note_id.and_then(|id| self.ctx.notes.load(id));
        let created = existing.is_none();
        let mut note = match existing {
            Some(n) => n,
            None => {
                let title = match app.and_then(linflow_core::meeting::detect::call_app_name) {
                    Some(name) => format!("{name} {}", MeetingNote::default_title(chrono::Local::now())),
                    None => MeetingNote::default_title(chrono::Local::now()),
                };
                self.ctx.notes.create(&title).map_err(|e| e.to_string())?
            }
        };
        let id = note.id.clone();
        let previous = note.duration_seconds.max(0.0);
        let keep_audio = settings.keep_meeting_audio;
        if keep_audio {
            let _ = std::fs::create_dir_all(self.ctx.notes.folder(&id));
        }
        let now = Instant::now();
        let (io_tx, io_rx) = mpsc::channel::<Io>();
        let (decode_tx, decode_rx) = mpsc::channel::<Option<(Source, Cut)>>();
        let live = Arc::new(Mutex::new(Live::default()));
        let session = Arc::new(Session {
            ctx: self.ctx.clone(),
            note_id: id.clone(),
            session_start: now,
            previous,
            live: live.clone(),
            decode: decode_tx,
        });
        // The live transcript: one piece at a time through the shared model.
        let dec = session.clone();
        let decode_thread = std::thread::Builder::new().name("linflow.live".into()).spawn(move || decode_loop(dec, decode_rx)).map_err(|e| e.to_string())?;

        let mut tracks = vec![Track::new(Source::System), Track::new(Source::Mic)];
        let mut sources = Sources { mic: None, system: None, io: io_tx.clone(), input: linflow_platform::mic::default_input_name(), output: linflow_platform::mic::default_output_name() };
        let mut started = vec![];
        let mut failed = vec![];
        for t in tracks.iter_mut() {
            let want = match t.source {
                Source::Mic => use_mic,
                Source::System => use_system,
            };
            if !want {
                continue;
            }
            t.wanted = true;
            if keep_audio {
                match WavWriter::create(&self.ctx.notes.audio_path(&id, t.source.file()), SAMPLE_RATE, true) {
                    Ok(w) => t.writer = Some(w),
                    Err(e) => {
                        log::error!("meeting: could not open {} audio file: {e}", t.source.file());
                        failed.push((t.source, e.to_string()));
                    }
                }
            }
            match sources.start(t.source) {
                Ok(()) => started.push(t.source),
                Err(e) => {
                    t.restart_at = Some(Instant::now() + Duration::from_secs_f64(t.backoff));
                    t.restart_reason = format!("retrying after: {e}");
                    failed.push((t.source, e));
                }
            }
        }
        if started.is_empty() {
            let why = failed.first().map(|(_, e)| e.clone()).unwrap_or_else(|| "No audio source could start.".into());
            let _ = session.decode.send(None);
            drop(tracks);
            if created {
                // Nothing was recorded: leave no empty note behind for the list or the next launch.
                let _ = self.ctx.notes.delete(&id, |p| std::fs::remove_dir_all(p));
            }
            return Err(why);
        }
        note.used_microphone = use_mic;
        note.used_system_audio = use_system;
        note.ended_at = None;
        let _ = self.ctx.notes.save(&note);
        let _ = self.ctx.notes.append_event(
            &id,
            &if previous > 0.0 {
                format!("recording resumed at {} s (mic={use_mic}, system={use_system})", previous as u64)
            } else {
                format!("recording started (mic={use_mic}, system={use_system}, audio kept={keep_audio})")
            },
        );
        for (source, e) in &failed {
            self.report(&format!("{} could not start ({e}). Lin Flow keeps trying every few seconds.", if *source == Source::Mic { "The microphone" } else { "The call's audio" }));
        }
        check_free_space(&self.ctx);

        let sess = session.clone();
        let io_thread = std::thread::Builder::new().name("linflow.meeting.io".into()).spawn(move || io_loop(sess, io_rx, tracks, sources)).map_err(|e| e.to_string())?;

        let notes_stop = Arc::new(AtomicBool::new(false));
        let notes_thread = settings.running_notes.then(|| {
            let ctx = self.ctx.clone();
            let id = id.clone();
            let stop = notes_stop.clone();
            std::thread::Builder::new().name("linflow.running-notes".into()).spawn(move || running_notes_loop(ctx, id, stop)).ok()
        });
        let tracker_thread = settings.call_tracker.then(|| {
            let ctx = self.ctx.clone();
            let id = id.clone();
            let stop = notes_stop.clone();
            std::thread::Builder::new().name("linflow.tracker".into()).spawn(move || tracker_loop(ctx, id, stop)).ok()
        });
        *guard = Some(Active {
            note_id: id.clone(),
            app: app.map(|a| a.to_lowercase()),
            started: now,
            previous,
            io: io_tx,
            io_thread: Some(io_thread),
            decode_thread: Some(decode_thread),
            live,
            notes_stop,
            notes_thread: notes_thread.flatten(),
            tracker_thread: tracker_thread.flatten(),
            _awake: linflow_platform::keep_awake("Lin Flow is recording a meeting"),
        });
        drop(guard);
        log::info!("meeting note {id} recording (mic={use_mic}, system={use_system}, resumed at {} s)", previous as u64);
        self.ctx.emit(Event::Note { event: NoteEvent::Recording { id: id.clone(), recording: true } });
        self.ctx.emit(Event::Note { event: NoteEvent::Listed });
        Ok(id)
    }

    fn report(&self, text: &str) {
        self.ctx.emit(Event::Note { event: NoteEvent::Error { text: text.into() } });
    }

    /// Stops the recording: capture, the last pieces of live transcript, the files, the note.
    /// Then, off this thread, the last running notes, the pass over the recording, the summary
    /// and the recap. `quitting` skips everything after the files.
    pub fn stop(self: &Arc<Self>, quitting: bool) -> Option<String> {
        let mut a = self.active.lock().unwrap().take()?;
        let id = a.note_id.clone();
        let (done_tx, done_rx) = mpsc::channel();
        let _ = a.io.send(Io::Stop(done_tx));
        let _ = done_rx.recv_timeout(Duration::from_secs(20));
        if let Some(t) = a.io_thread.take() {
            let _ = t.join();
        }
        // The live transcript's last pieces are in the file before anything reads it.
        if let Some(t) = a.decode_thread.take() {
            let _ = t.join();
        }
        let duration = a.previous + a.started.elapsed().as_secs_f64();
        if let Some(mut note) = self.ctx.notes.load(&id) {
            note.ended_at = Some(linflow_core::notes::now());
            note.duration_seconds = duration;
            let _ = self.ctx.notes.save(&note);
        }
        let _ = self.ctx.notes.append_event(&id, &format!("recording stopped at {} s", duration as u64));
        log::info!("meeting note stopped after {} s", duration as u64);
        self.ctx.emit(Event::Note { event: NoteEvent::Recording { id: id.clone(), recording: false } });
        self.ctx.emit(Event::Note { event: NoteEvent::Listed });
        a.notes_stop.store(true, Ordering::Relaxed);
        let notes_thread = a.notes_thread.take();
        let tracker_thread = a.tracker_thread.take();
        drop(a);
        if quitting {
            return Some(id);
        }
        let settings = self.ctx.settings();
        let work = self.work.clone();
        let ctx = self.ctx.clone();
        let note_id = id.clone();
        std::thread::spawn(move || {
            // The last running-notes pass reads the live transcript; only then is the transcript
            // rebuilt from the audio, or its new segments would read as unnoted and be noted
            // twice.
            for t in [notes_thread, tracker_thread].into_iter().flatten() {
                let _ = t.join();
            }
            if settings.keep_meeting_audio && settings.transcribe_after_meeting && ctx.notes.has_audio(&note_id) {
                work.transcribe_from_audio(&note_id, true);
            } else {
                work.summarize(&note_id, true);
            }
        });
        Some(id)
    }
}

/// The capture sources, owned by the io thread.
struct Sources {
    mic: Option<Microphone>,
    system: Option<SystemAudio>,
    io: Sender<Io>,
    input: Option<String>,
    output: Option<String>,
}

impl Sources {
    fn start(&mut self, source: Source) -> Result<(), String> {
        let tx = self.io.clone();
        let on_chunk: linflow_platform::OnChunk = Box::new(move |chunk: &[f32]| {
            let _ = tx.send(Io::Chunk(source, chunk.to_vec(), Instant::now()));
        });
        match source {
            Source::Mic => {
                self.mic = None;
                self.mic = Some(Microphone::start(on_chunk)?);
            }
            Source::System => {
                self.system = None;
                self.system = Some(SystemAudio::start(on_chunk)?);
            }
        }
        Ok(())
    }

    fn stop(&mut self) {
        self.mic = None;
        self.system = None;
    }
}

fn io_loop(s: Arc<Session>, rx: Receiver<Io>, mut tracks: Vec<Track>, mut sources: Sources) {
    let mut last_tick = Instant::now();
    let mut last_levels = Instant::now();
    let mut last_devices = Instant::now();
    loop {
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(Io::Chunk(source, chunk, at)) => {
                if let Some(t) = tracks.iter_mut().find(|t| t.source == source) {
                    handle_chunk(&s, t, &chunk, at);
                }
            }
            Ok(Io::Stop(done)) => {
                sources.stop();
                // Every chunk already queued is written before the files close.
                while let Ok(Io::Chunk(source, chunk, at)) = rx.try_recv() {
                    if let Some(t) = tracks.iter_mut().find(|t| t.source == source) {
                        handle_chunk(&s, t, &chunk, at);
                    }
                }
                for t in tracks.iter_mut() {
                    let rest = std::mem::take(&mut t.pending);
                    if !rest.is_empty() {
                        if let Some(cut) = t.segmenter.feed(&rest) {
                            let _ = s.decode.send(Some((t.source, cut)));
                        }
                    }
                    if let Some(cut) = t.segmenter.finish() {
                        let _ = s.decode.send(Some((t.source, cut)));
                    }
                }
                // The live transcript takes its last pieces and ends.
                let _ = s.decode.send(None);
                for t in tracks.iter_mut() {
                    if let Some(mut w) = t.writer.take() {
                        if let Err(e) = w.close() {
                            log::error!("meeting: closing {} audio: {e}", t.source.file());
                        }
                    }
                }
                let _ = done.send(());
                return;
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return,
        }
        let now = Instant::now();
        if now.duration_since(last_levels) >= Duration::from_millis(100) {
            last_levels = now;
            let (mic, system) = {
                let mut l = s.live.lock().unwrap();
                let levels = (l.mic_level, l.system_level);
                l.mic_level *= 0.8;
                l.system_level *= 0.8;
                levels
            };
            s.ctx.emit(Event::Note { event: NoteEvent::Levels { mic, system } });
        }
        if now.duration_since(last_devices) >= Duration::from_secs(2) {
            last_devices = now;
            // A new default device restarts the source that uses it.
            let input = linflow_platform::mic::default_input_name();
            if input != sources.input {
                sources.input = input;
                schedule_restart(&mut tracks, Source::Mic, "the input device changed", 0.5);
            }
            let output = linflow_platform::mic::default_output_name();
            if output != sources.output {
                sources.output = output;
                schedule_restart(&mut tracks, Source::System, "the output device changed", 0.7);
            }
        }
        if now.duration_since(last_tick) >= Duration::from_secs(1) {
            last_tick = now;
            watchdog(&s, &mut tracks, &mut sources, now);
        }
    }
}

fn decode_loop(s: Arc<Session>, rx: Receiver<Option<(Source, Cut)>>) {
    let settings = s.ctx.settings();
    let options = engine::options(&settings, &s.ctx.dictionary.terms());
    let cleaner = s.ctx.dictionary.cleaner(&settings, false);
    for msg in rx {
        let Some((source, cut)) = msg else { break };
        if audio::peak(&cut.samples) <= 0.01 {
            continue;
        }
        let (start, end) = cut.span(s.previous);
        match s.ctx.engine.transcribe(&cut.samples, &options) {
            Ok((t, _, _)) => {
                let text = cleaner.clean(&t.text);
                if text.is_empty() {
                    continue;
                }
                let segment = TranscriptSegment::new(start, end, source.speaker(), &text);
                if let Err(e) = s.ctx.notes.append_segment(&s.note_id, &segment) {
                    log::error!("meeting: could not save a transcript line: {e}");
                }
                s.ctx.emit(Event::Note { event: NoteEvent::Segment { id: s.note_id.clone(), segment } });
            }
            Err(e) => log::error!("live transcribe ({}): {e}", source.speaker()),
        }
    }
}

fn handle_chunk(s: &Session, t: &mut Track, chunk: &[f32], at: Instant) {
    if !t.wanted {
        return;
    }
    if t.last_restart_at.is_some_and(|r| at.duration_since(r).as_secs_f64() > 30.0) {
        t.backoff = 2.0;
    }
    if t.failing {
        t.failing = false;
        log::info!("meeting: {} audio is back", t.source.file());
        let _ = s.ctx.notes.append_event(&s.note_id, &format!("{} audio is back", t.source.file()));
    }
    let first = !t.saw_first_chunk;
    t.saw_first_chunk = true;
    t.last_chunk_at = Some(at);
    t.restart_at = None;

    // The live transcript runs on this session's clock (the note's offset carries the rest).
    let expected_session = (at.duration_since(s.session_start).as_secs_f64() * SAMPLE_RATE_F) as usize;
    let pad_t = shortfall(expected_session, t.fed_this_session + chunk.len(), first);
    if pad_t > 0 {
        feed(s, t, &vec![0.0; pad_t]);
    }
    feed(s, t, chunk);

    // The file runs on the note's clock, so a resumed session lands after the earlier audio.
    let mut pad_f = 0;
    if let Some(w) = t.writer.as_mut() {
        let expected_total = (s.note_seconds(at) * SAMPLE_RATE_F) as usize;
        pad_f = shortfall(expected_total, w.frames as usize + chunk.len(), first);
        let mut result = Ok(());
        let mut left = pad_f;
        while left > 0 && result.is_ok() {
            let n = left.min(SAMPLE_RATE as usize);
            result = w.append(&vec![0.0; n]);
            left -= n;
        }
        if result.is_ok() {
            result = w.append(chunk);
        }
        match result {
            Ok(()) => {
                if t.write_failing {
                    t.write_failing = false;
                    log::info!("meeting: writing {} audio again", t.source.file());
                }
            }
            Err(e) => {
                if !t.write_failing {
                    t.write_failing = true;
                    log::error!("meeting: writing {} audio failed: {e}", t.source.file());
                    let _ = s.ctx.notes.append_event(&s.note_id, &format!("could not write {} audio: {e}", t.source.file()));
                    s.ctx.emit(Event::Note {
                        event: NoteEvent::Error { text: format!("Could not write the meeting audio ({e}). Check the free space on this disk; the transcript keeps going.") },
                    });
                }
            }
        }
    }
    let gap = pad_t.max(pad_f) as f64 / SAMPLE_RATE_F;
    if first {
        if gap > 0.0 {
            log::info!("meeting: {} delivered its first audio {gap:.2} s after start; aligned with silence", t.source.file());
        }
    } else if gap >= 0.5 {
        log::info!("meeting: filled a {gap:.1} s gap in {} with silence", t.source.file());
        let _ = s.ctx.notes.append_event(&s.note_id, &format!("[{}] {gap:.1} s gap in {} filled with silence", stamp(s.note_seconds(at)), t.source.file()));
    }
}

/// Into the segmenter in 0.1 s pieces, with the meter and the speech and dead-side clocks kept.
fn feed(s: &Session, t: &mut Track, samples: &[f32]) {
    t.fed_this_session += samples.len();
    t.pending.extend_from_slice(samples);
    while t.pending.len() >= FEED {
        let piece: Vec<f32> = t.pending.drain(..FEED).collect();
        let cut = t.segmenter.feed(&piece);
        let (level, threshold) = t.segmenter.meter();
        let now = Instant::now();
        {
            let mut l = s.live.lock().unwrap();
            let dead = audio::peak(&piece) == 0.0;
            match t.source {
                Source::Mic => {
                    l.mic_level = l.mic_level.max(level);
                    l.mic_dead_since = if dead { l.mic_dead_since.or(Some(now)) } else { None };
                    if level > threshold {
                        l.mic_last_speech = Some(now);
                    }
                }
                Source::System => {
                    l.system_level = l.system_level.max(level);
                    l.system_dead_since = if dead { l.system_dead_since.or(Some(now)) } else { None };
                }
            }
            if level > threshold {
                l.last_speech = Some(now);
            }
        }
        if let Some(cut) = cut {
            let _ = s.decode.send(Some((t.source, cut)));
        }
    }
}

fn schedule_restart(tracks: &mut [Track], source: Source, reason: &str, after: f64) {
    if let Some(t) = tracks.iter_mut().find(|t| t.source == source && t.wanted) {
        let at = Instant::now() + Duration::from_secs_f64(after);
        t.restart_at = Some(t.restart_at.map_or(at, |r| r.min(at)));
        t.restart_reason = reason.into();
    }
}

fn watchdog(s: &Session, tracks: &mut [Track], sources: &mut Sources, now: Instant) {
    let others_wanted: Vec<Source> = tracks.iter().filter(|t| t.wanted).map(|t| t.source).collect();
    for t in tracks.iter_mut().filter(|t| t.wanted) {
        if let Some(due) = t.restart_at {
            if now >= due {
                let reason = t.restart_reason.clone();
                restart(s, t, sources, &reason, &others_wanted);
                continue;
            }
        }
        let last = t.last_chunk_at.or(t.last_restart_at).unwrap_or(s.session_start);
        let quiet = now.duration_since(last).as_secs_f64();
        let since_restart = t.last_restart_at.map_or(f64::INFINITY, |r| now.duration_since(r).as_secs_f64());
        if quiet > STALE_AFTER && since_restart >= t.backoff {
            restart(s, t, sources, &format!("no audio for {quiet:.0} s"), &others_wanted);
            t.backoff = (t.backoff * 2.0).min(60.0);
        }
    }
}

fn restart(s: &Session, t: &mut Track, sources: &mut Sources, reason: &str, wanted: &[Source]) {
    t.restart_at = None;
    t.last_restart_at = Some(Instant::now());
    log::info!("meeting: restarting {} ({reason})", t.source.file());
    let _ = s.ctx.notes.append_event(&s.note_id, &format!("[{}] restarting {}: {reason}", stamp(s.note_seconds(Instant::now())), t.source.file()));
    if let Err(e) = sources.start(t.source) {
        log::error!("meeting: {} restart failed: {e}", t.source.file());
        if !t.failing {
            t.failing = true;
            let what = if t.source == Source::Mic { "The microphone stopped" } else { "The call's audio stopped" };
            let other = if wanted.iter().any(|w| *w != t.source) { " The other track keeps recording." } else { "" };
            s.ctx.emit(Event::Note { event: NoteEvent::Error { text: format!("{what} ({e}). Lin Flow keeps trying every few seconds.{other}") } });
        }
    }
}

/// About 230 MB an hour for two tracks. Under half a gigabyte free, the meeting is warned
/// about before it starts, while there is still time to make room.
fn check_free_space(ctx: &Context) {
    let Some(free) = linflow_platform::free_bytes(&ctx.notes.dir) else { return };
    if free < 500_000_000 {
        let mb = free / 1_000_000;
        log::error!("meeting: only {mb} MB free for the recording");
        ctx.emit(Event::Note {
            event: NoteEvent::Error { text: format!("Only {mb} MB free on this disk. A meeting needs about 230 MB an hour; make room or the recording will stop short.") },
        });
    }
}

/// Running notes: every few seconds, whether enough new transcript has come in for a pass, and
/// at the end, passes until the backlog is noted.
fn running_notes_loop(ctx: Arc<Context>, id: String, stop: Arc<AtomicBool>) {
    let mut model = match notes::running_notes_model(&ctx) {
        Ok(m) => m,
        Err(why) => {
            log::info!("running notes unavailable: {why}");
            ctx.emit(Event::Note { event: NoteEvent::RunningNotesOff { id: id.clone(), why } });
            return;
        }
    };
    log::info!("running notes with {}", model.name());
    // Anything already in the transcript (a note recorded a second time) counts as noted.
    let mut noted: HashSet<String> = ctx.notes.transcript(&id).into_iter().map(|s| s.id).collect();
    let mut last_pass = Instant::now();
    let title = || ctx.notes.load(&id).map(|n| n.title).unwrap_or_else(|| "Meeting".into());
    loop {
        let finishing = stop.load(Ordering::Relaxed);
        if !finishing {
            std::thread::sleep(Duration::from_secs(10));
            if !stop.load(Ordering::Relaxed) {
                let fresh = running::window(&ctx.notes.transcript(&id), &noted, running::MAXIMUM_WINDOW_WORDS);
                if !running::is_due(running::word_count_of(&fresh), last_pass.elapsed().as_secs_f64(), false) {
                    continue;
                }
            }
        }
        let last = stop.load(Ordering::Relaxed);
        let mut passes = 0;
        while passes < (if last { 6 } else { 1 }) {
            let fresh = running::window(&ctx.notes.transcript(&id), &noted, running::MAXIMUM_WINDOW_WORDS);
            let words = running::word_count_of(&fresh);
            if fresh.is_empty() || (last && words < running::FINAL_MINIMUM_WORDS) {
                break;
            }
            passes += 1;
            let previous = running::recent(&ctx.notes.running_notes(&id), running::CONTEXT_BULLETS);
            let started = Instant::now();
            match linflow_core::meeting::summary::running_notes(model.as_mut(), &previous, &transcript_text(&fresh, true), &title()) {
                Ok(bullets) => {
                    noted.extend(fresh.iter().map(|s| s.id.clone()));
                    last_pass = Instant::now();
                    let block = running::format(&bullets, fresh[0].start);
                    let _ = ctx.notes.append_running_notes(&id, &block);
                    log::info!("running notes: {words} words in, {} bullet(s) out, {:.1} s{}", bullets.len(), started.elapsed().as_secs_f64(), if last { " (final)" } else { "" });
                    ctx.emit(Event::Note { event: NoteEvent::RunningNotes { id: id.clone(), text: ctx.notes.running_notes(&id) } });
                }
                Err(e) => {
                    // Leave the stretch unnoted; the next pass picks it up with what follows.
                    log::error!("running notes: {e}");
                    last_pass = Instant::now();
                    break;
                }
            }
        }
        if last {
            return;
        }
    }
}

/// The call tracker: every few seconds, whether enough new transcript has come in for a pass;
/// at the end, one last pass over what is left. Off with a reason when there is no local model,
/// since running notes already say so.
fn tracker_loop(ctx: Arc<Context>, id: String, stop: Arc<AtomicBool>) {
    let Ok(mut model) = notes::running_notes_model(&ctx) else { return };
    log::info!("call tracker with {}", model.name());
    // A note recorded a second time: what was already said was tracked the first time.
    let mut read: HashSet<String> = ctx.notes.transcript(&id).into_iter().map(|s| s.id).collect();
    let mut last_pass = Instant::now();
    let title = || ctx.notes.load(&id).map(|n| n.title).unwrap_or_else(|| "Meeting".into());
    loop {
        let last = stop.load(Ordering::Relaxed);
        if !last {
            std::thread::sleep(Duration::from_secs(5));
        }
        let mut working = ctx.notes.tracker(&id);
        let started = Instant::now();
        match tracker::step(model.as_mut(), &ctx.notes.transcript(&id), &mut read, &mut working, &title(), last_pass.elapsed().as_secs_f64(), last) {
            Ok(Some(step)) => {
                last_pass = Instant::now();
                let new: Vec<tracker::Item> = working.items[working.items.len() - step.added..].to_vec();
                log::info!("call tracker: {} words in, {} item(s) out, {:.1} s{}", step.words, step.added, started.elapsed().as_secs_f64(), if last { " (final)" } else { "" });
                if !new.is_empty() {
                    if let Err(e) = notes::update_tracker(&ctx, &id, |t| {
                        t.add(new);
                        true
                    }) {
                        log::error!("call tracker: saving: {e}");
                    }
                }
            }
            Ok(None) => {}
            Err(e) => {
                // The stretch stays unread; the next pass takes it with what follows.
                log::error!("call tracker: {e}");
                last_pass = Instant::now();
            }
        }
        if last {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jitter_never_pads_but_a_stall_does() {
        assert_eq!(shortfall(16_000, 15_000, false), 0, "a 60 ms lag is delivery jitter");
        assert_eq!(shortfall(32_000, 16_000, false), 16_000, "a one-second stall is filled");
        assert_eq!(shortfall(3_000, 1_000, true), 2_000, "the first chunk aligns tightly");
    }

    #[test]
    fn stamps_read_like_the_mac() {
        assert_eq!(stamp(75.0), "1:15");
        assert_eq!(stamp(3725.0), "1:02:05");
    }
}
