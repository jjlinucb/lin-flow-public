//! The checks and repairs: what John or an agent runs to see whether one part of Lin Flow works on
//! this computer, and to put a meeting right after a crash. Each says what it touches. Only
//! `mic-test`, `focus-test` and `paste` reach outside Lin Flow's own files, and none of them is
//! for an agent to run unasked: they open the microphone, read another app's field, or paste
//! into whatever has focus.

use crate::{cleaner, engine_options, flags, quit, usage};
use linflow_core::learn::{decide, LearnMode};
use linflow_core::meeting::{regions, running, summary, Recognizer};
use linflow_core::notes::{transcript_text, MeetingNote, NotesStore, TranscriptSegment};
use linflow_core::text::{glossary, Replacement};
use linflow_core::{models, paths, wav};
use std::path::Path;
use std::time::{Duration, Instant, SystemTime};

/// `download <model id>`: a speech model, or `vad` for the voice detector, into this app's own
/// models folder. Nothing happens if it is already installed, here or in the installed app's.
pub fn download(args: &[String]) {
    let Some(id) = args.get(1) else { usage() };
    let info = if id == "vad" { Some(&models::VAD_MODEL) } else { models::info(id) };
    let Some(info) = info else {
        eprintln!("unknown model '{id}'. `linflow models` lists what is installed; the Mac's `linflow models` lists the catalog.");
        std::process::exit(1)
    };
    if let Some(found) = models::locate(info.file_name) {
        println!("already installed: {}", found.display());
        return;
    }
    let dest = paths::models_dir().join(info.file_name);
    let _ = std::fs::create_dir_all(paths::models_dir());
    let mut shown = -1i64;
    let result = linflow_core::net::download(
        info.url,
        &dest,
        &mut |p| {
            let percent = (p * 100.0) as i64;
            if percent != shown {
                shown = percent;
                eprint!("\r{} ({} MB): {percent}%", info.id, info.size_mb);
            }
        },
        &|| true,
    );
    eprintln!();
    match result {
        Ok(()) => println!("saved {}", dest.display()),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1)
        }
    }
}

