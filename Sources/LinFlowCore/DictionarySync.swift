import Foundation

// One dictionary across every computer John dictates on. windows/LinFlow.Core/DictionarySync.cs is
// the same design, and SYNC-PLAN.md has the reasoning.
//
// vocab.txt and replacements.txt stay the files the app reads, and stay hand-editable. What is
// shared is one row per term and per rule in the table `dictionary_entries`, in the same Supabase
// project as the word totals. A deletion is a row marked deleted, so it reaches the computers
// that still have the entry instead of being brought back by them.
//
// Each computer keeps `dictionary-sync.json`: every entry as it last agreed with the table. A
// sync compares three things for each entry: the local files, that record, and the table. What
// differs from the record locally is this computer's change and is sent; what differs in the
// table is another computer's and is taken. When both changed the same entry, this computer's
// is sent and wins, so the last computer to sync a change wins. `updated_at` is only ever
// compared for equality, so the computers' clocks do not have to agree.

/// One term, or one "heard => meant" rule, as the table holds it.
public struct DictionaryEntry: Equatable {
    public enum Kind: String { case term, rule }

    public var kind: Kind
    /// The term, or the rule's left side, as written.
    public var text: String
    /// The rule's right side. Empty for a term.
    public var target: String
    public var learned: Bool
    public var deleted: Bool
    /// As the table wrote it. Empty before it has been sent.
    public var updatedAt: String

    public init(kind: Kind, text: String, target: String = "", learned: Bool = false, deleted: Bool = false, updatedAt: String = "") {
        self.kind = kind
        self.text = text
        self.target = target
        self.learned = learned
        self.deleted = deleted
        self.updatedAt = updatedAt
    }

    public static func term(_ text: String) -> DictionaryEntry { DictionaryEntry(kind: .term, text: text) }
    public static func rule(_ r: Replacement) -> DictionaryEntry {
        DictionaryEntry(kind: .rule, text: r.from, target: r.to, learned: r.learned)
    }

    /// The table's key: a term and a rule's left side are one entry whatever their case, as
    /// `Replacement.id` already has it.
    public var key: String { text.lowercased() }
    public var id: String { kind.rawValue + "|" + key }

    /// Equal apart from when it was written.
    public func sameContent(_ other: DictionaryEntry) -> Bool {
        kind == other.kind && text == other.text && target == other.target
            && learned == other.learned && deleted == other.deleted
    }

    var asReplacement: Replacement { Replacement(from: text, to: target, learned: learned) }
}

public struct DictionaryMerge: Equatable {
    /// vocab.txt's terms and replacements.txt's rules after the sync, in file order, with what was
    /// taken from the table at the end.
    public var terms: [String]
    public var rules: [Replacement]
    /// This computer's changes, deletions as deleted rows. Not yet stamped.
    public var upload: [DictionaryEntry]
    /// Other computers' changes that altered the files here.
    public var taken: [DictionaryEntry]
    /// The agreed state, not counting `upload`: the table's answer to the upload adds those.
    public var snapshot: [String: DictionaryEntry]
    /// Local deletions not sent because too many went at once. See `merge`.
    public var refusedDeletions: Int
}

public enum DictionaryMerger {
    /// More deletions than this in one sync, when they are also most of what this computer had,
    /// look like a file emptied by accident rather than words removed one by one.
    public static let deletionLimit = 5

