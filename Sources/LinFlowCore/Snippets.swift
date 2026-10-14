import Foundation

/// A phrase you say that expands into saved text: "my address", "sign off".
public struct Snippet: Codable, Identifiable, Equatable {
    public var id: String
    public var trigger: String
    public var text: String

    public init(id: String = UUID().uuidString, trigger: String, text: String) {
        self.id = id; self.trigger = trigger; self.text = text
    }
}

/// Snippets live in ~/Library/Application Support/Lin Flow/snippets.json and expand
/// after the cleanup pass, before anything is pasted.
public enum Snippets {
    public static let fileURL = ModelCatalog.appSupportDir.appendingPathComponent("snippets.json")
    public static let didChange = Notification.Name("LinFlow.Snippets.didChange")

    public static func load() -> [Snippet] {
        guard let data = try? Data(contentsOf: fileURL), let list = try? JSONDecoder().decode([Snippet].self, from: data) else { return [] }
        return list
    }

    public static func save(_ snippets: [Snippet]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(snippets) { try? data.write(to: fileURL, options: .atomic) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    /// Replaces each spoken trigger (optionally led by "insert" or "snippet") with its text.
    /// Whole words, any casing, longest trigger first. Sentence punctuation right after the
    /// trigger is dropped when the snippet is the whole dictation, spans lines or ends with
    /// its own punctuation; a single token such as an email address also sheds a final
    /// period so it pastes clean into a form.
    public static func expand(_ text: String, snippets: [Snippet]) -> String {
        var out = text
        for s in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let trigger = s.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty, !s.text.isEmpty else { continue }
            let words = trigger.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = "(?i)(?<![\\w'])(?:(?:insert|snippet)\\s+)?" + words.joined(separator: "[\\s,]+") + "(?![\\w'])([.!?,;:]?)"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = out as NSString
            let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var result = "", last = 0
            let multiline = s.text.contains("\n")
            let selfPunctuated = s.text.last.map { ".!?".contains($0) } ?? false
            let singleToken = !s.text.contains(" ")
            for m in matches {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let punct = ns.substring(with: m.range(at: 1))
                let before = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
                let after = ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
                let whole = before.isEmpty && after.isEmpty
                var keepPunct = !punct.isEmpty
                if whole || multiline || selfPunctuated { keepPunct = false }
                if singleToken, after.isEmpty, ".!?".contains(punct) { keepPunct = false }
                result += s.text
                if keepPunct { result += punct }
                last = m.range.location + m.range.length
            }
            out = result + ns.substring(from: last)
        }
        return out
    }
}
