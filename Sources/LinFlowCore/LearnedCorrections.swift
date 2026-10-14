import Foundation

/// Turns "what Lin Flow wrote" and "what the text says now" into dictionary corrections.
/// Wispr Flow does this silently; here the same thing happens either automatically or as a
/// suggestion, per `Settings.learnCorrections`.
///
/// The hard part is telling a mishearing from an edit. "K Wynn E D F" becoming "kkwinedf" is
/// worth learning forever; "Thursday" becoming "Friday" is a change of mind and would be a
/// destructive rule. The test is the consonant skeleton (the same one the fuzzy matcher uses)
/// plus an edit-distance fallback, so only pairs that plausibly sound alike are kept.
public enum LearnedCorrections {
    /// Words too common to ever become a rule: one bad auto-add here would rewrite everything.
    static let stopwords: Set<String> = [
        "the", "and", "but", "for", "not", "you", "your", "our", "its", "it's", "this", "that", "these", "those",
        "with", "from", "have", "has", "had", "was", "were", "will", "would", "should", "could", "can", "are",
        "been", "being", "they", "them", "their", "there", "then", "than", "when", "what", "who", "how", "why",
        "all", "any", "some", "one", "two", "just", "like", "get", "got", "make", "made", "want", "know", "think",
        "now", "here", "out", "about", "into", "over", "more", "most", "very", "too", "also", "yes", "yeah", "okay",
    ]

    /// At most this many rules from one dictation: a heavily rewritten one is not a mishearing.
    static let maxPerDictation = 3
    /// Longest phrase either side of a rule may be.
    static let maxPhraseWords = 6

    /// How much an edit is worth: a rule to write, or a rule to offer.
    public enum Confidence: Equatable { case apply, suggest }

    /// A fix too distant to write, but too clean to throw away.
    ///
    /// A badly misheard name is *by definition* phonetically distant -- "Duarte" came back as
    /// "Wort", four edits on a four-letter word, different consonant skeleton -- so `plausible`
    /// can never accept one, and before this every such correction vanished without a word.
    /// The narrow shape that survives here: exactly one word swapped for exactly one word, and
    /// the replacement is capitalized, which is what a name looks like and what ASR actually
    /// gets wrong. It is only ever offered, never applied, so a wrong guess costs one click
    /// rather than every future dictation.
    public static func worthOffering(from: String, to: String) -> Bool {
        let f = from.trimmingCharacters(in: .punctuationCharacters)
        let t = to.trimmingCharacters(in: .punctuationCharacters)
        guard !f.contains(" "), !t.contains(" ") else { return false }
        guard f.count >= 4, t.count >= 4, f.lowercased() != t.lowercased() else { return false }
        guard !stopwords.contains(f.lowercased()) else { return false }
        guard let head = t.first, head.isUppercase else { return false }
        let nameish: (Character) -> Bool = { $0.isLetter || $0 == "'" || $0 == "\u{2019}" || $0 == "-" }
        return f.allSatisfy(nameish) && t.allSatisfy(nameish)
    }

    /// Every rule an edit implies, each marked with how sure Lin Flow is of it.
    public static func scored(wrote: String, now: String, existing: [Replacement]) -> [(replacement: Replacement, confidence: Confidence)] {
        let a = words(wrote), b = words(now)
        guard !a.isEmpty, !b.isEmpty, a != b else { return [] }
        // A near-total rewrite is not a set of mishearings.
        guard a.count <= 400, b.count <= 400 else { return [] }
        var out: [(replacement: Replacement, confidence: Confidence)] = []
        var seen = Set(existing.map { $0.id })
        for (ra, rb) in substitutions(a, b) {
            guard !ra.isEmpty, !rb.isEmpty else { continue }
            guard ra.count <= maxPhraseWords, rb.count <= maxPhraseWords else { continue }
            let from = trimPhrase(a[ra].joined(separator: " "))
            let to = trimPhrase(b[rb].joined(separator: " "))
            let confidence: Confidence
            if plausible(from: from, to: to) { confidence = .apply }
            else if worthOffering(from: from, to: to) { confidence = .suggest }
            else { continue }
            // Already handled, either by this exact rule or by the rules as a whole.
            let candidate = Replacement(from: from, to: to, learned: true)
            guard !seen.contains(candidate.id) else { continue }
            guard TextCleaner.applyReplacements(from, existing) != to else { continue }
            seen.insert(candidate.id)
            out.append((candidate, confidence))
            if out.count == maxPerDictation { break }
        }
        return out
    }

