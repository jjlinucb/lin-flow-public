import Foundation
import SystemConfiguration

// Shared word totals: one number across every computer John dictates on, instead of one per
// computer. windows/LinFlow.Core/SharedTotals.cs is the same design, and SYNC-PLAN.md has the
// reasoning.
//
// What leaves the machine is one row per computer per day: its name, the date and three counts.
// Transcripts, audio, the dictionary and app names never do. Each row is rebuilt from the local
// history.jsonl and sent whole, so a retry or a double send can only write the same numbers
// again, and the other computers' rows come back from the same table.

/// Where the shared totals live and what this computer is called there: sync.env in the data
/// folder, KEY=VALUE lines that scripts/setup-sync.sh writes. The same file and keys on Windows.
public struct SyncConfig: Equatable {
    public let url: String
    public let key: String
    public let device: String

    public init(url: String, key: String, device: String) {
        self.url = url
        self.key = key
        self.device = device
    }

    /// The old anon keys are JWTs and also go in Authorization. The publishable keys that replace
    /// them go in apikey only: Supabase says so, and takes them in Authorization only for migration.
    public var keyIsJWT: Bool { key.hasPrefix("eyJ") }
    public var restBase: String { url + "/rest/v1" }
    /// What "already sent" is remembered against. A new project or a new name starts over.
    public var identity: String { url + "|" + device }

    public static var fileURL: URL { ModelCatalog.appSupportDir.appendingPathComponent("sync.env") }

    /// The name in System Settings > General > Sharing, read locally: Host.current() can stall
    /// on a DNS lookup. Only used when sync.env names no DEVICE, which the setup script always does.
    public static func defaultDevice() -> String {
        guard let name = SCDynamicStoreCopyComputerName(nil, nil) else { return "Mac" }
        return name as String
    }

    /// No config and no problem when there is no file, which is the normal state of a computer
    /// that has not been set up; no config and a reason when the file is there but unusable.
    public static func read(_ url: URL = fileURL, defaultDevice: String? = nil) -> (config: SyncConfig?, problem: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return (nil, "could not read \(url.lastPathComponent)")
        }
        return parse(text, defaultDevice: defaultDevice ?? Self.defaultDevice())
    }

    public static func parse(_ text: String, defaultDevice: String) -> (config: SyncConfig?, problem: String?) {
        var values: [String: String] = [:]
        // Not split(separator: "\n"): "\r\n" is one Character in Swift and would never match.
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            values[line[..<eq].trimmingCharacters(in: .whitespaces).uppercased()] = value
        }

        guard var url = values["SUPABASE_URL"]?.trimmingCharacters(in: .whitespaces), !url.isEmpty,
              let key = values["SUPABASE_KEY"]?.trimmingCharacters(in: .whitespaces), !key.isEmpty else {
            return (nil, "sync.env needs both SUPABASE_URL and SUPABASE_KEY")
        }
        while url.hasSuffix("/") { url.removeLast() }
        // The dashboard shows the project URL; a copy of the API URL with its path is the same place.
        if url.lowercased().hasSuffix("/rest/v1") { url = String(url.dropLast("/rest/v1".count)) }
        guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil else {
            return (nil, "SUPABASE_URL is not an https address: \(url)")
        }
        // A secret key skips every row rule in the table. It must never sit in a file the app reads.
        if key.hasPrefix("sb_secret_") { return (nil, "SUPABASE_KEY is a secret key; use the project's publishable key") }
        var device = values["DEVICE"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if device.isEmpty { device = defaultDevice }
        if device.count > 64 { device = String(device.prefix(64)) }
        return (SyncConfig(url: url, key: key, device: device), nil)
    }
}

/// One computer's dictation totals for one local calendar day. This, and nothing else, is sent.
public struct DayTotal: Equatable {
    public let device: String
    public let day: String
    public let words: Int
    public let dictations: Int
    public let audioSeconds: Double

    public init(device: String, day: String, words: Int, dictations: Int, audioSeconds: Double) {
        self.device = device
        self.day = day
        self.words = words
        self.dictations = dictations
        self.audioSeconds = audioSeconds
    }

    public var isEmpty: Bool { words == 0 && dictations == 0 && audioSeconds == 0 }
}

