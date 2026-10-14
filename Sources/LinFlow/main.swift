import AppKit
import AVFoundation
import Foundation
import LinFlowCore

// Entry point. With arguments it's a CLI (handy for scripts and for testing
// the engine without a window); with none it becomes the menu bar app.
//
// A command that loads a model ends in _exit, for the reason given in
// AppDelegate.applicationShouldTerminate, and _exit does not flush a piped stdout:
// fflush(stdout) first, or the output vanishes.

func usage(_ code: Int32 = 2) -> Never {
    print("""
    Lin Flow — local dictation on whisper.cpp

    usage:
      LinFlow                                  run the menu bar app (or show it, if it is already running)
      LinFlow transcribe <audio> [options]     transcribe a file and print the text
      LinFlow bench <audio> [options]          run every installed model on a file
      LinFlow models                           list installed + downloadable models
      LinFlow download <model-id>              fetch a model into Application Support
      LinFlow clean "<text>"                   run only the cleanup pass on some text
      LinFlow paste "<text>"                   type text into the focused app the way dictation does
      LinFlow selftest                         run the built-in unit checks
      LinFlow notes-test <audio>               stream a file through the live meeting transcriber
      LinFlow notes-transcribe <note id|folder|audio> [--save]   transcribe a note's saved audio whole (--save rewrites its transcript)
      LinFlow notes-repair [<wav>]             fix WAV headers of a recording cut short, or close every unfinished note
      LinFlow notes-export <note id|folder> [<out.mp3|out.m4a>]   both sides of a note's audio in one file, as Save Audio does
      LinFlow voice-enroll                     fetch the speaker model and learn your voice from your dictations
      LinFlow notes-voices <note id>           who spoke each line by voice, printed, nothing saved
      LinFlow voice-embed <wav> [--from <s>] [--to <s>] [--model <onnx>]   the speaker embedding of a stretch of audio, as JSON
      LinFlow summarize <transcript.jsonl|txt> [--recap]   summarize (Claude once a key is saved, else Apple Intelligence)
      LinFlow clean-batch                      JSON strings in, one per line; each cleaned, as JSON
      LinFlow notes-batch                      notetaker logic requests in as JSON lines, answers out
      LinFlow sync-batch                       sync logic requests in as JSON lines, answers out
      LinFlow ask <note id> "<question>"       ask Claude about a saved meeting; prints the answer, saves nothing
      LinFlow running-notes-test <transcript.jsonl> [--window <s>]   replay a transcript through the running-notes pass, a minute at a time
      LinFlow transform <name|id> "<text>"     rewrite text with a transform (Apple Intelligence, on-device)
      LinFlow transforms                       list the transforms and which apps use them
      LinFlow expand "<text>"                  run the cleanup pass and snippet expansion on some text
      LinFlow learn-test "<wrote>" "<now>" [--apply]   what an edit would teach the dictionary
      LinFlow focus-test                       whether the focused app's text field can be read back
      LinFlow mic-test                         record one second from the default input and say what came back
      LinFlow compare-engines [--count <n>]    run your saved takes through Parakeet and Whisper turbo and write a page to label them

    options:
      --model <id|path>   which ggml model (default: \(ModelCatalog.defaultModelID))
                          Parakeet ids run through libparakeet, everything else through libwhisper
      --lang <code|auto>  spoken language (default: en)
      --beam <n>          beam size, 1 = greedy (default: 5)
      --no-vad            disable Silero voice-activity trimming
      --fallback          enable temperature fallback retries (off by default: slower, rarely helps)
      --no-rescue         transcribe: leave an empty result empty instead of retrying on the other engine, as the app does
      --prompt <text>     initial prompt for the decoder (default: your glossary)
      --raw               skip the cleanup pass, print whisper's text as-is
      --verbose           show whisper.cpp / ggml log output

    environment:
      LINFLOW_DATA_DIR=<folder>          use another data folder (selftest does this by itself)
      LINFLOW_DEFAULTS_SUITE=<domain>    keep settings in another defaults domain, never the live one
    """)
    exit(code)
}

struct CLIArgs {
    var positional: [String] = []
    var flags: [String: String] = [:]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                let takesValue = ["model", "lang", "beam", "prompt", "window", "count", "from", "to"].contains(key)
                if takesValue {
                    guard i + 1 < argv.count, !argv[i + 1].hasPrefix("--") else {
                        fputs("--\(key) needs a value\n\n", stderr); usage()
                    }
                    flags[key] = argv[i + 1]; i += 2; continue
                }
                flags[key] = "true"
            } else {
                positional.append(a)
            }
            i += 1
        }
    }
    func has(_ k: String) -> Bool { flags[k] != nil }
}

func makeOptions(_ args: CLIArgs) -> TranscriptionOptions {
    var o = TranscriptionOptions()
    o.language = args.flags["lang"] ?? "en"
    if let b = args.flags["beam"], let n = Int32(b) { o.beamSize = n }
    if !args.has("no-vad") { o.vadModelPath = ModelCatalog.vadModelURL?.path }
    o.temperatureFallback = args.has("fallback")
    o.initialPrompt = args.flags["prompt"] ?? Glossary.initialPrompt(Glossary.load())
    return o
}

func loadEngine(_ args: CLIArgs, modelOverride: URL? = nil) -> SpeechEngine {
    let id = args.flags["model"] ?? ModelCatalog.defaultModelID
    guard let url = modelOverride ?? ModelCatalog.locate(id) else {
        fputs("model '\(id)' not found. Run `LinFlow models` to see what's installed, or `LinFlow download \(id)`.\n", stderr)
        exit(1)
    }
    do { return try EngineFactory.load(modelURL: url) } catch {
        fputs("\(error.localizedDescription)\n", stderr); exit(1)
    }
}

