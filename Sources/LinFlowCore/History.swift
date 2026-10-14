import Foundation

public struct HistoryEntry: Codable, Identifiable, Equatable {
    public var id: String
    public let timestamp: Date
    public let raw: String
    public var text: String
    public var model: String
    public let audioSeconds: Double
    public var inferenceSeconds: Double
    /// File name inside History.recordingsDir, when the audio was kept.
    public var audioFile: String?
    /// The text before a transform rewrote it, so the rewrite can be undone.
    public var original: String?
    /// Name of the transform that produced `text`, if one did.
    public var transform: String?
    /// How the take was made, kept with it because app.log is rotated away and these are the
    /// numbers a decision gets made from: which microphone, how long after the key the first
    /// audio arrived, how noisy the room was (AudioIO.snrEstimate), and the app it went to.
    public var inputDevice: String?
    public var firstAudioSeconds: Double?
    public var snrDB: Double?
    public var noiseFloor: Double?
    public var app: String?

    public init(id: String = UUID().uuidString, timestamp: Date, raw: String, text: String, model: String,
                audioSeconds: Double, inferenceSeconds: Double, audioFile: String? = nil,
                original: String? = nil, transform: String? = nil,
                inputDevice: String? = nil, firstAudioSeconds: Double? = nil,
                snrDB: Double? = nil, noiseFloor: Double? = nil, app: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.raw = raw; self.text = text; self.model = model
        self.audioSeconds = audioSeconds; self.inferenceSeconds = inferenceSeconds; self.audioFile = audioFile
        self.original = original; self.transform = transform
        self.inputDevice = inputDevice; self.firstAudioSeconds = firstAudioSeconds
        self.snrDB = snrDB; self.noiseFloor = noiseFloor; self.app = app
    }

    /// Rows written before ids existed get a stable synthetic one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        raw = try c.decodeIfPresent(String.self, forKey: .raw) ?? ""
        text = try c.decode(String.self, forKey: .text)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        audioSeconds = try c.decodeIfPresent(Double.self, forKey: .audioSeconds) ?? 0
        inferenceSeconds = try c.decodeIfPresent(Double.self, forKey: .inferenceSeconds) ?? 0
        audioFile = try c.decodeIfPresent(String.self, forKey: .audioFile)
        original = try c.decodeIfPresent(String.self, forKey: .original)
        transform = try c.decodeIfPresent(String.self, forKey: .transform)
        inputDevice = try c.decodeIfPresent(String.self, forKey: .inputDevice)
        firstAudioSeconds = try c.decodeIfPresent(Double.self, forKey: .firstAudioSeconds)
        snrDB = try c.decodeIfPresent(Double.self, forKey: .snrDB)
        noiseFloor = try c.decodeIfPresent(Double.self, forKey: .noiseFloor)
        app = try c.decodeIfPresent(String.self, forKey: .app)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? HistoryEntry.legacyID(timestamp: timestamp, text: text)
    }

    static func legacyID(timestamp: Date, text: String) -> String {
        var h: UInt64 = 5381
        for b in text.utf8 { h = (h &* 33) &+ UInt64(b) }
        return "legacy-\(Int(timestamp.timeIntervalSince1970 * 1000))-\(h)"
    }

    public var wordCount: Int { text.split { $0.isWhitespace || $0.isNewline }.count }
}

public struct HistoryStats: Equatable {
    public var count = 0
    public var totalWords = 0
    /// Words per minute of speech, over dictations longer than a second.
    public var wordsPerMinute = 0
    /// Consecutive days ending today (or yesterday) with at least one dictation.
    public var streakDays = 0
    public init() {}
}

