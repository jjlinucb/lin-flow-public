import Foundation
import FoundationModels

public enum SummaryKind {
    /// Full meeting write-up: summary, decisions, action items, open questions.
    case meeting
    /// "What did I miss": the gist of the last few minutes, as a few bullets.
    case recap
}

public enum SummarizerError: Error, LocalizedError {
    case unavailable(String)
    case empty
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let why): return "On-device summaries aren't available: \(why)"
        case .empty: return "Nothing to summarize yet."
        case .failed(let why): return "Summary failed: \(why)"
        }
    }
}

public protocol Summarizer {
    var name: String { get }
    func summarize(transcript: String, title: String, kind: SummaryKind, progress: @escaping (String) -> Void) async throws -> String
    /// Running notes during a meeting: what is new and worth writing down in the newest stretch
    /// of transcript, given the bullets already taken. Zero to three bullets; empty is the right
    /// answer for small talk. See RunningNotes for the cadence.
    func runningNotes(previous: [String], transcript: String, title: String) async throws -> [String]
}

public enum SummarizerFactory {
    /// For the summary and the recap: Claude once John has saved a key, else the device.
    public static func forSummaries() -> (Summarizer?, String?) {
        if let client = ClaudeClient() { return (ClaudeSummarizer(client: client), nil) }
        return best()
    }

    /// The best summarizer this Mac can run right now, or nil with a reason.
    public static func best() -> (Summarizer?, String?) {
        switch SystemLanguageModel.default.availability {
        case .available: return (AppleIntelligenceSummarizer(), nil)
        case .unavailable(let reason): return (nil, "Apple Intelligence is unavailable (\(reason)). Turn it on in System Settings → Apple Intelligence & Siri.")
        }
    }
}

/// Apple's on-device model. Its window is 4096 tokens for instructions,
/// prompt and answer together, so a long meeting is taken in pieces and the
/// pieces are merged. Slow (several seconds per call) but free, private, and
/// needs no download.
public final class AppleIntelligenceSummarizer: Summarizer {
    public let name = "Apple Intelligence (on-device)"
    public init() {}

    /// Conservative: ~3.2 characters per token leaves headroom for instructions and the answer.
    private let chunkCharacters = 6_500
    private let maxResponseTokens = 900