func cmdTranscribe(_ args: CLIArgs) {
    guard args.positional.count >= 2 else { usage() }
    let url = URL(fileURLWithPath: args.positional[1])
    let samples: [Float]
    do { samples = try AudioIO.loadSamples(from: url) } catch {
        fputs("could not read \(url.path): \(error.localizedDescription)\n", stderr); exit(1)
    }
    let engine = loadEngine(args)
    do {
        var r = try engine.transcribe(samples, options: makeOptions(args))
        // The app retries an empty take on the other engine kind (DictationController), so
        // without the same here a cafe take the app typed comes back blank. --no-rescue skips it.
        if r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !args.has("no-rescue"),
           let url = ModelCatalog.rescueModelURL(after: engine.kind, installed: ModelCatalog.installedModelURLs()) {
            fputs("[empty from \(engine.modelID); rescued by \(ModelCatalog.idFromURL(url))]\n", stderr)
            r = try EngineFactory.load(modelURL: url).transcribe(samples, options: makeOptions(args))
        }
        if args.has("raw") {
            print(r.text)
        } else {
            let cleaned = TextCleaner(glossary: Glossary.load()).clean(r.text)
            print(cleaned)
            if cleaned != r.text { fputs("[raw] \(r.text)\n", stderr) }
        }
        fputs(String(format: "[%.1fs audio -> %.2fs inference%@]\n", r.audioSeconds, r.inferenceSeconds,
                     r.detectedLanguage.map { ", lang=\($0)" } ?? ""), stderr)
    } catch {
        // _exit: a normal exit() with a model loaded trips ggml's Metal teardown assertion.
        fputs("\(error.localizedDescription)\n", stderr); fflush(stdout); Log.flush(); _exit(1)
    }
}

func cmdBench(_ args: CLIArgs) {
    guard args.positional.count >= 2 else { usage() }
    let url = URL(fileURLWithPath: args.positional[1])
    guard let samples = try? AudioIO.loadSamples(from: url) else { fputs("could not read \(url.path)\n", stderr); exit(1) }
    let opts = makeOptions(args)
    print(String(format: "audio: %.1fs   beam=%d  vad=%@  fallback=%@", Double(samples.count) / AudioIO.sampleRate,
                 opts.beamSize, opts.vadModelPath == nil ? "off" : "on", opts.temperatureFallback ? "on" : "off"))
    for modelURL in ModelCatalog.installedModelURLs() {
        guard let engine = try? EngineFactory.load(modelURL: modelURL) else { print("  \(modelURL.lastPathComponent): load failed"); continue }
        // Warm-up run first: Metal shader/pipeline setup lands on the first call.
        _ = try? engine.transcribe(samples, options: opts)
        var times: [Double] = []
        var text = ""
        for _ in 0..<3 {
            guard let r = try? engine.transcribe(samples, options: opts) else { continue }
            times.append(r.inferenceSeconds); text = r.text
        }
        let avg = times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count)
        print(String(format: "  %-32@ load %.2fs  infer %.2fs  -> %@", ModelCatalog.idFromURL(modelURL) as NSString, engine.loadSeconds, avg, text as NSString))
    }
}

func cmdModels() {
    print("models folder: \(ModelCatalog.modelsDir.path)\n")
    let installed = ModelCatalog.installedModelURLs()
    print("installed:")
    if installed.isEmpty { print("  (none)") }
    for u in installed {
        let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
        print(String(format: "  %-28@ %5d MB  %@", ModelCatalog.idFromURL(u) as NSString, size / 1_000_000, u.path as NSString))
    }
    print("\ndownloadable (LinFlow download <id>):")
    for m in ModelCatalog.known where ModelCatalog.locate(m.id) == nil {
        print(String(format: "  %-28@ %5d MB  %@", m.id as NSString, m.sizeMB, m.note as NSString))
    }
    print("\nVAD model: \(ModelCatalog.vadModelURL?.path ?? "not installed")")
}

func cmdDownload(_ args: CLIArgs) {
    guard args.positional.count >= 2 else { usage() }
    let id = args.positional[1]
    let info: ModelInfo
    if id == ModelCatalog.vadModel.id || id == "vad" { info = ModelCatalog.vadModel }
    else if let m = ModelCatalog.info(for: id) { info = m }
    else { fputs("unknown model id '\(id)'\n", stderr); exit(1) }
    let done = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    ModelCatalog.download(info, progress: { p in
        fputs(String(format: "\r  %3.0f%%", p * 100), stderr)
    }, completion: { result in
        fputs("\n", stderr)
        switch result {
        case .success(let u): print("saved to \(u.path)")
        case .failure(let e): fputs("failed: \(e.localizedDescription)\n", stderr); exitCode = 1
        }
        done.signal()
    })
    done.wait()
    exit(exitCode)
}

/// Pump the main run loop until `done` fires (callbacks in the core layer land on main).
func waitPumping(_ done: DispatchSemaphore, settle: TimeInterval = 0.3) {
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: settle))
}

func cmdNotesTest(_ args: CLIArgs) {
    guard args.positional.count >= 2 else { usage() }
    let url = URL(fileURLWithPath: args.positional[1])
    guard let samples = try? AudioIO.loadSamples(from: url) else { fputs("could not read \(url.path)\n", stderr); exit(1) }
    let engine = loadEngine(args)
    let opts = makeOptions(args)
    let live = LiveTranscriber(speaker: "You", engine: { engine }, options: { opts }, glossary: Glossary.load())
    var count = 0
    live.onSegment = { seg in
        count += 1
        print(String(format: "[%@ → %.1fs] %@: %@", seg.timestampLabel, seg.end, seg.speaker, seg.text))
    }
    // Feed 100 ms chunks the way the microphone would deliver them.
    let step = Int(AudioIO.sampleRate / 10)
    var i = 0
    while i < samples.count { live.feed(Array(samples[i..<min(i + step, samples.count)])); i += step }
    let done = DispatchSemaphore(value: 0)
    live.finish { done.signal() }
    waitPumping(done, settle: 0.5)
    fputs("\(count) segment(s) from \(String(format: "%.1f", Double(samples.count) / AudioIO.sampleRate))s of audio\n", stderr)
}

