//! `linflow`: Lin Flow Next's command line. Commands share names with the Swift CLI where both
//! have them, so the oracle can run the same command on each and compare.

mod diag;

use linflow_core::paths;
use linflow_core::text::{glossary, TextCleaner};
use std::io::{self, BufRead, Write};

fn usage() -> ! {
    eprintln!(
        "usage:
  linflow clean <text>        clean one dictation with the dictionary in the data folder
  linflow clean-batch         read JSON strings, one per line, and write each cleaned
  linflow numbers <text>      spoken numbers only
  linflow transcribe <audio> [--model <id>] [--lang <code>] [--beam <n>] [--no-vad] [--fallback] [--prompt <text>] [--raw]
  linflow bench <audio>       warmed timings for every installed model
  linflow models              installed models and where they are
  linflow ask <note id> <question>              ask Claude about a saved meeting; saves nothing
  linflow summarize <transcript.jsonl|txt> [--recap]   Claude once a key is saved, else Ollama
  linflow notes-batch         notetaker logic requests in as JSON lines, answers out
  linflow sync-batch          sync logic requests in as JSON lines, answers out
  linflow platform-check      what the OS layer sees, read only: no microphone, no keys, no paste
  linflow service-test <audio> [--model <id>]   one dictation through the app's own path, headless:
                              a temp data folder, no talk key, no microphone, no paste, no sounds
  linflow download <model id|vad>               into this app's models folder
  linflow doctor [--quick]    every part this computer needs, read only
  linflow version             this build and its commit
  linflow learn-test <wrote> <now>              what that fix would teach the dictionary; saves nothing
  linflow notes-repair [file.wav]               fix a WAV cut short, or close unfinished meetings
  linflow notes-transcribe <note id> [--save] [--model <id>]   the whole-file pass over a meeting
  linflow notes-export <note id|folder> [<out.mp3|out.wav>]   both sides of a note in one file, as Save Audio does
  linflow notes-test <audio> [--model <id>]     a file through the live transcriber, line by line
  linflow running-notes-test <transcript.jsonl> [--model claude|ollama]   replay a meeting's notes
  These open the microphone, read another app's field or paste, so only when asked:
  linflow mic-test            one second from the default input
  linflow focus-test [--wait <s>]               whether the focused field can be read back
  linflow paste <text>        paste the way a dictation does
  LINFLOW_DATA_DIR=<dir> picks the data folder (default: {})",
        paths::data_dir().display()
    );
    std::process::exit(2)
}

fn cleaner() -> TextCleaner {
    let vocab = std::fs::read_to_string(paths::vocab_file()).ok();
    let rules = std::fs::read_to_string(paths::replacements_file()).unwrap_or_default();
    TextCleaner::new(glossary::terms_or_defaults(vocab.as_deref()), glossary::parse_replacements(&rules))
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(cmd) = args.first() else { usage() };
    match cmd.as_str() {
        "clean" => {
            if args.len() < 2 {
                usage()
            }
            println!("{}", cleaner().clean(&args[1..].join(" ")));
        }
        "clean-batch" => {
            let c = cleaner();
            let stdin = io::stdin();
            let mut out = io::BufWriter::new(io::stdout().lock());
            for line in stdin.lock().lines() {
                let line = line.expect("stdin");
                if line.trim().is_empty() {
                    continue;
                }
                let raw: String = serde_json::from_str(&line).expect("each line is a JSON string");
                writeln!(out, "{}", serde_json::to_string(&c.clean(&raw)).unwrap()).unwrap();
            }
        }
        "transcribe" => cmd_transcribe(&args),
        "bench" => cmd_bench(&args),
        "models" => cmd_models(),
        "ask" => cmd_ask(&args),
        "summarize" => cmd_summarize(&args),
        "notes-batch" => notes_batch(),
        "sync-batch" => sync_batch(),
        "platform-check" => platform_check(),
        "service-test" => service_test(&args),
        "download" => diag::download(&args),
        "doctor" => diag::doctor(&args),
        "version" => diag::version(),
        "learn-test" => diag::learn_test(&args),
        "notes-repair" => diag::notes_repair(&args),
        "notes-transcribe" => diag::notes_transcribe(&args),
        "notes-export" => diag::notes_export(&args),
        "notes-test" => diag::notes_test(&args),
        "running-notes-test" => diag::running_notes_test(&args),
        "mic-test" => diag::mic_test(),
        "focus-test" => diag::focus_test(&args),
        "paste" => diag::paste(&args),
        "numbers" => {
            if args.len() < 2 {
                usage()
            }
            println!("{}", linflow_core::text::numbers::apply(&args[1..].join(" ")));
        }
        _ => usage(),
    }
}

