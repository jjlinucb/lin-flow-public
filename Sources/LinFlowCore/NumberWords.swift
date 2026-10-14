import Foundation

/// Spoken numbers as digits: "twenty two" becomes 22, "one two three four five" becomes
/// 1 2 3 4 5. Both engines write numbers as words, and reading a dictated figure back as
/// words is the thing that makes dictated notes feel unfinished.
///
/// The whole difficulty is "one", which is a number half the time and a pronoun the rest
/// ("one of the reasons", "the one that works", "no one knows"). So "one" converts only
/// when the sentence makes it a count: inside a bigger number, inside a run of digits, or
/// in front of a unit. Every other number word converts freely, apart from an ordinal
/// following it ("the twenty second") and hyphenated compounds ("one-on-one"). A scale word
/// with no number in front of it is speech ("a few hundred"), except after "a": "a hundred"
/// is 100.
///
/// Two shapes are written as figures that are not plain counts. A day after a month, or before
/// "of" and a month, is "September 30th" and "the 30th of September"; an ordinal anywhere else
/// stays a word ("my first job"). And a number followed by "point" and digit words is a
/// decimal: "Opus five point five" is "Opus 5.5". John asked for both on 2026-09-29.
public enum NumberWords {
    static let units: [String: Int] = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9]
    static let teens: [String: Int] = ["ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
    static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    static let scales: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]

    /// The scale words that "a" turns into a figure. Not million or billion: "one in a
    /// million" and "thanks a million" are idiom, and 1000000 reads worse than the words.
    static let countedAfterA: Set<String> = ["hundred", "thousand"]

    /// An ordinal right after a number means the number was part of it: "the twenty second".
    static let ordinals: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
        "eighteenth", "nineteenth", "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth",
        "seventieth", "eightieth", "ninetieth", "hundredth", "thousandth", "millionth",
        "half", "halves", "thirds", "quarter", "quarters", "fourths", "fifths", "sixths", "eighths",
    ]

    /// What makes a lone "one" a count rather than a pronoun.
    static let units_of_measure: Set<String> = [
        "percent", "dollar", "dollars", "cent", "cents", "euro", "euros", "pound", "pounds",
        "second", "seconds", "minute", "minutes", "hour", "hours", "day", "days", "week", "weeks",
        "month", "months", "year", "years", "time", "times", "o'clock", "degree", "degrees",
        "mile", "miles", "kilometer", "kilometers", "meter", "meters", "foot", "feet", "inch", "inches",
        "gram", "grams", "kilogram", "kilograms", "ounce", "ounces", "liter", "liters", "gallon", "gallons",
        "byte", "bytes", "kilobyte", "megabyte", "gigabyte", "terabyte", "page", "pages", "point", "points",
        "person", "people", "copy", "copies", "star", "stars", "line", "lines", "word", "words",
    ]

    static let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july",
                                      "august", "september", "october", "november", "december"]

    /// The ordinals a day of the month is made of. "twenty first" is 20 and 1.
    static let dayOrdinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30,
    ]

    /// What may follow "point" in a decimal: "two point oh" is 2.0.
    static let decimalDigits: [String: Int] = units.merging(["oh": 0]) { a, _ in a }

    static func value(_ word: String) -> Int? { units[word] ?? teens[word] ?? tens[word] }

    typealias Token = (range: NSRange, lower: String)

    /// "st", "nd", "rd" or "th": 1st, 22nd, 13th.
    static func ordinalSuffix(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "th" }
        switch n % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    /// Nothing but spaces between tokens `a` and `b`.
    static func spaced(_ tokens: [Token], _ a: Int, _ b: Int, in ns: NSString) -> Bool {
        let from = NSMaxRange(tokens[a].range)
        let gap = ns.substring(with: NSRange(location: from, length: tokens[b].range.location - from))
        return !gap.isEmpty && gap.allSatisfy { $0 == " " }
    }

    /// The day of the month spelled from token `k`, and how many tokens it takes: "thirtieth" is
    /// 30 in one, "twenty first" 21 in two. Nothing past 31.
    static func day(_ tokens: [Token], at k: Int, in ns: NSString) -> (value: Int, count: Int)? {
        guard k < tokens.count else { return nil }
        if let t = tens[tokens[k].lower], t == 20 || t == 30, k + 1 < tokens.count, spaced(tokens, k, k + 1, in: ns),
           let o = dayOrdinals[tokens[k + 1].lower], o <= 9, t + o <= 31 {
            return (t + o, 2)
        }
        if let d = dayOrdinals[tokens[k].lower] { return (d, 1) }
        return nil
    }

    /// A month as the engines write it, capitalized, so "you may first" and "march on" stay words.
    static func isMonth(_ tokens: [Token], _ k: Int, in ns: NSString) -> Bool {
        guard k >= 0, k < tokens.count, months.contains(tokens[k].lower) else { return false }
        return ns.substring(with: tokens[k].range).first?.isUppercase == true
    }

    /// Days written as figures, and the tokens they used: "September thirtieth" and "the
    /// thirtieth of September".
    static func dates(_ tokens: [Token], in ns: NSString) -> (edits: [(NSRange, String)], used: Set<Int>) {
        var edits: [(NSRange, String)] = [], used = Set<Int>()
        for k in tokens.indices where !used.contains(k) {
            var start: Int? = nil
            if isMonth(tokens, k - 1, in: ns), spaced(tokens, k - 1, k, in: ns) {
                start = k                                                   // September thirtieth
            } else if k > 0, tokens[k - 1].lower == "the", let d = day(tokens, at: k, in: ns),
                      k + d.count + 1 < tokens.count, spaced(tokens, k + d.count - 1, k + d.count, in: ns),
                      tokens[k + d.count].lower == "of", isMonth(tokens, k + d.count + 1, in: ns) {
                start = k                                                   // the thirtieth of September
            }
            guard let start, let d = day(tokens, at: start, in: ns) else { continue }
            let last = tokens[start + d.count - 1].range
            let span = NSRange(location: tokens[start].range.location, length: NSMaxRange(last) - tokens[start].range.location)
            edits.append((span, "\(d.value)\(ordinalSuffix(d.value))"))
            for u in start..<(start + d.count) { used.insert(u) }
        }
        return (edits, used)
    }

    /// The digit words after "point" that follow token `end`: "point five" is "5", "point one
    /// four" is "14". Nil when "point" is not there or no digit follows it.
    static func decimal(_ tokens: [Token], after end: Int, used: Set<Int>, in ns: NSString) -> (digits: String, last: Int)? {
        let p = end + 1
        guard p + 1 < tokens.count, tokens[p].lower == "point", spaced(tokens, end, p, in: ns) else { return nil }
        var digits = "", last = p, k = p + 1
        while k < tokens.count, !used.contains(k), let d = decimalDigits[tokens[k].lower], spaced(tokens, last, k, in: ns) {
            digits += String(d); last = k; k += 1
        }
        return digits.isEmpty ? nil : (digits, last)
    }

    static func isNumberWord(_ word: String) -> Bool { value(word) != nil || scales[word] != nil }

    /// The text with spoken numbers written as digits.
    public static func apply(to text: String) -> String {
        guard !text.isEmpty else { return text }
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z']*") else { return text }
        let tokens: [Token] = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            (range: $0.range, lower: ns.substring(with: $0.range).lowercased())
        }
        guard !tokens.isEmpty else { return text }

        let dated = dates(tokens, in: ns)
        var edits = dated.edits
        let used = dated.used
        var i = 0
        while i < tokens.count {
            guard !used.contains(i), isNumberWord(tokens[i].lower) else { i += 1; continue }
            // The longest run of number words, with "and" allowed between two of them.
            var end = i
            while end + 1 < tokens.count, !used.contains(end + 1) {
                let next = tokens[end + 1].lower
                if isNumberWord(next) { end += 1; continue }
                if next == "and", end + 2 < tokens.count, isNumberWord(tokens[end + 2].lower) { end += 2; continue }
                break
            }
            let run = Array(tokens[i...end])
            if let following = end + 1 < tokens.count ? tokens[end + 1].lower : nil, ordinals.contains(following) {
                i = end + 1; continue                                   // "the twenty second"
            }
            if hyphenated(run, in: ns) { i = end + 1; continue }         // "one-on-one"
            // A bare scale word is speech, not a figure: "a few hundred", "thousands of them".
            // After "a" it counts, which John asked for on 2026-09-25: "a hundred" is 100 and
            // "a hundred forty volts" is 140 volts. The "a" goes with it.
            var article: NSRange? = nil
            if scales[run[0].lower] != nil {
                guard countedAfterA.contains(run[0].lower), let a = articleBefore(i, tokens: tokens, in: ns) else { i = end + 1; continue }
                article = a
            }
            // Each number in the run replaces exactly the words that spell it, so the
            // separators between separate numbers ("1, 2, 3") are left as spoken.
            var next = end + 1
            for group in mergeYears(parse(run.map { $0.lower })) {
                let words = run[group.range]
                let first = group.range.lowerBound == 0 ? (article ?? words.first!.range) : words.first!.range
                // The run's last number may go on as a decimal: "five point five" is 5.5, and
                // "one point five" is 1.5 though a lone "one" is otherwise a pronoun.
                if group.range.upperBound == run.count, let d = decimal(tokens, after: end, used: used, in: ns) {
                    let span = NSRange(location: first.location, length: NSMaxRange(tokens[d.last].range) - first.location)
                    edits.append((span, "\(group.value).\(d.digits)"))
                    next = d.last + 1
                    continue
                }
                guard convertible(words.map { $0.lower }, run: run.count, tokens: tokens, at: i + group.range.lowerBound) else { continue }
                let span = NSRange(location: first.location, length: NSMaxRange(words.last!.range) - first.location)
                edits.append((span, String(group.value)))
            }
            i = next
        }
        guard !edits.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for (range, replacement) in edits.sorted(by: { $0.0.location < $1.0.location }).reversed() { out.replaceCharacters(in: range, with: replacement) }
        return out as String
    }

    /// A lone "one" is only a number when it is counting something.
    static func convertible(_ words: [String], run: Int, tokens: [Token], at index: Int) -> Bool {
        guard words.count == 1, words[0] == "one", run == 1 else { return true }
        guard index + 1 < tokens.count else { return false }
        return units_of_measure.contains(tokens[index + 1].lower)
    }

    /// The "a" right before token `index`, with nothing but spaces between the two.
    static func articleBefore(_ index: Int, tokens: [(range: NSRange, lower: String)], in ns: NSString) -> NSRange? {
        guard index > 0, tokens[index - 1].lower == "a" else { return nil }
        let a = tokens[index - 1].range
        let gap = ns.substring(with: NSRange(location: NSMaxRange(a), length: tokens[index].range.location - NSMaxRange(a)))
        return !gap.isEmpty && gap.allSatisfy({ $0 == " " }) ? a : nil
    }

    /// True when the run sits inside a hyphenated compound.
    static func hyphenated(_ run: [(range: NSRange, lower: String)], in ns: NSString) -> Bool {
        let before = run[0].range.location - 1
        let after = NSMaxRange(run[run.count - 1].range)
        if before >= 0, ns.substring(with: NSRange(location: before, length: 1)) == "-" { return true }
        if after < ns.length, ns.substring(with: NSRange(location: after, length: 1)) == "-" { return true }
        return false
    }

    struct Group { var value: Int; var range: Range<Int> }

    /// A year said as two numbers is one number: "nineteen eighty four" is 1984 and
    /// "twenty twenty six" is 2026. Kept narrow, because "twenty thirty" is usually a range.
    static func mergeYears(_ groups: [Group]) -> [Group] {
        guard groups.count >= 2 else { return groups }
        var out: [Group] = []
        var i = 0
        while i < groups.count {
            let a = groups[i]
            if i + 1 < groups.count {
                let b = groups[i + 1]
                let century = (13...19).contains(a.value) || a.value == 20
                let decade = a.value == 20 ? (20...29).contains(b.value) : (20...99).contains(b.value)
                if century, decade, a.range.upperBound == b.range.lowerBound {
                    out.append(Group(value: a.value * 100 + b.value, range: a.range.lowerBound..<b.range.upperBound))
                    i += 2
                    continue
                }
            }
            out.append(a)
            i += 1
        }
        return out
    }

    /// Splits a run of number words into the numbers it actually spells. "twenty two" is one
    /// number, "one two three" is three, "two thousand twenty six" is one, and a word that
    /// cannot join what is already built starts a new number.
    static func parse(_ words: [String]) -> [Group] {
        var out: [Group] = []
        var start = 0, taken = 0, total = 0, current = 0
        // The last of thousand, million and billion this number used. Each one after it has to
        // be smaller, so a second "thousand" belongs to the next number.
        var smallestBig: Int? = nil
        var ones = false, tenslot = false, hundreds = false, pending = false
        // Ends the number at the last word it took, so an "and" between two numbers stays in
        // the text: "panels one and two" is "panels 1 and 2", not "panels 1 2".
        func flush() {
            guard taken > start, pending else { return }
            out.append(Group(value: total + current, range: start..<taken))
            total = 0; current = 0; smallestBig = nil
            ones = false; tenslot = false; hundreds = false; pending = false
        }
        var i = 0
        while i < words.count {
            let w = words[i]
            if w == "and" { i += 1; continue }
            if let scale = scales[w] {
                if scale == 100 {
                    current = (current == 0 ? 1 : current) * 100
                    hundreds = true; ones = false; tenslot = false
                } else {
                    total += (current == 0 && total == 0 ? 1 : current) * scale
                    current = 0; ones = false; tenslot = false; hundreds = false
                    smallestBig = scale
                }
                pending = true
                i += 1; taken = i
                continue
            }
            guard let v = value(w) else { break }
            let above = hundreds || total > 0
            var canJoin: Bool
            if tens[w] != nil { canJoin = !tenslot && !ones && above }
            else if teens[w] != nil { canJoin = !ones && !tenslot && above }
            else { canJoin = !ones && (tenslot || above) }
            // A number never says the same place twice, so a word that leads into one starts
            // the next number: "eight hundred and seven hundred" is 800 and 700, not 80700.
            if canJoin, repeatsAPlace(words, from: i, ones: ones, tenslot: tenslot, hundreds: hundreds, smallestBig: smallestBig) {
                canJoin = false
            }
            if pending, !canJoin { flush(); start = i }
            current += v
            if tens[w] != nil { tenslot = true } else { ones = true }
            pending = true
            i += 1; taken = i
        }
        flush()
        return out
    }

    /// True when joining `words[index]` to the number being built would give that number a
    /// place it already has: a second hundreds, or a thousand after a thousand. It looks only
    /// as far as the words could still belong to this number, so "two thousand five, three
    /// thousand" is still 2005 and 3000.
    static func repeatsAPlace(_ words: [String], from index: Int, ones: Bool, tenslot: Bool, hundreds: Bool, smallestBig: Int?) -> Bool {
        var ones = ones, tenslot = tenslot, hundreds = hundreds
        if tens[words[index]] != nil { tenslot = true } else { ones = true }
        for w in words[(index + 1)...] {
            if w == "and" { continue }
            if let scale = scales[w] {
                if scale != 100 { return smallestBig.map { scale >= $0 } ?? false }
                if hundreds { return true }
                hundreds = true; ones = false; tenslot = false
                continue
            }
            // A word that cannot join ends this number, and nothing after it is this number's.
            let joins = tens[w] != nil || teens[w] != nil ? !tenslot && !ones : !ones
            if !joins { return false }
            if tens[w] != nil { tenslot = true } else { ones = true }
        }
        return false
    }
}
