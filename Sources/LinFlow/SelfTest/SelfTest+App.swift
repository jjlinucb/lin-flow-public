import AppKit
import Foundation
import LinFlowCore

extension SelfTest {
    /// The app around the pipeline: history, transforms, where the toast lands.
    static func app() {
        // history stats
        let cal = Calendar.current
        let now = Date()
        let mk = { (daysAgo: Int, text: String, secs: Double) in
            HistoryEntry(timestamp: cal.date(byAdding: .day, value: -daysAgo, to: now)!, raw: text, text: text, model: "t", audioSeconds: secs, inferenceSeconds: 0.1)
        }
        let st = History.stats([mk(0, "one two three four", 2), mk(1, "five six", 1.5), mk(3, "seven", 0.5)], now: now, calendar: cal)
        expect(st.count == 3, "stats count")
        expect(st.totalWords == 7, "stats words (\(st.totalWords))")
        expect(st.streakDays == 2, "stats streak (\(st.streakDays))")
        expect(st.wordsPerMinute == 103, "stats wpm (\(st.wordsPerMinute))")

        // transform routing
        let table = ["com.apple.Terminal": "agent", "com.tinyspeck.slackmacgap": Transforms.none]
        expect(AppSettings.resolveTransform(app: "com.apple.Terminal", table: table, level: .light) == "agent", "transform: app rule")
        expect(AppSettings.resolveTransform(app: "com.tinyspeck.slackmacgap", table: table, level: .medium) == nil, "transform: app rule 'none' beats Medium")
        expect(AppSettings.resolveTransform(app: "com.apple.mail", table: table, level: .medium) == Transforms.clarityID, "transform: Medium is Clarity elsewhere")
        expect(AppSettings.resolveTransform(app: "com.apple.mail", table: table, level: .light) == nil, "transform: Light has no transform")
        expect(AppSettings.resolveTransform(app: nil, table: table, level: .medium) == Transforms.clarityID, "transform: unknown app at Medium")
        expect(Transforms.lookup("Agent Prompt", in: Transforms.defaults)?.id == "agent", "transform: lookup by name")
        expect(Set(Transforms.defaults.map { $0.id }).count == Transforms.defaults.count, "transform: unique built-in ids")
        expect(Transforms.restoringDefaults(Transforms.defaults.filter { $0.id != "email" }).count == Transforms.defaults.count, "transform: restore puts a deleted built-in back")
        let edited = Transforms.defaults.map { t in var e = t; if t.id == "email" { e.instructions = "mine" }; return e }
        expect(Transforms.restoringDefaults(edited).first { $0.id == "email" }?.instructions == "mine", "transform: restore keeps an edited built-in")
        if let data = try? JSONEncoder().encode(HistoryEntry(timestamp: Date(), raw: "r", text: "t", model: "m", audioSeconds: 1, inferenceSeconds: 0.1, original: "before", transform: "Clarity")),
           let back = try? JSONDecoder().decode(HistoryEntry.self, from: data) {
            expect(back.original == "before" && back.transform == "Clarity", "history: transform fields round-trip")
        } else { expect(false, "history: transform fields encode") }
        let measured = HistoryEntry(timestamp: Date(), raw: "r", text: "t", model: "m", audioSeconds: 1, inferenceSeconds: 0.1,
                                    inputDevice: "MacBook Pro Microphone", firstAudioSeconds: 0.183, snrDB: 14.2, noiseFloor: 0.0143, app: "com.google.Chrome")
        if let data = try? JSONEncoder().encode(measured), let back = try? JSONDecoder().decode(HistoryEntry.self, from: data) {
            expect(back.inputDevice == "MacBook Pro Microphone" && back.firstAudioSeconds == 0.183 && back.snrDB == 14.2
                   && back.noiseFloor == 0.0143 && back.app == "com.google.Chrome", "history: how the take was made round-trips")
        } else { expect(false, "history: take fields encode") }
        let isoDecoder = JSONDecoder(); isoDecoder.dateDecodingStrategy = .iso8601
        if let old = try? isoDecoder.decode(HistoryEntry.self, from: Data(#"{"timestamp":"2026-09-10T08:00:00Z","text":"hello"}"#.utf8)) {
            expect(old.original == nil && old.transform == nil && old.text == "hello" && old.inputDevice == nil && old.snrDB == nil,
                   "history: old rows decode without the newer fields")
        } else { expect(false, "history: old row decodes") }
        expect(AppleIntelligenceRewriter.tidy("Here is the rewritten text:\n\n\"Please fix the build.\""), "Please fix the build.", "rewriter tidy: preamble and quotes")
        expect(AppleIntelligenceRewriter.tidy("```\nRun swift build.\n```"), "Run swift build.", "rewriter tidy: fences")
        expect(AppleIntelligenceRewriter.tidy("He said \"go\" and she said \"stay\"."), "He said \"go\" and she said \"stay\".", "rewriter tidy: inner quotes kept")
        expect(AppleIntelligenceRewriter.tidy("Subject: Candidate lists\n\nHi Maria,\n\nWe need the lists by Friday.\n\nBest regards,\n\n[Your Name]"), "Hi Maria,\n\nWe need the lists by Friday.\n\nBest regards,", "rewriter tidy: subject line and placeholder signature dropped")

        // vocab.txt edited by hand applies to the next dictation, and an untouched file is not reread.
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linflow-selftest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("vocab.txt")
            try? "Lin Flow\n".write(to: url, atomically: true, encoding: .utf8)
            var loads = 0
            let file = FileBacked(url) { () -> String in loads += 1; return (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
            _ = file.current; _ = file.current
            expect(loads == 1, "file-backed: an unchanged file is read once")
            try? "Lin Flow\nSuperlinear\n".write(to: url, atomically: true, encoding: .utf8)
            expect(file.current.contains("Superlinear"), "file-backed: a hand edit applies to the next read")
            Thread.sleep(forTimeInterval: 0.01)
            try? "Lin Flow\nSuperlinean\n".write(to: url, atomically: true, encoding: .utf8)
            expect(file.current.contains("Superlinean"), "file-backed: an edit that keeps the size still applies")
            try? FileManager.default.removeItem(at: url)
            expect(file.current == "", "file-backed: a deleted file reads as whatever load makes of it")
        }

        // The log is rotated, not deleted: what it held survives one more round as app.log.1.
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linflow-selftest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let log = dir.appendingPathComponent("app.log"), previous = dir.appendingPathComponent("app.log.1")
            try? String(repeating: "x", count: 100).write(to: log, atomically: true, encoding: .utf8)
            Log.rotate(log, past: 1_000)
            expect(FileManager.default.fileExists(atPath: log.path) && !FileManager.default.fileExists(atPath: previous.path),
                   "log: a small log is left alone")
            Log.rotate(log, past: 50)
            expect(!FileManager.default.fileExists(atPath: log.path) && (try? String(contentsOf: previous, encoding: .utf8))?.count == 100,
                   "log: past the limit it becomes app.log.1")
            try? String(repeating: "y", count: 80).write(to: log, atomically: true, encoding: .utf8)
            Log.rotate(log, past: 50)
            expect((try? String(contentsOf: previous, encoding: .utf8))?.hasPrefix("y") == true, "log: the next rotation replaces app.log.1")
        }

        // A dictation passes through the clipboard marked private, on a pasteboard of its own here.
        do {
            let pb = NSPasteboard(name: NSPasteboard.Name("linflow-selftest-\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            TextInjector.writePrivately("Ask John Lin about it.", to: pb)
            let types = pb.pasteboardItems?.first?.types ?? []
            expect(pb.string(forType: .string) == "Ask John Lin about it.", "paste: the text is on the clipboard")
            expect(TextInjector.privateTypes.allSatisfy { types.contains($0) }, "paste: marked for clipboard managers to skip")
        }

        // Where the pop-up lands. John keeps the pill at the top of his screen, and every
        // toast went 8pt above it -- off the edge, invisible, for weeks. These use his real
        // numbers: a 1512x949 visible frame and hudY 952.
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 949)
        let toast = NSSize(width: 332, height: 67)
        func fits(_ p: NSPoint) -> Bool {
            p.y >= screen.minY && p.y + toast.height <= screen.maxY
                && p.x >= screen.minX && p.x + toast.width <= screen.maxX
        }
        let atTop = NSRect(x: 559, y: 952, width: 200, height: 34)
        let top = ToastPanel.origin(for: toast, above: atTop, in: screen)
        expect(fits(top), "toast: the pill at the top of the screen still leaves it on screen")
        expect(top.y < atTop.minY, "toast: no room above the pill means below it")

        let atBottom = NSRect(x: 559, y: 110, width: 200, height: 34)
        let bottom = ToastPanel.origin(for: toast, above: atBottom, in: screen)
        expect(fits(bottom), "toast: the pill near the bottom keeps it on screen")
        expect(bottom.y > atBottom.maxY, "toast: room above the pill means above it")

        // Dragged hard against either side, the pill must not push it off.
        expect(fits(ToastPanel.origin(for: toast, above: NSRect(x: 0, y: 500, width: 200, height: 34), in: screen)),
               "toast: pill against the left edge")
        expect(fits(ToastPanel.origin(for: toast, above: NSRect(x: 1480, y: 500, width: 200, height: 34), in: screen)),
               "toast: pill against the right edge")
        expect(fits(ToastPanel.origin(for: toast, above: nil, in: screen)), "toast: no pill at all")
    }
}