public struct DeviceTotal: Equatable {
    public let device: String
    public let words: Int
    public let dictations: Int

    public init(device: String, words: Int, dictations: Int) {
        self.device = device
        self.words = words
        self.dictations = dictations
    }
}

/// Every computer's rows added up, with this computer's taken from its own history rather than
/// from the last copy the table sent back, so a dictation made a second ago is already in it.
public struct CombinedTotals: Equatable {
    public let words: Int
    public let dictations: Int
    public let audioSeconds: Double
    public let streakDays: Int
    /// Most words first. A name that only ever sent zeros is not a computer and is left out.
    public let devices: [DeviceTotal]
    public let thisDevice: String

    public var computers: Int { devices.count }
    public var here: DeviceTotal? { devices.first { $0.device == thisDevice } }

    /// "Mac 20,110 · DESK-01 15,002 · LAPTOP-02 6,091"
    public func breakdown() -> String {
        devices.map { "\($0.device) \(DailyTotals.grouped($0.words))" }.joined(separator: " · ")
    }
}

public enum DailyTotals {
    private struct Tally { var words = 0, dictations = 0, audio = 0.0 }

    /// "2026-09-25": the calendar date of `date` in `calendar`'s time zone.
    public static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// This computer's days, oldest first, one row per date with at least one dictation. Words
    /// are HistoryEntry.wordCount, the same count the Dictation tiles show.
    public static func fromHistory(_ entries: [HistoryEntry], device: String, calendar: Calendar = .current) -> [DayTotal] {
        var days: [String: Tally] = [:]
        for e in entries {
            let day = dayString(e.timestamp, calendar: calendar)
            days[day, default: Tally()].words += e.wordCount
            days[day, default: Tally()].dictations += 1
            days[day, default: Tally()].audio += e.audioSeconds
        }
        // Rounded so the same history always makes an equal row: "changed since it was sent" is
        // decided by comparing rows, and a sum of doubles is not worth a resend in its last digit.
        return days.keys.sorted().map { day in
            let t = days[day]!
            return DayTotal(device: device, day: day, words: t.words, dictations: t.dictations,
                            audioSeconds: (t.audio * 100).rounded() / 100)
        }
    }

    /// A plain loop on purpose: the grouping, filtering and sorting written as one chained
    /// expression was more than the type checker would finish (CI, 2026-09-25).
    public static func combine(remote: [DayTotal], local: [DayTotal], device: String, today: String) -> CombinedTotals {
        var rows: [DayTotal] = remote.filter { $0.device != device }
        rows.append(contentsOf: local)
        var words = 0, dictations = 0, audio = 0.0
        var active = Set<String>()
        var perDevice: [String: DeviceTotal] = [:]
        for r in rows {
            words += r.words
            dictations += r.dictations
            audio += r.audioSeconds
            if r.dictations > 0 { active.insert(r.day) }
            let had = perDevice[r.device] ?? DeviceTotal(device: r.device, words: 0, dictations: 0)
            perDevice[r.device] = DeviceTotal(device: r.device, words: had.words + r.words,
                                              dictations: had.dictations + r.dictations)
        }
        let devices: [DeviceTotal] = perDevice.values.filter { $0.dictations > 0 }.sorted(by: mostWordsFirst)
        return CombinedTotals(words: words, dictations: dictations, audioSeconds: (audio * 100).rounded() / 100,
                              streakDays: streak(active, today: today), devices: devices, thisDevice: device)
    }

    private static func mostWordsFirst(_ a: DeviceTotal, _ b: DeviceTotal) -> Bool {
        a.words != b.words ? a.words > b.words : a.device < b.device
    }

    /// Consecutive days with a dictation on any computer, ending today, or yesterday when today
    /// has none yet. HistoryStats.streakDays, counted over every computer.
    public static func streak(_ days: Set<String>, today: String) -> Int {
        var day = today
        if !days.contains(day) {
            guard let before = previousDay(day) else { return 0 }
            day = before
        }
        var streak = 0
        while days.contains(day) {
            streak += 1
            guard let before = previousDay(day) else { break }
            day = before
        }
        return streak
    }

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func previousDay(_ day: String) -> String? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let before = utc.date(byAdding: .day, value: -1, to: date) else { return nil }
        return dayString(before, calendar: utc)
    }

    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    /// 20110 as "20,110".
    public static func grouped(_ n: Int) -> String { groupedFormatter.string(from: NSNumber(value: n)) ?? "\(n)" }
}

