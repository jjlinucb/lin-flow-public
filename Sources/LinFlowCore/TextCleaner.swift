import Foundation

/// Deterministic, instant post-processing for dictated text. This replaces
/// the old Lin Flow LLM cleanup pass: Apple's on-device model was measured at
/// 4-11 s per call on this machine (and still missed the glossary fixes),
/// which is far too slow to sit between "release key" and "text appears".
///
/// Whisper already produces cased, punctuated prose and rarely emits "um",
/// so the rules here are the safe leftovers: filler tokens, spoken commands,
/// glossary spelling, and John's own style rules (no em dashes, no
/// semicolons). Nothing here rewrites meaning.
public struct TextCleaner {
    public var glossary: [String]
    public var replacements: [Replacement]
    public var removeFillers = true
    public var spokenCommands = true
    public var styleRules = true
    public var numbersAsDigits = true

    public init(glossary: [String] = Glossary.load(), replacements: [Replacement] = Glossary.loadReplacements()) {
        self.glossary = glossary
        self.replacements = replacements
    }

    public func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        text = Self.stripBracketedNoise(text)
        if text.isEmpty { return "" }
        text = Self.applyReplacements(text, replacements)
        if removeFillers { text = Self.removeFillers(text) }
        if spokenCommands { text = Self.applySpokenCommands(text) }
        text = GlossaryMatcher(terms: glossary).apply(to: text)
        // After the glossary, so a term that contains a number word still matches.
        if numbersAsDigits { text = NumberWords.apply(to: text) }
        if styleRules { text = Self.applyStyleRules(text) }
        text = Self.tidyWhitespaceAndPunctuation(text)
        // Last, and told what not to touch: the two steps above exist to produce an exact
        // spelling, and capitalizing the first letter of a sentence undid them.
        text = Self.capitalizeSentences(text, keepingLowercase: Self.lowercaseTerms(replacements, glossary))
        return text
    }

    /// John's style rules alone (em dashes and semicolons) for text a model wrote.
    public static func applyStyle(_ s: String) -> String { applyStyleRules(s) }

    // MARK: pieces (internal for tests)

    /// Exact phrase corrections from the dictionary ("wisper flow" -> "Wispr Flow"),
    /// case-insensitive, whole words only. Runs before the fuzzy glossary pass.
    public static func applyReplacements(_ s: String, _ replacements: [Replacement]) -> String {
        var out = s
        for r in replacements where !r.from.trimmingCharacters(in: .whitespaces).isEmpty {
            let pattern = "(?i)(?<![\\w'])" + NSRegularExpression.escapedPattern(for: r.from.trimmingCharacters(in: .whitespaces)) + "(?![\\w'])"
            out = out.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: r.to), options: .regularExpression)
        }
        return out
    }

    /// Whisper marks non-speech with bracketed tags: [BLANK_AUDIO], (music),
    /// *laughs*, ♪. Drop those; dictated parentheses such as "(408) 555-1234" or
    /// "(Parakeet)" stay. If nothing else is left the clip was empty.
    static func stripBracketedNoise(_ s: String) -> String {
        var out = s
        for pattern in [#"\[([^\]]*)\]"#, #"\(([^)]*)\)"#] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = out as NSString
            var result = "", last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                result += isNoiseTag(ns.substring(with: m.range(at: 1))) ? " " : ns.substring(with: m.range)
                last = m.range.location + m.range.length
            }
            out = result + ns.substring(from: last)
        }
        for pattern in [#"\*[^*]*\*"#, #"♪+"#] {
            out = out.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // Known whole-output hallucinations on silence.
        let lowered = out.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if Self.silenceHallucinations.contains(lowered) { return "" }
        return out
    }

    /// The contents of a bracket the recognizer used as a non-speech tag, not dictated text.
    static func isNoiseTag(_ inner: String) -> Bool {
        let t = inner.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.contains("_") { return true }                    // [BLANK_AUDIO]
        if t.contains(where: { $0.isNumber }) { return false }             // (408)
        let words = t.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        return words.count <= 3 && words.allSatisfy { noiseWords.contains($0) }
    }

    static let noiseWords: Set<String> = [
        "music", "laughs", "laughter", "laughing", "chuckles", "applause", "clapping", "cheering", "inaudible",
        "unintelligible", "indistinct", "silence", "blank", "audio", "noise", "background", "coughs", "coughing",
        "sighs", "sigh", "speaking", "foreign", "language", "crosstalk", "typing", "pause", "static", "beep",
        "door", "phone", "ringing", "upbeat", "soft", "gentle", "dramatic", "breathing", "sniffs", "mumbles",
        "murmurs", "speech", "sound", "sounds", "instrumental", "singing", "humming", "whispering", "clicking",
        "wind", "rain", "crying", "screaming", "gasps", "groans", "grunts", "whistling", "bell", "bells",
        "chime", "chimes", "intro", "outro", "no", "clears", "throat", "sneezes", "yawns", "engine", "traffic",
    ]

    static let silenceHallucinations: Set<String> = [
        "thank you", "thanks for watching", "thank you for watching", "you", "bye", "the end",
        "subtitles by the amara.org community", "please subscribe", "so", "oh", "hmm", "mm", "mhm", "uh", "um",
    ]

    /// Only tokens that are filler in every context. "like" and "so" are
    /// deliberately left alone: they carry meaning too often.
    static func removeFillers(_ s: String) -> String {
        var out = s
        // "um", "uh", "er", "erm", "ah", "hmm", "mm-hmm", "mhm", together with the comma before
        // and/or after it, so "the ER, uh, was full" loses no more than the filler. Spelled case
        // by case rather than (?i) so all-caps acronyms (ER, UM, AH) survive, hyphens excluded so
        // "uh-huh" stays whole, "err" excluded by [Ee]r(?:m+)?. A following period stays.
        out = out.replacingOccurrences(
            of: #"(?:,[ \t]*)?(?<![\w'-])(?:[Uu]+m+|[Uu]+h+|[Ee]r(?:m+)?|[Aa]+h+|[Hh]+m+|[Mm]m+-?[Hh]+m+|[Mm]hm)(?![\w'-]),?\s*"#,
            with: " ", options: .regularExpression)
        // "you know," as an aside (followed by a comma) — the meaningful use ("you know the answer") has no comma.
        out = out.replacingOccurrences(of: #"(?i)(?:,[ \t]*)?(?<![\w'])you know,\s*"#, with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespaces)
        // "I mean," at the start of a sentence.
        out = out.replacingOccurrences(of: #"(?i)(^|[.!?]\s+)I mean,\s*"#, with: "$1", options: .regularExpression)
        return out
    }

    /// Phrases nobody says literally in prose. "period" and "comma" are
    /// intentionally not here: whisper punctuates from prosody already, and
    /// both words are common in ordinary sentences.
    static func applySpokenCommands(_ s: String) -> String {
        var out = applyEnterRuns(s)
        let table: [(String, String)] = [
            // A comma before the command goes; a period stays (it ends the sentence).
            // "new line" runs first so "new paragraph" next to it still yields a blank line.
            (#"(?i),?\s*\bnew line\b[,.]?\s*"#, "\n"),
            (#"(?i),?\s*\bnew paragraph\b[,.]?\s*"#, "\n\n"),
            (#"(?i)\s*[,.]?\s*\bexclamation (?:mark|point)\b[,.]?"#, "!"),
            (#"(?i)\s*[,.]?\s*\bquestion mark\b[,.]?"#, "?"),
        ]
        for (pattern, replacement) in table {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        // "That's great!." -> "That's great!"  and  "really?." -> "really?"
        out = out.replacingOccurrences(of: #"([!?])\s*[.,]"#, with: "$1", options: .regularExpression)
        return out
    }

    /// "Hi Solomon comma enter enter where's that" -> "Hi Solomon,\n\nwhere's that". John,
    /// 2026-09-25: "when I say comma enter enter, I actually want the comma and enter enter to a
    /// new line". Each "enter" is one line break and a punctuation word in the run is its mark.
    ///
    /// Only a run of two or more command words with at least one "enter" counts, so "enter the
    /// password" and "press enter" stay words, and so does "comma" alone, as the note above says.
    /// A run with a single "enter" also needs its words said without a mark between them.
    /// The models often punctuate the run itself ("Comma, enter, enter."), so a mark between or
    /// after its words goes, and so does the mark the model put before it when the run brings
    /// its own. "Hi Solomon, enter enter" keeps the model's comma.
    static let enterRun = try! NSRegularExpression(
        pattern: #"(?i)[ \t]*([,.;:!?]?)[ \t]*(?<![\w'])((?:comma|period|full stop|colon|question mark|exclamation (?:mark|point)|enter)(?:[ \t]*[,.;:!?]?[ \t]+(?:comma|period|full stop|colon|question mark|exclamation (?:mark|point)|enter))+)(?![\w'])[,.;:!?]?[ \t]*"#)

    static func applyEnterRuns(_ s: String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in enterRun.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let words = ns.substring(with: m.range(at: 2)).lowercased()
                .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            let breaks = words.filter { $0 == "enter" }.count
            guard breaks > 0 else { continue }
            // One "enter" with a mark between it and the word before is prose: "after the trial
            // period, enter your card". Two in a row are a command however they were punctuated.
            if breaks == 1, ns.substring(with: m.range(at: 2)).rangeOfCharacter(from: CharacterSet(charactersIn: ",.;:!?")) != nil { continue }
            let marks: [(String, String)] = [("comma", ","), ("period", "."), ("stop", "."), ("colon", ":"),
                                             ("question", "?"), ("exclamation", "!")]
            // The last mark said wins; with none, the model's own mark before the run stays.
            let spoken = words.reversed().compactMap { w in marks.first { $0.0 == w }?.1 }.first
            let mark = spoken ?? ns.substring(with: m.range(at: 1))
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += mark + String(repeating: "\n", count: breaks)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    static func applyStyleRules(_ s: String) -> String {
        var out = s
        // Em/en dashes used as punctuation become a comma (mid-sentence) — John never writes them.
        // Horizontal whitespace only, so a newline a spoken command just inserted survives.
        out = out.replacingOccurrences(of: #"[ \t]*[—–][ \t]*"#, with: ", ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[ \t]+-[ \t]+"#, with: ", ", options: .regularExpression)
        // Semicolons become periods, and the next word gets capitalized later.
        out = out.replacingOccurrences(of: #";[ \t]*"#, with: ". ", options: .regularExpression)
        return out
    }

    static let sentenceEnders: Set<Character> = [".", "!", "?", "\n", "。", "！", "？", "…", "។", "؟"]
    static let closingMarks = "\"'”’)]"

    static func tidyWhitespaceAndPunctuation(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #" ?\n ?"#, with: "\n", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[ \t]+([,.!?:;])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\n[ \t]*,[ \t]*"#, with: "\n", options: .regularExpression)   // a dash that became ", " after a spoken new line
        out = out.replacingOccurrences(of: #"([,.!?:])\1+"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #",\s*\."#, with: ".", options: .regularExpression)
        // Clock times the models write without a colon: "3 45 p.m." / "7.15 am" -> "3:45 p.m." / "7:15 am".
        out = out.replacingOccurrences(of: #"(?i)\b(\d{1,2})[ .](\d{2})(?=\s*[ap]\.?m\b)"#, with: "$1:$2", options: .regularExpression)
        out = out.replacingOccurrences(of: #"^[,.\s]+"#, with: "", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // A trailing comma or colon (usually where a filler was cut off) is not an ending.
        out = out.replacingOccurrences(of: #"[,:;\s]+$"#, with: "", options: .regularExpression)
        // A dictation is a sentence; make sure it ends like one. Closing quotes and brackets
        // don't count, and neither does a Chinese, Japanese or Khmer full stop already there.
        let core = out.reversed().drop(while: { closingMarks.contains($0) })
        if let last = core.first, !sentenceEnders.contains(last) { out += fullStop(after: last) }
        return out
    }

    /// The full stop that belongs to the script of the last letter: "。" after Chinese or
    /// Japanese, "។" after Khmer, "." otherwise.
    static func fullStop(after c: Character) -> String {
        guard let v = c.unicodeScalars.first?.value else { return "." }
        switch v {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x3000...0x303F: return "。"
        case 0x1780...0x17FF: return "។"
        default: return "."
        }
    }

    /// Words a period does not end a sentence after: "p.m.", "e.g.", "etc.", titles. (The
    /// models already capitalize the name after "Mr.", so nothing is lost by not forcing it.)
    static let abbreviations: Set<String> = ["p.m", "a.m", "e.g", "i.e", "etc", "vs", "approx", "dept", "mr", "mrs", "ms", "dr", "prof", "st", "mt", "jr", "sr", "inc", "ltd"]

    /// Terms the user spells with a lowercase initial on purpose -- a username, a shell
    /// command, a package name -- taken from the right-hand side of their corrections and
    /// from the glossary. John's own "K Wynn E D F => kkwinedf" and "GWS C L I => gws cli"
    /// were being written out as "Kkwinedf" and "Gws cli" whenever the term opened a
    /// sentence, which is exactly where a handle or a command gets dictated.
    public static func lowercaseTerms(_ replacements: [Replacement], _ glossary: [String]) -> Set<String> {
        var out = Set<String>()
        for s in replacements.map(\.to) + glossary {
            guard let first = s.split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
                  let head = first.first, head.isLowercase else { continue }
            out.insert(first)
        }
        return out
    }

    /// The run of non-space characters at `i`, without the punctuation that ends the sentence
    /// rather than belonging to the word. "kkwinedf." is the term; "whisper.cpp" keeps its dot.
    static func word(in chars: [Character], at i: Int) -> String {
        var j = i
        while j < chars.count, !chars[j].isWhitespace { j += 1 }
        var w = Array(chars[i..<j])
        while let last = w.last, !last.isLetter, !last.isNumber { w.removeLast() }
        return String(w)
    }

    public static func capitalizeSentences(_ s: String, keepingLowercase protected: Set<String> = []) -> String {
        guard !s.isEmpty else { return s }
        var chars = Array(s)
        var capitalizeNext = true
        for i in chars.indices {
            let c = chars[i]
            if capitalizeNext, c.isLetter, !protected.isEmpty,
               protected.contains(Self.word(in: chars, at: i)) {
                capitalizeNext = false          // a spelling the user chose; leave it alone
            } else if capitalizeNext, c.isLetter {
                // "ß" uppercases to "SS" and ligatures to two letters; leave those alone rather than
                // build a Character from two clusters (which traps).
                let up = c.uppercased()
                if up.count == 1 { chars[i] = Character(up) }
                capitalizeNext = false
            } else if c == "\n" {
                capitalizeNext = true
            } else if ".!?".contains(c) {
                // Only a terminator that ends the token ends a sentence: not the dots in
                // "example.com", "whisper.cpp" or "p.m.", nor the "?" in a URL query.
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                let endsToken = next == nil || next!.isWhitespace || closingMarks.contains(next!)
                if endsToken {
                    if !(c == "." && isAbbreviation(before: i, in: chars)) { capitalizeNext = true }
                } else {
                    capitalizeNext = false
                }
            } else if !c.isWhitespace, !"\"'“‘(".contains(c) {
                capitalizeNext = false
            }
        }
        return String(chars)
    }

    /// Is the word before index `i` (letters and dots) an abbreviation or an initial?
    static func isAbbreviation(before i: Int, in chars: [Character]) -> Bool {
        var j = i - 1
        var word: [Character] = []
        while j >= 0, chars[j].isLetter || chars[j] == "." { word.append(chars[j]); j -= 1 }
        guard !word.isEmpty else { return false }
        let w = String(word.reversed()).lowercased()
        if abbreviations.contains(w) { return true }
        // "u.s", "a.m", "e.g": single letters separated by dots.
        return w.contains(".") && w.split(separator: ".").allSatisfy { $0.count == 1 }
    }
}

/// A dictionary correction: what the recognizer tends to write, and what you meant.
public struct Replacement: Codable, Equatable, Identifiable {
    public var from: String
    public var to: String
    /// Added by Lin Flow from an edit you made, rather than typed by hand.
    public var learned: Bool
    public var id: String { from.lowercased() }
    public init(from: String, to: String, learned: Bool = false) { self.from = from; self.to = to; self.learned = learned }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        learned = try c.decodeIfPresent(Bool.self, forKey: .learned) ?? false
    }
}

/// The user's proper-noun list. One term per line in
/// ~/Library/Application Support/Lin Flow/vocab.txt (seeded on first run).
/// Used two ways: fed to whisper as the initial prompt so it spells names
/// right in the first place, and as a fuzzy-match fixup afterwards.
/// replacements.txt holds explicit corrections, one "wrong => right" per line.
public enum Glossary {
    public static let fileURL = ModelCatalog.appSupportDir.appendingPathComponent("vocab.txt")
    public static let replacementsFileURL = ModelCatalog.appSupportDir.appendingPathComponent("replacements.txt")
    public static let didChange = Notification.Name("LinFlow.Glossary.didChange")
    /// Marks a correction Lin Flow learned from an edit, in replacements.txt.
    public static let learnedMarker = "# learned"

    public static func saveTerms(_ terms: [String]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? termsFile(terms).write(to: fileURL, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The Dictionary's reading order: what Lin Flow learned most recently first, then the
    /// rules John wrote himself, in the order he wrote them.
    ///
    /// Recency is file order, not a timestamp. Every rule is appended -- by `saveReplacements`
    /// when one is learned and by accepting a suggestion -- so the last learned line is the
    /// newest. A list that only grows downward buries the rule he just watched being learned,
    /// which is the one he opens this tab to check.
    public static func displayOrder(_ replacements: [Replacement]) -> [Replacement] {
        Array(replacements.filter(\.learned).reversed()) + replacements.filter { !$0.learned }
    }

    public static func loadReplacements() -> [Replacement] {
        guard let data = try? String(contentsOf: replacementsFileURL, encoding: .utf8) else { return [] }
        return parseReplacements(data)
    }

    /// The terms a vocab.txt holds, without falling back to the defaults the way `load` does:
    /// the shared dictionary has to tell an emptied list from one never written.
    public static func parseTerms(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// The vocab.txt `saveTerms` writes for these terms.
    public static func termsFile(_ terms: [String]) -> String {
        "# Lin Flow glossary: one name or term per line.\n"
            + terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
    }

    public static func parseReplacements(_ data: String) -> [Replacement] {
        data.split(whereSeparator: \.isNewline).compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#"), let range = s.range(of: "=>") else { return nil }
            let from = s[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            var to = s[range.upperBound...].trimmingCharacters(in: .whitespaces)
            // Rules Lin Flow added itself carry a trailing marker so the window can label them.
            var learned = false
            if to.hasSuffix(Glossary.learnedMarker) {
                learned = true
                to = String(to.dropLast(Glossary.learnedMarker.count)).trimmingCharacters(in: .whitespaces)
            }
            return from.isEmpty ? nil : Replacement(from: from, to: to, learned: learned)
        }
    }

    public static func saveReplacements(_ replacements: [Replacement]) {
        try? FileManager.default.createDirectory(at: replacementsFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: replacementsFileURL, encoding: .utf8)) ?? ""
        let body = Self.replacementsFile(replacements, keeping: existing)
        try? body.write(to: replacementsFileURL, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The file to write, carrying forward every line the parser could not read.
    ///
    /// This is a plain text file John edits by hand, so it collects grouping comments, blank
    /// lines, and the occasional typo -- an arrow written "->" instead of "=>". The loader
    /// drops all of those, and the writer rebuilt the file from only what survived, so the
    /// next learned correction deleted them from disk with no click and no message. A line
    /// Lin Flow does not understand is not a line it may throw away.
    public static func replacementsFile(_ replacements: [Replacement], keeping existing: String) -> String {
        let header = "# Lin Flow corrections: what was heard => what you meant, one per line."
        let keptHeader = "# Lines Lin Flow could not read, kept as you wrote them."
        let kept = existing.split(whereSeparator: \.isNewline).map(String.init).filter { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            // The kept section's own heading is written fresh below. Carried forward as one more
            // comment, it gained a copy on every save after the first.
            guard !s.isEmpty, s != header, s != keptHeader else { return false }
            // A rule the writer is about to emit itself, or a comment/typo it cannot parse.
            if !s.hasPrefix("#"), s.contains("=>") { return false }
            return true
        }
        var body = header + "\n"
            + replacements.map { "\($0.from) => \($0.to)" + ($0.learned ? "\t\(learnedMarker)" : "") }.joined(separator: "\n") + "\n"
        if !kept.isEmpty {
            body += "\n\(keptHeader)\n" + kept.joined(separator: "\n") + "\n"
        }
        return body
    }

    public static let defaults: [String] = [
        "John Lin", "Lin Flow", "Wispr Flow", "Parakeet", "whisper.cpp", "MLX",
        "WORKBRAIN", "MINISTRYBRAIN", "Claude", "Claude Code", "Anthropic", "GitHub",
        "Northwind", "Sunnyvale", "Santa Cruz", "Cambodia", "Khmer",
    ]

    public static func load() -> [String] {
        if let data = try? String(contentsOf: fileURL, encoding: .utf8) {
            let terms = data.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            if !terms.isEmpty { return terms }
        }
        return defaults
    }

    /// Write the default list if the user doesn't have one yet.
    public static func seedIfMissing() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = "# Lin Flow glossary: one name or term per line. Whisper is primed with these and\n# the cleanup pass snaps near-misses to this exact spelling.\n" + defaults.joined(separator: "\n") + "\n"
        try? body.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// The decoder prompt: a plain comma list reads as "here is how these are spelled".
    public static func initialPrompt(_ terms: [String]) -> String {
        terms.isEmpty ? "" : terms.joined(separator: ", ") + "."
    }
}

/// Snaps words that *sound like* a glossary term to the term's spelling:
/// "Lend Flow" / "Len Flow" / "LinFlow" -> "Lin Flow", "Whisper Flow" -> "Wispr Flow",
/// "Workbrain" -> "WORKBRAIN". Compares word windows of the same length as
/// the term (plus the glued single-word form) using a consonant skeleton and
/// a length-scaled edit distance, and insists every word start with the
/// same letter so "in flow" never turns into "Lin Flow".
public struct GlossaryMatcher {
    public let terms: [String]
    public init(terms: [String]) { self.terms = terms }

    /// Longer terms first so "Claude Code" wins over "Claude".
    private var orderedTerms: [String] {
        terms.sorted { a, b in
            let wa = a.split(separator: " ").count, wb = b.split(separator: " ").count
            return wa != wb ? wa > wb : a.count > b.count
        }
    }

    public func apply(to text: String) -> String {
        guard !terms.isEmpty else { return text }
        var tokens = Self.tokenize(text)
        let wordIdx = tokens.indices.filter { tokens[$0].isWord }
        var consumed = Set<Int>()
        let termSet = Set(terms)

        for term in orderedTerms {
            let termWords = term.split(separator: " ").map(String.init)
            // Windows of the term's own word count plus the glued one-word form ("Linflow");
            // for one-word terms also the split two-word form ("work brain", "Sunny Veil").
            let sizes = termWords.count > 1 ? [termWords.count, 1] : [1, 2]
            for n in sizes {
                let joiner = (termWords.count == 1 && n == 2) ? "" : " "
                var i = 0
                while i + n <= wordIdx.count {
                    let idxs = Array(wordIdx[i..<(i + n)])
                    if idxs.contains(where: { consumed.contains($0) }) { i += 1; continue }
                    let cores = idxs.map { tokens[$0].core }
                    if cores.contains(where: { $0.isEmpty }) { i += 1; continue }
                    let glued = joiner.isEmpty
                    // Two words split by a period are two words ("whisper.cpp. It").
                    if glued, !tokens[idxs[0]].trailing.isEmpty { i += 1; continue }
                    if let replacement = Self.correction(for: cores, glued: glued, term: term, termSet: termSet) {
                        let first = idxs.first!, last = idxs.last!
                        tokens[first].text = tokens[first].leading + replacement + tokens[last].trailing
                        if last > first { for k in (first + 1)...last { tokens[k].text = "" } }
                        idxs.forEach { consumed.insert($0) }
                        i += n
                    } else {
                        i += 1
                    }
                }
            }
        }
        return tokens.map { $0.text }.joined()
    }

    /// Endings a speaker adds to a name: "Parakeets", "Lin Flow's", "Cambodian", "Cambodians".
    static let inflections = ["'s", "’s", "s'", "s’", "es", "s", "an", "n"]
    static let pluralOrPossessive = ["'s", "’s", "s'", "s’", "es", "s"]

    /// The term, keeping any inflection the speaker used, if the window sounds like it.
    static func correction(for cores: [String], glued: Bool, term: String, termSet: Set<String>) -> String? {
        let termLower = term.lowercased()
        if glued {
            // Two words that should be one ("work brain", "git hub"). Two everyday English words
            // are two words ("work again", "another epic"): only a part that is not a word can
            // be a mangled name, and even then within the term's edit tolerance.
            guard cores.allSatisfy({ $0.count >= 3 }) else { return nil }
            let candidate = cores.joined()
            if termSet.contains(candidate) { return nil }
            let c = candidate.lowercased()
            for suffix in pluralOrPossessive where c.hasSuffix(suffix) && String(c.dropLast(suffix.count)) == termLower { return term + suffix }
            if c == termLower { return term }
            let allWords = cores.allSatisfy { englishWords.contains($0.lowercased()) }
            guard !allWords, c.first == termLower.first, abs(c.count - termLower.count) <= tolerance(termLower.count) else { return nil }
            return levenshtein(c, termLower) <= tolerance(termLower.count) ? term : nil
        }
        let candidate = cores.joined(separator: " ")
        if termSet.contains(candidate) { return nil }                       // already right
        if candidate.lowercased() == termLower { return term }              // casing only
        // Inflections of a term that is already right stay ("Parakeets", "Lin Flow's",
        // "Cambodians"); inflections of a lowercase or glued term keep their ending.
        let termGlued = termLower.replacingOccurrences(of: " ", with: "")
        var stems = [candidate]
        for _ in 0..<2 {
            var next: [String] = []
            for s in stems { for suffix in inflections where s.count > suffix.count + 2 && s.hasSuffix(suffix) { next.append(String(s.dropLast(suffix.count))) } }
            for s in next {
                if termSet.contains(s) { return nil }
                let l = s.lowercased()
                if l == termLower || l == termGlued { return term + String(candidate.dropFirst(s.count)) }   // "githubs" -> "GitHubs"
            }
            if next.isEmpty { break }
            stems = next
        }
        // The whole word first ("John Lynn" -> "John Lin"), then a plural or possessive of a
        // near miss ("Lend Flow's" -> "Lin Flow's").
        if matches(candidate: candidate, term: term) { return term }
        for suffix in pluralOrPossessive where candidate.count > suffix.count + 2 && candidate.hasSuffix(suffix) {
            if matches(candidate: String(candidate.dropLast(suffix.count)), term: term) { return term + suffix }
        }
        return nil
    }

    public static func matches(candidate: String, term: String) -> Bool {
        if candidate == term { return false }
        let c = candidate.lowercased(), t = term.lowercased()
        if c == t { return true }
        let cWords = c.split(separator: " ").map(String.init)
        let tWords = t.split(separator: " ").map(String.init)
        if cWords.count == 1, tWords.count > 1 {
            // "linflow" / "whisperflow" vs "lin flow" / "wispr flow": the word has to split into
            // the term's words, each part starting with its word's letter, within the whole
            // term's tolerance. "johnlyn" is "john" + "lyn"; "Johnson" has no "l" part.
            let glued = tWords.joined()
            guard !englishWords.contains(c) else { return false }
            if c == glued { return true }
            guard let d = gluedDistance(Substring(c), tWords[...]) else { return false }
            return d <= tolerance(glued.count)
        }
        guard cWords.count == tWords.count else { return false }
        for (a, b) in zip(cWords, tWords) {
            if a.first != b.first { return false }
            // "Claude's code" is about Claude's code, not "Claude Code".
            if a.contains(where: { "'’".contains($0) }), !b.contains(where: { "'’".contains($0) }) { return false }
            // A verb form is a verb, not a name: "Claude coded" stays.
            if (a.hasSuffix("ed") && !b.hasSuffix("ed")) || (a.hasSuffix("ing") && !b.hasSuffix("ing")) { return false }
            // "John Lee" and "John Lin" are two different people. A word that is itself a
            // real name only becomes another name when it actually sounds like one -- same
            // consonant skeleton, and the target is a name too. Plain near-misses that are
            // nobody's name ("Lend Flow", "Whisper Flow", "Cloud Code") are untouched by this.
            if a != b, personalNames.contains(a),
               nameKey(a) != nameKey(b) || !personalNames.contains(b) { return false }
        }
        if cWords.count == 1 {
            // An ordinary English word is never a misspelling of a name: "clause" and "cloud" stay
            // themselves even though they are one edit from "Claude", and "multi-team" is not
            // "Northwind". (Wrong words the recognizer keeps producing belong in the Dictionary's
            // corrections instead.)
            if englishWords.contains(c) { return false }
            if c.contains("-"), c.split(separator: "-").allSatisfy({ englishWords.contains(String($0)) }) { return false }
        }
        // Edit distance scaled to the term's length. Matching on the consonant skeleton
        // alone used to turn "could", "cold" and "cloud" into "Claude".
        return levenshtein(c, t) <= tolerance(t.count)
    }

    /// Smallest total edit distance over every way of cutting `c` into `words.count` parts
    /// whose first letters match the words, or nil when no cut lines up.
    static func gluedDistance(_ c: Substring, _ words: ArraySlice<String>) -> Int? {
        guard let word = words.first, c.first == word.first else { return nil }
        if words.count == 1 { return levenshtein(String(c), word) }
        guard c.count >= 2 else { return nil }
        var best: Int? = nil
        for cut in 1..<c.count {
            guard let rest = gluedDistance(c.dropFirst(cut), words.dropFirst()) else { continue }
            let d = levenshtein(String(c.prefix(cut)), word) + rest
            if best.map({ d < $0 }) ?? true { best = d }
        }
        return best
    }

    /// Common personal names, for the rule in `matches`: one real name is never rewritten
    /// into a different real name. Weighted toward the names John actually dictates.
    /// Without this, "John Lee", "John Liu", "John Lim", "John Liang", "John Lam" and
    /// "John Lang" all became "John Lin" -- the matching "John" donated enough of the
    /// phrase's edit budget to cover the whole surname.
    ///
    /// Coverage of this list is the maintenance surface: a surname missing from it can still be
    /// snapped onto a glossary name, so add names when one slips through. Known gap: the glued
    /// one-word path does not consult it, so "Johnlee" still becomes "John Lin" (ASR spaces real
    /// names, so it has not come up).
    static let personalNames: Set<String> = Set("""
lee li lim lin ling liang liu lam lang long lu lui loo law lo loh luk lai lau leung liao lien
chan chen cheng chang chiang chin ching cho choi chou chow chu chun chung tsai tsang tsao tse
tseng tsui tu tuan tung fan fang feng fong foo fu gao ge gong gu guo han hao he ho hong hou hsu
hu hua huang hui hung hwang jang jeong ji jiang jin jung kang kao ke khoo kim ko koh kong ku kuo
kwan kwok kwon ma mak mao mei meng min ming mo moon mun na nam ng ngo nguyen ni ning niu ou
ouyang pak pan pang park pei peng pham phan qi qian qin qiu quach ran rao ren ruan sam sang seo
seok seong sha shan shang shao shen sheng shi shin shu shum sim sin sit siu son song su sui sun
sung sze tai tam tan tang tao teng teo thai tian tien ting to tong tran trinh truong wan wang
wei wen weng wong woo wu xie xin xing xiong xu xue yan yang yao ye yee yeh yen yeo yeoh yeung yi
yim yin ying yip yiu yoo yoon you young yu yuan yue yuen yun zeng zhan zhang zhao zhen zheng
zhong zhou zhu
cody coty coady brady casey blake drew reese rowan sloan tate wade avery jody jodi cory corey kody
len lenn linn lynne lyn linh minh mai loan lien nhan bao dao hao thao chau chi
levin levine lund lind lian lok low lowe loy luce lund lindy lindsay lindsey leland lenny leona leonel levi lew liam lila lily lina lino lionel lola lonnie lora loren lorena lorenzo loretta lorna lorraine lottie lou louie lowell lucia lucille lucinda luis luisa luther lyle lyman lynda lyndon lynette lund lange lantz landry landon
claudia claudette claudine jan jann joann johann johanna jens jenny jess jodie joni juana juanita jorge jules julius jude junior kaylee kayla
adams allen anderson bailey baker barnes bell bennett brooks brown bryant burns butler campbell
carter chase clark cole collins cook cooper cox craig cruz curtis davis dean diaz dixon duncan
dunn edwards ellis evans fisher fleming ford foster fox freeman fuller garcia gibson gordon
graham grant gray green griffin hall hamilton harris hart hayes henderson hill holmes hopkins
howard hughes hunt hunter jackson james jenkins johnson jones jordan kelly kennedy king knight
lane lawrence lawson leonard lewis lloyd logan lopez lucas lynch lynn mason mccarthy miller mills
mitchell moore morgan morris murphy murray nelson newman nichols norris owens palmer parker
patterson payne perez perry peters phillips pierce porter powell price quinn reed reeves reid
reyes reynolds rice richards riley roberts robinson rogers rose ross russell ryan sanders scott
shaw shelton simmons simpson sims smith snyder spencer stevens stewart stone sullivan sutton
taylor thomas thompson todd torres tucker turner vaughn wagner walker wallace walsh ward warren
watson watts weaver webb webster wells west wheeler white wilson wood woods wright
aaron adam adrian alan albert alex alexander alice amanda amy andrea andrew angela anna anne
anthony april arthur ashley audrey barbara benjamin beth betty brandon brenda brian bruce bryan
calvin cameron carl carol caroline catherine charles charlotte cheryl chris christian christina
christine christopher cindy claire clara clarence claude cliff colin connie crystal cynthia dale
dan daniel danny darren dave david dawn debbie deborah debra dennis derek diana diane don donald
donna doris doug douglas dylan earl eddie edith edward edwin eileen elaine eleanor elena
eli elizabeth ellen emily emma eric erica erin ernest esther ethan eugene eva evan evelyn frances
frank fred frederick gabriel gail gary gene george gerald gina glen glenn gloria grace greg
gregory hannah harold harry heather helen henry herbert holly hugh ian irene isaac isabel ivan
jack jackie jacob jacqueline jamie jane janet janice jason jay jean jeff jeffrey jenna jennifer
jeremy jerry jesse jessica jill jimmy joan joanne joel john johnny jon jonathan jose joseph josh
joshua joy joyce juan judith judy julia julie justin karen kate katherine kathleen kathy katie
keith ken kenneth kevin kimberly kyle larry laura lauren leo leon leslie linda lisa lois lori
louis louise lucy luke lydia madison marc marcus margaret maria marie marilyn marion mark marvin
mary matthew maureen max maxine megan melanie melissa michael michelle mike mildred miriam molly
monica nancy naomi natalie nathan neil nicholas nick nicole noah norma norman olivia oscar owen
pam pamela pat patricia patrick paul paula pearl peggy peter phil philip phyllis rachel ralph
randy ray raymond rebecca regina rene rhonda richard rick rita rob robert roberta robin rodney
roger ron ronald rosemary roy ruby ruth sally sam samantha samuel sandra sara sarah sean seth
shane shannon sharon shawn sheila shelly sherry shirley sidney simon sophia stacy stan stanley
stella stephanie stephen steve steven stuart sue susan suzanne sydney sylvia tammy tara ted
teresa terry theodore theresa tiffany tim timothy tina tom tommy tony tracy travis trevor tyler
valerie vanessa vera vernon veronica vicki victor victoria vincent violet virginia vivian wade
walter wanda wayne wendy wesley will william willie wilma yvonne zachary
""".split(whereSeparator: \.isWhitespace).map(String.init))

    /// The system word list, lowercased. Loaded on first use (about 235k words).
    public static let englishWords: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()

    /// A name reduced to its spelling variants: "Lynn" and "Lin" are the same name written
    /// two ways, "Lane" and "Lin" are not. `key`'s consonant skeleton is too lossy here --
    /// it throws away every vowel, so "Lane", "Lin", "Lynn" and "Loon" all collapse to "ln".
    public static func nameKey(_ s: String) -> String {
        var out = ""
        var prev: Character? = nil
        for ch in s.lowercased() {
            let c: Character = ch == "y" ? "i" : ch
            if c == prev { continue }               // "Lynn" -> "lin"
            out.append(c)
            prev = c
        }
        if out.count > 2, out.hasSuffix("e") { out.removeLast() }   // silent "e": "Lane" -> "lan"
        return out
    }

    static func tolerance(_ length: Int) -> Int {
        switch length {
        case ..<4: return 0
        case 4...6: return 1
        case 7...11: return 2
        default: return 3
        }
    }

    /// Consonant skeleton: "Wispr Flow" -> "wsprflw", "Whisper Flow" -> "whsprflw",
    /// "Lin Flow" -> "lnflw", "Line Flow" -> "lnflw". Leading vowel kept; a trailing
    /// consonant is kept too, which the examples here used to drop and get wrong.
    public static func key(_ s: String) -> String {
        var out = ""
        var prev: Character? = nil
        for c in s.lowercased() where c.isLetter || c.isNumber {
            let isVowel = "aeiouy".contains(c)
            if isVowel, !out.isEmpty { continue }
            if c == prev { continue }
            out.append(c)
            prev = c
        }
        return out
    }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    struct Token {
        var text: String
        let isWord: Bool
        /// Opening quotes/brackets glued to the front of a word.
        var leading: String { String(text.prefix { $0.isPunctuation && !"'".contains($0) }) }
        /// Commas, periods, closing quotes glued to the end. Apostrophes stay with the
        /// word ("Claude's"); dots inside a word ("whisper.cpp", "p.m") stay in the core.
        var trailing: String {
            let body = text.dropFirst(leading.count)
            var t = String(body.reversed().prefix { $0.isPunctuation && !"'’".contains($0) }.reversed())
            // A closing quote or a bare possessive apostrophe ("Parakeets'") is trailing too.
            if let last = body.dropLast(t.count).last, "'’".contains(last) { t = String(last) + t }
            return t
        }
        var core: String {
            let start = text.index(text.startIndex, offsetBy: leading.count)
            let end = text.index(text.endIndex, offsetBy: -trailing.count)
            return start <= end ? String(text[start..<end]) : ""
        }
    }

    /// Runs of whitespace and runs of non-whitespace, in order, so the
    /// original spacing (including newlines) survives a rebuild.
    static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord = false
        for c in s {
            let isWordChar = !c.isWhitespace
            if current.isEmpty {
                current.append(c); currentIsWord = isWordChar
            } else if isWordChar == currentIsWord {
                current.append(c)
            } else {
                tokens.append(Token(text: current, isWord: currentIsWord))
                current = String(c); currentIsWord = isWordChar
            }
        }
        if !current.isEmpty { tokens.append(Token(text: current, isWord: currentIsWord)) }
        return tokens
    }
}
