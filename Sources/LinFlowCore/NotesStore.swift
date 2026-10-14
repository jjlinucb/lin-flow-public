import Foundation

public struct MeetingNote: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var endedAt: Date?
    public var durationSeconds: Double
    public var usedMicrophone: Bool
    public var usedSystemAudio: Bool
    public var summaryModel: String?
    /// Set once the transcript was rewritten from the saved audio (see NoteTranscriber).
    public var transcribedFromAudioAt: Date?
    public var transcriptModel: String?
    /// The app did not stop this recording; the next launch closed it from what was on disk.
    public var recovered: Bool?
    /// The audio files Save Audio wrote, so a renamed note can take its files' names along.
    public var audioExports: [AudioExportRecord]?

    public init(id: String = UUID().uuidString, title: String, createdAt: Date = Date()) {
        self.id = id; self.title = title; self.createdAt = createdAt
        endedAt = nil; durationSeconds = 0; usedMicrophone = true; usedSystemAudio = true; summaryModel = nil
        transcribedFromAudioAt = nil; transcriptModel = nil; recovered = nil; audioExports = nil
    }
}

/// A file Save Audio wrote, and the title its name came from.
public struct AudioExportRecord: Codable, Equatable {
    public var path: String
    public var title: String
    public init(path: String, title: String) { self.path = path; self.title = title }
}

public struct TranscriptSegment: Codable, Identifiable, Equatable {
    public var id: String
    /// Seconds from the start of the note.
    public var start: Double
    public var end: Double
    /// "You" (microphone) or "Others" (system audio).
    public var speaker: String
    public var text: String

    public init(id: String = UUID().uuidString, start: Double, end: Double, speaker: String, text: String) {
        self.id = id; self.start = start; self.end = end; self.speaker = speaker; self.text = text
    }