    /// `snapshot` nil means this computer has never synced with this project: the table's copy
    /// wins wherever the two differ, and whatever only this computer has is sent. The same
    /// happens when a file could not be read, which the caller passes as nil, so an unreadable
    /// file can never send deletions.
    public static func merge(terms: [String]?, rules: [Replacement]?, snapshot: [String: DictionaryEntry]?,
                             remote: [String: DictionaryEntry]) -> DictionaryMerge {
        var local: [String: DictionaryEntry] = [:]
        for t in terms ?? [] where local[DictionaryEntry.term(t).id] == nil { local[DictionaryEntry.term(t).id] = .term(t) }
        for r in rules ?? [] where local[DictionaryEntry.rule(r).id] == nil { local[DictionaryEntry.rule(r).id] = .rule(r) }

        var agreed = (terms == nil || rules == nil) ? nil : snapshot
        var refused = 0
        if let s = agreed {
            // Counted per kind: an emptied vocab.txt must not hide behind a long replacements.txt.
            for kind in [DictionaryEntry.Kind.term, .rule] {
                let live = s.values.filter { $0.kind == kind && !$0.deleted }
                let gone = live.filter { local[$0.id] == nil }.count
                if gone >= deletionLimit && gone * 2 > live.count { refused += gone }
            }
            if refused > 0 { agreed = nil }
        }

        var final: [String: DictionaryEntry] = [:]
        var upload: [DictionaryEntry] = [], taken: [DictionaryEntry] = []
        var snap: [String: DictionaryEntry] = [:]
        let ids = Set(local.keys).union(agreed?.keys ?? snapshot?.keys ?? [:].keys).union(remote.keys)

        for id in ids.sorted() {
            let l = local[id], r = remote[id]
            var result = l
            if let agreed {
                let s = agreed[id]
                let localChanged: Bool
                if let l, let s { localChanged = s.deleted || !l.sameContent(s) } else { localChanged = l != nil || (s.map { !$0.deleted } ?? false) }
                let remoteChanged = r.map { r in s.map { r.updatedAt != $0.updatedAt || !r.sameContent($0) } ?? true } ?? false
                if localChanged {
                    var mine = l ?? s!
                    if l == nil { mine.deleted = true }
                    if let r, r.sameContent(mine) { snap[id] = r } else { upload.append(mine) }
                } else if remoteChanged, let r {
                    result = r.deleted ? nil : r
                    snap[id] = r
                } else if let r {
                    snap[id] = r
                } else if let l {
                    // Gone from the table, most likely by hand in the dashboard: put it back.
                    upload.append(l)
                }
            } else if let r {
                if let l, r.sameContent(l) { snap[id] = r } else { result = r.deleted ? nil : r; snap[id] = r }
            } else if let l {
                upload.append(l)
            }
            if let result { final[id] = result }
            let changedHere = (result == nil) != (l == nil) || (result.map { res in l.map { !res.sameContent($0) } ?? false } ?? false)
            if changedHere, let r { taken.append(r) }
        }

        // The files' own order, so a sync moves nothing; what arrived goes at the end, as a rule
        // learned here would.
        var outTerms: [String] = [], outRules: [Replacement] = []
        var placed = Set<String>()
        for t in terms ?? [] {
            let id = DictionaryEntry.term(t).id
            if let e = final[id], !placed.contains(id) { outTerms.append(e.text); placed.insert(id) }
        }
        for r in rules ?? [] {
            let id = DictionaryEntry.rule(r).id
            if let e = final[id], !placed.contains(id) { outRules.append(e.asReplacement); placed.insert(id) }
        }
        for id in final.keys.sorted() where !placed.contains(id) {
            let e = final[id]!
            if e.kind == .term { outTerms.append(e.text) } else { outRules.append(e.asReplacement) }
        }
        return DictionaryMerge(terms: outTerms, rules: outRules, upload: upload, taken: taken, snapshot: snap, refusedDeletions: refused)
    }
}

/// Runs the merge against the table and the files. One instance runs for the app's life.
///
/// A sync reads the whole table (a few hundred rows at most), merges, sends this computer's
/// changes, and only then writes the files and the record, so a failed send changes nothing here.
/// Syncs run one at a time; one asked for while another waits to start is folded into it.
public final class DictionarySync {
    public typealias Transport = TotalsSync.Transport

    public static let table = "dictionary_entries"
    public static let pageSize = 1000
    public static let batchSize = 500
    /// How often the app syncs with nothing else asking it to, so a word added on another
    /// computer arrives while this one sits unused.
    public static let interval: TimeInterval = 600
    public static let stateFileName = "dictionary-sync.json"
    public static let shared = DictionarySync()

    private let queue = DispatchQueue(label: "linflow.dictionary")
    private let transport: Transport
    private let configOverride: (() -> SyncConfig?)?
    private let vocabURL: URL
    private let replacementsURL: URL
    private let stateURL: URL
    private let log: (String) -> Void
    private let now: () -> Date
    private let postsNotifications: Bool
    private let idle = DispatchGroup()

    // Touched only on `queue`.
    private var waiting = false
    private var running = false
    private var lastProblem: String?

    public init(transport: Transport? = nil, config: (() -> SyncConfig?)? = nil,
                vocab: URL = Glossary.fileURL, replacements: URL = Glossary.replacementsFileURL,
                state: URL = ModelCatalog.appSupportDir.appendingPathComponent(DictionarySync.stateFileName),
                log: ((String) -> Void)? = nil, now: @escaping () -> Date = { Date() },
                postsNotifications: Bool = true) {
        self.transport = transport ?? TotalsSync.urlSessionTransport
        self.configOverride = config
        self.vocabURL = vocab
        self.replacementsURL = replacements
        self.stateURL = state
        self.log = log ?? { Log.info($0) }
        self.now = now
        self.postsNotifications = postsNotifications
    }

    public func request() {
        idle.enter()
        queue.async { [self] in
            if waiting { idle.leave(); return }
            waiting = true
            pump()
        }
    }