/// `--name value` flags and `--name` switches, the rest positional, as the Swift CLI reads them.
struct Flags {
    positional: Vec<String>,
    values: std::collections::HashMap<String, String>,
    switches: std::collections::HashSet<String>,
}

const SWITCHES: [&str; 6] = ["raw", "no-vad", "fallback", "recap", "save", "quick"];

fn flags(args: &[String]) -> Flags {
    let mut f = Flags { positional: vec![], values: Default::default(), switches: Default::default() };
    let mut i = 0;
    while i < args.len() {
        if let Some(name) = args[i].strip_prefix("--") {
            if SWITCHES.contains(&name) || i + 1 >= args.len() {
                f.switches.insert(name.to_string());
            } else {
                f.values.insert(name.to_string(), args[i + 1].clone());
                i += 1;
            }
        } else {
            f.positional.push(args[i].clone());
        }
        i += 1;
    }
    f
}

fn engine_options(f: &Flags) -> linflow_engine::Options {
    let mut o = linflow_engine::Options { language: f.values.get("lang").cloned().unwrap_or_else(|| "en".into()), ..Default::default() };
    if let Some(n) = f.values.get("beam").and_then(|b| b.parse().ok()) {
        o.beam_size = n;
    }
    if !f.switches.contains("no-vad") {
        o.vad_model = linflow_core::models::vad_model_path();
    }
    o.temperature_fallback = f.switches.contains("fallback");
    let vocab = std::fs::read_to_string(paths::vocab_file()).ok();
    o.initial_prompt = Some(f.values.get("prompt").cloned().unwrap_or_else(|| glossary::initial_prompt(&glossary::terms_or_defaults(vocab.as_deref()))));
    o
}

/// Ends the process without running the C++ static destructors: with a model loaded, ggml's
/// Metal teardown aborts in them and macOS files a crash report. Output is flushed first.
fn quit(code: i32) -> ! {
    let _ = io::stdout().flush();
    let _ = io::stderr().flush();
    unsafe { libc::_exit(code) }
}

fn cmd_transcribe(args: &[String]) {
    let f = flags(args);
    let Some(file) = f.positional.get(1) else { usage() };
    let samples = linflow_core::audio::load_samples(std::path::Path::new(file)).unwrap_or_else(|e| {
        eprintln!("could not read {file}: {e}");
        std::process::exit(1)
    });
    let id = f.values.get("model").cloned().unwrap_or_else(|| linflow_core::models::DEFAULT_MODEL_ID.to_string());
    let Some(path) = linflow_core::models::locate(&id) else {
        eprintln!("model '{id}' not found. Run `linflow models` to see what's installed.");
        std::process::exit(1)
    };
    let mut engine = linflow_engine::load(&path).unwrap_or_else(|e| {
        eprintln!("{e}");
        quit(1)
    });
    match engine.transcribe(&samples, &engine_options(&f)) {
        Ok(r) => {
            if f.switches.contains("raw") {
                println!("{}", r.text);
            } else {
                let cleaned = cleaner().clean(&r.text);
                println!("{cleaned}");
                if cleaned != r.text {
                    eprintln!("[raw] {}", r.text);
                }
            }
            eprintln!(
                "[{:.1}s audio -> {:.2}s inference{}]",
                r.audio_seconds,
                r.inference_seconds,
                r.detected_language.map(|l| format!(", lang={l}")).unwrap_or_default()
            );
            drop(engine);
            quit(0)
        }
        Err(e) => {
            eprintln!("{e}");
            quit(1)
        }
    }
}

