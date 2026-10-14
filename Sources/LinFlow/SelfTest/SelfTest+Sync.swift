import Foundation
import LinFlowCore

extension SelfTest {
    /// Shared word totals: what leaves the Mac, and when. A fake server stands in for Supabase;
    /// nothing here opens a socket or reads the real sync.env. The same cases as
    /// windows/LinFlow.Tests/SharedTotalsTests.cs.
    static func sync() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
        let iso = ISO8601DateFormatter()
        let now = iso.date(from: "2026-09-25T19:00:00Z")!   // noon on the 25th, Pacific
        func take(_ utc: String, _ text: String, _ seconds: Double = 2) -> HistoryEntry {
            HistoryEntry(timestamp: iso.date(from: utc)!, raw: text, text: text, model: "t", audioSeconds: seconds, inferenceSeconds: 0.1)
        }
        let config = SyncConfig(url: "https://abcdefgh.supabase.co", key: "sb_publishable_test", device: "Mac")

        // sync.env
        let parsed = SyncConfig.parse("# written by setup-sync.sh\r\nSUPABASE_URL=https://abcdefgh.supabase.co/\r\nSUPABASE_KEY=\"sb_publishable_x\"\r\nDEVICE= DESK-01 \r\n",
                                      defaultDevice: "fallback")
        expect(parsed.config == SyncConfig(url: "https://abcdefgh.supabase.co", key: "sb_publishable_x", device: "DESK-01") && parsed.problem == nil,
               "sync.env: the three keys, past comments, quotes and CRLF")
        expect(SyncConfig.parse("SUPABASE_URL=https://a.supabase.co\nSUPABASE_KEY=k\n", defaultDevice: "Mac").config?.device == "Mac",
               "sync.env: no DEVICE means the computer's own name")
        expect(SyncConfig.parse("SUPABASE_URL=https://a.supabase.co/rest/v1\nSUPABASE_KEY=k\n", defaultDevice: "d").config?.url == "https://a.supabase.co",
               "sync.env: the API URL with its path is the same place")
        for (text, why) in [("SUPABASE_URL=https://a.supabase.co\n", "needs both"),
                            ("SUPABASE_KEY=k\n", "needs both"),
                            ("SUPABASE_URL=http://a.supabase.co\nSUPABASE_KEY=k\n", "not an https"),
                            ("SUPABASE_URL=https://a.supabase.co\nSUPABASE_KEY=sb_secret_abc\n", "secret key")] {
            let r = SyncConfig.parse(text, defaultDevice: "d")
            expect(r.config == nil && (r.problem ?? "").contains(why), "sync.env: unusable, and says why (\(why))")
        }
        let missing = SyncConfig.read(FileManager.default.temporaryDirectory.appendingPathComponent("linflow-no-sync-\(UUID().uuidString).env"), defaultDevice: "d")
        expect(missing.config == nil && missing.problem == nil, "sync.env: no file is off with nothing to report")
        expect(!config.keyIsJWT && SyncConfig(url: config.url, key: "eyJhbGciOiJIUzI1NiJ9.e30.x", device: "Mac").keyIsJWT,
               "sync.env: only an old anon JWT is a bearer token")

        // counting
        let days = DailyTotals.fromHistory([take("2026-09-25T03:30:00Z", "late one night", 1.5),
                                            take("2026-09-24T16:00:00Z", "morning", 1.25),
                                            take("2026-09-25T17:00:00Z", "the next day")], device: "Mac", calendar: pacific)
        expect(days == [DayTotal(device: "Mac", day: "2026-09-24", words: 4, dictations: 2, audioSeconds: 2.75),
                        DayTotal(device: "Mac", day: "2026-09-25", words: 3, dictations: 1, audioSeconds: 2)],
               "totals: a day is the local date the dictation was made on (\(days))")

