import Foundation
import CWhisper

public enum WhisperError: Error, LocalizedError {
    case modelLoadFailed(String)
    case inferenceFailed(Int32)
    case unknownLanguage(String)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let p): return "Could not load whisper model at \(p)"
        case .inferenceFailed(let rc): return "whisper_full failed (rc=\(rc))"
        case .unknownLanguage(let l): return "Unknown language code '\(l)'. Use a two-letter code such as en, km or zh, or auto."
        }
    }
}

/// Decoding knobs for one dictation. Defaults are tuned for short
/// push-to-talk clips of one speaker, not for subtitling long files.
public struct TranscriptionOptions {
    /// BCP-47-ish two letter code, or "auto" to let the model detect.
    public var language: String = "en"
    /// 1 = greedy (fastest), 5 = beam search (more accurate, a bit slower).
    public var beamSize: Int32 = 5
    /// Silero VAD model path. When set, whisper drops silent stretches
    /// before decoding, which is both faster and the main defense against
    /// the classic "Thank you." hallucination on near-empty audio.
    public var vadModelPath: String? = nil
    /// Comma-separated glossary the decoder is primed with. Whisper then
    /// spells those names the way the prompt does ("Lin Flow", not "Lend Flow").
    public var initialPrompt: String? = nil
    public var threads: Int32 = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))
    /// Retry at higher temperatures when the decoder looks stuck. Costs
    /// latency only when it actually triggers.
    public var temperatureFallback = true
    public init() {}
}

public struct TranscriptionResult {
    public var text: String
    public var segments: [String]
    public var detectedLanguage: String?
    public var inferenceSeconds: Double
    public var audioSeconds: Double
}

/// Thin, thread-safe wrapper over one loaded whisper.cpp context.
public final class WhisperEngine: SpeechEngine {
    public let kind: EngineKind = .whisper
    public let modelPath: String
    public var modelURL: URL { URL(fileURLWithPath: modelPath) }
    public let isMultilingual: Bool
    public private(set) var loadSeconds: Double = 0

    private let ctx: OpaquePointer
    private let queue = DispatchQueue(label: "linflow.whisper")

    // MARK: backends / logging

    private static var backendsLoaded = false
    private static let backendLock = NSLock()

    /// Homebrew's ggml is built with dynamically loaded backends
    /// (Metal / BLAS / CPU live in .so files under ggml's libexec). libwhisper
    /// does NOT load them itself -- whisper-cli does it in main() -- so an app
    /// that skips this ends up with zero compute devices. Idempotent.
    public static func ensureBackendsLoaded() {
        backendLock.lock(); defer { backendLock.unlock() }
        if backendsLoaded { return }
        installLogHandler()
        ggml_backend_load_all()
        backendsLoaded = true
        Log.debug("ggml backends loaded: \(ggml_backend_reg_count()) registries, \(ggml_backend_dev_count()) devices")
    }