fn cmd_bench(args: &[String]) {
    let f = flags(args);
    let Some(file) = f.positional.get(1) else { usage() };
    let Ok(samples) = linflow_core::audio::load_samples(std::path::Path::new(file)) else {
        eprintln!("could not read {file}");
        std::process::exit(1)
    };
    let opts = engine_options(&f);
    println!(
        "audio: {:.1}s   beam={}  vad={}  fallback={}",
        samples.len() as f64 / linflow_core::audio::SAMPLE_RATE_F,
        opts.beam_size,
        if opts.vad_model.is_some() { "on" } else { "off" },
        if opts.temperature_fallback { "on" } else { "off" }
    );
    for path in linflow_core::models::installed() {
        let id = linflow_core::models::id_from_path(&path);
        let Ok(mut engine) = linflow_engine::load(&path) else {
            println!("  {}: load failed", path.file_name().unwrap().to_string_lossy());
            continue;
        };
        // A warm-up run first: Metal's shader and pipeline setup lands on the first call.
        let _ = engine.transcribe(&samples, &opts);
        let mut times = vec![];
        let mut text = String::new();
        for _ in 0..3 {
            if let Ok(r) = engine.transcribe(&samples, &opts) {
                times.push(r.inference_seconds);
                text = r.text;
            }
        }
        let avg = if times.is_empty() { 0.0 } else { times.iter().sum::<f64>() / times.len() as f64 };
        println!("  {id:<32} load {:.2}s  infer {avg:.2}s  -> {text}", engine.load_seconds());
    }
    quit(0)
}

fn cmd_models() {
    println!("model folders: {}", linflow_core::models::search_dirs().iter().map(|d| d.display().to_string()).collect::<Vec<_>>().join(", "));
    println!("installed:");
    for p in linflow_core::models::installed() {
        let size = std::fs::metadata(&p).map(|m| m.len()).unwrap_or(0);
        println!("  {:<28} {:>5} MB  {}", linflow_core::models::id_from_path(&p), size / 1_000_000, p.display());
    }
    println!("VAD model: {}", linflow_core::models::vad_model_path().map(|p| p.display().to_string()).unwrap_or_else(|| "not installed".into()));
    match linflow_engine::library_version() {
        Ok(v) => println!("speech libraries: whisper.cpp {v}"),
        Err(e) => println!("speech libraries: {e}"),
    }
    quit(0)
}

fn cmd_ask(args: &[String]) {
    use linflow_core::llm::{questions, Claude};
    use linflow_core::notes::{transcript_text, NotesStore};
    if args.len() < 3 {
        usage()
    }
    let store = NotesStore::new(&paths::data_dir());
    let id = &args[1];
    let Some(note) = store.load(id) else {
        eprintln!("no note {id}");
        std::process::exit(1)
    };
    let Some(claude) = Claude::from_saved_key(std::sync::Arc::new(linflow_core::net::Ureq)) else {
        eprintln!("No Claude key is saved. Run scripts/setup-claude.sh once.");
        std::process::exit(1)
    };
    let prompt = questions::prompt(&note.title, &transcript_text(&store.transcript(id), true), &store.notes_text(id), &[], &args[2..].join(" "));
    let t0 = std::time::Instant::now();
    match claude.ask(questions::SYSTEM, &prompt, 8000) {
        Ok(answer) => println!("{answer}"),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1)
        }
    }
    eprintln!("[{}, {:.1}s]", linflow_core::llm::CLAUDE_MODEL, t0.elapsed().as_secs_f64());
}