        // what is sent
        let request = TotalsSync.upsertRequest(config, rows: DailyTotals.fromHistory([take("2026-09-25T17:00:00Z", "the quarterly numbers are confidential")],
                                                                                    device: "Mac", calendar: pacific), now: now)
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let sentRows = SelfTest.rows(request)
        expect(!body.contains("confidential"), "totals: the payload carries nothing that was said")
        expect(sentRows.count == 1 && Set(sentRows[0].keys) == ["audio_seconds", "day", "device", "dictations", "updated_at", "words"],
               "totals: the payload is the six columns (\(body))")
        expect((sentRows.first?["words"] as? Int) == 5 && (sentRows.first?["updated_at"] as? String) == "2026-09-25T19:00:00Z",
               "totals: words counted, stamped in UTC")
        expect(request.httpMethod == "POST" && request.url?.absoluteString == "https://abcdefgh.supabase.co/rest/v1/daily_totals?on_conflict=device,day",
               "totals: an upsert is a POST keyed on computer and day")
        expect(request.value(forHTTPHeaderField: "Prefer") == "resolution=merge-duplicates,return=minimal", "totals: an upsert merges")
        let page = TotalsSync.pageRequest(config, offset: 0, limit: 1000)
        expect(page.value(forHTTPHeaderField: "apikey") == "sb_publishable_test" && page.value(forHTTPHeaderField: "Authorization") == nil,
               "totals: a publishable key goes in apikey only")
        let legacy = TotalsSync.pageRequest(SyncConfig(url: config.url, key: "eyJx.y.z", device: "Mac"), offset: 0, limit: 1000)
        expect(legacy.value(forHTTPHeaderField: "apikey") == "eyJx.y.z" && legacy.value(forHTTPHeaderField: "Authorization") == "Bearer eyJx.y.z",
               "totals: an old anon key also goes in Authorization")

        // Pushes and pulls, run for real against a fake server. `make` wires one up.
        final class Box { var entries: [HistoryEntry] = []; var config: SyncConfig?; var log: [String] = [] }
        func make(_ box: Box, _ server: FakeServer) -> TotalsSync {
            TotalsSync(transport: server.transport, config: { box.config }, history: { box.entries }, log: { box.log.append($0) },
                       now: { now }, calendar: pacific, postsNotifications: false)
        }

        do {
            let box = Box(), server = FakeServer()
            box.config = config
            box.entries = [take("2026-09-23T17:00:00Z", "one"), take("2026-09-24T17:00:00Z", "one two")]
            let sync = make(box, server)
            sync.requestPush(); sync.waitUntilIdle()
            expect(server.requests.count == 1 && SelfTest.rows(server.requests[0]).count == 2, "totals: the first push sends every day")
            expect(box.log.contains { $0.contains("sent 2 days as Mac") }, "totals: the first push is logged")
            sync.requestPush(); sync.waitUntilIdle()
            expect(server.requests.count == 1, "totals: nothing changed, nothing sent")
            box.entries.append(take("2026-09-25T17:00:00Z", "three words here"))
            sync.requestPush(); sync.waitUntilIdle()
            let last = server.requests.count == 2 ? SelfTest.rows(server.requests[1]) : []
            expect(last.count == 1 && (last[0]["day"] as? String) == "2026-09-25" && (last[0]["words"] as? Int) == 3,
                   "totals: the next push sends only the changed day")
            expect(sync.currentStatus.on && sync.currentStatus.error == nil, "totals: on, with no error, after a send")
        }

        do {
            let box = Box(), server = FakeServer()
            box.config = config
            box.entries = [take("2026-09-24T17:00:00Z", "one two"), take("2026-09-25T17:00:00Z", "three")]
            let sync = make(box, server)
            sync.requestPush(); sync.waitUntilIdle()
            box.entries.removeFirst()
            sync.requestPush(); sync.waitUntilIdle()
            let zero = server.requests.count == 2 ? SelfTest.rows(server.requests[1]) : []
            let zeroDay = zero.first?["day"] as? String
            let zeroWords = zero.first?["words"] as? Int
            let zeroDictations = zero.first?["dictations"] as? Int
            expect(zero.count == 1 && zeroDay == "2026-09-24" && zeroWords == 0 && zeroDictations == 0,
                   "totals: a day whose dictations were all deleted is sent as zeros")
            sync.requestPush(); sync.waitUntilIdle()
            expect(server.requests.count == 2, "totals: and only once")
        }

