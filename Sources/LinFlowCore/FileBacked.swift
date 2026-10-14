import Foundation

/// A value read from a file and read again only when the file changes on disk. Each access
/// costs one stat, so a caller simply asks every time it needs the value: an edit made in
/// any editor, or by the window, applies to the next dictation without anything having to
/// say so. Until this, vocab.txt was read at launch and again only when the menu bar menu
/// closed, so a term added by hand did nothing until someone happened to open the menu.
/// The Windows port has checked the file's timestamp once per dictation from the start.
public final class FileBacked<Value> {
    private let url: URL
    private let load: () -> Value
    private let lock = NSLock()
    private var stamp: Stamp?
    private var value: Value?

    public init(_ url: URL, load: @escaping () -> Value) {
        self.url = url
        self.load = load
    }

    public var current: Value {
        lock.lock(); defer { lock.unlock() }
        let now = Stamp(url)
        if let value, now == stamp { return value }
        stamp = now
        let fresh = load()
        value = fresh
        return fresh
    }

    /// Modification date and size. A save through `write(to:atomically:)` replaces the file,
    /// and a hand edit rewrites it, so either one moves at least one of the two.
    struct Stamp: Equatable {
        let modified: Date?
        let size: Int?
        init(_ url: URL) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            modified = attributes?[.modificationDate] as? Date
            size = attributes?[.size] as? Int
        }
    }
}