fn cmd_summarize(args: &[String]) {
    use linflow_core::llm::{Claude, Ollama};
    use linflow_core::meeting::summary::{self, Kind, NoteModel};
    use linflow_core::notes::{transcript_text, TranscriptSegment};
    use std::sync::Arc;
    let Some(path) = args.get(1).filter(|a| !a.starts_with("--")) else { usage() };
    let path = std::path::Path::new(path);
    let Ok(raw) = std::fs::read_to_string(path) else {
        eprintln!("could not read {}", path.display());
        std::process::exit(1)
    };
    let transcript = if path.extension().is_some_and(|e| e == "jsonl") {
        let segs: Vec<TranscriptSegment> = raw.lines().filter_map(|l| serde_json::from_str(l).ok()).collect();
        transcript_text(&segs, true)
    } else {
        raw
    };
    let net = Arc::new(linflow_core::net::Ureq);
    let mut model: Box<dyn NoteModel> = match Claude::from_saved_key(net.clone()) {
        Some(c) => Box::new(c),
        None => {
            let settings = linflow_core::settings::SettingsFile::load(&paths::settings_file()).values;
            let o = Ollama::new(&settings.ollama_host, &settings.ollama_model, net);
            if let Some(why) = o.check() {
                eprintln!("{why}");
                std::process::exit(1)
            }
            Box::new(o)
        }
    };
    let kind = if args.iter().any(|a| a == "--recap") { Kind::Recap } else { Kind::Meeting };
    let title = path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let t0 = std::time::Instant::now();
    match summary::summarize(model.as_mut(), &transcript, &title, kind, &mut |p| eprintln!("  {p}")) {
        Ok(out) => println!("{out}"),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1)
        }
    }
    eprintln!("[{}, {:.1}s]", model.name(), t0.elapsed().as_secs_f64());
}

