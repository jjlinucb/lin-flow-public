import Foundation
import LinFlowCore

extension SelfTest {
    /// The shared dictionary: what each sync sends, what it takes, and what it must never do.
    /// A fake table stands in for Supabase and each "computer" is its own temp folder; nothing here
    /// reads John's dictionary or the real sync.env. The same cases as
    /// windows/LinFlow.Tests/DictionarySyncTests.cs.
    static func dictionary() {
        func term(_ t: String, _ stamp: String = "t0", deleted: Bool = false) -> DictionaryEntry {
            DictionaryEntry(kind: .term, text: t, deleted: deleted, updatedAt: stamp)
        }
        func rule(_ from: String, _ to: String, learned: Bool = false, _ stamp: String = "t0", deleted: Bool = false) -> DictionaryEntry {
            DictionaryEntry(kind: .rule, text: from, target: to, learned: learned, deleted: deleted, updatedAt: stamp)
        }
        func table(_ entries: [DictionaryEntry]) -> [String: DictionaryEntry] {
            Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        }
        func texts(_ entries: [DictionaryEntry]) -> [String] { entries.map { ($0.deleted ? "-" : "") + $0.text }.sorted() }
        func r(_ from: String, _ to: String, _ learned: Bool = false) -> Replacement { Replacement(from: from, to: to, learned: learned) }

        // The first computer to sync fills the table.
        var m = DictionaryMerger.merge(terms: ["Claude", "Jev"], rules: [r("Lynn", "Lin"), r("super base", "Supabase", true)],
                                       snapshot: nil, remote: [:])
        expect(texts(m.upload) == ["Claude", "Jev", "Lynn", "super base"] && m.taken.isEmpty
               && m.terms == ["Claude", "Jev"] && m.rules == [r("Lynn", "Lin"), r("super base", "Supabase", true)],
               "dictionary: a first sync to an empty table sends everything and changes nothing here")
        expect(m.upload.first { $0.text == "super base" }?.learned == true, "dictionary: a learned rule stays learned")

        // The next computer's first sync takes the table's copy where they differ and sends what only it has.
        m = DictionaryMerger.merge(terms: ["Claude", "LAPTOP-02"], rules: [r("Lynn", "Linn")], snapshot: nil,
                                   remote: table([term("Claude"), term("Jev"), rule("Lynn", "Lin"), rule("Dwart", "Duarte", learned: true),
                                                  term("Old", deleted: true)]))
        expect(m.terms == ["Claude", "LAPTOP-02", "Jev"] && m.rules == [r("Lynn", "Lin"), r("Dwart", "Duarte", true)],
               "dictionary: a second computer's first sync takes the table's copy (\(m.terms), \(m.rules))")
        expect(texts(m.upload) == ["LAPTOP-02"] && texts(m.taken) == ["Dwart", "Jev", "Lynn"],
               "dictionary: ... and sends only what the table lacked (\(texts(m.upload)), took \(texts(m.taken)))")

        // Steady state.
        let agreed = table([term("Alpha"), term("Beta"), rule("x", "y")])
        m = DictionaryMerger.merge(terms: ["Alpha", "Beta"], rules: [r("x", "y")], snapshot: agreed, remote: agreed)
        expect(m.upload.isEmpty && m.taken.isEmpty && m.terms == ["Alpha", "Beta"] && m.rules == [r("x", "y")],
               "dictionary: nothing changed anywhere sends nothing")

        // This computer's changes.
        m = DictionaryMerger.merge(terms: ["Alpha", "Gamma"], rules: [r("x", "z")], snapshot: agreed, remote: agreed)
        expect(texts(m.upload) == ["-Beta", "Gamma", "x"] && m.upload.first { $0.text == "x" }?.target == "z" && m.taken.isEmpty,
               "dictionary: an add, a deletion and an edit here are sent (\(texts(m.upload)))")
        m = DictionaryMerger.merge(terms: ["alpha", "Beta"], rules: [r("x", "y")], snapshot: agreed, remote: agreed)
        expect(texts(m.upload) == ["alpha"], "dictionary: a change of case is an edit, not a second entry")

        // Other computers' changes.
        m = DictionaryMerger.merge(terms: ["Alpha", "Beta"], rules: [r("x", "y")], snapshot: agreed,
                                   remote: table([term("Alpha"), term("Beta", "t1", deleted: true), rule("x", "w", "t1"), term("Delta", "t1")]))
        expect(m.terms == ["Alpha", "Delta"] && m.rules == [r("x", "w")] && m.upload.isEmpty && texts(m.taken) == ["-Beta", "Delta", "x"],
               "dictionary: another computer's add, deletion and edit arrive here (\(m.terms), \(m.rules))")

        // Both changed the same entry.
        m = DictionaryMerger.merge(terms: ["Alpha", "Beta"], rules: [r("x", "z")], snapshot: agreed,
                                   remote: table([term("Alpha"), term("Beta"), rule("x", "w", "t1")]))
        expect(m.rules == [r("x", "z")] && texts(m.upload) == ["x"], "dictionary: when both changed a rule, this sync's change is sent and wins")
        m = DictionaryMerger.merge(terms: ["Alpha", "Beta"], rules: [r("x", "w")], snapshot: agreed,
                                   remote: table([term("Alpha"), term("Beta"), rule("x", "w", "t1")]))
        expect(m.upload.isEmpty && m.snapshot["rule|x"]?.updatedAt == "t1", "dictionary: the same change made on both is not sent again")

        // What it must never do.
        m = DictionaryMerger.merge(terms: nil, rules: [r("x", "y")], snapshot: agreed, remote: agreed)
        expect(!m.upload.contains { $0.deleted } && m.terms == ["Alpha", "Beta"],
               "dictionary: a vocab.txt that could not be read deletes nothing anywhere")
        let six = table((1...6).map { rule("w\($0)", "v\($0)") })
        m = DictionaryMerger.merge(terms: [], rules: [], snapshot: six, remote: six)
        expect(m.refusedDeletions == 6 && m.upload.isEmpty && m.rules.count == 6,
               "dictionary: an emptied replacements.txt is refilled from the table, not sent as six deletions")
        m = DictionaryMerger.merge(terms: [], rules: Array((1...5).map { r("w\($0)", "v\($0)") }), snapshot: six, remote: six)
        expect(m.refusedDeletions == 0 && texts(m.upload) == ["-w6"], "dictionary: one deletion among many is sent")
        m = DictionaryMerger.merge(terms: ["Alpha", "Beta"], rules: [r("x", "y")], snapshot: agreed, remote: table([term("Alpha"), rule("x", "y")]))
        expect(texts(m.upload) == ["Beta"], "dictionary: an entry missing from the table is put back")

        // End to end: two computers and one table.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linflow-dict-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = FakeTable()
        final class Computer {
            let dir: URL, sync: DictionarySync
            var vocab: URL { dir.appendingPathComponent("vocab.txt") }
            var rules: URL { dir.appendingPathComponent("replacements.txt") }
            init(_ root: URL, _ name: String, _ server: FakeTable) {
                dir = root.appendingPathComponent(name)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let config = SyncConfig(url: "https://abcdefgh.supabase.co", key: "sb_publishable_test", device: name)
                sync = DictionarySync(transport: server.fake.transport, config: { config }, vocab: dir.appendingPathComponent("vocab.txt"),
                                      replacements: dir.appendingPathComponent("replacements.txt"),
                                      state: dir.appendingPathComponent(DictionarySync.stateFileName),
                                      log: { _ in }, postsNotifications: false)
            }
            func run() { sync.request(); sync.waitUntilIdle() }
            func write(_ url: URL, _ text: String) { try? text.write(to: url, atomically: true, encoding: .utf8) }
            func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        }
        let mac = Computer(root, "Mac", server), win = Computer(root, "LAPTOP-02", server)
        mac.write(mac.vocab, "# Lin Flow glossary: one name or term per line.\nClaude\nJev\n")
        mac.write(mac.rules, "# Lin Flow corrections: what was heard => what you meant, one per line.\nLynn => Lin\nsuper base => Supabase\t# learned\n# work names\nTeams -> teams\n")
        win.write(win.vocab, "# Lin Flow glossary: one name or term per line.\nClaude\nLAPTOP-02\n")
        win.write(win.rules, "")

        mac.run()
        let first = server.fake.requests.filter { $0.httpMethod == "POST" }
        let sent = first.flatMap(SelfTest.rows)
        expect(sent.count == 4 && Set(sent.first?.keys.map { $0 } ?? []) == ["kind", "key", "text", "target", "learned", "deleted", "updated_at", "device"],
               "dictionary: the Mac's first sync sends its 4 entries, in the table's 8 columns")
        expect(first.first?.url?.absoluteString == "https://abcdefgh.supabase.co/rest/v1/dictionary_entries?on_conflict=kind,key"
               && first.first?.value(forHTTPHeaderField: "Prefer") == "resolution=merge-duplicates,return=representation",
               "dictionary: an upsert keyed on kind and key, returning what the table stored")
        expect(FileManager.default.fileExists(atPath: mac.dir.appendingPathComponent(DictionarySync.stateFileName).path),
               "dictionary: the record of what was agreed is written")

        win.run()
        expect(Glossary.parseTerms(win.read(win.vocab)) == ["Claude", "LAPTOP-02", "Jev"]
               && Glossary.parseReplacements(win.read(win.rules)) == [r("Lynn", "Lin"), r("super base", "Supabase", true)],
               "dictionary: the second computer takes the Mac's words and rules (\(win.read(win.vocab)))")

        server.fake.clear()
        mac.run()
        expect(Glossary.parseTerms(mac.read(mac.vocab)) == ["Claude", "Jev", "LAPTOP-02"], "dictionary: the Mac takes the laptop's word on its next sync")
        expect(mac.read(mac.rules).contains("Teams -> teams") && mac.read(mac.rules).contains("# work names"),
               "dictionary: lines replacements.txt could not read survive a sync")
        expect(!server.fake.requests.contains { $0.httpMethod == "POST" }, "dictionary: taking a change sends nothing back")
        server.fake.clear()
        mac.run()
        expect(!server.fake.requests.isEmpty && server.fake.requests.allSatisfy { $0.httpMethod == "GET" },
               "dictionary: a sync with nothing new only reads")

        mac.write(mac.rules, "# Lin Flow corrections: what was heard => what you meant, one per line.\nsuper base => Supabase\t# learned\nDwart => Duarte\n")
        mac.run()
        win.run()
        expect(Glossary.parseReplacements(win.read(win.rules)) == [r("super base", "Supabase", true), r("Dwart", "Duarte")],
               "dictionary: a rule deleted and one added by hand on the Mac reach the laptop (\(win.read(win.rules)))")
        mac.run()
        expect(Glossary.parseReplacements(mac.read(mac.rules)).count == 2, "dictionary: a deletion does not come back")

        server.failPosts = true
        win.write(win.vocab, "# Lin Flow glossary: one name or term per line.\nClaude\nLAPTOP-02\nJev\nKhmer\n")
        let recordBefore = win.read(win.dir.appendingPathComponent(DictionarySync.stateFileName))
        win.run()
        expect(win.read(win.dir.appendingPathComponent(DictionarySync.stateFileName)) == recordBefore,
               "dictionary: a send that fails leaves the record as it was, so the next sync sends it again")
        server.failPosts = false
        win.run()
        mac.run()
        expect(Glossary.parseTerms(mac.read(mac.vocab)).contains("Khmer"), "dictionary: ... and it arrives once the send works")
    }
}

/// A dictionary_entries table in memory, answering reads and upserts as PostgREST would. It stamps
/// each write with its own updated_at, not the one sent, the way Postgres rewrites the format.
final class FakeTable {
    let fake = FakeServer()
    var failPosts = false
    private var rows: [String: [String: Any]] = [:]
    private var clock = 0

    init() {
        fake.respond = { [unowned self] request in
            if request.httpMethod == "POST" {
                if failPosts { return (Data(#"{"message":"down"}"#.utf8), 500) }
                var back: [[String: Any]] = []
                for var row in SelfTest.rows(request) {
                    clock += 1
                    row["updated_at"] = "2026-09-25T19:00:00.\(clock)+00:00"
                    rows["\(row["kind"]!)|\(row["key"]!)"] = row
                    back.append(row)
                }
                return (try? JSONSerialization.data(withJSONObject: back), 201)
            }
            let page = SelfTest.offset(of: request) == 0 ? rows.keys.sorted().map { rows[$0]! } : []
            return (try? JSONSerialization.data(withJSONObject: page), 200)
        }
    }
}