/// Local-only dictation log (JSON lines) plus one WAV per dictation, so the
/// window can show, replay, copy and re-transcribe anything. Nothing leaves
/// the machine.
public enum History {
    public static let fileURL = ModelCatalog.appSupportDir.appendingPathComponent("history.jsonl")
    public static let recordingsDir = ModelCatalog.appSupportDir.appendingPathComponent("recordings", isDirectory: true)
    public static let didChange = Notification.Name("LinFlow.History.didChange")
    private static let queue = DispatchQueue(label: "linflow.history")

    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    public static func append(_ entry: HistoryEntry) {
        queue.async {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard var data = try? encoder.encode(entry) else { return }
            data.append(0x0A)
            if let h = FileHandle(forUpdatingAtPath: fileURL.path) {
                // A hand-edited file may lack its final newline; never glue two rows together.
                let end = h.seekToEndOfFile()
                if end > 0 {
                    h.seek(toFileOffset: end - 1)
                    if h.readData(ofLength: 1).first != 0x0A { h.seekToEndOfFile(); h.write(Data([0x0A])) }
                }
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: fileURL)
            }
            notifyChange()
        }
    }

    /// Wait for queued writes to hit disk; call before a hard process exit.
    public static func flush() { queue.sync {} }

    /// Oldest first.
    public static func all() -> [HistoryEntry] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let dec = decoder
        var seen = Set<String>()
        // Split on "\n" only: U+2028 and friends inside a transcript are not row breaks.
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> HistoryEntry? in
            guard var e = try? dec.decode(HistoryEntry.self, from: Data(line.utf8)) else { return nil }
            // Legacy rows synthesize ids from timestamp and text; two identical rows must still differ.
            var id = e.id, n = 2
            while seen.contains(id) { id = "\(e.id)-\(n)"; n += 1 }
            e.id = id
            seen.insert(id)
            return e
        }
    }

    /// Newest first.
    public static func recent(_ n: Int = 10) -> [HistoryEntry] { Array(all().suffix(n).reversed()) }

    public static func delete(id: String) {
        queue.async {
            let entries = all()
            if let victim = entries.first(where: { $0.id == id }), let audio = victim.audioFile {
                try? FileManager.default.removeItem(at: recordingsDir.appendingPathComponent(audio))
            }
            writeAll(entries.filter { $0.id != id })
            notifyChange()
        }
    }

    public static func update(_ entry: HistoryEntry) {
        queue.async {
            // Update only: an entry deleted while it was being re-transcribed stays deleted.
            var entries = all()
            guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
            entries[i] = entry
            writeAll(entries)
            notifyChange()
        }
    }

    private static func writeAll(_ entries: [HistoryEntry]) {
        let enc = encoder
        var data = Data()
        for e in entries { if let d = try? enc.encode(e) { data.append(d); data.append(0x0A) } }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func notifyChange() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    // MARK: audio

    public static func audioURL(for entry: HistoryEntry) -> URL? {
        guard let f = entry.audioFile else { return nil }
        let u = recordingsDir.appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Writes the dictation's audio and returns the file name to store on the entry.
    public static func saveRecording(_ samples: [Float], id: String) -> String {
        let name = "\(id).wav"
        queue.async {
            try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
            try? AudioIO.writeWAV(samples, to: recordingsDir.appendingPathComponent(name))
        }
        return name
    }

    /// Removes a recording that never got an entry (empty or failed dictation).
    public static func discardRecording(_ name: String) {
        queue.async { try? FileManager.default.removeItem(at: recordingsDir.appendingPathComponent(name)) }
    }

    /// Drops recordings older than the retention window (entries stay, Play just disappears).
    /// 0 days means keep no audio at all, including what is already on disk.
    public static func pruneRecordings(olderThanDays days: Int) {
        queue.async {
            let cutoff = days > 0 ? Date().addingTimeInterval(-Double(days) * 86_400) : Date.distantFuture
            var entries = all()
            var changed = false
            for i in entries.indices where entries[i].timestamp < cutoff && entries[i].audioFile != nil {
                try? FileManager.default.removeItem(at: recordingsDir.appendingPathComponent(entries[i].audioFile!))
                entries[i].audioFile = nil
                changed = true
            }
            if changed { writeAll(entries); notifyChange() }
            // Files no entry points at (a dictation that came back empty or failed) go too, once
            // they are past the window; anything from the last minute may still be in flight.
            let referenced = Set(entries.compactMap { $0.audioFile })
            let fm = FileManager.default
            let orphanCutoff = min(cutoff, Date().addingTimeInterval(-60))
            for f in (try? fm.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                where f.pathExtension == "wav" && !referenced.contains(f.lastPathComponent) {
                let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if modified < orphanCutoff { try? fm.removeItem(at: f) }
            }
        }
    }

    // MARK: stats

    public static func stats(_ entries: [HistoryEntry], now: Date = Date(), calendar: Calendar = .current) -> HistoryStats {
        var s = HistoryStats()
        s.count = entries.count
        var words = 0.0, minutes = 0.0
        for e in entries {
            s.totalWords += e.wordCount
            if e.audioSeconds > 1 { words += Double(e.wordCount); minutes += e.audioSeconds / 60 }
        }
        s.wordsPerMinute = minutes > 0 ? Int((words / minutes).rounded()) : 0
        let days = Set(entries.map { calendar.startOfDay(for: $0.timestamp) })
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        while days.contains(day) {
            s.streakDays += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return s
    }
}