/// What the Settings pane says about the shared totals.
public struct SyncStatus: Equatable {
    public var on: Bool
    public var device: String?
    public var lastSync: Date?
    public var error: String?

    public init(on: Bool, device: String?, lastSync: Date?, error: String?) {
        self.on = on
        self.device = device
        self.lastSync = lastSync
        self.error = error
    }

    public static let off = SyncStatus(on: false, device: nil, lastSync: nil, error: nil)
}

/// Sends this computer's changed days and reads everyone's. One instance runs for the app's life.
///
/// "Changed" is decided against what this run has already sent, kept in memory: the first send
/// after a launch is every day in the history, which is also how a new computer backfills, and
/// after that a dictation sends only its own day. A day that vanishes from the history (deleting
/// a dictation) is sent as zeros. A day that is simply absent is never zeroed: an app that
/// launched against an empty or unreadable data folder must not wipe what the table holds.
///
/// Pushes and pulls run one at a time on a private queue. A request made while one of the same
/// kind is waiting to start is folded into it, and a push recomputes from the file as it is when
/// it starts, so a burst of dictations costs one send.
public final class TotalsSync {
    /// One HTTP exchange: the body, the status code (0 when there was no response) and the error.
    public typealias Transport = (URLRequest, @escaping (Data?, Int, Error?) -> Void) -> Void

    public static let table = "daily_totals"
    public static let pageSize = 1000
    /// Rows per upsert. A first send is a few hundred days at most; this keeps each request small.
    public static let batchSize = 500
    /// Posted on the main queue after a push or a pull finishes, whether or not it worked.
    public static let didChange = Notification.Name("LinFlow.TotalsSync.didChange")
    public static let shared = TotalsSync()

    /// Ephemeral: no cache between reads of the table, and no cookies.
    private static let session = URLSession(configuration: .ephemeral)
    public static let urlSessionTransport: Transport = { request, done in
        TotalsSync.session.dataTask(with: request) { data, response, error in
            done(data, (response as? HTTPURLResponse)?.statusCode ?? 0, error)
        }.resume()
    }

    private enum Op { case push, pull }

    private let queue = DispatchQueue(label: "linflow.totals")
    private let transport: Transport
    private let configOverride: (() -> SyncConfig?)?
    private let history: () -> [HistoryEntry]
    private let log: (String) -> Void
    private let now: () -> Date
    private let calendar: Calendar
    private let postsNotifications: Bool
    private let idle = DispatchGroup()
    private let problemLock = NSLock()
    private var lastProblem: String?

    // Touched only on `queue`.
    private var sent: [String: DayTotal] = [:]
    private var sentFor: String?
    private var remote: [DayTotal] = []
    private var remoteFor: String?
    private var status = SyncStatus.off
    private var queued: [Op] = []
    private var running = false

    /// Everything is injectable so the selftest can run the real logic against a fake server,
    /// a fixed clock and a fixed time zone. The app uses the defaults.
    public init(transport: Transport? = nil, config: (() -> SyncConfig?)? = nil,
                history: (() -> [HistoryEntry])? = nil, log: ((String) -> Void)? = nil,
                now: @escaping () -> Date = { Date() }, calendar: Calendar = .current,
                postsNotifications: Bool = true) {
        self.transport = transport ?? TotalsSync.urlSessionTransport
        self.configOverride = config
        self.history = history ?? { History.all() }
        self.log = log ?? { Log.info($0) }
        self.now = now
        self.calendar = calendar
        self.postsNotifications = postsNotifications
    }

    public var currentStatus: SyncStatus { queue.sync { status } }

    public func today() -> String { DailyTotals.dayString(now(), calendar: calendar) }

    /// Every computer's totals, or nil while sync is off or before the first read has come back.
    public func combined(localHistory: [HistoryEntry]) -> CombinedTotals? {
        guard let config = currentConfig() else { return nil }
        let snapshot: [DayTotal]? = queue.sync { remoteFor == config.identity ? remote : nil }
        guard let remote = snapshot else { return nil }
        let local = DailyTotals.fromHistory(localHistory, device: config.device, calendar: calendar)
        return DailyTotals.combine(remote: remote, local: local, device: config.device, today: today())
    }