    /// Blocks until every sync requested so far has finished. For the selftest.
    @discardableResult
    public func waitUntilIdle(timeout: TimeInterval = 10) -> Bool {
        idle.wait(timeout: .now() + timeout) == .success
    }

    private func pump() {
        guard !running, waiting else { return }
        waiting = false
        running = true
        sync { [self] in
            running = false
            idle.leave()
            pump()
        }
    }

    // MARK: pieces the selftest checks directly

    private static let stampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func upsertRequest(_ config: SyncConfig, entries: [DictionaryEntry], now: Date) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(config.restBase)/\(table)?on_conflict=kind,key")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The rows come back as the table stored them, so the record holds the table's own
        // updated_at and the next sync can tell this write from a later one.
        request.setValue("resolution=merge-duplicates,return=representation", forHTTPHeaderField: "Prefer")
        authorize(&request, config)
        let stamp = stampFormatter.string(from: now)
        let body: [[String: Any]] = entries.map { e -> [String: Any] in
            ["kind": e.kind.rawValue, "key": e.key, "text": e.text, "target": e.target, "learned": e.learned,
             "deleted": e.deleted, "updated_at": stamp, "device": config.device]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    public static func pageRequest(_ config: SyncConfig, offset: Int, limit: Int) -> URLRequest {
        var request = URLRequest(url: URL(string:
            "\(config.restBase)/\(table)?select=kind,text,target,learned,deleted,updated_at&order=kind.asc,key.asc&limit=\(limit)&offset=\(offset)")!)
        request.httpMethod = "GET"
        authorize(&request, config)
        return request
    }

    private static func authorize(_ request: inout URLRequest, _ config: SyncConfig) {
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(config.key, forHTTPHeaderField: "apikey")
        if config.keyIsJWT { request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization") }
    }

    /// The entries in a list of rows, or nil when the answer is not a list. A row that will not
    /// read is skipped rather than failing the rest.
    public static func parseRows(_ data: Data) -> [DictionaryEntry]? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return array.compactMap(entry)
    }

    static func entry(_ o: [String: Any]) -> DictionaryEntry? {
        guard let kind = (o["kind"] as? String).flatMap(DictionaryEntry.Kind.init(rawValue:)),
              let text = o["text"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty,
              let stamp = o["updated_at"] as? String else { return nil }
        return DictionaryEntry(kind: kind, text: text, target: o["target"] as? String ?? "",
                               learned: o["learned"] as? Bool ?? false, deleted: o["deleted"] as? Bool ?? false,
                               updatedAt: stamp)
    }

    /// The record of what this computer last agreed with the table, or nil when there is none
    /// for this project.
    public static func readState(_ url: URL, project: String) -> [String: DictionaryEntry]? {
        guard let data = try? Data(contentsOf: url),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              o["project"] as? String == project, let rows = o["entries"] as? [[String: Any]] else { return nil }
        var out: [String: DictionaryEntry] = [:]
        for e in rows.compactMap(entry) { out[e.id] = e }
        return out
    }

    public static func stateFile(_ entries: [String: DictionaryEntry], project: String) -> Data {
        let rows: [[String: Any]] = entries.keys.sorted().map { id in
            let e = entries[id]!
            return ["kind": e.kind.rawValue, "text": e.text, "target": e.target, "learned": e.learned,
                    "deleted": e.deleted, "updated_at": e.updatedAt]
        }
        return (try? JSONSerialization.data(withJSONObject: ["project": project, "entries": rows],
                                            options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    // MARK: running

    private func currentConfig() -> SyncConfig? {
        if let configOverride { return configOverride() }
        // TotalsSync logs a problem with sync.env; saying it twice adds nothing.
        return SyncConfig.read().config
    }

    private func sync(then done: @escaping () -> Void) {
        guard let config = currentConfig() else { done(); return }
        let vocabText = try? String(contentsOf: vocabURL, encoding: .utf8)
        let rulesText = try? String(contentsOf: replacementsURL, encoding: .utf8)
        let state = DictionarySync.readState(stateURL, project: config.url)
        readPage(config, offset: 0, pages: 0, rows: [:]) { [self] remote, problem in
            guard let remote else { fail("could not read the shared dictionary", problem ?? "no answer"); done(); return }
            // A file that is not there yet reads as nothing. That is safe: nil only ever takes
            // from the table, and an empty list with no record does the same.
            let terms = vocabText.map(Glossary.parseTerms) ?? (FileManager.default.fileExists(atPath: vocabURL.path) ? nil : [])
            let rules = rulesText.map(Glossary.parseReplacements) ?? (FileManager.default.fileExists(atPath: replacementsURL.path) ? nil : [])
            let merge = DictionaryMerger.merge(terms: terms, rules: rules, snapshot: state, remote: remote)
            send(merge.upload[...], config: config, stored: []) { [self] stored, problem in
                if let problem { fail("could not send this computer's dictionary changes", problem); done(); return }
                finish(merge, stored: stored, config: config, read: (vocabText, rulesText), had: (terms, rules))
                done()
            }
        }
    }

    private func finish(_ merge: DictionaryMerge, stored: [DictionaryEntry], config: SyncConfig,
                        read: (String?, String?), had: ([String]?, [Replacement]?)) {
        var snapshot = merge.snapshot
        for e in stored { snapshot[e.id] = e }
        // A file that is there but could not be read is never written over.
        let fm = FileManager.default
        let vocabChanged = had.0.map { merge.terms != $0 } ?? (!fm.fileExists(atPath: vocabURL.path) && !merge.terms.isEmpty)
        let rulesChanged = had.1.map { merge.rules != $0 } ?? (!fm.fileExists(atPath: replacementsURL.path) && !merge.rules.isEmpty)
        if vocabChanged || rulesChanged {
            // The learner or the window may have saved a file while the table answered. Writing
            // now would undo that; the next sync takes it in instead, and loses nothing, since
            // the record is not saved either.
            let vocabNow = try? String(contentsOf: vocabURL, encoding: .utf8)
            let rulesNow = try? String(contentsOf: replacementsURL, encoding: .utf8)
            guard vocabNow == read.0, rulesNow == read.1 else {
                log("dictionary: a file changed while syncing; the next sync takes it in")
                return
            }
            try? FileManager.default.createDirectory(at: vocabURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if vocabChanged { try? Glossary.termsFile(merge.terms).write(to: vocabURL, atomically: true, encoding: .utf8) }
            if rulesChanged {
                try? Glossary.replacementsFile(merge.rules, keeping: read.1 ?? "").write(to: replacementsURL, atomically: true, encoding: .utf8)
            }
            if postsNotifications {
                DispatchQueue.main.async { NotificationCenter.default.post(name: Glossary.didChange, object: nil) }
            }
        }
        try? DictionarySync.stateFile(snapshot, project: config.url).write(to: stateURL, options: .atomic)
        lastProblem = nil
        if merge.refusedDeletions > 0 {
            log("dictionary: \(merge.refusedDeletions) entries went missing here at once, so none was deleted anywhere and the shared copy was taken instead")
        }
        if !merge.upload.isEmpty || !merge.taken.isEmpty {
            log("dictionary: sent \(describe(merge.upload)), took \(describe(merge.taken)) as \(config.device)")
        }
    }

    private func describe(_ entries: [DictionaryEntry]) -> String {
        guard !entries.isEmpty else { return "nothing" }
        let names = entries.prefix(5).map { ($0.deleted ? "-" : "") + $0.text }.joined(separator: ", ")
        return entries.count > 5 ? "\(entries.count) (\(names), ...)" : names
    }

    /// Batch by batch. Returns the rows as the table stored them.
    private func send(_ entries: ArraySlice<DictionaryEntry>, config: SyncConfig, stored: [DictionaryEntry],
                      done: @escaping ([DictionaryEntry], String?) -> Void) {
        guard !entries.isEmpty else { done(stored, nil); return }
        let batch = Array(entries.prefix(DictionarySync.batchSize))
        transport(DictionarySync.upsertRequest(config, entries: batch, now: now())) { [self] data, code, error in
            queue.async { [self] in
                if let problem = TotalsSync.problem(data: data, code: code, error: error) { done(stored, problem); return }
                let back = data.flatMap(DictionarySync.parseRows) ?? []
                send(entries.dropFirst(batch.count), config: config, stored: stored + back, done: done)
            }
        }
    }

    private func readPage(_ config: SyncConfig, offset: Int, pages: Int, rows: [String: DictionaryEntry],
                          done: @escaping ([String: DictionaryEntry]?, String?) -> Void) {
        guard pages < 100 else { done(rows, nil); return }
        transport(DictionarySync.pageRequest(config, offset: offset, limit: DictionarySync.pageSize)) { [self] data, code, error in
            queue.async { [self] in
                if let problem = TotalsSync.problem(data: data, code: code, error: error) { done(nil, problem); return }
                guard let data, let page = DictionarySync.parseRows(data) else {
                    done(nil, "the table did not answer with a list of rows")
                    return
                }
                if page.isEmpty { done(rows, nil); return }
                var rows = rows
                for e in page { rows[e.id] = e }
                readPage(config, offset: offset + page.count, pages: pages + 1, rows: rows, done: done)
            }
        }
    }

    /// Logged once until a sync works again, not on every dictation.
    private func fail(_ what: String, _ reason: String) {
        let line = "dictionary: \(what): \(reason)"
        if line != lastProblem { log(line) }
        lastProblem = line
    }
}