/// The full pass NoteTranscriber runs after a meeting, from the command line. A note id or
/// its folder transcribes every saved track and merges them; a lone audio file is treated as
/// "You". Nothing is written unless --save is given, and even then the live transcript is
/// kept as transcript-live.jsonl.
func cmdNotesTranscribe(_ args: CLIArgs) {
    guard args.positional.count >= 2 else { usage() }
    let target = args.positional[1]
    let fm = FileManager.default
    var isDir: ObjCBool = false
    let exists = fm.fileExists(atPath: target, isDirectory: &isDir)
    let engine = loadEngine(args)
    let opts = makeOptions(args)
    let glossary = Glossary.load()
    let t0 = Date()
    let progress: (String) -> Void = { fputs("  \($0)\r", stderr) }
    do {
        var noteID: String?, voiceLine: String?
        let segments: [TranscriptSegment]
        if exists, !isDir.boolValue {
            segments = try NoteTranscriber.transcribe(file: URL(fileURLWithPath: target), speaker: "You", engine: engine, options: opts, glossary: glossary, progress: progress)
        } else {
            let id = exists ? URL(fileURLWithPath: target).lastPathComponent : target
            noteID = id
            segments = try NoteTranscriber.transcribe(noteID: id, engine: engine, options: opts, glossary: glossary, progress: progress,
                                                      voices: { voiceLine = $0 })
        }
        fputs("\n", stderr)
        for s in segments { print(String(format: "[%@ → %.1fs] %@: %@", s.timestampLabel, s.end, s.speaker, s.text)) }
        let words = segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
        if args.has("save"), let id = noteID {
            NotesStore.replaceTranscript(segments, for: id, model: engine.displayName)
            if let voiceLine { NotesStore.appendEvent(voiceLine, to: id) }
            fputs("saved as transcript.jsonl (live transcript kept as transcript-live.jsonl)\n", stderr)
        }
        fputs(String(format: "%d segment(s), %d words, %.1fs [%@]\n", segments.count, words, Date().timeIntervalSince(t0), engine.displayName), stderr)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr); fflush(stdout); Log.flush(); _exit(1)
    }
    fflush(stdout); Log.flush(); _exit(0)
}

/// With a file: repair that WAV's header from its size and print its duration. Without: close
/// every note the app never stopped, the way the app does at launch.
func cmdNotesRepair(_ args: CLIArgs) {
    if args.positional.count >= 2 {
        let url = URL(fileURLWithPath: args.positional[1])
        do {
            let before = WAVWriter.duration(at: url) ?? 0
            let changed = try WAVWriter.repairHeader(at: url)
            let after = WAVWriter.duration(at: url) ?? 0
            print(String(format: "%@: %@ (header said %.1f s, file holds %.1f s)", url.lastPathComponent, changed ? "repaired" : "already consistent", before, after))
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        return
    }
    let recovered = NotesStore.recoverUnfinished()
    if recovered.isEmpty { print("no unfinished notes") }
    for n in recovered { print("recovered \(n.id) \"\(n.title)\": \(Int(n.durationSeconds)) s") }
}

/// What Save Audio in a note's menu does: both sides leveled, mixed and encoded. The output's
/// extension picks MP3 or AAC. Without one, the file is named after the note, in this folder.
func cmdNotesExport(_ args: CLIArgs) {
    guard args.positional.count >= 2 else { usage() }
    let target = args.positional[1]
    let id = FileManager.default.fileExists(atPath: target) ? URL(fileURLWithPath: target).lastPathComponent : target
    let title = NotesStore.load(id)?.title ?? id
    var format = AudioExport.preferredFormat
    let out: URL
    if args.positional.count >= 3 {
        out = URL(fileURLWithPath: args.positional[2])
        guard let f = AudioExport.Format(rawValue: out.pathExtension.lowercased()) else { fputs("the output must end in .mp3 or .m4a\n", stderr); exit(2) }
        format = f
    } else {
        out = URL(fileURLWithPath: NotesStore.fileName(title, ext: format.rawValue))
    }
    let t0 = Date()
    do {
        let r = try AudioExport.export(noteID: id, title: title, to: out, format: format) { p in fputs(String(format: "  %3.0f%%\r", p * 100), stderr) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: out.path)[.size]) as? Int) ?? 0
        let gains = r.gains.keys.sorted().map { String(format: "%@ %+.1f dB", $0, r.gains[$0]!) }.joined(separator: ", ")
        print(String(format: "%@: %.0f s, %.1f MB, %@, %@ (call %+.2f s from the mic), in %.1f s", out.path, r.seconds, Double(size) / 1e6, gains,
                     r.coupling.rawValue, r.delay, Date().timeIntervalSince(t0)))
    } catch {
        fputs("\(error.localizedDescription)\n", stderr); exit(1)
    }
}

/// What the app does at launch to tell voices apart: the model, then the voiceprint.
func cmdVoiceEnroll(_ args: CLIArgs) {
    if let why = VoiceID.prepare() { fputs("\(why)\n", stderr); exit(1) }
    if let v = VoiceID.loadVoiceprint() { print("voiceprint from \(v.takes) dictations, made \(v.madeAt)") }
}

