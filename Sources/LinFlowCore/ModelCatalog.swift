import Foundation

public struct ModelInfo: Equatable {
    /// Short id used in settings/CLI, e.g. "large-v3-turbo-q5_0".
    public let id: String
    public let fileName: String
    public let downloadURL: URL
    public let sizeMB: Int
    public let multilingual: Bool
    /// One-line human description for the menu.
    public let note: String
    public var engine: EngineKind = .whisper

    public var label: String { "\(id)  (\(sizeMB) MB, \(multilingual ? "multilingual" : "English"))" }
}

/// Where models live and how to get them. Ready-made ggml files come from
/// ggerganov's Hugging Face mirror, the same place whisper.cpp's own
/// download script pulls from.
public enum ModelCatalog {
    public static let appSupportDir: URL = {
        // A test points this at a temp folder so it can never read or write the live
        // dictionary, suggestions, history or notes. Without it `LinFlow selftest` read
        // John's real replacements.txt, and on 2026-09-18 it failed -- correctly -- because
        // his dictionary had auto-learned "cloud => Claude", which the check named
        // "cloud is not Claude" is there to catch. A check whose result depends on what he
        // dictated yesterday is not a check. This is the Mac half of PR #5, which fixed the
        // same coupling on Windows (there the tests were appending to the installed app's
        // live log). Read once, so it must be set before anything touches this.
        if let override = ProcessInfo.processInfo.environment["LINFLOW_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lin Flow", isDirectory: true)
    }()
    public static let modelsDir = appSupportDir.appendingPathComponent("models", isDirectory: true)

    private static let hf = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

    public static let known: [ModelInfo] = [
        ModelInfo(id: "parakeet-tdt-0.6b-v3-q8_0", fileName: "ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
                  downloadURL: URL(string: "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q8_0.bin")!,
                  sizeMB: 669, multilingual: false, note: "Default. Top English accuracy and ~10x faster than Whisper turbo.", engine: .parakeet),
        ModelInfo(id: "parakeet-tdt-0.6b-v3-q4_k", fileName: "ggml-parakeet-tdt-0.6b-v3-q4_k.bin",
                  downloadURL: URL(string: "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q4_k.bin")!,
                  sizeMB: 416, multilingual: false, note: "Smaller Parakeet; slightly less accurate.", engine: .parakeet),
        ModelInfo(id: "large-v3-turbo-q5_0", fileName: "ggml-large-v3-turbo-q5_0.bin",
                  downloadURL: URL(string: hf + "ggml-large-v3-turbo-q5_0.bin")!, sizeMB: 574, multilingual: true,
                  note: "Whisper's best speed/accuracy trade-off; use for Khmer and other languages."),
        ModelInfo(id: "large-v3-turbo-q8_0", fileName: "ggml-large-v3-turbo-q8_0.bin",
                  downloadURL: URL(string: hf + "ggml-large-v3-turbo-q8_0.bin")!, sizeMB: 874, multilingual: true,
                  note: "Same model, less quantized. Marginally better, more RAM."),
        ModelInfo(id: "small.en-q8_0", fileName: "ggml-small.en-q8_0.bin",
                  downloadURL: URL(string: hf + "ggml-small.en-q8_0.bin")!, sizeMB: 264, multilingual: false,
                  note: "Fast English-only fallback."),
        ModelInfo(id: "medium-q5_0", fileName: "ggml-medium-q5_0.bin",
                  downloadURL: URL(string: hf + "ggml-medium-q5_0.bin")!, sizeMB: 539, multilingual: true,
                  note: "Older generation; turbo is better and faster."),
        ModelInfo(id: "base.en", fileName: "ggml-base.en.bin",
                  downloadURL: URL(string: hf + "ggml-base.en.bin")!, sizeMB: 148, multilingual: false,
                  note: "Tiny and quick, noticeably less accurate."),
    ]

    public static let defaultModelID = "parakeet-tdt-0.6b-v3-q8_0"

    public static let vadModel = ModelInfo(
        id: "silero-v6.2.0", fileName: "ggml-silero-v6.2.0.bin",
        downloadURL: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin")!,
        sizeMB: 1, multilingual: true, note: "Voice activity detection")

