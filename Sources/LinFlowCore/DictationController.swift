import AppKit
import Foundation

public enum DictationState: Equatable {
    case loading(String)            // "Loading large-v3-turbo…"
    case downloading(String, Double) // model id, 0...1
    case idle
    case recording
    case transcribing
    case rewriting                   // a transform is running on the text
    case error(String)

    public var label: String {
        switch self {
        case .loading(let what): return "Loading \(what)…"
        case .downloading(let id, let p): return "Downloading \(id) \(Int(p * 100))%"
        case .idle: return "Lin Flow"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .rewriting: return "Rewriting…"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

public protocol DictationControllerDelegate: AnyObject {
    func dictation(_ controller: DictationController, didChange state: DictationState)
    func dictation(_ controller: DictationController, audioLevel: Float)
    func dictation(_ controller: DictationController, didFinish entry: HistoryEntry)
}

/// The whole pipeline, minus any UI: hotkey -> mic -> engine -> cleanup ->
/// paste. The app delegate owns one of these and draws whatever it reports.
/// Everything the delegate hears arrives on the main thread.
public final class DictationController {
    public weak var delegate: DictationControllerDelegate?
    public let settings: Settings
    public private(set) var state: DictationState = .loading("model") {
        didSet {
            let s = state
            if case .downloading = s {} else { Log.info("state: \(s.label)") }
            DispatchQueue.main.async { self.delegate?.dictation(self, didChange: s) }
        }
    }
    /// Test hook: when LINFLOW_TEST_AUDIO points at a WAV, the microphone is
    /// never touched (no permission prompt) and that file stands in for the
    /// recording. Lets the whole hotkey -> engine -> cleanup path run unattended.
    private let testAudioURL: URL? = ProcessInfo.processInfo.environment["LINFLOW_TEST_AUDIO"].map { URL(fileURLWithPath: $0) }
    public private(set) var engine: SpeechEngine?
    /// vocab.txt, snippets.json and transforms.json as they are on disk right now: read again
    /// whenever one changes, whoever changed it, so nothing has to tell the controller.
    public var glossary: [String] { vocab.current }
    public var snippets: [Snippet] { snippetFile.current }
    public var transforms: [Transform] { transformFile.current }
    private let vocab = FileBacked(Glossary.fileURL, load: Glossary.load)
    private let snippetFile = FileBacked(Snippets.fileURL, load: Snippets.load)
    private let transformFile = FileBacked(Transforms.fileURL, load: Transforms.load)
    /// The app that had focus when the key went down: the one the text is pasted into,
    /// and the one whose transform applies. Only touched on the audio queue.
    private var targetBundleID: String?
    /// Posted on the main thread when a take came back as pure digital silence. userInfo:
    /// "seconds" (Double) and, when it could be read, "device" (String).
    public static let microphoneSilent = Notification.Name("LinFlow.Dictation.microphoneSilent")
    /// Posted on the main thread when the Mac's audio looks wedged (`AudioRepair`): a press
    /// failed with the stuck error twice, or two takes in a row were pure digital silence.
    public static let audioStuck = Notification.Name("LinFlow.Dictation.audioStuck")
    /// Posted on the main thread when the built-in mic is in a loud room (`LoudRoom`).
    /// userInfo: "device" (String).
    public static let loudRoom = Notification.Name("LinFlow.Dictation.loudRoom")
    /// Only touched on the audio queue.
    private var silentStreak = AudioRepair.SilentStreak()
    private var loudRoomWatch = LoudRoom()

    private let recorder = Recorder()
    private let hotkey: HotkeyMonitor
    /// Recorder start/stop live here so a key press is never queued behind
    /// a transcription that's still running.
    private let audioQueue = DispatchQueue(label: "linflow.audio", qos: .userInteractive)
    private let workQueue = DispatchQueue(label: "linflow.work", qos: .userInitiated)
    private var pressed = false
    private var pendingModelID: String?

    /// Ignore accidental taps shorter than this.
    public var minimumClipSeconds = 0.35
    /// Below this peak amplitude the clip is treated as silence.
    public var silencePeak: Float = 0.01

    public init(settings: Settings = .shared) {
        self.settings = settings
        self.hotkey = HotkeyMonitor(hotkey: settings.hotkey)
        hotkey.onPress = { [weak self] in self?.pressBegan() }
        hotkey.onRelease = { [weak self] in self?.pressEnded() }
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            DispatchQueue.main.async { self.delegate?.dictation(self, audioLevel: level) }
        }
    }

    // MARK: lifecycle

    public func start() {
        Glossary.seedIfMissing()
        History.pruneRecordings(olderThanDays: settings.audioRetentionDays)
        Log.info("accessibility trusted: \(HotkeyMonitor.checkAccessibility(prompt: false)), microphone authorized: \(Recorder.microphoneAuthorized)")
        if testAudioURL == nil {
            Recorder.requestMicrophoneAccess { granted in
                Log.info(granted ? "microphone access granted" : "microphone access NOT granted")
            }
        } else {
            Log.info("LINFLOW_TEST_AUDIO set: microphone disabled, using \(testAudioURL!.path)")
        }
        startHotkey()
        loadModel(id: settings.modelID)
    }

    /// Set while the event tap could not be created (no Accessibility grant yet). The model
    /// load must not paint over that error, and we keep retrying until the grant lands.
    private var hotkeyFailed = false

    private func startHotkey(retry: Bool = false) {
        do {
            try hotkey.start()
            if hotkeyFailed {
                hotkeyFailed = false
                if state == .error("no keyboard access") { state = engine == nil ? .loading(settings.modelID) : .idle }
            }
        } catch {
            if !retry { Log.error(error.localizedDescription) }
            hotkeyFailed = true
            if state != .error("no keyboard access") { state = .error("no keyboard access") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.hotkeyFailed else { return }
                self.startHotkey(retry: true)
            }
        }
    }

    public func stop() {
        hotkey.stop()
        audioQueue.sync { _ = recorder.stop() }
        // Free the whisper/parakeet context (and its Metal buffers) while the
        // backend is still fully alive, instead of leaving it to exit-time teardown.
        workQueue.sync { engine = nil }
    }

    public func setHotkey(_ key: Hotkey) {
        settings.hotkey = key
        hotkey.stop()
        hotkey.hotkey = key
        try? hotkey.start()
        Log.info("talk key set to \(key.label)")
    }

    /// Settings' Record button turns the talk key off while it listens, so pressing the new key
    /// neither dictates nor loses Fn to the tap before the window sees it.
    public func suspendHotkey() { hotkey.stop() }
    public func resumeHotkey() { try? hotkey.start() }

    /// An edit made to a dictation in the window, run through the learning setting.
    @discardableResult
    public func learn(wrote: String, now: String) -> CorrectionLearning.Outcome {
        CorrectionLearning.handle(wrote: wrote, now: now, mode: settings.learnCorrections)
    }

    /// Whitespace-only counts as nothing. whisper.cpp and libparakeet both return a string
    /// with a space or a newline in it rather than "" when they hear no words.
    public static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The rule-based pass at the current level, then snippets. No model involved.
    func cleanAndExpand(_ raw: String) -> String {
        var text = raw
        if settings.cleanupLevel != .none {
            var cleaner = TextCleaner(glossary: glossary)
            cleaner.spokenCommands = settings.spokenCommands
            cleaner.numbersAsDigits = settings.numbersAsDigits
            text = cleaner.clean(raw)
        }
        return Snippets.expand(text, snippets: snippets)
    }

    /// Decoder options the notetaker should use, matching dictation.
    public func currentOptions() -> TranscriptionOptions { settings.transcriptionOptions(glossary: glossary) }

    /// Run a saved dictation through the current model again (the "Retry" button).
    public func retranscribe(_ entry: HistoryEntry, completion: @escaping (Result<HistoryEntry, Error>) -> Void) {
        guard let url = History.audioURL(for: entry) else {
            completion(.failure(NSError(domain: "LinFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "The audio for this dictation is gone."]))); return
        }
        workQueue.async { [weak self] in
            guard let self else { return }
            guard let engine = self.engine else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "LinFlow", code: 2, userInfo: [NSLocalizedDescriptionKey: "The speech model is still loading."])))
                }
                return
            }
            do {
                let samples = try AudioIO.loadSamples(from: url)
                let result = try engine.transcribe(samples, options: self.currentOptions())
                var updated = entry
                updated.text = self.cleanAndExpand(result.text)
                updated.original = nil
                updated.transform = nil
                updated.model = engine.modelID
                updated.inferenceSeconds = result.inferenceSeconds
                History.update(updated)
                DispatchQueue.main.async { completion(.success(updated)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Switch models. Downloads first if the file isn't on disk yet.
    public func loadModel(id: String) {
        settings.modelID = id
        pendingModelID = id
        if let url = ModelCatalog.locate(id) {
            load(url: url, id: id)
        } else if let info = ModelCatalog.info(for: id) {
            state = .downloading(id, 0)
            ModelCatalog.download(info, progress: { [weak self] p in
                guard let self, self.pendingModelID == id else { return }
                self.state = .downloading(id, p)
            }, completion: { [weak self] result in
                guard let self, self.pendingModelID == id else { return }
                switch result {
                case .success(let url): self.load(url: url, id: id)
                case .failure(let e): self.state = .error("download failed: \(e.localizedDescription)"); Sound.error.play()
                }
            })
        } else {
            state = .error("unknown model \(id)")
        }
    }

    private func load(url: URL, id: String) {
        state = .loading(id)
        // The VAD model is tiny; fetch it once in the background if missing.
        if settings.useVAD, ModelCatalog.vadModelURL == nil {
            ModelCatalog.download(ModelCatalog.vadModel, progress: { _ in }, completion: { _ in })
        }
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let engine = try EngineFactory.load(modelURL: url)
                // First inference compiles Metal pipelines (~0.5-1 s). Pay it now, not on the
                // first dictation. VAD must be off here or whisper skips the encoder on silence
                // and the warm-up warms nothing.
                var warm = self.settings.transcriptionOptions(glossary: self.glossary)
                warm.vadModelPath = nil
                _ = try? engine.transcribe([Float](repeating: 0, count: Int(AudioIO.sampleRate * 1.5)), options: warm)
                self.engine = engine
                guard self.pendingModelID == id else { return }
                self.state = self.hotkeyFailed ? .error("no keyboard access") : .idle
                Log.info("ready: \(engine.displayName)")
                Sound.ready.play()
            } catch {
                Log.error("model load failed: \(error.localizedDescription)")
                self.state = .error(error.localizedDescription)
                Sound.error.play()
            }
        }
    }

    // MARK: push to talk

    /// Safe from any thread: the hotkey calls it from its own, the pill's button from main.
    public func pressBegan() {
        // Stamped where the key arrived, so the delay to the first audio includes this hop.
        let keyDown = mach_absolute_time()
        audioQueue.async { [self] in
            guard !pressed else { return }
            guard engine != nil, state == .idle || state == .transcribing || state == .rewriting else {
                Sound.error.play()
                return
            }
            pressed = true
            // The previous dictation's watch deliberately keeps running: two dictations into the
            // same box inside 15s is normal, and canceling here meant a fix to the first one could
            // never be learned (2026-09-14 14:54 in the log).
            targetBundleID = Self.frontmostBundleID()
            do {
                if testAudioURL == nil { try startRecorder(since: keyDown) }
                state = .recording
                Sound.recordStart.play()
            } catch {
                pressed = false
                Log.error("recorder: \(error.localizedDescription)")
                let stuck = AudioRepair.isStuck(error)
                if stuck { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.audioStuck, object: self) } }
                state = .error(stuck ? "Mac audio is stuck" : error.localizedDescription)
                Sound.error.play()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    if let self, case .error = self.state, self.engine != nil { self.state = .idle }
                }
            }
        }
    }