/// The voice pass on a saved note's transcript, printed with each line's score. Writes nothing.
func cmdNotesVoices(_ args: CLIArgs) {
    guard args.positional.count >= 2 else { usage() }
    let id = args.positional[1]
    let before = NotesStore.transcript(id)
    let t0 = Date()
    let r = VoiceID.label(before, noteID: id)
    let after = Dictionary(uniqueKeysWithValues: r.segments.map { ($0.id, $0) })
    for s in before {
        let mark = after[s.id].map { $0.speaker == s.speaker ? "  " : "->" } ?? "xx"
        print(String(format: "%@ %7.1f %@ %@%@", mark, s.start, s.speaker, after[s.id].map { $0.speaker != s.speaker ? "\($0.speaker): " : "" } ?? "", String(s.text.prefix(90))))
    }
    fputs(String(format: "%@: %d judged, %d moved, %d dropped, in %.1f s\n", r.coupling.rawValue, r.judged, r.moved, r.dropped, Date().timeIntervalSince(t0)), stderr)
}

/// A speaker embedding from the command line, for checking the Swift network against a reference.
func cmdVoiceEmbed(_ args: CLIArgs) {
    guard args.positional.count >= 2 else { usage() }
    do {
        let model = try SpeakerModel(url: args.flags["model"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? SpeakerModel.fileURL)
        let samples = try AudioIO.loadSamples(from: URL(fileURLWithPath: args.positional[1]))
        let rate = AudioIO.sampleRate
        let a = max(0, Int((Double(args.flags["from"] ?? "") ?? 0) * rate)), b = min(samples.count, Int((Double(args.flags["to"] ?? "") ?? .infinity) * rate))
        let t0 = Date()
        guard a < b, let e = model.embed(samples[a..<b]) else { fputs("too little audio\n", stderr); exit(1) }
        fputs(String(format: "%.0f ms\n", Date().timeIntervalSince(t0) * 1000), stderr)
        print("[" + e.map { String(format: "%.6f", $0) }.joined(separator: ",") + "]")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

/// Replays a saved transcript the way a meeting would have fed it: a pass every `--window`
/// seconds (60 by default) over the segments that landed since the last one, with the bullets
/// so far as context. Prints each pass's bullets and timing, so a prompt change can be judged
/// against a real meeting before it ships.
func cmdRunningNotesTest(_ args: CLIArgs) {
    guard args.positional.count >= 2 else { usage() }
    let url = URL(fileURLWithPath: args.positional[1])
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else { fputs("could not read \(url.path)\n", stderr); exit(1) }
    let dec = JSONDecoder()
    let segments = raw.split(whereSeparator: \.isNewline).compactMap { try? dec.decode(TranscriptSegment.self, from: Data($0.utf8)) }.sorted { $0.start < $1.start }
    guard !segments.isEmpty else { fputs("no segments in \(url.path)\n", stderr); exit(1) }
    let window = Double(args.flags["window"] ?? "") ?? RunningNotes.interval
    let (summarizer, why) = SummarizerFactory.best()
    guard let summarizer else { fputs("\(why ?? "no summarizer")\n", stderr); exit(1) }
    let title = url.deletingLastPathComponent().lastPathComponent
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        var notes = ""
        var processed = Set<String>()
        var windowEnd = window
        var passes = 0, calls = 0, totalSeconds = 0.0
        let last = segments.last!.end
        while windowEnd < last + window {
            let due = segments.filter { !processed.contains($0.id) && $0.end <= windowEnd }
            let final = windowEnd >= last
            let fresh = RunningNotes.window(due, processed: processed)
            let words = RunningNotes.wordCount(fresh)
            if !fresh.isEmpty, RunningNotes.isDue(newWords: words, sinceLast: window, final: final) {
                passes += 1
                let previous = RunningNotes.recent(notes)
                let t0 = Date()
                do {
                    let bullets = try await summarizer.runningNotes(previous: previous, transcript: NotesStore.transcriptText(fresh), title: title)
                    let dt = Date().timeIntervalSince(t0); totalSeconds += dt; calls += 1
                    processed.formUnion(fresh.map(\.id))
                    let block = RunningNotes.format(bullets, at: fresh[0].start)
                    notes += block
                    print(String(format: "-- pass %d at %@: %d words in, %d bullet(s), %.1f s", passes, fresh[0].timestampLabel, words, bullets.count, dt))
                    print(block.isEmpty ? "   (nothing worth noting)" : block, terminator: block.isEmpty ? "\n" : "")
                } catch {
                    print("-- pass \(passes) failed: \(error.localizedDescription)")
                    processed.formUnion(fresh.map(\.id))
                }
                continue   // drain the backlog at this window before moving on
            }
            if final { break }
            windowEnd += window
        }
        print(String(format: "\n%d model call(s), %.1f s total, %.1f s each; %d bullets", calls, totalSeconds, calls > 0 ? totalSeconds / Double(calls) : 0, notes.split(separator: "\n").count))
        done.signal()
    }
    waitPumping(done, settle: 0.1)
    fflush(stdout); Log.flush(); _exit(0)
}

func cmdAsk(_ args: CLIArgs) {
    guard args.positional.count >= 3 else { usage() }
    let id = args.positional[1]
    guard let note = NotesStore.load(id) else { fputs("no note \(id)\n", stderr); exit(1) }
    guard let client = ClaudeClient() else { fputs("\(ClaudeClient.Failure.noKey.localizedDescription)\n", stderr); exit(1) }
    let prompt = MeetingQuestions.prompt(title: note.title, transcript: NotesStore.transcriptText(NotesStore.transcript(id)),
                                         notes: NotesStore.notesText(id), earlier: [], question: args.positional[2...].joined(separator: " "))
    let done = DispatchSemaphore(value: 0)
    let t0 = Date()
    Task {
        do { print(try await client.ask(system: MeetingQuestions.system, user: prompt)) }
        catch { fputs("\(error.localizedDescription)\n", stderr) }
        done.signal()
    }
    done.wait()
    fputs(String(format: "[%@, %.1fs]\n", ClaudeClient.model, Date().timeIntervalSince(t0)), stderr)
}

func cmdSummarize(_ args: CLIArgs) {
    guard args.positional.count >= 2 else { usage() }
    let url = URL(fileURLWithPath: args.positional[1])
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else { fputs("could not read \(url.path)\n", stderr); exit(1) }
    let transcript: String
    if url.pathExtension == "jsonl" {
        let dec = JSONDecoder()
        let segs = raw.split(whereSeparator: \.isNewline).compactMap { try? dec.decode(TranscriptSegment.self, from: Data($0.utf8)) }
        transcript = NotesStore.transcriptText(segs)
    } else {
        transcript = raw
    }
    let (summarizer, why) = SummarizerFactory.forSummaries()
    guard let summarizer else { fputs("\(why ?? "no summarizer")\n", stderr); exit(1) }
    let kind: SummaryKind = args.has("recap") ? .recap : .meeting
    let done = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    let t0 = Date()
    Task.detached {
        do {
            let out = try await summarizer.summarize(transcript: transcript, title: url.deletingPathExtension().lastPathComponent, kind: kind) { p in
                fputs("  \(p)\n", stderr)
            }
            print(out)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr); exitCode = 1
        }
        done.signal()
    }
    waitPumping(done)
    fputs(String(format: "[%@, %.1fs]\n", summarizer.name, Date().timeIntervalSince(t0)), stderr)
    exit(exitCode)
}

func cmdTransform(_ args: CLIArgs) {
    guard args.positional.count >= 3 else { usage() }
    let transforms = Transforms.load()
    guard let transform = Transforms.lookup(args.positional[1], in: transforms) else {
        fputs("no transform called '\(args.positional[1])'. Run `LinFlow transforms`.\n", stderr); exit(1)
    }
    let text = args.positional[2...].joined(separator: " ")
    let (rewriter, why) = RewriterFactory.best()
    guard let rewriter else { fputs("\(why ?? "no rewriter")\n", stderr); exit(1) }
    let done = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    let t0 = Date()
    Task.detached {
        do { print(TextCleaner.applyStyle(try await rewriter.rewrite(text, using: transform))) }
        catch { fputs("\(error.localizedDescription)\n", stderr); exitCode = 1 }
        done.signal()
    }
    waitPumping(done, settle: 0.05)
    fputs(String(format: "[%@ · %@, %.1fs]\n", transform.name, rewriter.name, Date().timeIntervalSince(t0)), stderr)
    exit(exitCode)
}

func cmdTransforms() {
    let settings = Settings.shared
    let apps = settings.appTransforms
    print("cleanup level: \(settings.cleanupLevel.label)" + (settings.cleanupLevel == .medium ? " (Clarity everywhere without an app rule)" : ""))
    for t in Transforms.load() {
        let used = apps.filter { $0.value == t.id }.keys.sorted()
        print("\n\(t.name) [\(t.id)]\(t.builtIn ? " built in" : "")" + (used.isEmpty ? "" : "  used in: \(used.joined(separator: ", "))"))
        print("  \(t.instructions)")
    }
    let off = apps.filter { $0.value == Transforms.none }.keys.sorted()
    if !off.isEmpty { print("\nno transform in: \(off.joined(separator: ", "))") }
}

func cmdLearnTest(_ args: CLIArgs) {
    guard args.positional.count >= 3 else { usage() }
    let wrote = args.positional[1], now = args.positional[2]
    let existing = Glossary.loadReplacements()
    let scored = LearnedCorrections.scored(wrote: wrote, now: now, existing: existing)
    if scored.isEmpty {
        if let pair = CorrectionLearning.lonePair(wrote: wrote, now: now) {
            print("\(pair.from) => \(pair.to)   [neither tier took it; offered on screen, added by a click]")
        } else {
            print("nothing to learn from that edit")
        }
    } else {
        for s in scored {
            print("\(s.replacement.from) => \(s.replacement.to)"
                  + (s.confidence == .suggest ? "   [offered only; needs a click in the Dictionary]" : ""))
        }
    }
    guard args.has("apply") else {
        fputs("[dry run; pass --apply to add these to the dictionary]\n", stderr)
        return
    }
    let outcome = CorrectionLearning.handle(wrote: wrote, now: now, mode: Settings.shared.learnCorrections)
    fputs("[mode \(Settings.shared.learnCorrections.rawValue): added \(outcome.added.count), suggested \(outcome.suggested.count)]\n", stderr)
}

/// Says whether the app you are typing in exposes its text to Accessibility, which is what
/// learning from an edit in place depends on.
func cmdFocusTest() {
    guard AXIsProcessTrusted() else {
        fputs("this binary is not trusted for Accessibility, so it cannot check\n", stderr); exit(1)
    }
    guard let app = NSWorkspace.shared.frontmostApplication else { fputs("no frontmost app\n", stderr); exit(1) }
    print("frontmost app: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))")
    // Chromium builds its tree asynchronously once asked, so ask and then keep looking.
    PasteWatcher.primeAccessibility(app.processIdentifier)
    var found: AXUIElement? = nil
    for waited in [0.0, 0.6, 1.5, 3.0, 5.0] {
        if waited > 0 { Thread.sleep(forTimeInterval: waited) }
        if let e = PasteWatcher.focusedTextElement(app.processIdentifier) {
            print("focused element found after \(Int(waited * 1000))ms")
            found = e
            break
        }
    }
    guard let element = found else {
        print("no focused element after 5s: editing in place cannot be learned in this app, use the pencil in the Dictation list")
        return
    }
    if let value = PasteWatcher.value(of: element) {
        print("readable: yes, \(value.count) characters in the focused field")
    } else {
        print("focused element found but its value is not readable: a password field, or an app that hides its text")
    }
}

/// One second through the same Recorder a dictation uses: which device, how long until audio
/// arrived, how loud it was, and whether the input is dead. Nothing is saved.
func cmdMicTest() {
    guard Recorder.microphoneAuthorized else { fputs("this process has no microphone access, so it cannot check\n", stderr); exit(1) }
    let recorder = Recorder()
    do { try recorder.start() } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
    let samples = recorder.stop()
    if let start = recorder.lastStart { print(DictationController.describe(start, after: "asking")) }
    let noise = AudioIO.snrEstimate(samples)
    print(String(format: "%.2fs of audio, peak %.4f, noise floor %.4f", Double(samples.count) / AudioIO.sampleRate, AudioIO.peak(samples), noise.noiseFloor))
    print(DictationController.isDeadMicrophone(samples) ? "dead: pure digital silence, the device is sending nothing" : "live")
}

let argv = Array(CommandLine.arguments.dropFirst())
let args = CLIArgs(argv)
Log.verbose = args.has("verbose")

// The checks run against fixed inputs, never against John's live files. This has to happen
// before anything reads `ModelCatalog.appSupportDir`, which resolves once and keeps the
// answer. `LINFLOW_DATA_DIR` set by hand wins, so a test folder can be inspected afterwards.
if args.positional.first == "selftest", ProcessInfo.processInfo.environment["LINFLOW_DATA_DIR"] == nil {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("linflow-selftest-\(getpid())", isDirectory: true)
    setenv("LINFLOW_DATA_DIR", dir.path, 1)
}
// Settings too: a check that ever writes one writes it somewhere John's app never reads.
if args.positional.first == "selftest", Settings.testSuite == nil {
    setenv("LINFLOW_DEFAULTS_SUITE", "\(Settings.domain).selftest", 1)
}

if args.positional.isEmpty {
    // A flag with no command is a mistyped CLI call, not a request for the app: `LinFlow --help`
    // used to start a second, complete Lin Flow with its own Fn listener.
    if !args.flags.isEmpty { usage(args.has("help") ? 0 : 2) }
    // One Lin Flow at a time. Two copies means two event taps, and one key press recorded and
    // pasted twice. A second launch -- the build folder, dist/, `open -n` -- shows the copy
    // that is already running and leaves.
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Settings.domain)
        .first(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
        fputs("Lin Flow is already running (pid \(running.processIdentifier)); showing it instead of starting another.\n", stderr)
        if let url = running.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            let shown = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in shown.signal() }
            _ = shown.wait(timeout: .now() + 3)
        } else {
            running.activate()
        }
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    exit(0)
}

