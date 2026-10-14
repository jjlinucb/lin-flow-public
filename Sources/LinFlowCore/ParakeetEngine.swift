import Foundation
import CWhisper

/// NVIDIA Parakeet TDT 0.6B through whisper.cpp's libparakeet. Same shape as
/// WhisperEngine so the app can switch between them at runtime. Parakeet is
/// a transducer, not an encoder-decoder with a 30 s window, so it has no
/// prompt, no language switch and no temperature fallback -- and it's fast.
public final class ParakeetEngine: SpeechEngine {
    public let kind: EngineKind = .parakeet
    public let modelURL: URL
    public let isMultilingual: Bool
    public private(set) var loadSeconds: Double = 0

    private let ctx: OpaquePointer
    private let queue = DispatchQueue(label: "linflow.parakeet")

    public init(modelPath: String, useGPU: Bool = true) throws {
        WhisperEngine.ensureBackendsLoaded()
        parakeet_log_set({ level, text, _ in
            guard let text = text else { return }
            let s = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return }
            switch level {
            case GGML_LOG_LEVEL_ERROR: Log.error("parakeet: \(s)")
            case GGML_LOG_LEVEL_WARN: Log.info("parakeet: \(s)")
            default: Log.debug("parakeet: \(s)")
            }
        }, nil)
        var cparams = parakeet_context_default_params()
        cparams.use_gpu = useGPU
        let t0 = Date()
        guard let ctx = parakeet_init_from_file_with_params(modelPath, cparams) else {
            throw WhisperError.modelLoadFailed(modelPath)
        }
        self.ctx = ctx
        self.modelURL = URL(fileURLWithPath: modelPath)
        // v3 auto-detects 25 European languages (no Khmer, no CJK) and has no
        // language switch, so from the app's point of view there's nothing to pick.
        self.isMultilingual = false
        self.loadSeconds = Date().timeIntervalSince(t0)
        Log.info("loaded \(modelURL.lastPathComponent) in \(String(format: "%.2f", loadSeconds))s (parakeet)")
    }

    deinit { parakeet_free(ctx) }

    public func transcribe(_ samples: [Float], options: TranscriptionOptions = TranscriptionOptions()) throws -> TranscriptionResult {
        try queue.sync {
            // libparakeet 1.9.1 drops whole sentences after a pause once a clip passes about
            // 60 s (every probe of 60 s or less came back complete).
            try decodeInPieces(samples, limitSeconds: 45, searchFromSeconds: 30) { try run($0, options) }
        }
    }

    private func run(_ input: [Float], _ options: TranscriptionOptions) throws -> TranscriptionResult {
        var samples = input
        let minSamples = Int(1.0 * AudioIO.sampleRate)
        if samples.count < minSamples { samples += [Float](repeating: 0, count: minSamples - samples.count) }

        var p = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY)
        p.n_threads = min(options.threads, 4)
        p.no_context = true

        let t0 = Date()
        let rc = samples.withUnsafeBufferPointer { buf in
            parakeet_full(ctx, p, buf.baseAddress, Int32(buf.count))
        }
        let dt = Date().timeIntervalSince(t0)
        guard rc == 0 else { throw WhisperError.inferenceFailed(rc) }

        var segments: [String] = []
        for i in 0..<parakeet_full_n_segments(ctx) {
            guard let c = parakeet_full_get_segment_text(ctx, i) else { continue }
            let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { segments.append(s) }
        }
        return TranscriptionResult(text: segments.joined(separator: " "), segments: segments,
                                   detectedLanguage: nil, inferenceSeconds: dt,
                                   audioSeconds: Double(input.count) / AudioIO.sampleRate)
    }
}