        do {
            let box = Box(), server = FakeServer()
            box.config = config
            let sync = make(box, server)
            sync.requestPush(); sync.waitUntilIdle()
            expect(server.requests.isEmpty, "totals: an empty history after a launch zeroes nothing")
        }

        do {
            let box = Box(), server = FakeServer()
            box.config = config
            box.entries = [take("2026-09-25T17:00:00Z", "one")]
            server.respond = { _ in (Data(#"{"message":"Invalid API key"}"#.utf8), 401) }
            let sync = make(box, server)
            sync.requestPush(); sync.waitUntilIdle()
            expect((sync.currentStatus.error ?? "").contains("HTTP 401"), "totals: a failed send is in the status")
            expect(box.log.contains { $0.contains("could not send") && $0.contains("Invalid API key") }, "totals: and in the log")
            server.respond = { _ in (nil, 201) }
            sync.requestPush(); sync.waitUntilIdle()
            expect(server.requests.count == 2 && server.requests[0].httpBody == server.requests[1].httpBody,
                   "totals: a failed send is sent again on the next push")
            expect(sync.currentStatus.error == nil, "totals: and the error clears")
        }

        do {
            let box = Box(), server = FakeServer()
            box.config = config
            box.entries = [take("2026-09-25T17:00:00Z", "one")]
            let sync = make(box, server)
            sync.requestPush(); sync.waitUntilIdle()
            box.config = SyncConfig(url: config.url, key: config.key, device: "Laptop")
            sync.requestPush(); sync.waitUntilIdle()
            expect(server.requests.count == 2 && (SelfTest.rows(server.requests[1]).first?["device"] as? String) == "Laptop",
                   "totals: a new name for this computer sends everything again")
        }

        do {
            let box = Box(), server = FakeServer()
            box.entries = [take("2026-09-25T17:00:00Z", "one")]
            let sync = make(box, server)
            sync.requestPush(); sync.requestPull(); sync.waitUntilIdle()
            expect(server.requests.isEmpty && !sync.currentStatus.on && sync.combined(localHistory: []) == nil,
                   "totals: with no sync.env nothing is sent or read")
        }

        // what is read
        do {
            let table: [[String: Any]] = [
                ["device": "DESK-01", "day": "2026-09-24", "words": 10, "dictations": 2, "audio_seconds": 4.5],
                ["device": "DESK-01", "day": "2026-09-25", "words": 20, "dictations": 3, "audio_seconds": 6],
                ["device": "LAPTOP-02", "day": "2026-09-25", "words": 30, "dictations": 4, "audio_seconds": 7.25],
            ]
            let box = Box(), server = FakeServer()
            box.config = config
            // Two rows a page, the way a project whose "max rows" is below pageSize answers.
            server.respond = { request in
                let rows = Array(table.dropFirst(SelfTest.offset(of: request)).prefix(2))
                return (try? JSONSerialization.data(withJSONObject: rows), 200)
            }
            let sync = make(box, server)
            sync.requestPull(); sync.waitUntilIdle()
            let offsets = server.requests.map { SelfTest.offset(of: $0) }
            expect(offsets == [0, 2, 3], "totals: a pull reads page after page until one comes back empty (\(offsets))")
            expect(server.requests.allSatisfy { $0.url!.absoluteString.contains("order=device.asc,day.asc") }, "totals: pages in a fixed order")
            let combined = sync.combined(localHistory: [])
            expect(combined?.words == 60 && combined?.dictations == 9, "totals: every page is counted")
        }

        do {
            let box = Box(), server = FakeServer()
            box.config = config
            server.respond = { _ in
                (Data(#"[{"device":"DESK-01","day":"2026-09-25","words":100,"dictations":10,"audio_seconds":40},{"device":"Mac","day":"2026-09-25","words":1,"dictations":1,"audio_seconds":1},{"device":"Old name","day":"2026-09-20","words":0,"dictations":0,"audio_seconds":0}]"#.utf8), 200)
            }
            let sync = make(box, server)
            sync.requestPull(); sync.waitUntilIdle()
            server.respond = { _ in (Data("[]".utf8), 200) }
            // The table still holds this Mac's older row; the history already has two more words.
            let combined = sync.combined(localHistory: [take("2026-09-25T17:00:00Z", "one two three")])
            let hereWords = combined?.here?.words
            expect(combined?.words == 103 && combined?.computers == 2 && hereWords == 3,
                   "totals: this computer comes from its own history, a zeros-only name is not a computer")
            expect(combined?.breakdown() ?? "", "DESK-01 100 · Mac 3", "totals: breakdown, most words first")
        }

        let streaky = DailyTotals.combine(remote: [DayTotal(device: "Mac", day: "2026-09-23", words: 5, dictations: 1, audioSeconds: 1),
                                                   DayTotal(device: "DESK-01", day: "2026-09-24", words: 5, dictations: 1, audioSeconds: 1),
                                                   DayTotal(device: "Mac", day: "2026-09-21", words: 5, dictations: 1, audioSeconds: 1),
                                                   DayTotal(device: "DESK-01", day: "2026-09-22", words: 0, dictations: 0, audioSeconds: 0)],
                                          local: [DayTotal(device: "LAPTOP-02", day: "2026-09-25", words: 5, dictations: 1, audioSeconds: 1)],
                                          device: "LAPTOP-02", today: "2026-09-25")
        expect(streaky.streakDays == 3, "totals: the streak counts a day dictated on any computer (\(streaky.streakDays))")
        expect(DailyTotals.streak(["2026-09-23", "2026-09-24"], today: "2026-09-25") == 2, "totals: a streak stands before the day's first dictation")
        expect(DailyTotals.streak(["2026-09-23", "2026-09-24"], today: "2026-09-27") == 0, "totals: two days off ends it")
        expect(DailyTotals.streak(["2026-02-28", "2026-03-01"], today: "2026-03-01") == 2, "totals: a streak runs across the end of a month")
        let read = TotalsSync.parseRows(Data(#"[{"device":"Mac","day":"2026-09-25","words":"many"},{"device":"Mac","day":"2026-09-24","words":2,"dictations":1,"audio_seconds":1},{"day":"2026-09-23"}]"#.utf8))
        expect(read == [DayTotal(device: "Mac", day: "2026-09-24", words: 2, dictations: 1, audioSeconds: 1)], "totals: a row that will not read is skipped")
        expect(TotalsSync.parseRows(Data(#"{"message":"no"}"#.utf8)) == nil, "totals: an answer that is not a list is not rows")
    }

    /// The rows in an upsert's body.
    static func rows(_ request: URLRequest) -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [[String: Any]] ?? []
    }

    /// The offset a page request asked for.
    static func offset(of request: URLRequest) -> Int {
        guard let url = request.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let value = items.first(where: { $0.name == "offset" })?.value else { return -1 }
        return Int(value) ?? -1
    }
}

/// Stands in for Supabase: records every request and answers from `respond`, synchronously.
final class FakeServer {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var respond: (URLRequest) -> (Data?, Int) = { _ in (nil, 201) }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func clear() { lock.lock(); recorded = []; lock.unlock() }

    var transport: TotalsSync.Transport {
        return { [self] request, done in
            lock.lock()
            recorded.append(request)
            let answer = respond(request)
            lock.unlock()
            done(answer.0, answer.1, nil)
        }
    }
}