    private static func installLogHandler() {
        let cb: ggml_log_callback = { level, text, _ in
            guard let text = text else { return }
            let s = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return }
            switch level {
            case GGML_LOG_LEVEL_ERROR: Log.error("whisper: \(s)")
            case GGML_LOG_LEVEL_WARN: Log.info("whisper: \(s)")
            default: Log.debug("whisper: \(s)")
            }
        }
        whisper_log_set(cb, nil)
        ggml_log_set(cb, nil)
    }

    public static var libraryVersion: String { String(cString: whisper_version()) }

    // MARK: lifecycle

    public init(modelPath: String, useGPU: Bool = true, flashAttention: Bool = true) throws {
        WhisperEngine.ensureBackendsLoaded()
        var cparams = whisper_context_default_params()
        cparams.use_gpu = useGPU
        cparams.flash_attn = flashAttention
        let t0 = Date()
        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw WhisperError.modelLoadFailed(modelPath)
        }
        self.ctx = ctx
        self.modelPath = modelPath
        self.isMultilingual = whisper_is_multilingual(ctx) != 0
        self.loadSeconds = Date().timeIntervalSince(t0)
        Log.info("loaded \(URL(fileURLWithPath: modelPath).lastPathComponent) in \(String(format: "%.2f", loadSeconds))s (multilingual=\(isMultilingual), whisper.cpp \(WhisperEngine.libraryVersion))")
    }

    deinit { whisper_free(ctx) }

    // MARK: inference

    /// Transcribe 16 kHz mono float PCM. Serialized: whisper contexts are
    /// not safe to use from two threads at once.
    public func transcribe(_ samples: [Float], options: TranscriptionOptions = TranscriptionOptions()) throws -> TranscriptionResult {
        try queue.sync {
            // whisper decodes 30 s windows and, with timestamps off, drops whatever straddles
            // a window edge, so long audio is cut at the quietest stretch before the edge.
            try decodeInPieces(samples, limitSeconds: Self.chunkSeconds, searchFromSeconds: 18) { try run($0, options) }
        }
    }

    /// Longest clip decoded in one go; anything longer is split at quiet points.
    static let chunkSeconds = 28.0

    private func run(_ input: [Float], _ options: TranscriptionOptions) throws -> TranscriptionResult {
        // whisper_full refuses input shorter than 1 s ("input is too short").
        // A quick "yes" is well under that, so pad with silence to 1.5 s.
        var samples = input
        let minSamples = Int(1.5 * AudioIO.sampleRate)
        if samples.count < minSamples { samples += [Float](repeating: 0, count: minSamples - samples.count) }

        let useBeam = options.beamSize > 1
        var p = whisper_full_default_params(useBeam ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        let strings = CStringPool()

        p.n_threads = options.threads
        p.no_context = true          // each dictation stands alone
        p.no_timestamps = true       // we only want text; also a small speed win
        p.single_segment = false
        p.print_special = false
        p.print_progress = false
        p.print_realtime = false
        p.print_timestamps = false
        p.suppress_blank = true
        if !options.temperatureFallback { p.temperature_inc = 0 }
        if useBeam { p.beam_search.beam_size = options.beamSize } else { p.greedy.best_of = 1 }

        // ".en" models only know English; whisper.cpp warns and forces it anyway.
        let lang = isMultilingual ? (options.language.isEmpty ? "auto" : options.language) : "en"
        if lang != "auto", whisper_lang_id(lang) < 0 { throw WhisperError.unknownLanguage(lang) }
        p.language = strings.pointer(lang)
        p.detect_language = false

        if let prompt = options.initialPrompt, !prompt.isEmpty {
            p.initial_prompt = strings.pointer(prompt)
        }
        if let vad = options.vadModelPath, FileManager.default.fileExists(atPath: vad) {
            p.vad = true
            p.vad_model_path = strings.pointer(vad)
            var vp = whisper_vad_default_params()
            vp.threshold = 0.5
            vp.min_speech_duration_ms = 200
            vp.min_silence_duration_ms = 100
            vp.max_speech_duration_s = Float.greatestFiniteMagnitude
            vp.speech_pad_ms = 60
            vp.samples_overlap = 0.1
            p.vad_params = vp
        }

        let t0 = Date()
        let rc = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, p, buf.baseAddress, Int32(buf.count))
        }
        let dt = Date().timeIntervalSince(t0)
        withExtendedLifetime(strings) {}
        guard rc == 0 else { throw WhisperError.inferenceFailed(rc) }

        var segments: [String] = []
        let n = whisper_full_n_segments(ctx)
        for i in 0..<n {
            guard let c = whisper_full_get_segment_text(ctx, i) else { continue }
            let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { segments.append(s) }
        }
        var detected: String? = nil
        if isMultilingual {
            let id = whisper_full_lang_id(ctx)
            if id >= 0, let c = whisper_lang_str(id) { detected = String(cString: c) }
        }
        return TranscriptionResult(
            text: segments.joined(separator: " "),
            segments: segments,
            detectedLanguage: detected,
            inferenceSeconds: dt,
            audioSeconds: Double(input.count) / AudioIO.sampleRate
        )
    }
}

/// Owns strdup'd copies of Swift strings for the duration of a C call.
/// `whisper_full_params` stores raw `const char *` fields, so the usual
/// String -> UnsafePointer bridging (valid only for one call expression)
/// would leave dangling pointers behind.
final class CStringPool {
    private var owned: [UnsafeMutablePointer<CChar>] = []
    func pointer(_ s: String) -> UnsafePointer<CChar> {
        let p = strdup(s)!
        owned.append(p)
        return UnsafePointer(p)
    }
    deinit { owned.forEach { free($0) } }
}