/// The notetaker's pure logic, one JSON request per line: the same requests and answers as the
/// Swift CLI's `notes-batch`, so the oracle can compare the two.
fn notes_batch() {
    use linflow_core::meeting::{echo, merge, regions, running, summary};
    use linflow_core::notes::TranscriptSegment;
    use serde_json::{json, Value};

    fn strs(v: &Value) -> Vec<String> {
        v.as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default()
    }
    fn reps(v: &Value) -> Vec<linflow_core::text::Replacement> {
        v.as_array()
            .map(|a| {
                a.iter()
                    .map(|r| linflow_core::text::Replacement {
                        from: r["from"].as_str().unwrap_or("").into(),
                        to: r["to"].as_str().unwrap_or("").into(),
                        learned: r["learned"].as_bool().unwrap_or(false),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }
    let stdin = io::stdin();
    let mut out = io::BufWriter::new(io::stdout().lock());
    for line in stdin.lock().lines() {
        let line = line.expect("stdin");
        let Ok(req) = serde_json::from_str::<Value>(&line) else { continue };
        let s = |k: &str| req[k].as_str().unwrap_or("").to_string();
        let n = |k: &str, default: u64| req[k].as_u64().unwrap_or(default) as usize;
        let answer: Value = match req["op"].as_str().unwrap_or("") {
            "regions" => {
                let levels: Vec<f32> = req["levels"].as_array().map(|a| a.iter().map(|x| x.as_f64().unwrap_or(0.0) as f32).collect()).unwrap_or_default();
                let found = regions::regions(&levels, n("total", 0), &regions::Params::default());
                json!(found.iter().map(|r| [r.start, r.end]).collect::<Vec<_>>())
            }
            "echo" => {
                let segs: Vec<TranscriptSegment> = req["segments"]
                    .as_array()
                    .map(|a| {
                        a.iter()
                            .enumerate()
                            .map(|(i, d)| TranscriptSegment {
                                id: i.to_string(),
                                start: d["start"].as_f64().unwrap_or(0.0),
                                end: d["end"].as_f64().unwrap_or(0.0),
                                speaker: d["speaker"].as_str().unwrap_or("").into(),
                                text: d["text"].as_str().unwrap_or("").into(),
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                let kept = echo::drop_echo(&segs, echo::SLACK_SECONDS, echo::SHARE);
                json!(kept.iter().map(|s| s.id.parse::<usize>().unwrap()).collect::<Vec<_>>())
            }
            "filter" => json!(running::filter(&strs(&req["bullets"]), &strs(&req["previous"]), &s("transcript"))),
            "grounded" => json!(running::grounded(&s("bullet"), &s("transcript"), &strs(&req["previous"]))),
            "worth" => json!(running::worth_keeping(&s("bullet"))),
            "repeats" => json!(running::drop_repeats(&strs(&req["bullets"]), &strs(&req["previous"]))),
            "recent" => json!(running::recent(&s("notes"), n("count", 10))),
            "wordcount" => json!(running::word_count(&s("text"))),
            "tidy" => json!(merge::tidy(&strs(&req["items"]))),
            "merge" => {
                let parts: Vec<merge::Sections> = req["parts"]
                    .as_array()
                    .map(|a| {
                        a.iter()
                            .map(|lists| {
                                let mut sec = merge::Sections::default();
                                for (i, l) in lists.as_array().cloned().unwrap_or_default().iter().take(4).enumerate() {
                                    sec.set(merge::Section::ALL[i], strs(l));
                                }
                                sec
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                json!(merge::render(&merge::merge(&parts)))
            }
            "edited" => json!(linflow_core::readback::edited_version(&s("wrote"), &s("now"))),
            "scored" => {
                use linflow_core::learn::{scored, Confidence};
                let existing = reps(&req["existing"]);
                json!(scored(&s("wrote"), &s("now"), &existing)
                    .iter()
                    .map(|(r, c)| json!({"from": r.from, "to": r.to, "learned": r.learned, "apply": *c == Confidence::Apply}))
                    .collect::<Vec<_>>())
            }
            "lone-pair" => json!(linflow_core::learn::lone_pair(&s("wrote"), &s("now")).map(|(a, b)| vec![a, b])),
            "word-checks" => {
                use linflow_core::learn::*;
                let (from, to) = (s("from"), s("to"));
                json!({"offering": worth_offering(&from, &to), "plausible": plausible(&from, &to), "showing": worth_showing(&from, &to), "everyday": everyday_english(&from)})
            }
            "merging" => {
                let candidate = reps(&json!([req["candidate"].clone()])).pop().unwrap();
                json!(linflow_core::learn::merging(&candidate, &reps(&req["waiting"]), &reps(&req["accepted"]))
                    .map(|v| v.iter().map(|r| json!({"from": r.from, "to": r.to, "learned": r.learned})).collect::<Vec<_>>()))
            }
            "track" => {
                // A saved WAV read the way the whole-file pass reads it: its levels and regions.
                let path = std::path::PathBuf::from(s("path"));
                match linflow_core::wav::info(&path) {
                    Some(info) => {
                        let total = (info.data_bytes.min(info.file_size.saturating_sub(info.data_offset)) / 2) as usize;
                        let mut read = |start: usize, count: usize| linflow_core::wav::read_pcm16_range(&path, &info, start as u64, count).unwrap_or_default();
                        let levels = regions::levels(&mut read, total, 0.1);
                        let found = regions::regions(&levels, total, &regions::Params::default());
                        json!({
                            "frames": levels.len(),
                            "sum": levels.iter().map(|&l| l as f64).sum::<f64>(),
                            "regions": found.iter().map(|r| [r.start, r.end]).collect::<Vec<_>>(),
                        })
                    }
                    None => Value::Null,
                }
            }
            "split" => json!(summary::split(&s("text"), n("max", 100))),
            "tail" => json!(summary::tail(&s("text"), n("max", 100))),
            _ => Value::Null,
        };
        writeln!(out, "{}", json!({ "out": answer })).unwrap();
    }
}

/// The sync's pure logic, one JSON request per line, answered as the Swift CLI's `sync-batch`.
fn sync_batch() {
    use linflow_core::sync::dictionary::{self, Entry, Kind};
    use linflow_core::sync::{totals, SyncConfig};
    use linflow_core::text::glossary::Replacement;
    use serde_json::{json, Value};
    use std::collections::{BTreeMap, HashMap};

    fn entry_of(d: &Value) -> Entry {
        let mut e = if d["kind"].as_str() == Some("rule") {
            Entry::rule(&Replacement { from: d["text"].as_str().unwrap_or("").into(), to: d["target"].as_str().unwrap_or("").into(), learned: false })
        } else {
            let mut e = Entry::term(d["text"].as_str().unwrap_or(""));
            e.target = d["target"].as_str().unwrap_or("").into();
            e
        };
        e.learned = d["learned"].as_bool().unwrap_or(false);
        e.deleted = d["deleted"].as_bool().unwrap_or(false);
        e.updated_at = d["updated_at"].as_str().unwrap_or("").into();
        e
    }
    fn dict_of(e: &Entry) -> Value {
        json!({"kind": if e.kind == Kind::Term { "term" } else { "rule" }, "text": e.text, "target": e.target, "learned": e.learned, "deleted": e.deleted, "updated_at": e.updated_at})
    }
    fn keyed(v: &Value) -> Option<BTreeMap<String, Entry>> {
        v.as_array().map(|rows| rows.iter().map(entry_of).map(|e| (e.id(), e)).collect())
    }
    fn day_of(d: &Value) -> totals::DayTotal {
        totals::DayTotal {
            device: d["device"].as_str().unwrap_or("").into(),
            day: d["day"].as_str().unwrap_or("").into(),
            words: d["words"].as_i64().unwrap_or(0),
            dictations: d["dictations"].as_i64().unwrap_or(0),
            audio_seconds: d["audio_seconds"].as_f64().unwrap_or(0.0),
        }
    }
    fn day_dict(r: &totals::DayTotal) -> Value {
        json!({"device": r.device, "day": r.day, "words": r.words, "dictations": r.dictations, "audio_seconds": r.audio_seconds})
    }
    fn days(v: &Value) -> Vec<totals::DayTotal> {
        v.as_array().map(|a| a.iter().map(day_of).collect()).unwrap_or_default()
    }

    let stdin = io::stdin();
    let mut out = io::BufWriter::new(io::stdout().lock());
    for line in stdin.lock().lines() {
        let line = line.expect("stdin");
        let Ok(req) = serde_json::from_str::<Value>(&line) else { continue };
        let answer = match req["op"].as_str().unwrap_or("") {
            "dict-merge" => {
                let terms: Option<Vec<String>> = req["terms"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect());
                let rules: Option<Vec<Replacement>> = req["rules"].as_array().map(|a| {
                    a.iter()
                        .map(|r| Replacement { from: r["from"].as_str().unwrap_or("").into(), to: r["to"].as_str().unwrap_or("").into(), learned: r["learned"].as_bool().unwrap_or(false) })
                        .collect()
                });
                let snapshot = keyed(&req["snapshot"]);
                let remote = keyed(&req["remote"]).unwrap_or_default();
                let m = dictionary::merge(terms.as_deref(), rules.as_deref(), snapshot.as_ref(), &remote);
                json!({
                    "terms": m.terms,
                    "rules": m.rules.iter().map(|r| json!({"from": r.from, "to": r.to, "learned": r.learned})).collect::<Vec<_>>(),
                    "upload": m.upload.iter().map(dict_of).collect::<Vec<_>>(),
                    "taken": m.taken.iter().map(dict_of).collect::<Vec<_>>(),
                    "snapshot": m.snapshot.values().map(dict_of).collect::<Vec<_>>(),
                    "refused": m.refused_deletions,
                })
            }
            "totals-plan" => {
                let sent: HashMap<String, totals::DayTotal> = days(&req["sent"]).into_iter().map(|r| (r.day.clone(), r)).collect();
                json!(totals::plan(&days(&req["local"]), &sent).iter().map(day_dict).collect::<Vec<_>>())
            }
            "totals-combine" => {
                let c = totals::combine(&days(&req["remote"]), &days(&req["local"]), req["device"].as_str().unwrap_or(""), req["today"].as_str().unwrap_or(""));
                json!({
                    "words": c.words, "dictations": c.dictations, "audio_seconds": c.audio_seconds, "streak": c.streak_days,
                    "breakdown": c.breakdown(), "devices": c.devices.iter().map(|d| json!([d.device, d.words, d.dictations])).collect::<Vec<_>>(),
                })
            }
            "sync-config" => match SyncConfig::parse(req["text"].as_str().unwrap_or(""), "Mac") {
                (Some(c), _) => json!({"url": c.url, "key": c.key, "device": c.device}),
                (None, problem) => json!({"problem": problem.unwrap_or_default()}),
            },
            _ => Value::Null,
        };
        writeln!(out, "{}", json!({ "out": answer })).unwrap();
    }
}

/// What the platform layer reports, touching nothing: no stream is opened, no key is watched or
/// posted, and nothing is read from another app's fields or the clipboard.
fn platform_check() {
    use linflow_platform as os;
    println!("trusted for Accessibility: {}", os::trusted(false));
    match os::frontmost_app() {
        Some(app) => println!("frontmost app: {} ({}), pid {}", app.name, app.id, app.pid),
        None => println!("frontmost app: none"),
    }
    let users = os::mic_users();
    println!("apps holding the microphone: {}", if users.is_empty() { "none".to_string() } else { users.join(", ") });
    for id in &users {
        if let Some(name) = linflow_core::meeting::detect::call_app_name(id) {
            println!("  {id} is a call app: {name}");
        }
    }
    println!("default input: {}", os::mic::default_input_name().unwrap_or_else(|| "none".into()));
    println!("default output: {}", os::mic::default_output_name().unwrap_or_else(|| "none".into()));
    // The guard is released at the end of this statement, before the line saying so.
    let granted = os::keep_awake("Lin Flow Next platform check").is_some();
    println!("stay-awake request: {}", if granted { "granted and released" } else { "refused" });
}

/// The app's dictation path end to end, minus everything that would touch John's computer: the
/// audio file stands in for the microphone, the text is logged instead of pasted, and the data
/// folder is a temporary one, so his history and dictionary are never read or written.
fn service_test(args: &[String]) {
    use linflow_service::{Event, Service};
    use std::sync::mpsc;
    use std::time::Duration;
    let f = flags(&args[1..]);
    let Some(audio) = f.positional.first() else { usage() };
    let audio = std::fs::canonicalize(audio).unwrap_or_else(|e| {
        eprintln!("{audio}: {e}");
        quit(1)
    });
    let dir = std::env::temp_dir().join(format!("linflow-service-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let model = f.values.get("model").cloned().unwrap_or_else(|| linflow_core::models::DEFAULT_MODEL_ID.to_string());
    let settings = serde_json::json!({"sounds": false, "modelID": model, "audioRetentionDays": 0, "learnCorrections": "off"});
    std::fs::write(dir.join("settings.json"), settings.to_string()).unwrap();
    std::env::set_var("LINFLOW_DATA_DIR", &dir);
    std::env::set_var("LINFLOW_TEST_AUDIO", &audio);
    std::env::set_var("LINFLOW_NO_PASTE", "1");
    std::env::set_var("LINFLOW_NO_HOTKEY", "1");
    let (tx, rx) = mpsc::channel::<Event>();
    let tx = std::sync::Mutex::new(tx);
    let svc = Service::start(std::sync::Arc::new(move |e| {
        let _ = tx.lock().unwrap().send(e);
    }));
    let started = std::time::Instant::now();
    let mut ready = false;
    let mut result = None;
    while started.elapsed() < Duration::from_secs(120) {
        match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(Event::State { phase, label }) => {
                println!("state: {label}");
                if phase == "idle" && !ready {
                    ready = true;
                    svc.dictation.press();
                    std::thread::sleep(Duration::from_millis(400));
                    svc.dictation.release();
                }
                if phase == "error" {
                    break;
                }
            }
            Ok(Event::Dictated { entry }) => {
                result = Some(entry);
                break;
            }
            _ => {}
        }
    }
    match result {
        Some(e) => println!("dictated in {:.2}s on {}: {}", e.inference_seconds, e.model, e.text),
        None => println!("no dictation came back"),
    }
    let saved = std::fs::read_to_string(dir.join("history.jsonl")).map(|t| t.lines().count()).unwrap_or(0);
    println!("history rows in the temp folder: {saved}");
    svc.shutdown();
    let _ = std::fs::remove_dir_all(&dir);
    quit(if saved == 1 { 0 } else { 1 })
}