    /// Whether a phrase is made of ordinary English words -- words John might have meant.
    ///
    /// The system word list is the same one the fuzzy matcher has always used to keep
    /// "cloud" and "clause" from becoming "Claude". Two things about it shape this test.
    /// It is web2, which stops in 1934: "laptop" and "fridge" are simply absent, so this is
    /// a floor and not a fence. And it lists few inflections -- "fail" is there, "failed" is
    /// not -- which is why `isEnglish` strips the common endings; an inflected word is still
    /// a word he might have meant, and "failed" => "filled" is as destructive a rule as
    /// "cloud" => "Claude".
    ///
    /// A single letter never counts, whatever the list says, and a phrase carrying one is
    /// not English prose: that is how "K Wynn E D F" => "kkwinedf", the rule this whole
    /// feature was built for, stays learnable even though "lynn" is in the list. A phrase
    /// also needs one word of real length -- "Q 3" and "10 1" are not English either way.
    public static func everydayEnglish(_ phrase: String) -> Bool {
        let words = phrase.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\u{2019}")) }
        guard words.contains(where: { $0.count >= 3 }) else { return false }
        return words.allSatisfy { $0.count >= 2 && isEnglish($0) }
    }

    /// One word, or an ordinary inflection of one.
    static func isEnglish(_ w: String) -> Bool {
        let dict = GlossaryMatcher.englishWords
        if dict.contains(w) { return true }
        for suffix in ["s", "es", "ed", "d", "ing"] where w.count > suffix.count + 2 && w.hasSuffix(suffix) {
            let stem = String(w.dropLast(suffix.count))
            if dict.contains(stem) { return true }
            if dict.contains(stem + "e") { return true }                      // "saving" -> "save"
            if let last = stem.last, stem.dropLast().last == last,            // "stopped" -> "stop"
               dict.contains(String(stem.dropLast())) { return true }
            if stem.hasSuffix("i"), dict.contains(stem.dropLast() + "y") { return true }   // "tried" -> "try"
        }
        return false
    }

    /// Whether one phrase plausibly became the other by mishearing rather than by editing.
    public static func plausible(from: String, to: String) -> Bool {
        let f = from.lowercased(), t = to.lowercased()
        guard !f.isEmpty, !t.isEmpty, f != t || from != to else { return false }
        // Something has to be left after punctuation, and a rule on punctuation alone is noise.
        guard from.contains(where: { $0.isLetter || $0.isNumber }), to.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        let fWords = f.split(separator: " ").map(String.init)
        // A single short or everyday word is too dangerous to bind globally.
        if fWords.count == 1 {
            guard f.count >= 4, !stopwords.contains(f.trimmingCharacters(in: .punctuationCharacters)) else { return false }
        }
        // Same letters and digits in the same order: only the spacing or the punctuation
        // moved. "Q 3" -> "Q3", "10 1" -> "10/1", "spider riders" -> "spiderriders",
        // "cant" -> "can't". A rule that keeps every letter cannot destroy a word.
        let body: (String) -> String = { $0.filter { $0.isLetter || $0.isNumber } }
        if body(f) == body(t), f != t { return true }
        // An everyday English word on the left is a word John might have meant, so a global
        // rule on it rewrites his own writing. On 2026-09-18 the dictionary held
        // "cloud => Claude", "clod => Claude" and "threat => thread", all written by this
        // function and all firing on every dictation: "I saved it to the cloud" came out as
        // "I saved it to the Claude". The skeleton test is what let them in -- key("cloud")
        // and key("claude") are both "cld" -- and the same test is what makes "k wynn e d f"
        // work, so it stays; what it may no longer do is bind an ordinary word. The fuzzy
        // matcher has refused to touch a dictionary word since it was written and names
        // "cloud" and "clause" as the reason; the learner was simply never given the guard.
        // A pair refused here is not lost: it falls through to `worthOffering`, where it is
        // shown once and costs a click rather than every future dictation.
        //
        // The one everyday word worth binding is a name spelled another way. "Lynn" => "Lin"
        // is John's own rule, and "lynn" is in that 1934 list by accident. `nameKey` is the
        // fuzzy matcher's test for one name written two ways -- it folds "y" to "i",
        // collapses doubles and drops a silent "e" -- and the replacement has to look like a
        // name. "cloud" and "Claude" are not respellings of each other ("cloud" against
        // "claud"), nor are "Claudia" and "Claude", so neither comes back in this way.
        let sameName = to.first?.isUppercase == true
            && GlossaryMatcher.nameKey(f) == GlossaryMatcher.nameKey(t)
        guard !everydayEnglish(from) || sameName else { return false }
        if f == t { return true }                                        // capitalization only
        // The consonant skeleton is what makes "k wynn e d f" and "kkwinedf" the same word.
        if GlossaryMatcher.key(f) == GlossaryMatcher.key(t) { return true }
        let distance = GlossaryMatcher.levenshtein(f, t)
        return distance <= GlossaryMatcher.tolerance(min(f.count, t.count))
    }