/// `learn-test <wrote> <now>`: what fixing a dictation from one text to the other would teach the
/// dictionary, with the corrections and waiting list in the data folder. Saves nothing.
pub fn learn_test(args: &[String]) {
    let (Some(wrote), Some(now)) = (args.get(1), args.get(2)) else { usage() };
    let existing = glossary::parse_replacements(&std::fs::read_to_string(paths::replacements_file()).unwrap_or_default());
    let pending: Vec<Replacement> =
        std::fs::read_to_string(paths::data_dir().join("pending-corrections.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
    let setting = linflow_core::settings::SettingsFile::load(&paths::settings_file()).values.learn_corrections;
    // Learning off still answers what it would do, as automatic.
    let mode = if setting == LearnMode::Off { LearnMode::Auto } else { setting };
    let d = decide(wrote, now, mode, &existing, &pending);
    for r in &d.outcome.added {
        println!("learned: {} => {}", r.from, r.to);
    }
    for r in &d.outcome.suggested {
        println!("suggested, waiting for a click: {} => {}", r.from, r.to);
    }
    if let Some((from, to)) = &d.declined {
        println!("seen and refused as a rule, offered once instead: {from} => {to}");
    }
    if d.outcome.added.is_empty() && d.outcome.suggested.is_empty() && d.declined.is_none() {
        println!("nothing to learn");
    }
    if setting == LearnMode::Off {
        println!("(learning is off in Settings, so the app would do none of this)");
    }
}

/// `mic-test`: one second from the default input. Opens the microphone, so macOS may ask for it.
pub fn mic_test() {
    use std::sync::{Arc, Mutex};
    let heard = Arc::new(Mutex::new((0usize, 0f32)));
    let into = heard.clone();
    let mic = match linflow_platform::mic::Microphone::start(Box::new(move |chunk: &[f32]| {
        let mut h = into.lock().unwrap();
        h.0 += chunk.len();
        h.1 = chunk.iter().fold(h.1, |m, s| m.max(s.abs()));
    })) {
        Ok(m) => m,
        Err(e) => {
            println!("the microphone would not open: {e}");
            std::process::exit(1)
        }
    };
    std::thread::sleep(Duration::from_secs(1));
    println!("device: {} ({} Hz, {} channel{})", mic.device, mic.sample_rate, mic.channels, if mic.channels == 1 { "" } else { "s" });
    match mic.first_audio() {
        Some(d) => println!("first audio after {:.0} ms", d.as_secs_f64() * 1000.0),
        None => println!("no audio arrived in a second"),
    }
    let (samples, peak) = *heard.lock().unwrap();
    println!("{:.2} s collected, peak {peak:.3}", samples as f64 / linflow_core::audio::SAMPLE_RATE_F);
    println!("{}", if mic.heard_anything() { "it sends sound" } else { "only digital silence: muted, dead or stuck" });
    if let Some(e) = mic.error() {
        println!("error: {e}");
    }
}

/// `focus-test [--wait <s>]`: whether the field focused after a few seconds can be read back, the
/// way learning from edits reads it. Prints the field's length, never its text.
pub fn focus_test(args: &[String]) {
    let f = flags(args);
    let wait: f64 = f.values.get("wait").and_then(|w| w.parse().ok()).unwrap_or(3.0);
    eprintln!("Click into the field to test. Reading it in {wait} s.");
    std::thread::sleep(Duration::from_secs_f64(wait));
    let Some(app) = linflow_platform::frontmost_app() else {
        println!("no app is in front");
        return;
    };
    println!("app: {} ({}), pid {}", app.name, app.id, app.pid);
    if !linflow_platform::trusted(false) {
        println!("not trusted for Accessibility, so nothing can be read");
        return;
    }
    let reader = match linflow_platform::FieldReader::new() {
        Ok(r) => r,
        Err(e) => {
            println!("could not start reading fields: {e}");
            return;
        }
    };
    match reader.focused(app.pid) {
        None => println!("no readable field is focused, or it is a password field"),
        Some(field) => match reader.text(&field) {
            Some(t) => println!("readable: {} characters. Lin Flow can learn from edits here.", t.chars().count()),
            None => println!("a field is focused, but its text cannot be read"),
        },
    }
}

/// `paste <text>`: pastes the way a dictation does, into whatever has focus.
pub fn paste(args: &[String]) {
    if args.len() < 2 {
        usage()
    }
    linflow_platform::paste(&args[1..].join(" "), Duration::from_millis(400));
    // The clipboard is put back on a timer: stay until it has been.
    std::thread::sleep(Duration::from_millis(700));
}

/// `version`: this build and the commit it came from.
pub fn version() {
    println!("linflow {} ({})", env!("CARGO_PKG_VERSION"), option_env!("LINFLOW_COMMIT").unwrap_or("commit unknown"));
}

/// `doctor [--quick]`: every part this computer needs, each with what is wrong if it is. Reads
/// only. `--quick` skips loading the speech model.
pub fn doctor(args: &[String]) {
    let quick = args.iter().any(|a| a == "--quick");
    let mut problems = 0;
    let mut line = |ok: bool, what: &str, detail: String| {
        if !ok {
            problems += 1;
        }
        println!("{} {what}: {detail}", if ok { "ok     " } else { "PROBLEM" });
    };
    let dir = paths::data_dir();
    line(dir.is_dir(), "data folder", dir.display().to_string());
    let settings = linflow_core::settings::SettingsFile::load(&paths::settings_file()).values;
    let platform = linflow_core::hotkey::Platform::current();
    // No setting means the default, as in the app.
    let key = if settings.hotkey.is_empty() { Some(linflow_service::context::default_hotkey()) } else { linflow_core::hotkey::Hotkey::parse(&settings.hotkey, platform) };
    line(key.is_some(), "talk key", key.map(|k| k.label(platform)).unwrap_or_else(|| format!("'{}' is not a key this computer has", settings.hotkey)));
    let model = models::locate(&settings.model_id);
    line(model.is_some(), "speech model", model.as_ref().map(|p| p.display().to_string()).unwrap_or_else(|| format!("{} is not installed: linflow download {}", settings.model_id, settings.model_id)));
    line(!settings.use_vad || models::vad_model_path().is_some(), "voice detector", models::vad_model_path().map(|p| p.display().to_string()).unwrap_or_else(|| "not installed: linflow download vad".into()));
    match linflow_engine::library_version() {
        Ok(v) => line(true, "speech libraries", format!("whisper.cpp {v}")),
        Err(e) => line(false, "speech libraries", e),
    }
    if let (Some(path), false) = (&model, quick) {
        let t0 = Instant::now();
        match linflow_engine::load(path) {
            Ok(mut engine) => {
                let silence = vec![0f32; linflow_core::audio::SAMPLE_RATE as usize];
                match engine.transcribe(&silence, &linflow_engine::Options::default()) {
                    Ok(_) => line(true, "speech engine", format!("loaded and ran in {:.1} s", t0.elapsed().as_secs_f64())),
                    Err(e) => line(false, "speech engine", e.to_string()),
                }
                // The engine stays loaded: freeing it at exit is what the Metal teardown aborts on.
                std::mem::forget(engine);
            }
            Err(e) => line(false, "speech engine", e.to_string()),
        }
    }
    let net = std::sync::Arc::new(linflow_core::net::Ureq);
    let claude = linflow_core::llm::Claude::from_saved_key(net.clone()).is_some();
    let ollama = linflow_core::llm::Ollama::new(&settings.ollama_host, &settings.ollama_model, net).check();
    line(true, "Claude", if claude { "key saved".into() } else { "no key, so summaries use Ollama. scripts/setup-claude.sh saves one".into() });
    let local = format!("{} at {}", settings.ollama_model, settings.ollama_host);
    match (&ollama, claude) {
        (None, _) => line(true, "Ollama", local),
        (Some(_), true) => line(true, "Ollama", format!("not answering at {}, so running notes use Claude", settings.ollama_host)),
        (Some(why), false) => line(false, "Ollama", format!("{why} Nothing can write notes or summaries")),
    }
    let sync = std::fs::read_to_string(dir.join(linflow_core::sync::FILE_NAME)).ok();
    match sync.as_deref().map(|t| linflow_core::sync::SyncConfig::parse(t, "this computer")) {
        None => line(true, "sync", "off: no sync.env in the data folder".into()),
        Some((Some(c), _)) => line(true, "sync", format!("on as {}", c.device)),
        Some((None, problem)) => line(false, "sync", problem.unwrap_or_else(|| "sync.env does not read".into())),
    }
    let trusted = linflow_platform::trusted(false);
    line(trusted, "Accessibility", if trusted { "granted".into() } else { "not granted. The talk key, pasting and learning from edits need it".into() });
    line(true, "default microphone", linflow_platform::mic::default_input_name().unwrap_or_else(|| "none".into()));
    println!("{}", if problems == 0 { "all good".to_string() } else { format!("{problems} problem(s)") });
    quit(if problems == 0 { 0 } else { 1 })
}

/// The unfinished note whose audio is still being written, if any: Lin Flow Next is recording it.
fn recording_now(store: &NotesStore) -> Option<MeetingNote> {
    store.list().into_iter().filter(|n| n.ended_at.is_none()).find(|n| {
        ["mic", "system"].iter().any(|s| {
            std::fs::metadata(store.audio_path(&n.id, s))
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| SystemTime::now().duration_since(t).ok())
                .is_some_and(|age| age < Duration::from_secs(10))
        })
    })
}

/// `notes-repair [file.wav]`: fixes a WAV cut short by a crash, or with no file, closes every
/// meeting left unfinished, as the app does at launch. Refuses while a meeting records.
pub fn notes_repair(args: &[String]) {
    if let Some(file) = args.get(1) {
        let path = Path::new(file);
        match wav::repair_header(path) {
            Ok(true) => println!("repaired: {:.1} s of audio", wav::duration(path).unwrap_or(0.0)),
            Ok(false) => println!("the header was already right: {:.1} s of audio", wav::duration(path).unwrap_or(0.0)),
            Err(e) => {
                eprintln!("{}: {e}", path.display());
                std::process::exit(1)
            }
        }
        return;
    }
    let store = NotesStore::new(&paths::data_dir());
    if let Some(n) = recording_now(&store) {
        eprintln!("\"{}\" is recording right now. Stop it in Lin Flow Next first.", n.title);
        std::process::exit(1)
    }
    let closed = store.recover_unfinished();
    if closed.is_empty() {
        println!("no unfinished meetings");
    }
    for n in &closed {
        println!("closed \"{}\" ({}), {} of audio", n.title, n.id, linflow_core::notes::clock(n.duration_seconds));
    }
    if !closed.is_empty() {
        println!("`linflow notes-transcribe <id> --save` rebuilds a transcript from its audio.");
    }
}

/// A loaded engine as the meeting code's `Recognizer`.
struct EngineRecognizer {
    engine: Box<dyn linflow_engine::Engine>,
    options: linflow_engine::Options,
}

impl Recognizer for EngineRecognizer {
    fn recognize(&mut self, samples: &[f32]) -> Result<String, String> {
        self.engine.transcribe(samples, &self.options).map(|r| r.text).map_err(|e| e.to_string())
    }
}

fn recognizer(f: &crate::Flags) -> EngineRecognizer {
    let settings = linflow_core::settings::SettingsFile::load(&paths::settings_file()).values;
    let id = f.values.get("model").cloned().unwrap_or(settings.model_id);
    let Some(path) = models::locate(&id) else {
        eprintln!("model '{id}' is not installed: linflow download {id}");
        std::process::exit(1)
    };
    let engine = linflow_engine::load(&path).unwrap_or_else(|e| {
        eprintln!("{e}");
        quit(1)
    });
    EngineRecognizer { engine, options: engine_options(f) }
}

/// The cleaner a meeting's lines go through: "question mark" said in a meeting is a phrase.
fn meeting_cleaner() -> linflow_core::text::TextCleaner {
    let mut c = cleaner();
    c.spoken_commands = false;
    c
}

/// `notes-transcribe <note id> [--save] [--model <id>]`: the whole-file pass over a note's saved
/// audio, as the app runs it when a meeting ends. Prints the transcript. `--save` replaces the
/// note's, keeping the old one as transcript-live.jsonl.
/// What Save Audio in a note's menu does: both sides leveled, mixed and encoded. The output's
/// extension picks MP3 or WAV. Without one, the file is named after the note, in this folder.
/// A note folder can be given by path, so a meeting in another data folder is read in place.
pub fn notes_export(args: &[String]) {
    use linflow_core::audio_export::{self, Format};
    let Some(target) = args.get(1) else { usage() };
    let folder = if Path::new(target).is_dir() { Path::new(target).to_path_buf() } else { NotesStore::new(&paths::data_dir()).folder(target) };
    let note: Option<MeetingNote> = std::fs::read_to_string(folder.join("note.json")).ok().and_then(|t| serde_json::from_str(&t).ok());
    let title = note.map(|n| n.title).unwrap_or_else(|| folder.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default());
    let (out, format) = match args.get(2) {
        Some(o) => {
            let Some(f) = Path::new(o).extension().and_then(|e| e.to_str()).and_then(Format::from_ext) else {
                eprintln!("the output must end in .mp3 or .wav");
                std::process::exit(2)
            };
            (Path::new(o).to_path_buf(), f)
        }
        None => {
            let f = audio_export::preferred_format();
            (Path::new(&linflow_core::notes::file_name(&title, f.ext())).to_path_buf(), f)
        }
    };
    let t0 = Instant::now();
    match audio_export::export_note(&folder, &title, &out, format, &mut |p| eprint!("  {:3.0}%\r", p * 100.0)) {
        Ok(r) => {
            let size = std::fs::metadata(&out).map(|m| m.len()).unwrap_or(0);
            let gains: Vec<String> = r.gains.iter().map(|(k, g)| format!("{k} {g:+.1} dB")).collect();
            println!(
                "{}: {:.0} s, {:.1} MB, {}, {} (call {:+.2} s from the mic), in {:.1} s",
                out.display(),
                r.seconds,
                size as f64 / 1e6,
                gains.join(", "),
                r.coupling.name(),
                r.delay,
                t0.elapsed().as_secs_f64()
            );
        }
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1)
        }
    }
}

