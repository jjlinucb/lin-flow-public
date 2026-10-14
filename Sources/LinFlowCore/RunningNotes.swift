import Foundation

/// Running notes: a few bullets a minute, written while the meeting is still going, the way
/// Wispr Flow's meeting mode does. Every pass hands the model the newest stretch of the live
/// transcript and the notes already taken, and gets back zero to three new bullets, each
/// stamped with where in the meeting it came from and appended to the note's running-notes.md.
/// This is the pure half: which segments a pass reads, when a pass is due, how a pass is written
/// down. The model call is `Summarizer.runningNotes`; the timer lives in the window model.
public enum RunningNotes {
    /// Seconds between passes. A minute is long enough for a point to be made and short enough
    /// that the notes keep up with the call.
    public static var interval: TimeInterval = 60
    /// A pass with less new material than this waits; the model has nothing to say about a
    /// "yeah, okay" and would say it anyway.
    public static var minimumNewWords = 40
    /// One pass reads at most this much. The rest waits for the next pass, oldest first, so a
    /// long silence on the model's side never loses anything, it just catches up.
    public static var maximumWindowWords = 600
    /// The last stretch of the meeting gets a pass with less than the usual minimum.
    public static var finalMinimumWords = 12
    /// How many earlier bullets the model sees, so it does not write the same thing twice.
    public static var contextBullets = 10

    /// The unprocessed segments in time order, capped to a word budget (never a partial
    /// segment, always at least one).
    public static func window(_ segments: [TranscriptSegment], processed: Set<String>, maxWords: Int = maximumWindowWords) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var words = 0
        for s in segments.sorted(by: { $0.start < $1.start }) where !processed.contains(s.id) {
            let n = wordCount(s.text)
            if !out.isEmpty, words + n > maxWords { break }
            out.append(s)
            words += n
        }
        return out
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    public static func wordCount(_ segments: [TranscriptSegment]) -> Int {
        segments.reduce(0) { $0 + wordCount($1.text) }
    }

    /// Whether to run a pass now: enough new words and enough time since the last pass, or
    /// the meeting has ended and anything of substance is still unnoted.
    public static func isDue(newWords: Int, sinceLast: TimeInterval, final: Bool) -> Bool {
        if final { return newWords >= finalMinimumWords }
        return newWords >= minimumNewWords && sinceLast >= interval
    }

    /// One pass as Markdown: a bullet per note, stamped with where the stretch began.
    public static func format(_ bullets: [String], at start: Double) -> String {
        let stamp = TranscriptSegment(start: start, end: start, speaker: "", text: "").timestampLabel
        return bullets.map { "- [\(stamp)] \($0)" }.joined(separator: "\n") + (bullets.isEmpty ? "" : "\n")
    }