    /// Contiguous runs where the two word lists disagree, as (range in a, range in b).
    static func substitutions(_ a: [String], _ b: [String]) -> [(Range<Int>, Range<Int>)] {
        // Longest common subsequence over words, then the gaps between the matches.
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Range<Int>, Range<Int>)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { i += 1; j += 1; continue }
            let startI = i, startJ = j
            while i < a.count || j < b.count {
                if i < a.count, j < b.count, a[i] == b[j] { break }
                if j >= b.count { i += 1 }
                else if i >= a.count { j += 1 }
                else if table[i + 1][j] >= table[i][j + 1] { i += 1 }
                else { j += 1 }
            }
            pairs.append((startI..<i, startJ..<j))
        }
        return pairs
    }

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    /// Drops the punctuation a phrase picked up from its sentence. Inner marks survive
    /// ("whisper.cpp"), and "#" is kept at either end so "C#" stays itself.
    static func trimPhrase(_ s: String) -> String {
        var t = Substring(s)
        while let f = t.first, !f.isLetter, !f.isNumber, f != "#" { t = t.dropFirst() }
        while let l = t.last, !l.isLetter, !l.isNumber, l != "#" { t = t.dropLast() }
        return String(t)
    }
}


/// Applies the learning setting to one edit, and holds suggestions until they are answered.
public enum CorrectionLearning {
    public static let didChange = Notification.Name("LinFlow.Corrections.didChange")
    /// Posted with the `Outcome` in `userInfo["outcome"]` whenever an edit taught something.
    /// The dictation lands in some other app with the window shut, so without this a learned
    /// rule existed only as a line in the log and John had no way to know it had happened.
    public static let didLearn = Notification.Name("LinFlow.Corrections.didLearn")
    /// Posted when an edit WAS seen but produced no rule, carrying `from`/`to` in `userInfo`
    /// when the edit was one clean word-for-word change. A dictionary that never grows looks
    /// exactly like a readback that never runs; this is what tells the two apart on screen,
    /// and it gives the one case worth keeping a way in that costs a single click.
    public static let didDecline = Notification.Name("LinFlow.Corrections.didDecline")
    static let pendingURL = ModelCatalog.appSupportDir.appendingPathComponent("pending-corrections.json")

    /// What came of an edit: rules added outright, and rules waiting to be confirmed.
    public struct Outcome: Equatable {
        public var added: [Replacement] = []
        public var suggested: [Replacement] = []
        public var isEmpty: Bool { added.isEmpty && suggested.isEmpty }
        public init(added: [Replacement] = [], suggested: [Replacement] = []) {
            self.added = added
            self.suggested = suggested
        }
    }

    @discardableResult
    public static func handle(wrote: String, now: String, mode: LearnMode) -> Outcome {
        guard mode != .off else { return Outcome() }
        let existing = Glossary.loadReplacements()
        var scored = LearnedCorrections.scored(wrote: wrote, now: now, existing: existing)
        // Never suggest the same thing twice.
        let waiting = Set(pending().map { $0.id })
        scored.removeAll { waiting.contains($0.replacement.id) }
        guard !scored.isEmpty else {
            decline(wrote: wrote, now: now)
            return Outcome()
        }
        // A rule Lin Flow is sure of goes straight in; one it only suspects waits for a click.
        // "ask" adds caution and never removes it, so there everything waits.
        let confident = mode == .auto ? scored.filter { $0.confidence == .apply }.map(\.replacement) : []
        let offered = scored.filter { mode == .ask || $0.confidence == .suggest }.map(\.replacement)
        if !confident.isEmpty {
            Glossary.saveReplacements(existing + confident)
            for c in confident { Log.info("learned correction: \(c.from) => \(c.to)") }
        }
        if !offered.isEmpty {
            savePending(pending() + offered)
            for c in offered { Log.info("suggested correction: \(c.from) => \(c.to)") }
        }
        return announce(Outcome(added: confident, suggested: offered))
    }