switch args.positional[0] {
case "transcribe": cmdTranscribe(args)
case "bench": cmdBench(args)
case "models": cmdModels()
case "download": cmdDownload(args)
case "selftest": exit(SelfTest.run())
case "toast-shot": cmdToastShot(args)
case "notes-test": cmdNotesTest(args)
case "notes-transcribe": cmdNotesTranscribe(args)
case "notes-repair": cmdNotesRepair(args)
case "notes-export": cmdNotesExport(args)
case "voice-embed": cmdVoiceEmbed(args)
case "voice-enroll": cmdVoiceEnroll(args)
case "notes-voices": cmdNotesVoices(args)
case "summarize": cmdSummarize(args)
case "ask": cmdAsk(args)
case "running-notes-test": cmdRunningNotesTest(args)
case "paste":
    guard args.positional.count >= 2 else { usage() }
    // Give the caller's window a moment to be frontmost, then paste and let the clipboard restore land.
    Thread.sleep(forTimeInterval: 0.3)
    TextInjector.paste(args.positional[1...].joined(separator: " "))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
case "clean":
    guard args.positional.count >= 2 else { usage() }
    print(TextCleaner(glossary: Glossary.load()).clean(args.positional[1...].joined(separator: " ")))
case "clean-batch":
    // One JSON string per line in, the cleaned JSON string per line out: the oracle the Rust
    // rebuild (next/) is compared against, without a process per dictation.
    let cleaner = TextCleaner(glossary: Glossary.load())
    while let line = readLine(strippingNewline: true) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
              let raw = try? JSONDecoder().decode(String.self, from: Data(line.utf8)) else { continue }
        let out = try! JSONEncoder().encode(cleaner.clean(raw))
        print(String(decoding: out, as: UTF8.self))
    }