    // MARK: lookup

    public static func info(for id: String) -> ModelInfo? { known.first { $0.id == id } }

    /// Every ggml whisper model file we can find, catalog or not.
    public static func installedModelURLs() -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil) else { return [] }
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("ggml-") && name.hasSuffix(".bin") && !name.contains("silero") && !name.contains("-encoder")
        }
    }

    /// id "large-v3-turbo-q5_0" -> ggml-large-v3-turbo-q5_0.bin; also
    /// accepts a bare file name or an absolute path.
    public static func locate(_ idOrPath: String) -> URL? {
        if idOrPath.hasPrefix("/") || idOrPath.hasPrefix("~") {
            let p = (idOrPath as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
        }
        let fileName = idOrPath.hasPrefix("ggml-") ? idOrPath : "ggml-\(idOrPath)" + (idOrPath.hasSuffix(".bin") ? "" : ".bin")
        let u = modelsDir.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Which model to retry a take on when the first one produced nothing at all.
    ///
    /// Measured 2026-09-20, in NOISE.md: at 0 dB babble Parakeet returns an *empty* transcript
    /// rather than a degraded one, while Whisper degrades instead of failing. So the retry has
    /// to be at a different engine kind - a second Parakeet file would fail the same way - and
    /// the most capable of those installed is preferred, because by the time this runs the
    /// alternative is pasting nothing, and a second of latency is cheap against that.
    ///
    /// Pure, so the selftest can pin it without any model on disk, and so the C# port can be
    /// held to the same cases.
    public static func rescueModelURL(after kind: EngineKind, installed: [URL]) -> URL? {
        let others = installed.filter { EngineFactory.kind(for: $0) != kind }
        guard !others.isEmpty else { return nil }
        let rank = ["large-v3-turbo", "large-v3", "medium", "small", "base", "tiny"]
        func score(_ url: URL) -> Int {
            let name = url.lastPathComponent.lowercased()
            return rank.firstIndex(where: { name.contains($0) }) ?? rank.count
        }
        // min by rank, and by name where two rank the same, so the choice is deterministic.
        return others.min { a, b in
            let (x, y) = (score(a), score(b))
            return x == y ? a.lastPathComponent < b.lastPathComponent : x < y
        }
    }

    public static func idFromURL(_ url: URL) -> String {
        var s = url.lastPathComponent
        if s.hasPrefix("ggml-") { s.removeFirst(5) }
        if s.hasSuffix(".bin") { s.removeLast(4) }
        return s
    }

    public static var vadModelURL: URL? { locate(vadModel.fileName) }

    // MARK: download

    /// Streams a model to models/<file>.part, then renames it into place.
    /// Progress is 0...1 on a background queue.
    @discardableResult
    public static func download(_ info: ModelInfo,
                                progress: @escaping (Double) -> Void,
                                completion: @escaping (Result<URL, Error>) -> Void) -> URLSessionDownloadTask {
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let dest = modelsDir.appendingPathComponent(info.fileName)
        let delegate = DownloadDelegate(dest: dest, progress: progress, completion: completion)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: info.downloadURL)
        delegate.session = session
        task.resume()
        Log.info("downloading \(info.fileName) (\(info.sizeMB) MB)...")
        return task
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let dest: URL
        let progress: (Double) -> Void
        let completion: (Result<URL, Error>) -> Void
        var session: URLSession?
        private var lastReported = -1.0

        init(dest: URL, progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
            self.dest = dest; self.progress = progress; self.completion = completion
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            if p - lastReported >= 0.01 { lastReported = p; progress(p) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
                    throw NSError(domain: "LinFlow.Download", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) fetching \(downloadTask.originalRequest?.url?.absoluteString ?? "?")"])
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
                Log.info("downloaded \(dest.lastPathComponent)")
                completion(.success(dest))
            } catch {
                completion(.failure(error))
            }
            session.finishTasksAndInvalidate()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error {
                Log.error("download failed: \(error.localizedDescription)")
                completion(.failure(error))
                session.finishTasksAndInvalidate()
            }
        }
    }
}
