import Foundation

/// Asks Claude about a meeting: summaries, recaps and John's own questions mid-call. The
/// transcript goes to Anthropic's API, so it is used only when John has saved a key
/// (`scripts/setup-claude.sh`); without one the app stays on Apple's on-device model.
/// Raw HTTP, since there is no Anthropic SDK for Swift.
public final class ClaudeClient {
    public static let model = "claude-opus-5-5"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// `~/.config/anthropic/lin-flow-key`, or `LINFLOW_CLAUDE_KEY_FILE` for a test.
    public static var keyFile: URL {
        if let p = ProcessInfo.processInfo.environment["LINFLOW_CLAUDE_KEY_FILE"] { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/anthropic/lin-flow-key")
    }

    public static func loadKey() -> String? {
        guard let raw = try? String(contentsOf: keyFile, encoding: .utf8) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    public static var isConfigured: Bool { loadKey() != nil }

    public enum Failure: Error, LocalizedError {
        case noKey
        case http(Int, String)
        case refused
        case empty

        public var errorDescription: String? {
            switch self {
            case .noKey: return "No Claude key is saved. Run scripts/setup-claude.sh once."
            case .http(let code, let message): return "Claude answered \(code): \(message)"
            case .refused: return "Claude declined to answer that."
            case .empty: return "Claude sent back no text."
            }
        }
    }

    private let key: String
    private let session: URLSession

    public init(key: String, session: URLSession = .shared) {
        self.key = key
        self.session = session
    }

    public convenience init?() {
        guard let key = Self.loadKey() else { return nil }
        self.init(key: key)
    }

    /// One request, one answer. Low effort: these are reading questions asked during a call,
    /// where a quick answer matters more than a deep one. `fallbacks: "default"` reruns a
    /// declined request on the model Anthropic picks for it, instead of returning the refusal.
    public static func request(key: String, system: String, user: String, maxTokens: Int = 8000) -> URLRequest {
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.timeoutInterval = 120
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "fallbacks": "default",
            "output_config": ["effort": "low"],
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    /// The answer's text blocks joined. Thinking blocks come back empty and are skipped.
    public static func parse(status: Int, data: Data) throws -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw Failure.http(status, message)
        }
        if json?["stop_reason"] as? String == "refusal" { throw Failure.refused }
        let blocks = json?["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }
        return trimmed
    }

    public func ask(system: String, user: String, maxTokens: Int = 8000) async throws -> String {
        let (data, response) = try await session.data(for: Self.request(key: key, system: system, user: user, maxTokens: maxTokens))
        return try Self.parse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }
}

/// What John can ask about a meeting, while it runs or after. Each question goes as one
/// request carrying the whole transcript so far, his own notes and the conversation before it,
/// so nothing depends on a server-side session.
public enum MeetingQuestions {
    public struct Turn: Codable, Equatable {
        public var question: String
        public var answer: String
        public var askedAt: Date
        public init(question: String, answer: String, askedAt: Date = Date()) {
            self.question = question; self.answer = answer; self.askedAt = askedAt
        }
    }

    /// The buttons above the question box. Each is just a question, so it lands in the
    /// conversation like a typed one.
    public static let quick: [(label: String, question: String)] = [
        ("Summarize so far", "Summarize the meeting so far: the main points, anything decided, and who owes what."),
        ("Last 5 minutes", "What did we talk about in the last 5 minutes?"),
        ("What should I ask?", "What are the best questions I could ask right now, given where the conversation is?"),
    ]

    public static let system = """
    You help John during and after his meetings. You get the transcript so far, any notes he \
    typed, and his question. "You" in the transcript is John's microphone and "Others" is \
    everyone else on the call, so names come only from what people say. The transcript is \
    machine speech recognition: words can be misheard, so read through obvious errors and say \
    so when something important is unclear rather than guessing. Answer from the transcript \
    only. Be brief and concrete: he is often reading this while the call goes on.
    """

    public static func prompt(title: String, transcript: String, notes: String, earlier: [Turn], question: String) -> String {
        var parts = ["Meeting: \(title)", "Transcript so far:\n\(transcript.isEmpty ? "(nothing yet)" : transcript)"]
        let typed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append("John's notes:\n\(typed)") }
        if !earlier.isEmpty {
            parts.append("Earlier in this conversation:\n" + earlier.map { "John: \($0.question)\nYou: \($0.answer)" }.joined(separator: "\n\n"))
        }
        parts.append("John asks: \(question)")
        return parts.joined(separator: "\n\n")
    }

    public static func fileURL(for noteID: String) -> URL {
        NotesStore.folder(for: noteID).appendingPathComponent("questions.json")
    }

    public static func load(_ noteID: String) -> [Turn] {
        guard let data = try? Data(contentsOf: fileURL(for: noteID)) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Turn].self, from: data)) ?? []
    }

    public static func save(_ turns: [Turn], for noteID: String) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(turns) else { return }
        try? data.write(to: fileURL(for: noteID), options: .atomic)
    }
}

/// Summaries and recaps from Claude, in the same shape the on-device model writes, so the
/// window and the saved `summary.md` do not care which one wrote them. The whole meeting fits
/// in one request, where the on-device model has to take it in pieces and merge them.
/// Running notes stay on the device: they run every minute or so and cost nothing there.
public final class ClaudeSummarizer: Summarizer {
    public let name = "Claude (\(ClaudeClient.model))"
    private let client: ClaudeClient

    public init(client: ClaudeClient) { self.client = client }

    static let meetingInstructions = """
    You write up a meeting from its transcript. "You" is the person who recorded it and \
    "Others" is everyone else; the transcript is machine speech recognition, so read through \
    misheard words. Answer in exactly these four Markdown sections, in this order, each a list \
    of short bullets, and write "None" under a section with nothing in it:
    ## Summary
    ## Decisions
    ## Action items
    ## Open questions
    Keep names, numbers, dates and product names as said. Nothing that is not in the \
    transcript. No preamble, no em dashes.
    """

    public func summarize(transcript: String, title: String, kind: SummaryKind, progress: @escaping (String) -> Void) async throws -> String {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SummarizerError.empty }
        progress("Asking Claude…")
        switch kind {
        case .meeting:
            return try await client.ask(system: Self.meetingInstructions, user: "Meeting: \(title)\n\n\(transcript)")
        case .recap:
            return try await client.ask(system: AppleIntelligenceSummarizer.recapInstructions, user: "Meeting: \(title)\nLast few minutes:\n\n\(transcript)")
        }
    }

    public func runningNotes(previous: [String], transcript: String, title: String) async throws -> [String] {
        guard let device = SummarizerFactory.best().0 else { return [] }
        return try await device.runningNotes(previous: previous, transcript: transcript, title: title)
    }
}
