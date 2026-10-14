import Foundation

/// Tiny logger: stdout always, plus an append-only file once `setupFile` runs.
/// Kept deliberately dumb so it works identically from the CLI and the app.
public enum Log {
    public static var verbose = false

    private static let queue = DispatchQueue(label: "linflow.log")
    private static var handle: FileHandle?
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Default log location: ~/Library/Logs/Lin Flow/app.log
    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Lin Flow/app.log")
    }

    public static func setupFile(at url: URL = defaultFileURL) {
        queue.sync {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            rotate(url, past: 2_000_000)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
        }
    }

    /// Past `limit` bytes the log becomes app.log.1, replacing the previous one, and a new log
    /// starts. It used to be deleted outright at 2 MB, taking with it every noise estimate and
    /// timing it held, which are the numbers engine decisions get made from.
    public static func rotate(_ url: URL, past limit: Int) {
        let fm = FileManager.default
        guard let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > limit else { return }
        let previous = url.appendingPathExtension("1")
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: url, to: previous)
    }

    /// Drain pending writes; call before a hard process exit.
    public static func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    public static func info(_ msg: @autoclosure () -> String) { write(msg()) }
    public static func error(_ msg: @autoclosure () -> String) { write("ERROR " + msg()) }
    public static func debug(_ msg: @autoclosure () -> String) { if verbose { write(msg()) } }

    private static func write(_ msg: String) {
        let line = "[lin-flow \(stamp.string(from: Date()))] \(msg)\n"
        queue.async {
            FileHandle.standardError.write(line.data(using: .utf8)!)
            handle?.write(line.data(using: .utf8)!)
        }
    }
}