    public func pressEnded() {
        audioQueue.async { [self] in
            guard pressed else { return }
            pressed = false
            var samples = recorder.stop()
            Sound.recordStop.play()
            let start = testAudioURL == nil ? recorder.lastStart : nil
            if let url = testAudioURL, let fake = try? AudioIO.loadSamples(from: url) { samples = fake }
            let seconds = Double(samples.count) / AudioIO.sampleRate
            if let start { Log.info(Self.describe(start)) }
            if MicMode.isolating { Log.info(MicMode.summary) }
            let dead = Self.isDeadMicrophone(samples)
            // A tap too short to judge neither adds to the streak nor breaks it.
            let judged = samples.count >= Int(0.5 * AudioIO.sampleRate)
            if testAudioURL == nil, judged, silentStreak.record(dead: dead) {
                Log.info("audio stuck: a second take in a row of pure digital silence")
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.audioStuck, object: self) }
                Sound.error.play()
                state = .idle
                return
            }
            if dead {
                // A fresh engine is built for every take already, so the next press starts clean;
                // what was missing was any sign that this happened at all.
                Log.info(String(format: "dead microphone: %.1fs of pure digital silence from %@", seconds, start?.device ?? "the default input"))
                Sound.error.play()
                var info: [String: Any] = ["seconds": seconds]
                if let device = start?.device { info["device"] = device }
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.microphoneSilent, object: self, userInfo: info) }
                state = .idle
                return
            }
            guard seconds >= minimumClipSeconds, AudioIO.peak(samples) >= silencePeak else {
                Log.info(String(format: "dropped clip (%.2fs, peak %.3f)", seconds, AudioIO.peak(samples)))
                state = .idle
                return
            }
            state = .transcribing
            let target = targetBundleID
            workQueue.async { self.process(samples, target: target, start: start) }
        }
    }

    /// A fresh engine per take already recovers from most device trouble. The stuck error
    /// gets one more try after a short pause before the press is given up, in case the
    /// daemon was only mid-switch.
    private func startRecorder(since keyDown: UInt64) throws {
        do {
            try recorder.start(since: keyDown)
        } catch where AudioRepair.isStuck(error) {
            Log.info("microphone: \(error.localizedDescription), trying once more")
            Thread.sleep(forTimeInterval: 0.3)
            try recorder.start(since: keyDown)
            Log.info("microphone: the second try worked")
        }
    }

    /// The app with focus, read off the main thread: `runningApplications` is documented as
    /// safe from any thread, and `frontmostApplication` is not.
    static func frontmostBundleID() -> String? {
        NSWorkspace.shared.runningApplications.first { $0.isActive }?.bundleIdentifier
    }

    /// "microphone: MacBook Pro Microphone, first audio 0.21s after the key (engine start 0.04s)"
    public static func describe(_ start: Recorder.Start, after event: String = "the key") -> String {
        let first = start.firstAudioSeconds.map { String(format: "first audio %.2fs after %@", $0, event) } ?? "no audio arrived"
        return String(format: "microphone: %@, %@ (engine start %.2fs)", start.device ?? "unknown device", first, start.engineSeconds)
    }

    /// Half a second or more with nothing above -80 dB. No working microphone is that quiet,
    /// even in a silent room: John's quiet-home noise floor is 0.0009, about -60 dB. On 09-15
    /// the input sent pure zeros for eight takes in a row, through a restart of the app, and
    /// each was dropped as silence without a word.
    public static func isDeadMicrophone(_ samples: [Float]) -> Bool {
        samples.count >= Int(0.5 * AudioIO.sampleRate) && AudioIO.peak(samples) < 0.0001
    }

    private func process(_ samples: [Float], target: String?, start: Recorder.Start?) {
        defer { if state == .transcribing || state == .rewriting { state = .idle } }
        guard let engine = engine else { return }
        let id = UUID().uuidString
        let audioFile: String? = settings.audioRetentionDays > 0 ? History.saveRecording(samples, id: id) : nil
        let options = settings.transcriptionOptions(glossary: glossary)
        var result: TranscriptionResult
        do {
            result = try engine.transcribe(samples, options: options)
        } catch {
            Log.error("transcribe failed: \(error.localizedDescription)")
            Sound.error.play()
            if let audioFile { History.discardRecording(audioFile) }
            return
        }
        // A take that produced nothing is retried on the other engine kind before it is given
        // up on. In heavy babble - a cafe, a loud room - Parakeet returns an empty transcript
        // rather than a degraded one (NOISE.md, measured 2026-09-20), and until now the app's
        // whole response was to delete the recording and return in silence: hold the key,
        // speak, nothing pastes, and the audio is gone so it cannot even be retried. Whisper
        // degrades on the same audio instead of failing.
        var modelID = engine.modelID   // the rescue's, when it wrote the text
        if Self.isBlank(result.text) {
            let installed = ModelCatalog.installedModelURLs()
            if let url = ModelCatalog.rescueModelURL(after: engine.kind, installed: installed) {
                Log.info("empty transcript from \(engine.kind.displayName); retrying on \(ModelCatalog.idFromURL(url))")
                // Loaded and released here rather than kept: this is a rare path and the
                // primary engine is still holding its own weights and Metal buffers.
                if let second = try? EngineFactory.load(modelURL: url),
                   let retry = try? second.transcribe(samples, options: options),
                   !Self.isBlank(retry.text) {
                    result = retry
                    modelID = ModelCatalog.idFromURL(url)
                    Log.info(String(format: "rescued by %@: %@", ModelCatalog.idFromURL(url), retry.text))
                }
            }
        }
        let raw = result.text
        var text = cleanAndExpand(raw)
        if Self.looksLikePromptEcho(text, glossary: glossary, peak: AudioIO.peak(samples)) {
            Log.info("dropped prompt echo: \(text)")
            text = ""
        }
        // The noise estimate is logged on every take. Its floor drives the loud-room nudge
        // (`LoudRoom`) and nothing else: no engine switch. Parakeet is
        // measurably worse than Whisper in babble below about 10 dB (NOISE.md), so an automatic
        // switch is worth having - but the estimator cannot yet tell loud babble from someone
        // talking without pausing, and a threshold that makes dictation eight times slower when
        // it misfires has to be set from real recordings in real rooms. These lines are how that
        // data gets collected.
        let noise = AudioIO.snrEstimate(samples)
        Log.info(String(format: "%.1fs audio -> %.2fs %@ | snr~%.0fdB floor %.4f | raw: %@ | out: %@",
                        result.audioSeconds, result.inferenceSeconds, modelID,
                        noise.snrDB, noise.noiseFloor, raw, text))
        if testAudioURL == nil, loudRoomWatch.record(floor: Double(noise.noiseFloor), device: start?.device) {
            Log.info(String(format: "loud room on %@: floor %.4f", start?.device ?? "?", noise.noiseFloor))
            let info: [String: Any] = ["device": start?.device ?? "the Mac's microphone"]
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.loudRoom, object: self, userInfo: info) }
        }
        guard !text.isEmpty else {
            if Self.isBlank(raw) {
                // The engine heard nothing in a clip that passed the duration and peak gates,
                // so there was speech in it. Keep the recording - it is the only evidence, and
                // the Retry button can run it through another model - and make a sound, because
                // silence here is indistinguishable from a broken hotkey.
                Log.info("no transcript for a clip with speech in it; keeping the audio to retry")
                Sound.error.play()
            } else if let audioFile {
                History.discardRecording(audioFile)   // cleanup emptied it; nothing to play back
            }
            return
        }
        // A transform assigned to the target app (or the Medium cleanup level) rewrites the
        // text with the on-device model; the untouched text is kept so the row can undo it.
        var original: String? = nil, transformName: String? = nil
        if let id = settings.transformID(forApp: target), let transform = Transforms.lookup(id, in: transforms) {
            state = .rewriting
            if let rewritten = rewriteBlocking(text, with: transform), rewritten != text {
                original = text
                text = rewritten
                transformName = transform.name
                Log.info("transform \(transform.name) for \(target ?? "?") | out: \(text)")
            }
        }

        let toPaste = settings.trailingSpace && !text.hasSuffix("\n") ? text + " " : text
        if ProcessInfo.processInfo.environment["LINFLOW_NO_PASTE"] != nil {
            Log.info("LINFLOW_NO_PASTE set; not pasting: \(toPaste)")
        } else {
            let mode = settings.learnCorrections
            let pasted = text
            DispatchQueue.main.async {
                TextInjector.paste(toPaste)
                // Then watch that field: a fix typed by hand becomes a dictionary correction.
                guard mode != .off, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
                PasteWatcher.shared.watch(pasted: pasted, in: pid) { wrote, now in
                    // False keeps the field under watch: an edit that taught nothing is very
                    // often a word still being typed, and the real fix lands a moment later.
                    !CorrectionLearning.handle(wrote: wrote, now: now, mode: mode).isEmpty
                }
            }
        }

        func rounded(_ x: Double, _ places: Double) -> Double { (x * places).rounded() / places }
        let entry = HistoryEntry(id: id, timestamp: Date(), raw: raw, text: text, model: modelID,
                                 audioSeconds: result.audioSeconds, inferenceSeconds: result.inferenceSeconds, audioFile: audioFile,
                                 original: original, transform: transformName,
                                 inputDevice: start?.device, firstAudioSeconds: start?.firstAudioSeconds.map { rounded($0, 1000) },
                                 snrDB: noise.snrDB < 99 ? rounded(noise.snrDB, 10) : nil,   // 99 means "could not judge"
                                 noiseFloor: rounded(Double(noise.noiseFloor), 100_000), app: target)
        History.append(entry)
        DispatchQueue.main.async { self.delegate?.dictation(self, didFinish: entry) }
    }

    /// Runs a transform on the work queue and waits for it (the model is async). Nil when
    /// the model is unavailable, declines, fails or takes over 30 s: the text goes out as it was.
    /// A call takes 8 to 13 s on the M1 Pro; `LinFlow transform <name> "<text>"` times one.
    private func rewriteBlocking(_ text: String, with transform: Transform) -> String? {
        let (rewriter, why) = RewriterFactory.best()
        guard let rewriter else { Log.error("transform \(transform.name) skipped: \(why ?? "no rewriter")"); return nil }
        final class Box: @unchecked Sendable { var value: String? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let t0 = Date()
        Task.detached {
            defer { done.signal() }
            do { box.value = try await rewriter.rewrite(text, using: transform) }
            catch { Log.error("transform \(transform.name) failed: \(error.localizedDescription)") }
        }
        guard done.wait(timeout: .now() + 30) == .success else { Log.error("transform \(transform.name) timed out"); return nil }
        Log.info(String(format: "transform %@ took %.1fs", transform.name, Date().timeIntervalSince(t0)))
        return box.value.map { TextCleaner.applyStyle($0) }
    }

    /// Whisper primed with a glossary sometimes recites it back over
    /// near-silent audio. VAD catches almost all of that; this catches the rest.
    public static func looksLikePromptEcho(_ text: String, glossary: [String], peak: Float) -> Bool {
        guard peak < 0.05, !text.isEmpty else { return false }
        let glossaryWords = Set(glossary.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "." }.map(String.init)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        return !words.isEmpty && words.count <= 8 && words.allSatisfy { glossaryWords.contains($0) }
    }
}