case "notes-batch":
    // The notetaker's pure logic, one JSON request per line in and one JSON answer per line out:
    // the oracle the Rust rebuild's meeting module (next/core/src/meeting) is compared against.
    func strs(_ v: Any?) -> [String] { v as? [String] ?? [] }
    func answer(_ v: Any) {
        let data = try! JSONSerialization.data(withJSONObject: ["out": v], options: [.sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }
    while let line = readLine(strippingNewline: true) {
        guard let req = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let op = req["op"] as? String else { continue }
        switch op {
        case "regions":
            let levels = (req["levels"] as? [Double] ?? []).map(Float.init)
            answer(NoteTranscriber.regions(levels: levels, totalSamples: req["total"] as? Int ?? 0).map { [$0.start, $0.end] })
        case "echo":
            let segs = (req["segments"] as? [[String: Any]] ?? []).enumerated().map { i, d in
                TranscriptSegment(id: String(i), start: d["start"] as? Double ?? 0, end: d["end"] as? Double ?? 0,
                                  speaker: d["speaker"] as? String ?? "", text: d["text"] as? String ?? "")
            }
            answer(NoteTranscriber.dropEcho(segs).map { Int($0.id)! })
        case "filter":
            answer(RunningNotes.filter(strs(req["bullets"]), previous: strs(req["previous"]), transcript: req["transcript"] as? String ?? ""))
        case "grounded":
            answer(RunningNotes.grounded(req["bullet"] as? String ?? "", in: req["transcript"] as? String ?? "", previous: strs(req["previous"])))
        case "worth":
            answer(RunningNotes.worthKeeping(req["bullet"] as? String ?? "") ?? NSNull())
        case "repeats":
            answer(RunningNotes.dropRepeats(strs(req["bullets"]), previous: strs(req["previous"])))
        case "recent":
            answer(RunningNotes.recent(req["notes"] as? String ?? "", count: req["count"] as? Int ?? 10))
        case "wordcount":
            answer(RunningNotes.wordCount(req["text"] as? String ?? ""))
        case "tidy":
            answer(NotesMerge.tidy(strs(req["items"])))
        case "merge":
            let order = NotesMerge.Section.allCases
            let parts = (req["parts"] as? [[[String]]] ?? []).map { lists in
                Dictionary(uniqueKeysWithValues: zip(order, lists + Array(repeating: [], count: max(0, order.count - lists.count))))
            }
            answer(NotesMerge.render(NotesMerge.merge(parts)))
        case "edited":
            answer(PasteWatcher.editedVersion(of: req["wrote"] as? String ?? "", in: req["now"] as? String ?? "") ?? NSNull())
        case "scored":
            let existing = (req["existing"] as? [[String: Any]] ?? []).map { Replacement(from: $0["from"] as? String ?? "", to: $0["to"] as? String ?? "", learned: $0["learned"] as? Bool ?? false) }
            answer(LearnedCorrections.scored(wrote: req["wrote"] as? String ?? "", now: req["now"] as? String ?? "", existing: existing).map {
                ["from": $0.replacement.from, "to": $0.replacement.to, "learned": $0.replacement.learned, "apply": $0.confidence == .apply] as [String: Any]
            })
        case "lone-pair":
            if let p = CorrectionLearning.lonePair(wrote: req["wrote"] as? String ?? "", now: req["now"] as? String ?? "") { answer([p.from, p.to]) } else { answer(NSNull()) }
        case "word-checks":
            let from = req["from"] as? String ?? "", to = req["to"] as? String ?? ""
            answer(["offering": LearnedCorrections.worthOffering(from: from, to: to), "plausible": LearnedCorrections.plausible(from: from, to: to),
                    "showing": CorrectionLearning.worthShowing(from, to), "everyday": LearnedCorrections.everydayEnglish(from)])
        case "merging":
            func reps(_ v: Any?) -> [Replacement] { (v as? [[String: Any]] ?? []).map { Replacement(from: $0["from"] as? String ?? "", to: $0["to"] as? String ?? "", learned: $0["learned"] as? Bool ?? false) } }
            let c = reps([req["candidate"] as Any]).first ?? Replacement(from: "", to: "")
            if let out = CorrectionLearning.merging(c, into: reps(req["waiting"]), accepted: reps(req["accepted"])) {
                answer(out.map { ["from": $0.from, "to": $0.to, "learned": $0.learned] as [String: Any] })
            } else { answer(NSNull()) }
        case "track":
            // A saved WAV read the way NoteTranscriber reads it: its levels and speech regions.
            guard let path = req["path"] as? String, let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { answer(NSNull()); continue }
            let total = Int(file.length)
            let read: (Int, Int) -> [Float] = { start, count in
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { return [] }
                file.framePosition = AVAudioFramePosition(start)
                guard (try? file.read(into: buf, frameCount: AVAudioFrameCount(count))) != nil, let p = buf.floatChannelData?[0] else { return [] }
                return Array(UnsafeBufferPointer(start: p, count: Int(buf.frameLength)))
            }
            let levels = NoteTranscriber.levels(read: read, totalSamples: total)
            answer(["frames": levels.count, "sum": levels.reduce(0.0) { $0 + Double($1) },
                    "regions": NoteTranscriber.regions(levels: levels, totalSamples: total).map { [$0.start, $0.end] }])
        case "split":
            answer(AppleIntelligenceSummarizer.split(req["text"] as? String ?? "", maxCharacters: req["max"] as? Int ?? 100))
        case "tail":
            answer(AppleIntelligenceSummarizer.tail(req["text"] as? String ?? "", maxCharacters: req["max"] as? Int ?? 100))
        default:
            answer(NSNull())
        }
    }
case "sync-batch":
    // The sync's pure logic, one JSON request per line: the oracle for next/core/src/sync.
    func entryOf(_ d: [String: Any]) -> DictionaryEntry {
        DictionaryEntry(kind: DictionaryEntry.Kind(rawValue: d["kind"] as? String ?? "term") ?? .term, text: d["text"] as? String ?? "",
                        target: d["target"] as? String ?? "", learned: d["learned"] as? Bool ?? false,
                        deleted: d["deleted"] as? Bool ?? false, updatedAt: d["updated_at"] as? String ?? "")
    }
    func dictOf(_ e: DictionaryEntry) -> [String: Any] {
        ["kind": e.kind.rawValue, "text": e.text, "target": e.target, "learned": e.learned, "deleted": e.deleted, "updated_at": e.updatedAt]
    }
    func keyed(_ v: Any?) -> [String: DictionaryEntry]? {
        guard let rows = v as? [[String: Any]] else { return nil }
        var out: [String: DictionaryEntry] = [:]
        for e in rows.map(entryOf) { out[e.id] = e }
        return out
    }
    func dayOf(_ d: [String: Any]) -> DayTotal {
        DayTotal(device: d["device"] as? String ?? "", day: d["day"] as? String ?? "", words: d["words"] as? Int ?? 0,
                 dictations: d["dictations"] as? Int ?? 0, audioSeconds: d["audio_seconds"] as? Double ?? 0)
    }
    func dayDict(_ r: DayTotal) -> [String: Any] {
        ["device": r.device, "day": r.day, "words": r.words, "dictations": r.dictations, "audio_seconds": r.audioSeconds]
    }
    func reply(_ v: Any) {
        let data = try! JSONSerialization.data(withJSONObject: ["out": v], options: [.sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }
    while let line = readLine(strippingNewline: true) {
        guard let req = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let op = req["op"] as? String else { continue }
        switch op {
        case "dict-merge":
            let rules = (req["rules"] as? [[String: Any]])?.map { Replacement(from: $0["from"] as? String ?? "", to: $0["to"] as? String ?? "", learned: $0["learned"] as? Bool ?? false) }
            let m = DictionaryMerger.merge(terms: req["terms"] as? [String], rules: rules, snapshot: keyed(req["snapshot"]), remote: keyed(req["remote"]) ?? [:])
            reply(["terms": m.terms, "rules": m.rules.map { ["from": $0.from, "to": $0.to, "learned": $0.learned] },
                   "upload": m.upload.map(dictOf), "taken": m.taken.map(dictOf),
                   "snapshot": m.snapshot.keys.sorted().map { dictOf(m.snapshot[$0]!) }, "refused": m.refusedDeletions])
        case "totals-plan":
            var sent: [String: DayTotal] = [:]
            for r in (req["sent"] as? [[String: Any]] ?? []).map(dayOf) { sent[r.day] = r }
            reply(TotalsSync.plan(local: (req["local"] as? [[String: Any]] ?? []).map(dayOf), sent: sent).map(dayDict))
        case "totals-combine":
            let c = DailyTotals.combine(remote: (req["remote"] as? [[String: Any]] ?? []).map(dayOf), local: (req["local"] as? [[String: Any]] ?? []).map(dayOf),
                                        device: req["device"] as? String ?? "", today: req["today"] as? String ?? "")
            reply(["words": c.words, "dictations": c.dictations, "audio_seconds": c.audioSeconds, "streak": c.streakDays,
                   "breakdown": c.breakdown(), "devices": c.devices.map { [$0.device, $0.words, $0.dictations] as [Any] }])
        case "sync-config":
            let (c, problem) = SyncConfig.parse(req["text"] as? String ?? "", defaultDevice: "Mac")
            if let c { reply(["url": c.url, "key": c.key, "device": c.device]) } else { reply(["problem": (problem ?? "") as Any]) }
        default:
            reply(NSNull())
        }
    }
case "expand":
    guard args.positional.count >= 2 else { usage() }
    let cleaned = TextCleaner(glossary: Glossary.load()).clean(args.positional[1...].joined(separator: " "))
    print(Snippets.expand(cleaned, snippets: Snippets.load()))
case "learn-test": cmdLearnTest(args)
case "focus-test": cmdFocusTest()
case "mic-test": cmdMicTest()
case "compare-engines": EngineComparison.run(count: Int(args.flags["count"] ?? "") ?? 50, longest: 20)
case "transform": cmdTransform(args)
case "transforms": cmdTransforms()
default: usage()
}

/// Renders the real toast offscreen, every variant stacked into one PNG, so its legibility
/// can be judged without a screen recording grant and without interrupting a dictation.
/// Usage: LinFlow toast-shot [out.png]
func cmdToastShot(_ args: CLIArgs) {
    let out = args.positional.count > 1 ? args.positional[1] : "toast.png"
    let declined = LearnToast.declined(from: "Merissa Wong", to: "Marisa Vuong")
    let variants: [(String, String, Bool)] = [
        (declined.title, declined.detail, false),
        ("Learned: “Brona” → “Verona”", "Used from now on. Click to change it in the Dictionary.", false),
        ("Suggested: “Wort” → “Duarte”  +2 more", "Not applied yet. Click to confirm it in the Dictionary.", false),
        ("No sound from MacBook Pro Microphone", "3.2 s of pure silence, so nothing was typed. Click to check the input in Sound settings.", true),
        ("Pill hidden", "Dictation still works. Click here to bring it back, or use Show Floating Pill in the menu bar menu.", false),
    ]
    let pad: CGFloat = 16
    var reps: [NSBitmapImageRep] = []
    for (title, detail, warning) in variants {
        let view = ToastView(frame: .zero)
        view.set(title: title, detail: detail, warning: warning)
        let size = view.measure()
        view.frame = NSRect(origin: .zero, size: size)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("toast-shot: could not make a bitmap"); exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        reps.append(rep)
        print(String(format: "  %-44@  %.0f x %.0f", title as NSString, size.width, size.height))
    }
    let w = (reps.map { CGFloat($0.pixelsWide) }.max() ?? 0) + pad * 2
    let h = reps.reduce(pad) { $0 + CGFloat($1.pixelsHigh) + pad }
    let canvas = NSImage(size: NSSize(width: w, height: h))
    canvas.lockFocus()
    NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: h)).fill()
    var y = h
    for rep in reps {
        y -= pad + CGFloat(rep.pixelsHigh)
        rep.draw(in: NSRect(x: pad, y: y, width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh)))
    }
    canvas.unlockFocus()
    guard let tiff = canvas.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        print("toast-shot: could not encode"); exit(1)
    }
    try! png.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
    exit(0)
}