pub fn notes_transcribe(args: &[String]) {
    let f = flags(args);
    let Some(id) = f.positional.get(1).cloned() else { usage() };
    let store = NotesStore::new(&paths::data_dir());
    let Some(note) = store.load(&id) else {
        eprintln!("no meeting {id}");
        std::process::exit(1)
    };
    if recording_now(&store).is_some_and(|n| n.id == id) {
        eprintln!("\"{}\" is recording right now.", note.title);
        std::process::exit(1)
    }
    let mut rec = recognizer(&f);
    let model = rec.engine.model_id();
    let t0 = Instant::now();
    let result = regions::transcribe_note(&store, &id, &mut rec, &meeting_cleaner(), &mut |p| eprint!("\r{p}        "));
    eprintln!();
    let segments = match result {
        Ok(s) => s,
        Err(e) => {
            eprintln!("{e}");
            quit(1)
        }
    };
    println!("{}", transcript_text(&segments, true));
    eprintln!("[{} lines from \"{}\" in {:.1} s with {model}]", segments.len(), note.title, t0.elapsed().as_secs_f64());
    if f.switches.contains("save") {
        match store.replace_transcript(&id, &segments, &model) {
            Ok(()) => eprintln!("saved. The transcript before is kept as transcript-live.jsonl."),
            Err(e) => eprintln!("could not save: {e}"),
        }
    }
    quit(0)
}