    /// The most recent bullets of running-notes.md, stamps removed, as context for the model.
    public static func recent(_ notes: String, count: Int = contextBullets) -> [String] {
        let all = notes.split(separator: "\n").compactMap { line -> String? in
            var s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("- ") || s.hasPrefix("* ") else { return nil }
            s = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("["), let close = s.firstIndex(of: "]") { s = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces) }
            return s.isEmpty ? nil : s
        }
        return Array(all.suffix(count))
    }

    /// What the model gave back, made fit to keep: fragments and labels gone, anything the
    /// stretch never said gone, repeats gone.
    public static func filter(_ bullets: [String], previous: [String], transcript: String) -> [String] {
        dropRepeats(bullets.compactMap(worthKeeping).filter { grounded($0, in: transcript, previous: previous) }, previous: previous)
    }

    /// A note that names a number, a date, a month, a weekday or a person the stretch never
    /// mentioned is an invention, and an invented deadline is worse than no note: on
    /// 2026-09-17 the on-device model produced "Friday, October 18th" and "five deals" for a
    /// transcript with none of those words. Numbers are compared as digits ("two" and "2"
    /// match, "40,000" and "$40,000" match), names and dates as words.
    public static func grounded(_ bullet: String, in transcript: String, previous: [String] = []) -> Bool {
        let sourceWords = vocabulary(of: transcript + " " + previous.joined(separator: " "))
        var sourceNumbers = Set(sourceWords.compactMap(numberValue))
        sourceNumbers.formUnion(sourceWords.filter { $0.allSatisfy(\.isNumber) })
        for (i, raw) in bullet.split(separator: " ").enumerated() {
            let w = String(raw).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard !w.isEmpty else { continue }
            let lower = w.lowercased()
            if let n = numberValue(lower) ?? digits(lower) {
                guard sourceNumbers.contains(n) else { return false }
            } else if dateWords.contains(lower) {
                guard sourceWords.contains(lower) else { return false }
            } else if i > 0, w.first!.isUppercase, !pronouns.contains(w), w.count > 1 {
                guard sourceWords.contains(lower) else { return false }
            } else if i == 0, w.first!.isUppercase, GlossaryMatcher.personalNames.contains(lower) {
                // A sentence's first word is capitalized whatever it is, so only a word that is a
                // known personal name is checked there ("Anna agreed to help" for a stretch with no Anna).
                guard sourceWords.contains(lower) else { return false }
            }
        }
        return true
    }

    /// Every word of a text, lowercased, with the commas inside numbers removed first.
    static func vocabulary(of text: String) -> Set<String> {
        let joined = text.lowercased().replacingOccurrences(of: #"(\d),(\d)"#, with: "$1$2", options: .regularExpression)
        return Set(joined.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// "18th" -> "18", "40,000" -> "40000"; nil when the word is not a number.
    static func digits(_ word: String) -> String? {
        var w = word.replacingOccurrences(of: ",", with: "")
        for suffix in ["st", "nd", "rd", "th"] where w.hasSuffix(suffix) && w.count > suffix.count && w.dropLast(suffix.count).allSatisfy(\.isNumber) { w = String(w.dropLast(suffix.count)) }
        return !w.isEmpty && w.allSatisfy(\.isNumber) ? w : nil
    }

    static let spelled: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70",
        "eighty": "80", "ninety": "90", "hundred": "100", "thousand": "1000", "million": "1000000", "billion": "1000000000",
        "first": "1", "second": "2", "third": "3", "fourth": "4", "fifth": "5", "sixth": "6", "seventh": "7", "eighth": "8", "ninth": "9", "tenth": "10",
    ]
    static func numberValue(_ word: String) -> String? { spelled[word] ?? digits(word) }

    static let dateWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "tomorrow", "yesterday", "tonight",
    ]
    static let pronouns: Set<String> = ["You", "Others", "I", "We", "They", "He", "She", "It", "The", "A", "An", "This", "That", "There", "No", "Yes", "OK"]

    /// A note worth keeping is a sentence, not a label or a fragment. A small model likes to
    /// answer "Task: I" or "Name: Ted": a leading label of up to three words is stripped, and
    /// what is left needs at least five words.
    public static func worthKeeping(_ bullet: String) -> String? {
        var s = bullet.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = s.firstIndex(of: ":") {
            let label = s[..<colon]
            if label.split(separator: " ").count <= 3, label.allSatisfy({ $0.isLetter || $0 == " " }) {
                s = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard wordCount(s) >= 5, s.contains(where: { $0.isLetter }), !s.hasSuffix(":") else { return nil }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// Drops bullets that say what an earlier bullet already says. Two notes are the same when
    /// seven in ten of the shorter one's words (crudely stemmed, so "overviewing" is
    /// "overview") are in the other. Small models repeat themselves in new words.
    public static func dropRepeats(_ bullets: [String], previous: [String]) -> [String] {
        var kept = previous.map(words)
        var out: [String] = []
        for b in bullets {
            let w = words(b)
            guard !w.isEmpty else { continue }
            let repeats = kept.contains { other in
                let smaller = min(w.count, other.count)
                guard smaller > 0 else { return false }
                if w == other { return true }
                return smaller >= 3 && Double(w.intersection(other).count) / Double(smaller) >= 0.7
            }
            guard !repeats else { continue }
            kept.append(w)
            out.append(b)
        }
        return out
    }

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { stem(String($0)) }.filter { !$0.isEmpty })
    }

    static func stem(_ word: String) -> String {
        var s = word
        if s.count > 5, s.hasSuffix("ing") { s.removeLast(3) }
        else if s.count > 4, s.hasSuffix("ed") { s.removeLast(2) }
        else if s.count > 3, s.hasSuffix("s") { s.removeLast() }
        return s
    }
}
