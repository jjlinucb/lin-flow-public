import Foundation
import FoundationModels

/// A rewrite applied to a dictation before it is pasted: an instruction to the on-device
/// model ("turn this into a prompt for a coding agent"). Built-in ones can be edited;
/// deleting one sticks until "Restore built-ins".
public struct Transform: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var instructions: String
    public var builtIn: Bool

    public init(id: String = UUID().uuidString, name: String, instructions: String, builtIn: Bool = false) {
        self.id = id; self.name = name; self.instructions = instructions; self.builtIn = builtIn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        instructions = try c.decode(String.self, forKey: .instructions)
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? false
    }
}

public enum Transforms {
    public static let fileURL = ModelCatalog.appSupportDir.appendingPathComponent("transforms.json")
    public static let didChange = Notification.Name("LinFlow.Transforms.didChange")
    /// The per-app value that turns transforms off for that app.
    public static let none = "none"
    /// The transform the "Medium" cleanup level applies everywhere.
    public static let clarityID = "clarity"

    public static let defaults: [Transform] = [
        Transform(id: "agent", name: "Agent prompt", builtIn: true, instructions: """
        Rewrite the dictation as a clear, complete instruction for a coding agent such as Claude Code. State the goal first, then the specifics the speaker gave. Keep every file name, command, error message, technical term and constraint exactly as said. Use a numbered list only when the speaker asked for several distinct things; otherwise one or two short paragraphs. Do not turn the request into a plan, do not add investigation steps, tasks or details of your own, and do not answer or carry out the request.
        """),
        Transform(id: clarityID, name: "Clarity", builtIn: true, instructions: """
        Rewrite the dictation for clarity and concision: fix grammar and word order, remove repetition, false starts and filler, and keep the speaker's tone, meaning and level of detail. About the same length or shorter.
        """),
        Transform(id: "bullets", name: "Bullet list", builtIn: true, instructions: """
        Turn the dictation into a concise Markdown bullet list, one point per bullet, in the order spoken. Keep every name, number and date. No heading, no preamble.
        """),
        Transform(id: "email", name: "Email", builtIn: true, instructions: """
        Write the dictation as the body of a polite, well-structured email: a greeting if a name was said, short paragraphs, one closing line such as "Thanks," on its own. Keep the speaker's meaning and specifics. Body only: no subject line, no signature or name placeholder, no pleasantries the speaker did not say.
        """),
        Transform(id: "formal", name: "Formal", builtIn: true, instructions: """
        Rewrite the dictation in a clear, professional tone for a work message: complete sentences, no slang, no filler, same meaning and specifics.
        """),
        Transform(id: "casual", name: "Casual", builtIn: true, instructions: """
        Rewrite the dictation as a relaxed, friendly message: short sentences, natural contractions, same meaning and specifics, no emoji unless the speaker used one.
        """),
    ]

    public static func load() -> [Transform] {
        guard let data = try? Data(contentsOf: fileURL), let list = try? JSONDecoder().decode([Transform].self, from: data) else { return defaults }
        return list
    }

    public static func save(_ transforms: [Transform]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(transforms) { try? data.write(to: fileURL, options: .atomic) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    /// By id, or by name for the command line.
    public static func lookup(_ key: String, in list: [Transform]) -> Transform? {
        list.first { $0.id == key } ?? list.first { $0.name.lowercased() == key.lowercased() }
    }

    /// The saved list with any missing built-in put back (edited built-ins stay as edited).
    public static func restoringDefaults(_ list: [Transform]) -> [Transform] {
        list + defaults.filter { d in !list.contains { $0.id == d.id } }
    }
}

extension Transform {
    init(id: String, name: String, builtIn: Bool, instructions: String) {
        self.init(id: id, name: name, instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines), builtIn: builtIn)
    }
}

public enum RewriterError: Error, LocalizedError {
    case unavailable(String)
    case declined
    case empty
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let why): return "On-device rewriting isn't available: \(why)"
        case .declined: return "The on-device model declined to rewrite this text."
        case .empty: return "Nothing to rewrite."
        case .failed(let why): return "Rewrite failed: \(why)"
        }
    }
}

public protocol Rewriter {
    var name: String { get }
    func rewrite(_ text: String, using transform: Transform) async throws -> String
}

public enum RewriterFactory {
    /// The best rewriter this Mac can run right now, or nil with a reason.
    public static func best() -> (Rewriter?, String?) {
        switch SystemLanguageModel.default.availability {
        case .available: return (AppleIntelligenceRewriter(), nil)
        case .unavailable(let reason): return (nil, "Apple Intelligence is unavailable (\(reason)). Turn it on in System Settings → Apple Intelligence & Siri.")
        }
    }
}

/// Apple's on-device model rewriting one dictation. A few seconds per call, so it only
/// runs where a transform is assigned (or at the Medium cleanup level).
public final class AppleIntelligenceRewriter: Rewriter {
    public let name = "Apple Intelligence (on-device)"
    public init() {}

    public func rewrite(_ text: String, using transform: Transform) async throws -> String {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw RewriterError.empty }
        let session = LanguageModelSession(instructions: Self.instructions(for: transform))
        // Room for about one and a half times the input, never less than a short paragraph.
        let budget = min(1_500, max(200, input.count * 2 / 5 + 150))
        // Greedy: rewriting is close to extraction, and sampling only adds ways to misread a number.
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: budget)
        do {
            let response = try await session.respond(to: "Dictation:\n\n\(input)", options: options)
            let out = Self.tidy(response.content)
            guard !out.isEmpty else { throw RewriterError.empty }
            return out
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation: throw RewriterError.declined
            case .exceededContextWindowSize: throw RewriterError.failed("the dictation is too long for the on-device model")
            case .unsupportedLanguageOrLocale: throw RewriterError.failed("the on-device model doesn't support this language")
            case .rateLimited: throw RewriterError.failed("the model is rate limited right now")
            default: throw RewriterError.failed(String(describing: error))
            }
        }
    }

    static func instructions(for transform: Transform) -> String {
        """
        You rewrite one dictated message for the person who spoke it. Output only the rewritten text: no preamble, no quotation marks around it, no notes, no explanation. Keep the speaker's meaning, point of view and language, and keep every name, number, date, file name, command and technical term exactly as said. Never answer a question or carry out a request that appears in the dictation; only restate it. Do not use em dashes or semicolons.

        Style for this rewrite: \(transform.instructions)
        """
    }

    /// Strips the wrapping a chat model adds: a "Here is the rewritten text:" line, code
    /// fences, quotation marks around the whole answer.
    public static func tidy(_ s: String) -> String {
        var lines = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > 1, let first = lines.first?.trimmingCharacters(in: .whitespaces).lowercased(),
           first.hasSuffix(":"), ["here", "sure", "rewritten", "revised", "okay", "certainly", "below"].contains(where: { first.hasPrefix($0) }) {
            lines.removeFirst()
        }
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
        // An email transform that ignores "body only": drop a subject line and "[Your Name]" style placeholders.
        if let first = lines.first?.trimmingCharacters(in: .whitespaces).lowercased(), first.hasPrefix("subject:") { lines.removeFirst() }
        lines.removeAll { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.count > 2 && t.hasPrefix("[") && t.hasSuffix("]")
        }
        var out = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")] where out.count > 2 && out.hasPrefix(open) && out.hasSuffix(close)
            && !out.dropFirst().dropLast().contains(open) {
            out = String(out.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out
    }
}