    public func requestPush() { request(.push) }
    public func requestPull() { request(.pull) }

    /// Blocks until every push and pull requested so far has finished. For the selftest.
    @discardableResult
    public func waitUntilIdle(timeout: TimeInterval = 10) -> Bool {
        idle.wait(timeout: .now() + timeout) == .success
    }

    // MARK: pieces the selftest checks directly

    /// The rows to send: each day whose totals differ from what was sent, and zeros for a day that
    /// was sent this run and has since gone from the history.
    public static func plan(local: [DayTotal], sent: [String: DayTotal]) -> [DayTotal] {
        var rows = local.filter { sent[$0.day] != $0 }
        let present = Set(local.map { $0.day })
        rows += sent.values.filter { !present.contains($0.day) && !$0.isEmpty }
            .sorted { $0.day < $1.day }
            .map { DayTotal(device: $0.device, day: $0.day, words: 0, dictations: 0, audioSeconds: 0) }
        return rows
    }

    private static let stampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func upsertRequest(_ config: SyncConfig, rows: [DayTotal], now: Date) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(config.restBase)/\(table)?on_conflict=device,day")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        authorize(&request, config)
        let stamp = stampFormatter.string(from: now)
        let body: [[String: Any]] = rows.map { r -> [String: Any] in
            ["device": r.device, "day": r.day, "words": r.words, "dictations": r.dictations,
             "audio_seconds": r.audioSeconds, "updated_at": stamp]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    public static func pageRequest(_ config: SyncConfig, offset: Int, limit: Int) -> URLRequest {
        var request = URLRequest(url: URL(string:
            "\(config.restBase)/\(table)?select=device,day,words,dictations,audio_seconds&order=device.asc,day.asc&limit=\(limit)&offset=\(offset)")!)
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

    /// The table's rows, or nil when the answer is not a list. A row that will not read is
    /// skipped rather than failing the rest.
    public static func parseRows(_ data: Data) -> [DayTotal]? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return array.compactMap { o -> DayTotal? in
            guard let device = o["device"] as? String, !device.isEmpty,
                  let day = o["day"] as? String, !day.isEmpty,
                  let words = number(o["words"]), let dictations = number(o["dictations"]),
                  let audio = number(o["audio_seconds"]) else { return nil }
            return DayTotal(device: device, day: day, words: words.intValue, dictations: dictations.intValue,
                            audioSeconds: audio.doubleValue)
        }
    }

    /// A number, zero when the key is missing, nil when it holds something else.
    private static func number(_ value: Any?) -> NSNumber? {
        guard let value else { return NSNumber(value: 0) }
        return value as? NSNumber
    }

    /// Nil when the exchange worked; otherwise one line saying why it did not.
    static func problem(data: Data?, code: Int, error: Error?) -> String? {
        if let error {
            return (error as NSError).code == NSURLErrorTimedOut ? "no answer in 20 seconds" : error.localizedDescription
        }
        guard (200..<300).contains(code) else {
            var body = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if body.count > 200 { body = String(body.prefix(200)) }
            return "HTTP \(code)" + (body.isEmpty ? "" : ": " + body)
        }
        return nil
    }

    // MARK: running

    /// sync.env, read fresh each time so the setup script takes effect with no relaunch. A problem
    /// with the file is logged once, not on every dictation.
    private func currentConfig() -> SyncConfig? {
        if let configOverride { return configOverride() }
        let (config, problem) = SyncConfig.read()
        problemLock.lock()
        defer { problemLock.unlock() }
        if let problem, problem != lastProblem { log("shared totals are off: \(problem)") }
        lastProblem = problem
        return config
    }

    private func request(_ op: Op) {
        idle.enter()
        queue.async { [self] in
            if queued.contains(op) { idle.leave(); return }
            queued.append(op)
            pump()
        }
    }

    private func pump() {
        guard !running, !queued.isEmpty else { return }
        running = true
        let op = queued.removeFirst()
        let finish: () -> Void = { [self] in
            running = false
            if postsNotifications {
                DispatchQueue.main.async { NotificationCenter.default.post(name: TotalsSync.didChange, object: nil) }
            }
            idle.leave()
            pump()
        }
        switch op {
        case .push: push(then: finish)
        case .pull: pull(then: finish)
        }
    }

    private func push(then finish: @escaping () -> Void) {
        guard let config = currentConfig() else { status = .off; finish(); return }
        if sentFor != config.identity { sent = [:]; sentFor = config.identity }
        let local = DailyTotals.fromHistory(history(), device: config.device, calendar: calendar)
        let rows = TotalsSync.plan(local: local, sent: sent)
        guard !rows.isEmpty else {
            // Nothing to send is still news when the file has just appeared: the totals are on.
            if !status.on { status = SyncStatus(on: true, device: config.device, lastSync: nil, error: nil) }
            finish()
            return
        }
        let first = sent.isEmpty
        send(rows[...], config: config) { [self] problem in
            if let problem {
                fail(config, "could not send this computer's totals", problem)
            } else {
                log(first
                    ? "shared totals: sent \(rows.count) day\(rows.count == 1 ? "" : "s") as \(config.device), the first send since Lin Flow started"
                    : "shared totals: sent \(rows.map { $0.day }.joined(separator: ", ")) as \(config.device)")
                status = SyncStatus(on: true, device: config.device, lastSync: now(), error: nil)
            }
            finish()
        }
    }

    /// Batch by batch; each batch is remembered as sent only once the table has taken it.
    private func send(_ rows: ArraySlice<DayTotal>, config: SyncConfig, done: @escaping (String?) -> Void) {
        guard !rows.isEmpty else { done(nil); return }
        let batch = Array(rows.prefix(TotalsSync.batchSize))
        transport(TotalsSync.upsertRequest(config, rows: batch, now: now())) { [self] data, code, error in
            queue.async { [self] in
                if let problem = TotalsSync.problem(data: data, code: code, error: error) { done(problem); return }
                for r in batch {
                    if r.isEmpty { sent.removeValue(forKey: r.day) } else { sent[r.day] = r }
                }
                send(rows.dropFirst(batch.count), config: config, done: done)
            }
        }
    }

    private func pull(then finish: @escaping () -> Void) {
        guard let config = currentConfig() else { status = .off; finish(); return }
        readPage(config: config, offset: 0, pages: 0, rows: [:]) { [self] rows, problem in
            if let rows {
                remote = Array(rows.values)
                remoteFor = config.identity
                status = SyncStatus(on: true, device: config.device, lastSync: now(), error: nil)
            } else {
                fail(config, "could not read the shared totals", problem ?? "no answer")
            }
            finish()
        }
    }

    /// Page after page until one comes back empty. It does not stop at a short page: the
    /// project's "max rows" setting can be lower than pageSize, and stopping early would quietly
    /// drop the rest. A hundred pages is about 90 years of three computers; the cap is for a
    /// server that ignores offset and answers every page with the first one.
    private func readPage(config: SyncConfig, offset: Int, pages: Int, rows: [String: DayTotal],
                          done: @escaping ([String: DayTotal]?, String?) -> Void) {
        guard pages < 100 else { done(rows, nil); return }
        transport(TotalsSync.pageRequest(config, offset: offset, limit: TotalsSync.pageSize)) { [self] data, code, error in
            queue.async { [self] in
                if let problem = TotalsSync.problem(data: data, code: code, error: error) { done(nil, problem); return }
                guard let data, let page = TotalsSync.parseRows(data) else {
                    done(nil, "the table did not answer with a list of rows")
                    return
                }
                if page.isEmpty { done(rows, nil); return }
                // A row written by another computer mid-read can shift a page; the key keeps one copy.
                var rows = rows
                for r in page { rows[r.device + "\n" + r.day] = r }
                readPage(config: config, offset: offset + page.count, pages: pages + 1, rows: rows, done: done)
            }
        }
    }

    private func fail(_ config: SyncConfig, _ what: String, _ reason: String) {
        log("shared totals: \(what): \(reason)")
        status = SyncStatus(on: true, device: config.device, lastSync: status.lastSync, error: reason)
    }
}
