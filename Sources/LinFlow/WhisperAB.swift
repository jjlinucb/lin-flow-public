import Foundation
import LinFlowCore

/// `LinFlow whisper-ab`: today's Whisper against one change to it, on John's own takes.
///
/// A is the installed large-v3-turbo-q5_0 with today's settings. B is the same settings with a
/// different model file (`--model-b`). The takes are the ones `compare-engines` picks. A is the oracle: a speed-up only counts if B says the same
/// words, so the summary is how often B differs, by how much, and whether it ever loses a run of
/// words, which is the failure a faster encoder is most likely to have. The texts go to
/// `rows.jsonl` in the output folder, which must stay on this Mac.
enum WhisperAB {
    struct Row: Codable {
        var id: String
        var seconds: Double
        var a: String
        var b: String
        var aSeconds: Double
        var bSeconds: Double
        /// Word-level edit distance from A to B, ignoring case and punctuation.
        var distance: Int
        var aWords: Int
        /// The longest run of A's words that B leaves out.
        var longestDrop: Int
    }

    static func run(count: Int, modelB: URL, out: URL) -> Never {
        let id = "large-v3-turbo-q5_0"
        guard let modelA = ModelCatalog.locate(id) else { fputs("\(id) must be installed\n", stderr); exit(1) }
        let picked = EngineComparison.pick(History.all().filter { $0.audioSeconds >= 1.5 && History.audioURL(for: $0) != nil },
                                           count: count, longest: count * 2 / 5)
        guard !picked.isEmpty else { fputs("no saved recordings\n", stderr); exit(1) }
        let options = Settings.shared.transcriptionOptions(glossary: Glossary.load())
        let a: SpeechEngine, b: SpeechEngine
        do { a = try EngineFactory.load(modelURL: modelA); b = try EngineFactory.load(modelURL: modelB) }
        // _exit: A may already be loaded, and a normal exit() trips ggml's Metal teardown assertion.
        catch { fputs("\(error.localizedDescription)\n", stderr); fflush(stdout); Log.flush(); _exit(1) }
        let hush = [Float](repeating: 0, count: Int(AudioIO.sampleRate * 1.5))
        _ = try? a.transcribe(hush, options: options)
        _ = try? b.transcribe(hush, options: options)

        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var rows: [Row] = []
        var unreadable = 0, aFailed = 0, bFailed = 0
        for (i, entry) in picked.enumerated() {
            guard let url = History.audioURL(for: entry), let samples = try? AudioIO.loadSamples(from: url) else { unreadable += 1; continue }
            guard let ra = try? a.transcribe(samples, options: options) else { aFailed += 1; continue }
            // A B failure is a result, not noise: a candidate that errors on a take has failed it.
            guard let rb = try? b.transcribe(samples, options: options) else { bFailed += 1; continue }
            let wa = EngineComparison.words(ra.text), wb = EngineComparison.words(rb.text)
            rows.append(Row(id: entry.id, seconds: ra.audioSeconds, a: ra.text, b: rb.text,
                            aSeconds: ra.inferenceSeconds, bSeconds: rb.inferenceSeconds,
                            distance: PasteWatcher.wordDistance(wa, wb), aWords: wa.count, longestDrop: longestDrop(wa, wb)))
            fputs("\r  \(i + 1)/\(picked.count)", stderr)
        }
        fputs("\n", stderr)
        let enc = JSONEncoder()
        let lines = rows.compactMap { try? enc.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
        try? (lines.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("rows.jsonl"), atomically: true, encoding: .utf8)

        func summary(_ label: String, _ rs: [Row]) {
            guard !rs.isEmpty else { return }
            let ta = rs.map(\.aSeconds).reduce(0, +), tb = rs.map(\.bSeconds).reduce(0, +)
            let words = rs.map(\.aWords).reduce(0, +), dist = rs.map(\.distance).reduce(0, +)
            print(String(format: "  %@: %d takes, %.0fs audio | A %.2fs  B %.2fs  (%.2fx) | identical %d | differ %.1f%% of words | takes dropping 3+ words: %d",
                         label as NSString, rs.count, rs.map(\.seconds).reduce(0, +), ta, tb, ta / max(tb, 0.001),
                         rs.filter { $0.distance == 0 }.count, 100 * Double(dist) / Double(max(words, 1)),
                         rs.filter { $0.longestDrop >= 3 }.count))
        }
        print("A: \(id)  B: \(modelB.lastPathComponent)  beam=\(options.beamSize)")
        if unreadable + aFailed + bFailed > 0 {
            print("  skipped: \(unreadable) unreadable, \(aFailed) where A failed, \(bFailed) where B failed (B failures count against B)")
        }
        summary("all", rows)
        summary("under 10 s", rows.filter { $0.seconds < 10 })
        summary("10 to 28 s", rows.filter { $0.seconds >= 10 && $0.seconds <= 28 })
        summary("over 28 s", rows.filter { $0.seconds > 28 })
        print("rows: \(out.appendingPathComponent("rows.jsonl").path)")
        fflush(stdout); Log.flush()
        _exit(0)   // two models loaded: a normal exit trips ggml's Metal teardown assertion
    }

    /// The longest run of consecutive words of `a` that are not matched in `b`, by LCS alignment.
    static func longestDrop(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty else { return 0 }
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var i = 0, j = 0, run = 0, longest = 0
        while i < a.count {
            if j < b.count, a[i] == b[j] { i += 1; j += 1; run = 0 }
            else if j < b.count, lcs[i][j + 1] >= lcs[i + 1][j] { j += 1 }
            else { i += 1; run += 1; longest = max(longest, run) }
        }
        return longest
    }
}