    public var timestampLabel: String {
        let s = Int(start)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// One folder per meeting note under Application Support/Lin Flow/notes/:
/// note.json (metadata), transcript.jsonl (segments as they land, then rewritten from
/// the audio once the meeting ends, the live version kept as transcript-live.jsonl),
/// notes.md (what you typed), summary.md, events.log (gaps, restarts, failures), and the
/// audio as WAV. Plain files on purpose: they open in anything and back up like any
/// other folder.
public enum NotesStore {
    public static let notesDir = ModelCatalog.appSupportDir.appendingPathComponent("notes", isDirectory: true)
    public static let didChange = Notification.Name("LinFlow.Notes.didChange")
    private static let queue = DispatchQueue(label: "linflow.notes")

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    public static func folder(for id: String) -> URL { notesDir.appendingPathComponent(id, isDirectory: true) }
    public static func transcriptURL(_ id: String) -> URL { folder(for: id).appendingPathComponent("transcript.jsonl") }
    public static func notesURL(_ id: String) -> URL { folder(for: id).appendingPathComponent("notes.md") }
    public static func summaryURL(_ id: String) -> URL { folder(for: id).appendingPathComponent("summary.md") }
    public static func audioURL(_ id: String, source: String) -> URL { folder(for: id).appendingPathComponent("audio-\(source).wav") }
    public static func liveTranscriptURL(_ id: String) -> URL { folder(for: id).appendingPathComponent("transcript-live.jsonl") }
    public static func runningNotesURL(_ id: String) -> URL { folder(for: id).appendingPathComponent("running-notes.md") }
    public static func eventsURL(_ id: String) -> URL { folder(for: id).appendingPathComponent("events.log") }

    /// A note's title as a file name. Finder shows a ":" as "/", and "/" separates folders.
    public static func fileName(_ title: String, ext: String) -> String {
        var name = title.replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.hasPrefix(".") { name = "Meeting" + name }
        return name + "." + ext
    }

    /// Gives each exported file the note's current title. A file still named for the title it was
    /// saved under follows. One John renamed or moved himself is his and is let go, and a gone file
    /// is forgotten. One whose new name is taken waits for the next rename.
    public static func followTitle(_ exports: [AudioExportRecord], to title: String) -> [AudioExportRecord] {
        let fm = FileManager.default
        return exports.compactMap { r in
            let url = URL(fileURLWithPath: r.path)
            guard fm.fileExists(atPath: url.path), url.lastPathComponent == fileName(r.title, ext: url.pathExtension) else { return nil }
            let target = url.deletingLastPathComponent().appendingPathComponent(fileName(title, ext: url.pathExtension))
            if target.path == url.path { return AudioExportRecord(path: r.path, title: title) }
            let onlyCase = target.path.lowercased() == url.path.lowercased()   // the disk ignores case
            guard onlyCase || !fm.fileExists(atPath: target.path), (try? fm.moveItem(at: url, to: target)) != nil else { return r }
            return AudioExportRecord(path: target.path, title: title)
        }
    }

    public static func hasAudio(_ id: String) -> Bool {
        ["mic", "system"].contains { FileManager.default.fileExists(atPath: audioURL(id, source: $0).path) }
    }

    /// Newest first.
    public static func list() -> [MeetingNote] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil) else { return [] }
        let dec = decoder
        return dirs.compactMap { dir -> MeetingNote? in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("note.json")) else { return nil }
            return try? dec.decode(MeetingNote.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public static func load(_ id: String) -> MeetingNote? {
        guard let data = try? Data(contentsOf: folder(for: id).appendingPathComponent("note.json")) else { return nil }
        return try? decoder.decode(MeetingNote.self, from: data)
    }

    @discardableResult
    public static func create(title: String) -> MeetingNote {
        let note = MeetingNote(title: title)
        try? FileManager.default.createDirectory(at: folder(for: note.id), withIntermediateDirectories: true)
        save(note)
        return note
    }

    public static func save(_ note: MeetingNote) {
        queue.sync {
            try? FileManager.default.createDirectory(at: folder(for: note.id), withIntermediateDirectories: true)
            if let data = try? encoder.encode(note) {
                try? data.write(to: folder(for: note.id).appendingPathComponent("note.json"), options: .atomic)
            }
        }
        notifyChange()
    }

    /// Moves the note to the Trash instead of erasing it. Deleting is one gesture from
    /// the list now (hover trash, right-click, or the Delete key over a selection), and
    /// a one-gesture delete of a meeting's transcript, notes and audio has to be
    /// recoverable. Falls back to a real delete only where there is no Trash to move to.
    /// Meetings older than this go to the Trash by themselves. John, 2026-10-08: "you can delete
    /// any meetings over 14 days, so that can just be auto delete."
    public static let keepDays = 14

    /// Meetings started more than `keepDays` before `now`, leaving out one still open or busy.
    public static func expired(_ notes: [MeetingNote], now: Date, busy: Set<String>) -> [MeetingNote] {
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        return notes.filter { $0.createdAt < cutoff && $0.endedAt != nil && !busy.contains($0.id) }
    }

    /// Moves expired meetings to the Trash, where they can still be put back. Never deletes outright:
    /// a meeting the Trash refuses stays for the next pass. Returns the ones moved.
    @discardableResult
    public static func trashExpired(now: Date = Date(), busy: Set<String> = []) -> [MeetingNote] {
        var moved: [MeetingNote] = []
        for note in expired(list(), now: now, busy: busy) {
            let ok = queue.sync { (try? FileManager.default.trashItem(at: folder(for: note.id), resultingItemURL: nil)) != nil }
            if ok { moved.append(note) } else { Log.error("notes: could not move \(note.id) to the Trash, kept it") }
        }
        if !moved.isEmpty {
            Log.info("notes: moved \(moved.count) meeting(s) older than \(keepDays) days to the Trash: \(moved.map(\.id).joined(separator: ", "))")
            notifyChange()
        }
        return moved
    }

    public static func delete(_ id: String) {
        queue.sync {
            let url = folder(for: id)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            catch { try? FileManager.default.removeItem(at: url) }
        }
        notifyChange()
    }

    public static func appendSegment(_ segment: TranscriptSegment, to id: String) {
        queue.sync {
            guard var data = try? JSONEncoder().encode(segment) else { return }
            data.append(0x0A)
            appendLine(data, to: transcriptURL(id))
        }
    }

    /// One dated line in the note's events.log: starts and stops, gaps filled with silence,
    /// source restarts, write failures, recoveries. The audit trail for "what happened to
    /// the recording", readable in any text editor.
    public static func appendEvent(_ text: String, to id: String) {
        queue.sync {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            appendLine(Data("\(df.string(from: Date())) \(text)\n".utf8), to: eventsURL(id))
        }
    }

    private static func appendLine(_ data: Data, to url: URL) {
        if let h = FileHandle(forWritingAtPath: url.path) {
            defer { try? h.close() }
            do { try h.seekToEnd(); try h.write(contentsOf: data) } catch { Log.error("notes: appending to \(url.lastPathComponent): \(error.localizedDescription)") }
        } else {
            do { try data.write(to: url) } catch { Log.error("notes: writing \(url.lastPathComponent): \(error.localizedDescription)") }
        }
    }

    /// Replaces the transcript with one made from the saved audio. The first time, the live
    /// transcript is kept next to it as transcript-live.jsonl; nothing is thrown away.
    public static func replaceTranscript(_ segments: [TranscriptSegment], for id: String, model: String) {
        queue.sync {
            let fm = FileManager.default
            let live = liveTranscriptURL(id), main = transcriptURL(id)
            if fm.fileExists(atPath: main.path), !fm.fileExists(atPath: live.path) { try? fm.moveItem(at: main, to: live) }
            let enc = JSONEncoder()
            var data = Data()
            for s in segments { if let d = try? enc.encode(s) { data.append(d); data.append(0x0A) } }
            do { try data.write(to: main, options: .atomic) } catch { Log.error("notes: writing transcript for \(id): \(error.localizedDescription)"); return }
        }
        if var note = load(id) {
            note.transcribedFromAudioAt = Date()
            note.transcriptModel = model
            save(note)
        } else {
            notifyChange()
        }
        appendEvent("transcript rewritten from the audio: \(segments.count) segments (\(model))", to: id)
    }

    /// Closes notes the app never stopped: a crash, a force quit, a dead battery. Repairs the
    /// WAV headers from the file sizes (see WAVWriter), takes the duration from the longest
    /// track or the last transcript line, and stamps an approximate end. A note that was
    /// created but never recorded is left as it is. Call once at launch, before anything records.
    @discardableResult
    public static func recoverUnfinished() -> [MeetingNote] {
        var recovered: [MeetingNote] = []
        for var note in list() where note.endedAt == nil {
            var duration = 0.0, hadAudio = false
            for source in ["mic", "system"] {
                let url = audioURL(note.id, source: source)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                hadAudio = true
                if (try? WAVWriter.repairHeader(at: url)) == true { Log.info("notes: repaired the header of \(url.lastPathComponent) in \(note.id)") }
                duration = max(duration, WAVWriter.duration(at: url) ?? 0)
            }
            let lastLine = transcript(note.id).last?.end ?? 0
            duration = max(duration, lastLine)
            guard hadAudio || lastLine > 0 else { continue }
            note.durationSeconds = duration
            note.endedAt = note.createdAt.addingTimeInterval(duration)
            note.recovered = true
            save(note)
            appendEvent("recovered after an unclean stop with \(Int(duration)) s of audio", to: note.id)
            Log.info("notes: recovered \(note.id) (\(Int(duration)) s) after an unclean stop")
            recovered.append(note)
        }
        return recovered
    }

    public static func transcript(_ id: String) -> [TranscriptSegment] {
        guard let text = try? String(contentsOf: transcriptURL(id), encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { try? dec.decode(TranscriptSegment.self, from: Data($0.utf8)) }
            .sorted { $0.start < $1.start }
    }

    public static func notesText(_ id: String) -> String { (try? String(contentsOf: notesURL(id), encoding: .utf8)) ?? "" }

    /// The bullets written during the meeting (see RunningNotes), appended a pass at a time so
    /// they are on disk the moment they exist.
    public static func runningNotes(_ id: String) -> String { (try? String(contentsOf: runningNotesURL(id), encoding: .utf8)) ?? "" }
    public static func appendRunningNotes(_ markdown: String, to id: String) {
        guard !markdown.isEmpty else { return }
        queue.sync { appendLine(Data(markdown.utf8), to: runningNotesURL(id)) }
    }
    public static func saveNotesText(_ text: String, for id: String) {
        queue.sync { try? text.write(to: notesURL(id), atomically: true, encoding: .utf8) }
    }

    public static func summary(_ id: String) -> String? { try? String(contentsOf: summaryURL(id), encoding: .utf8) }
    public static func saveSummary(_ text: String, for id: String) {
        queue.sync { try? text.write(to: summaryURL(id), atomically: true, encoding: .utf8) }
        notifyChange()
    }

    /// Transcript as readable lines, e.g. "[3:05] You: ..." — what the summarizer and the export use.
    public static func transcriptText(_ segments: [TranscriptSegment], timestamps: Bool = true) -> String {
        segments.map { timestamps ? "[\($0.timestampLabel)] \($0.speaker): \($0.text)" : "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }

    /// Everything about a note as one Markdown document.
    public static func markdown(for note: MeetingNote) -> String {
        let df = DateFormatter(); df.dateStyle = .full; df.timeStyle = .short
        var md = "# \(note.title)\n\n"
        md += "\(df.string(from: note.createdAt))"
        if note.durationSeconds > 0 { md += " · \(Int(note.durationSeconds / 60)) min" }
        md += "\n\n"
        if let summary = summary(note.id), !summary.isEmpty { md += "## Summary\n\n\(summary.trimmingCharacters(in: .whitespacesAndNewlines))\n\n" }
        let notes = notesText(note.id)
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { md += "## My notes\n\n\(notes.trimmingCharacters(in: .whitespacesAndNewlines))\n\n" }
        let running = runningNotes(note.id)
        if !running.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { md += "## Running notes\n\n\(running.trimmingCharacters(in: .whitespacesAndNewlines))\n\n" }
        let segments = transcript(note.id)
        if !segments.isEmpty { md += "## Transcript\n\n\(transcriptText(segments))\n" }
        return md
    }

    private static func notifyChange() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }
}