    public func summarize(transcript: String, title: String, kind: SummaryKind, progress: @escaping (String) -> Void) async throws -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SummarizerError.empty }
        var limit = chunkCharacters
        var attempt = 0
        while true {
            do {
                if kind == .meeting { return try await meetingNotes(chunks: Self.split(text, maxCharacters: limit), title: title, progress: progress) }
                // A recap is about the last few minutes, so when they run past one call it reads
                // the most recent stretch that fits. It used to take notes on each part and fold
                // the notes together, three model calls or more for a five-minute recap.
                progress("Summarizing…")
                return try await respond(Self.recapInstructions, "Meeting: \(title)\nLast few minutes:\n\n\(Self.tail(text, maxCharacters: limit))")
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error, attempt < 3 {
                    // Halve the piece size and go again.
                    attempt += 1
                    limit = max(1_500, chunkCharacters >> attempt)
                    continue
                }
                throw SummarizerError.failed(Self.describe(error))
            } catch let error as SummarizerError {
                throw error
            } catch {
                throw SummarizerError.failed(error.localizedDescription)
            }
        }
    }

    // MARK: running notes, a stretch at a time

    public func runningNotes(previous: [String], transcript: String, title: String) async throws -> [String] {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let root = DynamicGenerationSchema(name: "RunningNotes", description: "New notes on the newest stretch of a meeting", properties: [
            Self.stringList("notes", "Zero to three complete sentences, each under 20 words, each something new from the newest stretch worth remembering afterwards. Usually one, often none.", atMost: 3),
        ])
        let schema = try GenerationSchema(root: root, dependencies: [])
        let session = LanguageModelSession(instructions: Self.runningInstructions)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 240)
        let taken = previous.isEmpty ? "(none yet)" : previous.map { "* " + $0 }.joined(separator: "\n")
        let prompt = "Meeting: \(title)\nNotes already taken:\n\(taken)\n\nNewest stretch of the transcript:\n\n\(text)"
        do {
            let response = try await session.respond(to: prompt, schema: schema, options: options)
            let bullets = NotesMerge.tidy((try? response.content.value([String].self, forProperty: "notes")) ?? [])
            return RunningNotes.filter(bullets, previous: previous, transcript: text)
        } catch let error as LanguageModelSession.GenerationError {
            throw SummarizerError.failed(Self.describe(error))
        }
    }

    static let runningInstructions = """
    You take running notes during a meeting, a minute or two at a time. Lines look like "[m:ss] Speaker: words". "You" is the note-taker, "Others" are the other participants. You are given the notes already taken and the newest stretch of transcript. Write down only what is new in the newest stretch and worth remembering afterwards: something decided, something someone agreed to do and who, a number, a date, a deadline, a question left open, a fact that matters. Each note is one complete sentence, under 20 words, in your own words, that a colleague who missed this minute would understand on its own: say who and what. Not a label, not a heading, not a name or a number on its own, never a transcript line copied out, never "Task:" or "Question:" in front. Most stretches deserve one note or none: greetings, small talk, filler, thinking aloud and anything already in the notes get nothing. Something asked but not settled is written as a question, not as a fact. Keep names, numbers, dates and product names exactly as written, and never add a number, a date or a name the stretch does not contain. Do not add commentary, do not infer what was not said, do not use em dashes.
    """

    // MARK: meeting notes, part by part

    /// Notes on each part as four bounded lists (the schema is enforced while the model
    /// generates, unlike a count in the instructions), merged heading by heading in code,
    /// with a list that still runs long handed back to the model to shorten. Asking the
    /// model for the finished document instead gave one list copied under every heading,
    /// a "## None" heading, and numbers that drifted as it rewrote 50 bullets. About 15 s for a
    /// short meeting and 4 minutes for a 25-minute one. The schemas are DynamicGenerationSchema
    /// because the @Generable macro needs a plugin the Command Line Tools do not ship.
    private func meetingNotes(chunks: [String], title: String, progress: @escaping (String) -> Void) async throws -> String {
        var parts: [[NotesMerge.Section: [String]]] = []
        for (i, chunk) in chunks.enumerated() {
            progress(chunks.count == 1 ? "Taking notes…" : "Reading part \(i + 1) of \(chunks.count)…")
            parts.append(try await partNotes(title: title, part: i + 1, of: chunks.count, chunk: chunk))
        }
        var sections = NotesMerge.merge(parts)
        for section in NotesMerge.Section.allCases {
            let bullets = sections[section] ?? []
            let cap = Self.longestList(section)
            guard bullets.count > cap else { continue }
            progress("Condensing \(section.heading.lowercased())…")
            let shorter = try await shorten(section, bullets, title: title, to: cap)
            if !shorter.isEmpty { sections[section] = shorter }
        }
        return NotesMerge.render(sections)
    }

    /// How many entries a merged section may show before the model shortens it.
    static func longestList(_ section: NotesMerge.Section) -> Int {
        switch section {
        case .summary: return 6
        case .decisions: return 10
        case .actions: return 12
        case .questions: return 8
        }
    }

    /// How many entries one part may contribute to a section.
    static func partCap(_ section: NotesMerge.Section) -> Int {
        switch section {
        case .summary: return 6
        case .decisions: return 5
        case .actions: return 8
        case .questions: return 4
        }
    }

    static let partKeys: [(NotesMerge.Section, String, String)] = [
        (.summary, "keyPoints", "What was discussed or reported in this part, each entry one short sentence under 20 words in your own words, with names, numbers and dates exactly as said"),
        (.decisions, "decisions", "Only things the participants agreed to do in this part; a proposal, a question or a status report is not a decision"),
        (.actions, "actionItems", "Tasks someone took on in this part: who does what, with the date if one was said"),
        (.questions, "openQuestions", "Questions raised in this part and left unanswered"),
    ]

    private static func stringList(_ name: String, _ description: String, atMost cap: Int) -> DynamicGenerationSchema.Property {
        DynamicGenerationSchema.Property(name: name, description: description,
            schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 0, maximumElements: cap))
    }

    private static func partSchema() throws -> GenerationSchema {
        let root = DynamicGenerationSchema(name: "MeetingPartNotes", description: "Notes on one part of a meeting", properties: partKeys.map { section, key, description in
            stringList(key, description, atMost: partCap(section))
        })
        return try GenerationSchema(root: root, dependencies: [])
    }

    private func partNotes(title: String, part: Int, of count: Int, chunk: String) async throws -> [NotesMerge.Section: [String]] {
        let session = LanguageModelSession(instructions: Self.partInstructions)
        // Greedy decoding: note-taking is extraction, and sampling only adds ways to misread a number.
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 700)
        let what = count == 1 ? "The transcript" : "Part \(part) of \(count) of the transcript"
        let response = try await session.respond(to: "Meeting: \(title)\n\(what):\n\n\(chunk)", schema: try Self.partSchema(), options: options)
        var out: [NotesMerge.Section: [String]] = [:]
        for (section, key, _) in Self.partKeys {
            out[section] = NotesMerge.tidy((try? response.content.value([String].self, forProperty: key)) ?? [])
        }
        return out
    }

    private func shorten(_ section: NotesMerge.Section, _ bullets: [String], title: String, to cap: Int) async throws -> [String] {
        let root = DynamicGenerationSchema(name: "ShortenedList", description: "The same list, shorter", properties: [
            Self.stringList("entries", "At most \(cap) entries, each under 25 words, in the original order, repeats merged, every name, number and date exactly as written", atMost: cap),
        ])
        let schema = try GenerationSchema(root: root, dependencies: [])
        let session = LanguageModelSession(instructions: Self.shortenInstructions(section))
        let list = bullets.map { "* " + $0 }.joined(separator: "\n")
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 600)
        let response = try await session.respond(to: "Meeting: \(title)\n\(section.heading), in order:\n\n\(list)", schema: schema, options: options)
        return NotesMerge.tidy((try? response.content.value([String].self, forProperty: "entries")) ?? [])
    }

    private func respond(_ instructions: String, _ prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: maxResponseTokens)
        let response = try await session.respond(to: prompt, options: options)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize: return "the transcript is too long for the on-device model even in pieces"
        case .guardrailViolation: return "the on-device model declined this content"
        case .unsupportedLanguageOrLocale: return "the on-device model doesn't support this language"
        case .assetsUnavailable: return "the model assets aren't downloaded yet"
        case .rateLimited: return "the model is rate limited right now, try again in a moment"
        default: return String(describing: error)
        }
    }

    // MARK: prompts

    static let partInstructions = """
    You take notes on a meeting transcript, or on one part of it. Lines look like "[m:ss] Speaker: words". "You" is the note-taker, "Others" are the other participants. Record only what this text actually contains and leave a list empty rather than pad it. Each entry is one short sentence under 20 words in your own words, never a copied transcript line, no greetings or small talk. Keep names, numbers, dates and product names exactly as written. A decision is only something the participants agreed to do. Do not infer dates or numbers that were not said, do not add commentary, do not use em dashes.
    """

    static func shortenInstructions(_ section: NotesMerge.Section) -> String {
        let what: String
        switch section {
        case .summary: what = "the key points of a meeting"
        case .decisions: what = "the decisions made in a meeting"
        case .actions: what = "the action items from a meeting"
        case .questions: what = "the open questions from a meeting"
        }
        return """
        You shorten a list of \(what). The entries were taken in order from successive parts of the meeting. Keep the order, merge entries that say the same thing, and drop the least important ones to fit. Each entry under 25 words. Keep every name, number, date and product name exactly as written; never change a number. Do not add anything that is not in the list, do not use em dashes or semicolons.
        """
    }

    static let recapInstructions = """
    Someone stepped away from a meeting and asks what they missed. Given the last few minutes of transcript ("You" is the asker, "Others" are the other participants), answer in 2 to 5 short plain bullets: what was discussed, anything decided, anything asked of them. Keep names and numbers exactly as given. No headings, no preamble, no commentary, no em dashes.
    """

    /// The longest run of whole lines at the end of `text` that fits in `maxCharacters`, or
    /// its last `maxCharacters` when even the final line is longer than that.
    public static func tail(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        var kept: [Substring] = []
        var total = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let cost = line.count + (kept.isEmpty ? 0 : 1)
            if total + cost > maxCharacters { break }
            kept.append(line)
            total += cost
        }
        return kept.isEmpty ? String(text.suffix(maxCharacters)) : kept.reversed().joined(separator: "\n")
    }

    /// Splits on line boundaries so no transcript line is cut in half.
    public static func split(_ text: String, maxCharacters: Int) -> [String] {
        guard text.count > maxCharacters else { return [text] }
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > maxCharacters, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            if line.count > maxCharacters {
                // One giant line: hard-split it.
                var rest = Substring(line)
                while rest.count > maxCharacters {
                    chunks.append(String(rest.prefix(maxCharacters)))
                    rest = rest.dropFirst(maxCharacters)
                }
                current = String(rest)
            } else {
                current += (current.isEmpty ? "" : "\n") + line
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