    /// The one thing that changed in an edit, when exactly one thing did.
    ///
    /// The span on each side may be several words, and that matters more than it sounds: the
    /// commonest way a name is misheard is as one glued word, so the fix splits it in two.
    /// "Marisvo" -> "Marisa Vuong" on 2026-09-14 was refused by both learning tiers AND left
    /// unnamed here, because this used to insist on one word for one word. It is exactly the
    /// correction worth keeping.
    ///
    /// Used only to say what was seen. A misheard name ("Wort" -> "Duarte") and a plain retype
    /// ("roles" -> "departmetns") are indistinguishable here on purpose: this decides nothing,
    /// it shows John the pair and lets him judge it.
    public static func lonePair(wrote: String, now: String) -> (from: String, to: String)? {
        let a = LearnedCorrections.words(wrote), b = LearnedCorrections.words(now)
        guard !a.isEmpty, !b.isEmpty, a != b, a.count <= 400, b.count <= 400 else { return nil }
        let subs = LearnedCorrections.substitutions(a, b)
        guard subs.count == 1, let (ra, rb) = subs.first else { return nil }
        guard !ra.isEmpty, !rb.isEmpty,
              ra.count <= LearnedCorrections.maxPhraseWords,
              rb.count <= LearnedCorrections.maxPhraseWords else { return nil }
        let from = LearnedCorrections.trimPhrase(a[ra].joined(separator: " "))
        let to = LearnedCorrections.trimPhrase(b[rb].joined(separator: " "))
        guard !from.isEmpty, !to.isEmpty else { return nil }
        let f = from.lowercased(), t = to.lowercased()
        guard f != t else { return nil }
        // Carrying on typing after a dictation reads as a substitution, because the last word
        // carried a full stop and the new words did not: "Ask John." -> "Ask John about it."
        // arrives here as "John" -> "John about it". Continuing a sentence is not a correction.
        guard !t.hasPrefix(f + " "), !f.hasPrefix(t + " ") else { return nil }
        return (from, to)
    }

