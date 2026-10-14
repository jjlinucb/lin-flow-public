import Foundation

public enum EngineKind: String {
    case whisper, parakeet

    public var displayName: String {
        switch self {
        case .whisper: return "Whisper"
        case .parakeet: return "Parakeet"
        }
    }
}

/// One loaded speech-to-text model. Both engines come from the same
/// Homebrew whisper.cpp install: libwhisper for OpenAI's Whisper family,
/// libparakeet for NVIDIA's Parakeet TDT (English-leaning, very fast).
public protocol SpeechEngine: AnyObject {
    var kind: EngineKind { get }
    var modelURL: URL { get }
    var isMultilingual: Bool { get }
    var loadSeconds: Double { get }
    /// Whisper honors language / prompt / VAD; Parakeet ignores what it
    /// can't use. Callers pass the same options either way.
    func transcribe(_ samples: [Float], options: TranscriptionOptions) throws -> TranscriptionResult
}

public extension SpeechEngine {
    var modelID: String { ModelCatalog.idFromURL(modelURL) }
    var displayName: String { "\(kind.displayName) · \(modelID)" }
}

/// Decodes audio past `limitSeconds` in pieces cut at its quietest points (AudioIO.splitLong)
/// and joins the text back in order, skipping pieces that are digital silence. Both engines
/// lose words on long clips, each in its own way (see their `transcribe`), so both come here.
/// A 298 s clip came back as 963 words from Whisper turbo and 968 from Parakeet.
func decodeInPieces(_ samples: [Float], limitSeconds: Double, searchFromSeconds: Double,
                    decode: ([Float]) throws -> TranscriptionResult) rethrows -> TranscriptionResult {
    let pieces = AudioIO.splitLong(samples, limitSeconds: limitSeconds, searchFromSeconds: searchFromSeconds)
    guard pieces.count > 1 else { return try decode(samples) }
    var texts: [String] = [], segments: [String] = [], seconds = 0.0
    var detected: String?
    for piece in pieces where AudioIO.peak(piece) > 0.002 {
        let r = try decode(piece)
        if !r.text.isEmpty { texts.append(r.text) }
        segments += r.segments
        seconds += r.inferenceSeconds
        detected = detected ?? r.detectedLanguage
    }
    return TranscriptionResult(text: texts.joined(separator: " "), segments: segments, detectedLanguage: detected,
                               inferenceSeconds: seconds, audioSeconds: Double(samples.count) / AudioIO.sampleRate)
}

public enum EngineFactory {
    public static func kind(for url: URL) -> EngineKind {
        url.lastPathComponent.lowercased().contains("parakeet") ? .parakeet : .whisper
    }

    public static func load(modelURL url: URL) throws -> SpeechEngine {
        switch kind(for: url) {
        case .whisper: return try WhisperEngine(modelPath: url.path)
        case .parakeet: return try ParakeetEngine(modelPath: url.path)
        }
    }
}