/// `notes-test <audio> [--model <id>]`: a file streamed through the live transcriber in the
/// pieces a meeting delivers, with each line as it would appear. Writes nothing.
pub fn notes_test(args: &[String]) {
    let f = flags(args);
    let Some(file) = f.positional.get(1) else { usage() };
    let samples = linflow_core::audio::load_samples(Path::new(file)).unwrap_or_else(|e| {
        eprintln!("could not read {file}: {e}");
        std::process::exit(1)
    });
    let mut rec = recognizer(&f);
    let cleaner = meeting_cleaner();
    let mut segmenter = linflow_core::meeting::live::LiveSegmenter::new();
    let mut emit = |cut: linflow_core::meeting::live::Cut| {
        let (start, end) = cut.span(0.0);
        let t0 = Instant::now();
        match rec.recognize(&cut.samples) {
            Ok(raw) => {
                let text = cleaner.clean(&raw);
                if !text.is_empty() {
                    println!("[{} - {}] {text}   ({:.2} s)", linflow_core::notes::clock(start), linflow_core::notes::clock(end), t0.elapsed().as_secs_f64());
                }
            }
            Err(e) => eprintln!("{e}"),
        }
    };
    // The 100 ms pieces the recorder hands over.
    for chunk in samples.chunks(1600) {
        if let Some(cut) = segmenter.feed(chunk) {
            emit(cut);
        }
    }
    if let Some(cut) = segmenter.finish() {
        emit(cut);
    }
    quit(0)
}