    /// An edit was seen and refused. Say so: silence here is what made the dictionary feel
    /// broken even while the readback was working.
    private static func decline(wrote: String, now: String) {
        guard let pair = lonePair(wrote: wrote, now: now) else {
            Log.info("readback: edit seen but nothing learnable in it")
            return
        }
        Log.info("declined correction: \(pair.from) => \(pair.to) (too far apart to learn on its own)")
        guard worthShowing(pair.from, pair.to) else { return }
        // Keep it as well as show it. The toast lasts 12 seconds and John is mid-sentence by
        // definition -- that is the entire premise of the readback -- so a pair that lived
        // only on screen was a pair he lost. On 2026-09-14 the chain finally ran clean on
        // "Marissa Wang" => "Marisa Vuong", the toast went up, and the correction still
        // evaporated. It now waits in the Dictionary's Suggested row until he answers it,
        // exactly like a rule that arrived through `scored`. Clicking the toast accepts it,
        // and `accept` dismisses the pending copy, so the two paths cannot disagree.
        let candidate = Replacement(from: pair.from, to: pair.to, learned: true)
        if let list = merging(candidate, into: pending(), accepted: Glossary.loadReplacements()) {
            savePending(list)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didDecline, object: nil,
                                            userInfo: ["from": pair.from, "to": pair.to])
        }
    }

    /// Whether a refused pair has earned a pop-up, as opposed to a line in the log. Every
    /// decline is logged; only one that could plausibly be a misheard word interrupts John.
    /// "go" -> "do" reached the screen on 2026-09-14, and a toast that is usually noise is a
    /// toast he stops reading -- which costs more than the occasional missed offer.
    public static func worthShowing(_ from: String, _ to: String) -> Bool {
        let fromTrimmed = LearnedCorrections.trimPhrase(from)
        let toTrimmed = LearnedCorrections.trimPhrase(to)
        let f = fromTrimmed.lowercased(), t = toTrimmed.lowercased()
        guard !f.isEmpty, !t.isEmpty, f != t else { return false }
        guard !LearnedCorrections.stopwords.contains(f), !LearnedCorrections.stopwords.contains(t) else { return false }
        // A capitalized replacement is what a name looks like, and a misheard name is the
        // entire point of this path. "Dor" -> "Duarte" is three letters becoming six and has
        // to get through; "go" -> "do" must not. A length floor cannot tell those apart, and
        // on 2026-09-14 a four-character floor -- added that same day to stop "go" -> "do" --
        // silently refused "Dor" -> "Duarte" while John was sitting there testing it.
        // ...but the replacement still has to be long enough to be a name. Dictated text is
        // capitalized at the start of every sentence, so without this floor the escape hatch
        // covers the single commonest position for a change of mind: "We can push it to
        // Friday." retyped as "He can push it to Friday." offered "We" => "He", and accepting
        // that writes a case-insensitive whole-word rule that turns every future "we" into
        // "He". "Dor" => "Duarte" still gets through, because the short side is the misheard
        // one and the floor is on the replacement.
        // A misheard name or term is short. A retyped sentence is not, and the waiting list
        // on 2026-09-18 was four entries long with nothing in it worth keeping: "growth" =>
        // "grove", "fruit" => "fridge", "Let's add them to" => "What's item", "I will charge
        // my laptop" => "passed sp". The last two are a readback catching John mid-retype,
        // and one stray click on either writes a rule that mangles every future dictation.
        guard LearnedCorrections.words(fromTrimmed).count <= 3,
              LearnedCorrections.words(toTrimmed).count <= 3 else { return false }
        if let head = toTrimmed.first, head.isUppercase, t.count >= 4 { return true }
        // Lowercase on both sides: a short swap is a change of mind far more often than a
        // mishearing, and it is the one a global rule would damage most widely.
        // ...and both sides being ordinary English is the signature of a change of mind.
        // "growth" => "grove" and "fruit" => "fridge" were both offered this way. A misheard
        // word is usually not a word at all ("triadge", "Brona", "Marisvo"), and when it is
        // one, the fix is a name, which the capitalized path above already covers.
        guard !LearnedCorrections.everydayEnglish(fromTrimmed) else { return false }
        return f.count >= 4 && t.count >= 4
    }

    /// The waiting list as it should be written once a refused pair arrives, or nil to leave
    /// it alone. Pure, because the real one writes to John's live pending-corrections.json
    /// and no test may go near that.
    ///
    /// Replace rather than skip when the same left side is already waiting with a different
    /// right side. `Replacement.id` is the left side alone, and keeping the watch alive after
    /// an edit that taught nothing -- added the same day -- makes several declines per
    /// dictation the normal case rather than an edge one. Skipping let the first win
    /// permanently, so "Marisvo" caught mid-word as "Marisa V" would squat the slot, the
    /// finished "Marisa Vuong" would be dropped as a duplicate, and the truncated pair would
    /// sit in the Suggested row waiting to be accepted by mistake. The newest reading is the
    /// one that saw him stop typing.
    public static func merging(_ candidate: Replacement, into waiting: [Replacement],
                               accepted: [Replacement]) -> [Replacement]? {
        // A rule John has already accepted wins: never reopen a decision he made.
        guard !accepted.contains(where: { $0.id == candidate.id }) else { return nil }
        guard let i = waiting.firstIndex(where: { $0.id == candidate.id }) else { return waiting + [candidate] }
        guard waiting[i].to != candidate.to else { return nil }
        var out = waiting
        out[i] = candidate
        return out
    }

    /// Tells the app what just happened so it can say so on screen.
    @discardableResult
    private static func announce(_ outcome: Outcome) -> Outcome {
        guard !outcome.isEmpty else { return outcome }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didLearn, object: nil, userInfo: ["outcome": outcome])
        }
        return outcome
    }

    // MARK: the waiting list

    public static func pending() -> [Replacement] {
        guard let data = try? Data(contentsOf: pendingURL),
              let list = try? JSONDecoder().decode([Replacement].self, from: data) else { return [] }
        return list
    }

    public static func savePending(_ list: [Replacement]) {
        try? FileManager.default.createDirectory(at: pendingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(list) { try? data.write(to: pendingURL, options: .atomic) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    /// Accepts a suggestion into the corrections list.
    public static func accept(_ replacement: Replacement) {
        let existing = Glossary.loadReplacements()
        if !existing.contains(where: { $0.id == replacement.id }) {
            Glossary.saveReplacements(existing + [replacement])
        }
        dismiss(replacement)
    }

    public static func dismiss(_ replacement: Replacement) {
        savePending(pending().filter { $0.id != replacement.id })
    }
}
