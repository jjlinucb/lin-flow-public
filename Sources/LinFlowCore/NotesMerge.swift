import Foundation

/// Notes the model took on successive parts of one meeting, merged heading by heading in
/// code. The on-device model is good at "take notes on this part" and bad at "reorganize
/// all these notes into four sections": given the merged notes it copied one list under
/// every heading, added a "## None" heading and dropped the start and end of the meeting.
/// So the reorganizing happens here, and the model only ever shortens one list at a time.
public enum NotesMerge {
    public enum Section: CaseIterable {
        case summary, decisions, actions, questions

        public var heading: String {
            switch self {
            case .summary: return "Summary"
            case .decisions: return "Decisions"
            case .actions: return "Action items"
            case .questions: return "Open questions"
            }
        }
    }

    /// Strings the model generated into a list: markers and bold stripped, "None" and
    /// empty entries dropped.
    public static func tidy(_ items: [String]) -> [String] {
        items.compactMap { bullet($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// The sections of successive parts, in order, without repeats. A fact filed under
    /// open questions moves to the key points; a near repeat within a section keeps its
    /// shorter phrasing.
    public static func merge(_ parts: [[Section: [String]]]) -> [Section: [String]] {
        var out: [Section: [String]] = [:]
        var seen = Set<String>()
        for part in parts.map(refile) {
            for section in Section.allCases {
                for b in part[section] ?? [] where seen.insert(key(b)).inserted {
                    let words = wordSet(b)
                    if let i = out[section]?.firstIndex(where: { similar(wordSet($0), words) }) {
                        if b.count < out[section]![i].count { out[section]![i] = b }
                        continue
                    }
                    out[section, default: []].append(b)
                }
            }
        }
        return out
    }

    /// Entries under open questions that do not read as questions are key points the model
    /// had nowhere else to put.
    public static func refile(_ part: [Section: [String]]) -> [Section: [String]] {
        var out = part
        let (questions, facts) = (part[.questions] ?? []).reduce(into: ([String](), [String]())) { acc, e in
            if isQuestion(e) { acc.0.append(e) } else { acc.1.append(e) }
        }
        out[.questions] = questions
        if !facts.isEmpty { out[.summary] = (part[.summary] ?? []) + facts }
        return out
    }

    static func isQuestion(_ text: String) -> Bool {
        let t = text.lowercased()
        if t.hasSuffix("?") { return true }
        let starts = ["who ", "whom ", "whose ", "what ", "when ", "where ", "why ", "how ", "which ", "whether ", "do we ", "do they ", "does ", "did ", "should ", "shall ", "is it ", "is there ", "are we ", "are there ", "can we ", "could ", "will ", "would ", "might ", "need to decide", "decide whether", "decision on", "decision about", "open question", "still open", "unresolved", "undecided", "unclear", "not yet decided", "not decided", "to be decided", "to be determined", "tbd", "pending", "waiting on", "waiting for", "still owe", "still need", "depends on", "question of", "question about", "questions about", "asked whether", "asked if", "wants to know", "unknown"]
        return starts.contains { t.hasPrefix($0) || (!$0.hasSuffix(" ") && t.contains($0)) }
    }

    static func wordSet(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 || $0.allSatisfy { $0.isNumber } })
    }

    /// Two entries say the same thing when nearly every word of the shorter is in the longer.
    static func similar(_ a: Set<String>, _ b: Set<String>) -> Bool {
        guard a.count >= 4, b.count >= 4 else { return false }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count)) >= 0.8
    }

    /// The four headings in order, "* None" where there is nothing.
    public static func render(_ sections: [Section: [String]]) -> String {
        Section.allCases.map { section in
            let bullets = sections[section] ?? []
            return "## \(section.heading)\n" + (bullets.isEmpty ? "* None" : bullets.map { "* " + punctuated($0) }.joined(separator: "\n"))
        }.joined(separator: "\n\n")
    }

    // MARK: pieces

    /// The text of a bullet line without its marker, or nil for "None" and the like.
    static func bullet(_ line: String) -> String? {
        var s = Substring(line)
        // "* text", "- text", "• text"; a leading "**bold**" is not a marker.
        if let f = s.first, "*-•–—".contains(f), s.count > 1, "•–—".contains(f) || s[s.index(after: s.startIndex)].isWhitespace {
            s = s.dropFirst()
        } else {
            let digits = s.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 2, let m = s.dropFirst(digits.count).first, ".)".contains(m) {
                s = s.dropFirst(digits.count + 1)
            }
        }
        var text = s.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        while text.count > 2, let f = text.first, let l = text.last, f == l, "*_".contains(f) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        text = trimScraps(text)
        guard text.contains(where: { $0.isLetter || $0.isNumber }), !isNone(text) else { return nil }
        return text
    }

    static func punctuated(_ s: String) -> String {
        guard let last = s.last else { return s }
        return last.isLetter || last.isNumber || "\"”’')".contains(last) && !(s.dropLast().last.map { ".!?".contains($0) } ?? false) ? s + "." : s
    }

    /// The transcript's speaker labels and the scraps a copied line drags along:
    /// "You: The build is stable. Good, next." -> "The build is stable."
    static func trimScraps(_ text: String) -> String {
        var t = text
        for label in ["You:", "Others:", "You :", "Others :"] where t.hasPrefix(label) {
            t = String(t.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        var sentences = splitSentences(t)
        func scrap(_ s: String) -> Bool { s.split(separator: " ").count <= 3 && !s.contains(where: { $0.isNumber }) }
        while sentences.count > 1, scrap(sentences[0]) { sentences.removeFirst() }
        while sentences.count > 1, scrap(sentences[sentences.count - 1]) { sentences.removeLast() }
        return sentences.joined(separator: " ")
    }

    static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "jr", "sr", "inc", "ltd", "no", "approx", "dept"]

    /// Splits after . ! ? when a capital letter follows, except after "Mr." style abbreviations.
    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            current.append(c)
            guard ".!?".contains(c), i + 2 < chars.count, chars[i + 1] == " ", chars[i + 2].isUppercase else { continue }
            if c == "." {
                let word = current.dropLast().reversed().prefix { $0.isLetter }.reversed()
                if word.count <= 1 || abbreviations.contains(String(word).lowercased()) { continue }
            }
            out.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// "None", "N/A", "No decisions were made", "None mentioned".
    static func isNone(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
        if ["none", "n/a", "na", "nothing", "no", "nil", "not applicable", "none yet", "none noted", "none mentioned", "none stated", "none discussed", "none recorded", "not discussed", "not mentioned"].contains(t) { return true }
        if t.hasPrefix("no ") || t.hasPrefix("none ") {
            for w in ["decision", "action", "question", "mentioned", "discussed", "item", "noted", "made", "raised", "stated", "recorded", "identified", "specific"] where t.contains(w) { return true }
        }
        return false
    }

    static func key(_ b: String) -> String { b.lowercased().filter { $0.isLetter || $0.isNumber } }
}