/// `running-notes-test <transcript.jsonl> [--model claude|ollama]`: a meeting replayed through the
/// running notes a stretch at a time, on the clock the meeting had, as the app would have written
/// them. For judging a prompt change on a real meeting. Writes nothing.
pub fn running_notes_test(args: &[String]) {
    use linflow_core::llm::{Claude, Ollama};
    use summary::NoteModel;
    let f = flags(args);
    let Some(file) = f.positional.get(1) else { usage() };
    let segments: Vec<TranscriptSegment> = std::fs::read_to_string(file)
        .unwrap_or_else(|e| {
            eprintln!("{file}: {e}");
            std::process::exit(1)
        })
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();
    let settings = linflow_core::settings::SettingsFile::load(&paths::settings_file()).values;
    let net = std::sync::Arc::new(linflow_core::net::Ureq);
    let ollama = || -> Option<Box<dyn NoteModel>> {
        let o = Ollama::new(&settings.ollama_host, &settings.ollama_model, net.clone());
        o.check().is_none().then(|| Box::new(o) as Box<dyn NoteModel>)
    };
    let claude = || Claude::from_saved_key(net.clone()).map(|c| Box::new(c) as Box<dyn NoteModel>);
    // The app's order: a local model first, since this runs every minute of a meeting.
    let model = match f.values.get("model").map(String::as_str) {
        Some("claude") => claude(),
        Some("ollama") => ollama(),
        _ => ollama().or_else(claude),
    };
    let Some(mut model) = model else {
        eprintln!(
            "{}",
            match f.values.get("model").map(String::as_str) {
                Some("ollama") => format!("Ollama is not answering at {}.", settings.ollama_host),
                Some("claude") => "No Claude key is saved. scripts/setup-claude.sh saves one.".to_string(),
                _ => "No model to write notes with: start Ollama, or save a Claude key with scripts/setup-claude.sh.".to_string(),
            }
        );
        std::process::exit(1)
    };
    let title = Path::new(file).parent().and_then(|d| d.file_name()).map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "Meeting".into());
    let end = segments.iter().map(|s| s.end).fold(0.0, f64::max);
    let mut noted = std::collections::HashSet::new();
    let mut notes = String::new();
    let mut last_pass = 0.0;
    let mut clock = 0.0;
    // The app looks every 10 s and writes when enough is new; at the end, until the rest is noted.
    loop {
        let last = clock >= end;
        let heard: Vec<TranscriptSegment> = segments.iter().filter(|s| last || s.end <= clock).cloned().collect();
        let mut passes = 0;
        while passes < (if last { 6 } else { 1 }) {
            let fresh = running::window(&heard, &noted, running::MAXIMUM_WINDOW_WORDS);
            let words = running::word_count_of(&fresh);
            if fresh.is_empty() || (last && words < running::FINAL_MINIMUM_WORDS) || (!last && !running::is_due(words, clock - last_pass, false)) {
                break;
            }
            passes += 1;
            let previous = running::recent(&notes, running::CONTEXT_BULLETS);
            let t0 = Instant::now();
            match summary::running_notes(model.as_mut(), &previous, &transcript_text(&fresh, true), &title) {
                Ok(bullets) => {
                    noted.extend(fresh.iter().map(|s| s.id.clone()));
                    let block = running::format(&bullets, fresh[0].start);
                    print!("{block}");
                    eprintln!("  [at {}: {words} words in, {} bullet(s) out, {:.1} s]", linflow_core::notes::clock(clock.min(end)), bullets.len(), t0.elapsed().as_secs_f64());
                    notes.push_str(&block);
                }
                Err(e) => {
                    // As the app does: the stretch stays unnoted and the next pass takes it.
                    eprintln!("  [at {}: {e}]", linflow_core::notes::clock(clock));
                    last_pass = clock;
                    break;
                }
            }
            last_pass = clock;
        }
        if last {
            break;
        }
        clock += 10.0;
    }
    eprintln!("[{}]", model.name());
}

/// Replays a meeting through the call tracker on the local model, as the app runs it during a
/// call, and prints each question and promise when it would have appeared.
pub fn tracker_test(args: &[String]) {
    use linflow_core::llm::Ollama;
    use linflow_core::meeting::tracker::{self, Kind};
    use summary::NoteModel;
    let f = flags(args);
    let Some(file) = f.positional.get(1) else { usage() };
    let segments: Vec<TranscriptSegment> = std::fs::read_to_string(file)
        .unwrap_or_else(|e| {
            eprintln!("{file}: {e}");
            std::process::exit(1)
        })
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();
    let settings = linflow_core::settings::SettingsFile::load(&paths::settings_file()).values;
    let name = f.values.get("model").cloned().unwrap_or_else(|| linflow_core::llm::OLLAMA_MODEL.into());
    let mut model = Ollama::new(&settings.ollama_host, &name, std::sync::Arc::new(linflow_core::net::Ureq));
    if let Some(why) = model.check() {
        eprintln!("{why}");
        std::process::exit(1)
    }
    let title = Path::new(file).parent().and_then(|d| d.file_name()).map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "Meeting".into());
    let end = segments.iter().map(|s| s.end).fold(0.0, f64::max);
    let (mut read, mut t) = (std::collections::HashSet::new(), tracker::Tracker::default());
    let (mut clock, mut last_pass, mut seconds) = (0.0, 0.0, vec![]);
    loop {
        let last = clock >= end;
        let heard: Vec<TranscriptSegment> = segments.iter().filter(|s| last || s.end <= clock).cloned().collect();
        let t0 = Instant::now();
        match tracker::step(&mut model, &heard, &mut read, &mut t, &title, clock - last_pass, last) {
            Ok(Some(step)) => {
                seconds.push(t0.elapsed().as_secs_f64());
                last_pass = clock;
                for i in &t.items[t.items.len() - step.added..] {
                    match i.kind {
                        Kind::Question => println!("[{}] Q  {}\n         -> {}", linflow_core::notes::clock(clock.min(end)), i.text, i.detail),
                        Kind::Action => println!("[{}] TO DO  {}: {}", linflow_core::notes::clock(clock.min(end)), i.detail, i.text),
                    }
                }
            }
            Ok(None) => {}
            Err(e) => {
                eprintln!("  [at {}: {e}]", linflow_core::notes::clock(clock));
                last_pass = clock;
            }
        }
        if last {
            break;
        }
        clock += 5.0;
    }
    let n = seconds.len().max(1) as f64;
    eprintln!("[{}: {} passes, {:.1} s each on average, {:.1} s at most]", model.name(), seconds.len(), seconds.iter().sum::<f64>() / n, seconds.iter().cloned().fold(0.0, f64::max));
}
