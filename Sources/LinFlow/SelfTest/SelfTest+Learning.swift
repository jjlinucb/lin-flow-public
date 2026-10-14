import Foundation
import LinFlowCore

extension SelfTest {
    /// Learning from edits: the readback, the two learning tiers, the pop-up gate, the waiting list.
    static func learning() {
        // learning corrections from an edit
        /// The rules Lin Flow would write by itself, which is what `handle` does with the `apply` tier.
        func learned(_ wrote: String, _ now: String, _ existing: [Replacement] = []) -> String {
            LearnedCorrections.scored(wrote: wrote, now: now, existing: existing)
                .filter { $0.confidence == .apply }.map { "\($0.replacement.from)=>\($0.replacement.to)" }.joined(separator: "|")
        }
        expect(learned("My GitHub is K Wynn E D F.", "My GitHub is kkwinedf."), "K Wynn E D F=>kkwinedf", "learn: John's own case, five words to one")
        expect(learned("Ask John Lynn about it.", "Ask John Lin about it."), "Lynn=>Lin", "learn: one word inside a sentence")
        expect(learned("It runs on work brain.", "It runs on WORKBRAIN."), "work brain=>WORKBRAIN", "learn: glued form")
        expect(learned("Send it to github.", "Send it to GitHub."), "github=>GitHub", "learn: capitalization only")
        expect(learned("Let's meet Thursday.", "Let's meet Friday."), "", "learn: a change of mind is not a mishearing")
        expect(learned("The build is green.", "The build is broken."), "", "learn: unrelated word rejected")
        expect(learned("I want the report.", "I want that report."), "", "learn: stopword never becomes a rule")
        expect(learned("Ship it now.", "Ship it."), "", "learn: a deletion is not a correction")
        expect(learned("Ask John Lynn about it.", "Ask John Lin about it.", [Replacement(from: "Lynn", to: "Lin")]), "", "learn: existing rule not repeated")
        expect(learned("Ask Lynn about it.", "Ask Lin about it.", [Replacement(from: "Lynn", to: "Lin")]), "", "learn: covered by the rules as a whole")
        expect(learned("A totally different sentence entirely.", "Nothing whatsoever alike here now."), "", "learn: wholesale rewrite yields nothing")
        expect(LearnedCorrections.scored(wrote: "one two three", now: "one two three", existing: []).isEmpty, "learn: no edit, no rule")
        expect(LearnedCorrections.plausible(from: "Claudea", to: "Claude"), "learn: plausible mishearing")
        // The cleaner check above says "Claudia is not Claude" and the fuzzy matcher has
        // always honoured it; the learner would happily have bound the two globally.
        expect(!LearnedCorrections.plausible(from: "Claudia", to: "Claude"), "learn: an everyday word is not bound")
        expect(!LearnedCorrections.plausible(from: "a", to: "the"), "learn: single short word rejected")
        expect(!LearnedCorrections.plausible(from: ".", to: "?"), "learn: punctuation only rejected")

        // 2026-09-18: three rules this function wrote by itself, found live in John's
        // dictionary, each firing on every dictation. "I saved it to the cloud." came out
        // as "I saved it to the Claude." An everyday word is a word he might have meant.
        expect(!LearnedCorrections.plausible(from: "cloud", to: "Claude"), "learn: cloud never becomes Claude")
        expect(!LearnedCorrections.plausible(from: "clod", to: "Claude"), "learn: clod never becomes Claude")
        expect(!LearnedCorrections.plausible(from: "threat", to: "thread"), "learn: threat never becomes thread")
        expect(!LearnedCorrections.plausible(from: "clause", to: "Claude"), "learn: the other word the matcher protects")
        expect(!LearnedCorrections.plausible(from: "failed", to: "filled"), "learn: an inflection is a word too")
        expect(!LearnedCorrections.plausible(from: "saving", to: "shaving"), "learn: and so is a participle")
        expect(!LearnedCorrections.plausible(from: "loose", to: "lose"), "learn: a respelling still has to be a name")
        expect(learned("I saved it to the cloud.", "I saved it to Claude."), "", "learn: the live case, end to end")
        // ...and the rules that must survive it.
        expect(LearnedCorrections.plausible(from: "Lynn", to: "Lin"), "learn: one name spelled two ways")
        expect(LearnedCorrections.plausible(from: "Marissa", to: "Marisa"), "learn: a misheard name is not a word")
        expect(LearnedCorrections.plausible(from: "triadge", to: "triage"), "learn: nor is a mangled one")
        expect(LearnedCorrections.plausible(from: "Q 3", to: "Q3"), "learn: single letters are not English prose")
        expect(LearnedCorrections.plausible(from: "spider riders", to: "spiderriders"),
               "learn: same letters, only the spacing moved")
        expect(LearnedCorrections.plausible(from: "cant", to: "can't"), "learn: same letters, only the apostrophe")
        expect(!LearnedCorrections.everydayEnglish("K Wynn E D F"), "learn: a spelled-out phrase is not prose")
        expect(LearnedCorrections.everydayEnglish("like that"), "learn: two ordinary words are prose")
        expect(!LearnedCorrections.everydayEnglish("Marisvo"), "learn: a mishearing is not prose")
        // the learned flag survives the corrections file
        let mixed = [Replacement(from: "wisper flow", to: "Wispr Flow"), Replacement(from: "K Wynn E D F", to: "kkwinedf", learned: true)]
        let file = Glossary.replacementsFile(mixed, keeping: "")
        expect(file.contains("\nwisper flow => Wispr Flow\n") && file.contains("\nK Wynn E D F => kkwinedf\t# learned\n"),
               "learn: a learned rule is marked in the file")
        expect(TextCleaner.applyReplacements("my github is k wynn e d f", mixed), "my github is kkwinedf", "learn: a learned rule applies like any other")

        // The Dictionary reads newest-learned first, then the rules John wrote, in his order.
        // Recency is file order: every rule is appended, so the last learned line is the newest.
        let ordered = Glossary.displayOrder([
            Replacement(from: "Lynn", to: "Lin"),
            Replacement(from: "triadge", to: "triage", learned: true),
            Replacement(from: "Vin", to: "Vinh"),
            Replacement(from: "Brona", to: "Verona", learned: true),
        ])
        expect(ordered.map(\.from).joined(separator: ","), "Brona,triadge,Lynn,Vin", "dictionary: newest learned first")
        expect(Glossary.displayOrder(mixed).map(\.from).joined(separator: ","), "K Wynn E D F,wisper flow", "dictionary: a learned rule outranks a written one")
        expect(Glossary.displayOrder([]).isEmpty, "dictionary: nothing to order")

        // finding the pasted phrase again in the field
        expect(PasteWatcher.editedVersion(of: "Ask John Lynn.", in: "Ask John Lynn.") == nil, "readback: unchanged means nothing to learn")
        expect(PasteWatcher.editedVersion(of: "Ask John Lynn.", in: "Ask John Lin.") ?? "", "Ask John Lin.", "readback: short field compared whole")
        expect(PasteWatcher.editedVersion(of: "Ask John Lynn.", in: "") == nil, "readback: emptied field")
        let long = String(repeating: "Filler words to pad the document out. ", count: 30)
        expect(PasteWatcher.editedVersion(of: "the quarterly sensor platform review", in: long + "the quarterly sensor platform preview " + long) ?? "",
               "the quarterly sensor platform preview", "readback: phrase located inside a long document")
        expect(PasteWatcher.editedVersion(of: "the quarterly sensor platform review", in: long + long) == nil, "readback: phrase gone from a long document")
        expect(PasteWatcher.wordDistance(["a", "b", "c"], ["a", "x", "c"]) == 1, "readback: word distance")
        // Hitting send empties the composer and the app puts its placeholder there; that is
        // not an edit of the dictation, and learning from it would poison the dictionary.
        expect(PasteWatcher.editedVersion(of: "You can merge it in now.", in: "Type / for commands") == nil,
               "readback: a composer placeholder is not an edit")
        expect(PasteWatcher.editedVersion(of: "Ask John Lynn.", in: "Message #general") == nil,
               "readback: an unrelated field is not an edit")
        expect(PasteWatcher.editedVersion(of: "Hey, change the name Justin.", in: "Hey, change the name Justine.") ?? "",
               "Hey, change the name Justine.", "readback: one word fixed still learns")
        expect(PasteWatcher.editedVersion(of: "Ask John Lynn.", in: "Totally different words here now.") == nil,
               "readback: a wholesale retype is not an edit")
        // 2026-09-14: John dictated his wife's name to test it and fixed both words. Two words
        // means a word budget of one, so the word check can never pass; characters can.
        expect(PasteWatcher.editedVersion(of: "Merissa Wong.", in: "Marisa Vuong") ?? "", "Marisa Vuong",
               "readback: a first and last name fixed at once")
        expect(PasteWatcher.editedVersion(of: "Marisvo.", in: "Marisa Vuong") ?? "", "Marisa Vuong",
               "readback: a glued name split in two")
        expect(PasteWatcher.editedVersion(of: "Hello there.", in: "Type a message") == nil,
               "readback: a placeholder of the same shape is still refused")

        // The whole chain, end to end, on what actually happened in the log. Three separate
        // gates refused John's wife's name on three different days, each found only after he
        // re-tested by hand, because every test until now checked one stage in isolation.
        // This one asserts on what he sees: a rule added, a rule offered, or silence.
        func chain(_ wrote: String, _ fieldNow: String) -> String {
            guard let edited = PasteWatcher.editedVersion(of: wrote, in: fieldNow) else { return "unseen" }
            let scored = LearnedCorrections.scored(wrote: wrote, now: edited, existing: [])
            if let first = scored.first {
                return "\(first.confidence == .apply ? "learn" : "suggest") \(first.replacement.from)=>\(first.replacement.to)"
            }
            if let p = CorrectionLearning.lonePair(wrote: wrote, now: edited) {
                return CorrectionLearning.worthShowing(p.from, p.to) ? "offer \(p.from)=>\(p.to)" : "silent"
            }
            return "silent"
        }
        expect(chain("Merissa Wong.", "Marisa Vuong"), "offer Merissa Wong=>Marisa Vuong",
               "chain: a first and last name fixed at once reaches John")
        expect(chain("Marisvo.", "Marisa Vuong"), "offer Marisvo=>Marisa Vuong",
               "chain: a glued name split in two reaches John")
        expect(chain("Just use the Marisvo 6 Repos.", "Just use the Marisa Vuong 6 Repos."),
               "offer Marisvo=>Marisa Vuong", "chain: the same fix inside a sentence")
        expect(chain("Hey change the name Justin.", "Hey change the name Justine."),
               "learn Justin=>Justine", "chain: a near miss is still learned outright")
        expect(chain("Then you can draft a better email to Wort.", "Then you can draft a better email to Duarte."),
               "suggest Wort=>Duarte", "chain: a capitalized one-word name is suggested")
        expect(chain("You can merge it in now.", "Type / for commands"), "unseen",
               "chain: hitting send teaches nothing")
        expect(chain("Ask John Lynn.", "Message #general"), "unseen",
               "chain: an unrelated field teaches nothing")
        // Carrying on typing is refused by editedVersion before the learner is ever consulted,
        // which is better than being refused later: no offer, no log line, no work.
        expect(chain("Ask John.", "Ask John about it."), "unseen",
               "chain: carrying on typing is not an edit at all")

        // 2026-09-14, every readback in the log that produced nothing, as a case.
        // This was "learn failed=>filled" until 2026-09-18, and it is the case that showed
        // what was wrong with that: a rule binding "failed" to "filled" rewrites every
        // future "the build failed" the same way "cloud => Claude" rewrote every "cloud".
        // The edit is still seen and still logged; it just no longer becomes a rule.
        expect(chain("All because I failed out a survey that said this was their service was terrible.",
                     "All because I filled out a survey that said this was their service was terrible."),
               "silent", "chain: one real word for another is never bound")
        // Kept in its place: an end-to-end edit that does still teach the dictionary.
        expect(chain("We need to triadge the bugs.", "We need to triage the bugs."),
               "learn triadge=>triage", "chain: a mangled word still teaches, John's own rule")
        expect(chain("I'm John and I just want to check in on my 2022 Silver Brona to see if you guys have an update cost to fix and time.",
                     "Hi is this Mercer Collision? I'm John and I just want to check in on my 2022 Silver Verona to see if you guys have an update cost to fix and time."),
               "suggest Brona=>Verona", "chain: a misheard name survives a prepended sentence")
        expect(chain("By the way, the fix it ticket for the Tesla now everything is in the system, so we were just a little week too late.",
                     "By the way, the fix it ticket for the Tesla now everything is in the system, so we were just a little week too early."),
               "silent", "chain: the fix behind the half-typed \"earl\" the watcher used to stop on")
        // Two letters, a change of mind, and a rule that would rewrite every "go" he dictates.
        // It reached the screen before worthShowing existed.
        expect(chain("I'm going to be remote on Wednesday but you can we can do a Zoom call and you can screen share or we can go Thursday.",
                     "I'm going to be remote on Wednesday but you can we can do a Zoom call and you can screen share or we can do Thursday."),
               "silent", "chain: a two-letter swap is logged, not shown")

        // The pop-up gate on its own.
        expect(CorrectionLearning.worthShowing("Merissa Wong", "Marisa Vuong"), "offer gate: a two-word name")
        expect(!CorrectionLearning.worthShowing("go", "do"), "offer gate: too short to bind globally")
        expect(!CorrectionLearning.worthShowing("the", "a"), "offer gate: stopword")
        expect(CorrectionLearning.worthShowing("Brona", "Verona"), "offer gate: a misheard name")
        // 2026-09-14, live, while John was testing: a four-character floor refused this.
        expect(CorrectionLearning.worthShowing("Dor", "Duarte"), "offer gate: a short mishearing of a name")
        // Dictated text is capitalized at the start of every sentence, so the name escape
        // hatch covers the commonest spot for a change of mind. Accepting "We" => "He" writes
        // a case-insensitive whole-word rule that rewrites every future "we".
        expect(!CorrectionLearning.worthShowing("We", "He"), "offer gate: a capitalized two-letter swap")
        expect(!CorrectionLearning.worthShowing("Go", "Do"), "offer gate: capitalized at the start of a sentence")
        expect(!CorrectionLearning.worthShowing("Sam", "Pam"), "offer gate: a three-letter name is a change of mind")
        expect(CorrectionLearning.worthShowing("Wort", "Duarte"), "offer gate: the original Duarte case")
        expect(!CorrectionLearning.worthShowing("their", "there"), "offer gate: two stopwords that sound alike")
        expect(!CorrectionLearning.worthShowing("go", "dos"), "offer gate: short and lowercase on both sides")
        // 2026-09-18: everything that was actually waiting in pending-corrections.json,
        // four entries, none of them worth a click. The first two are ordinary words swapped
        // for ordinary words; the last two are the readback catching John mid-retype, and
        // either one accepted by mistake mangles every dictation after it.
        expect(!CorrectionLearning.worthShowing("growth", "grove"), "offer gate: two ordinary words")
        expect(!CorrectionLearning.worthShowing("fruit", "fridge"), "offer gate: and two more")
        expect(!CorrectionLearning.worthShowing("Let's add them to", "What's item"),
               "offer gate: a half-retyped sentence is not a name")
        expect(!CorrectionLearning.worthShowing("I will charge my laptop", "passed sp"),
               "offer gate: nor is a whole one")
        expect(!CorrectionLearning.worthShowing("threat", "thread"), "offer gate: a real word for a real word")
        // A misheard name or term is short, and these are John's own.
        expect(CorrectionLearning.worthShowing("our decide", "Regicide"), "offer gate: two words for a title")
        expect(CorrectionLearning.worthShowing("Mari Sa", "Marisa Vuong"), "offer gate: two words for a name")
        expect(chain("Okay then let's try with Dor.", "Okay then let's try with Duarte."),
               "offer Dor=>Duarte", "chain: the Duarte test John ran by hand")

        // The waiting list when a refused pair arrives. Keeping the watch alive means several
        // declines per dictation, so the same left side arrives more than once as John types.
        func afterDecline(_ from: String, _ to: String, waiting: [(String, String)],
                          accepted: [(String, String)] = []) -> String {
            let list = CorrectionLearning.merging(
                Replacement(from: from, to: to, learned: true),
                into: waiting.map { Replacement(from: $0.0, to: $0.1, learned: true) },
                accepted: accepted.map { Replacement(from: $0.0, to: $0.1) })
            guard let list else { return "unchanged" }
            return list.map { "\($0.from)=>\($0.to)" }.joined(separator: "|")
        }
        expect(afterDecline("Marisvo", "Marisa Vuong", waiting: []), "Marisvo=>Marisa Vuong",
               "waiting list: a new pair is added")
        // The half-typed one lands first; the finished one must not be dropped as a duplicate.
        expect(afterDecline("Marisvo", "Marisa Vuong", waiting: [("Marisvo", "Marisa V")]),
               "Marisvo=>Marisa Vuong", "waiting list: a finished pair replaces the half-typed one")
        expect(afterDecline("Marisvo", "Marisa Vuong", waiting: [("Marisvo", "Marisa Vuong")]), "unchanged",
               "waiting list: the same pair twice writes nothing")
        expect(afterDecline("Marisvo", "Marisa Vuong", waiting: [], accepted: [("Marisvo", "Marisa Vuong")]),
               "unchanged", "waiting list: a rule John already accepted is never reopened")
        expect(afterDecline("Dwart", "Duarte", waiting: [("Brona", "Verona")]),
               "Brona=>Verona|Dwart=>Duarte", "waiting list: an unrelated pair is left alone")

        // An older watch must not read the next dictation's paste as John editing its field.
        // Re-dictating over a selection is the case: two ASR outputs one word apart would
        // auto-write a rule from something he never typed.
        let p1 = PasteWatcher.Paste(seq: 1, text: "Let's meet Thursday.")
        let p2 = PasteWatcher.Paste(seq: 2, text: "Let's meet Tuesday.")
        expect(PasteWatcher.superseded(by: [p1, p2], mine: 1, fieldNow: "Let's meet Tuesday."),
               "readback: the older watch stands down once the newer dictation is in its field")
        expect(!PasteWatcher.superseded(by: [p1, p2], mine: 2, fieldNow: "Let's meet Tuesday."),
               "readback: the newest watch is never superseded by itself")
        expect(!PasteWatcher.superseded(by: [p1, p2], mine: 1, fieldNow: "Let's meet Thursday!"),
               "readback: a hand edit is not a newer dictation")

        // replacements.txt is hand-edited, so a line the parser cannot read must survive a save.
        let hand = """
        # Lin Flow corrections: what was heard => what you meant, one per line.
        # names I keep fixing
        Lynn => Lin
        wisper flow -> Wispr Flow
        """
        let written = Glossary.replacementsFile([Replacement(from: "Lynn", to: "Lin")], keeping: hand)
        expect(written.contains("Lynn => Lin"), "replacements: the rule is written")
        expect(written.contains("wisper flow -> Wispr Flow"), "replacements: a typo'd arrow is not deleted")
        expect(written.contains("# names I keep fixing"), "replacements: a hand-written comment survives")
        expect(written.components(separatedBy: "Lynn => Lin").count == 2, "replacements: the rule is not duplicated")
        // Every learned correction saves the file again, so a second save must change nothing:
        // the kept section's heading used to be kept as one more hand-written line, each time.
        expect(Glossary.replacementsFile([Replacement(from: "Lynn", to: "Lin")], keeping: written) == written,
               "replacements: saving twice changes nothing")
        // Two dictations appended into one box: the second is present, so the first stands
        // down. Safer than the alternative, which is learning from Lin Flow's own output.
        expect(PasteWatcher.superseded(by: [p1, p2], mine: 1, fieldNow: "Let's meet Thursday. Let's meet Tuesday."),
               "readback: appended second dictation also stands the first down")

        // Chrome refuses Electron's accessibility switch, so it is the one app still given VoiceOver's.
        expect(PasteWatcher.isChromiumBrowser("com.google.Chrome") && PasteWatcher.isChromiumBrowser("com.google.Chrome.canary"),
               "readback: Chrome takes VoiceOver's switch")
        expect(!PasteWatcher.isChromiumBrowser("com.anthropic.claudefordesktop") && !PasteWatcher.isChromiumBrowser("com.apple.mail")
               && !PasteWatcher.isChromiumBrowser(nil), "readback: Electron and native apps never get it")

        // Settling now takes two looks in a row, so the window needs two polls past its end
        // or an edit made in the last second can never be confirmed.
        let w = PasteWatcher.shared
        expect((w.checkDelays.last ?? 0) >= w.watchWindow + w.pollInterval,
               "readback: the window leaves room for an edit to settle at the very end")
        expect(w.checkDelays.count >= 2, "readback: more than one look")

        // What the pop-up says. A rule that only reached the log was a rule John never saw,
        // which is why the dictionary felt broken while it was quietly working.
        let learnedOutcome = CorrectionLearning.Outcome(added: [Replacement(from: "GWS C L I", to: "gws cli", learned: true)])
        expect(LearnToast.lines(for: learnedOutcome)?.title ?? "", "Learned: “GWS C L I” → “gws cli”", "toast: says what was learned")
        expect((LearnToast.lines(for: learnedOutcome)?.detail ?? "").contains("Used from now on"), "toast: says the rule now applies")
        let suggestedOutcome = CorrectionLearning.Outcome(suggested: [Replacement(from: "Wort", to: "Duarte", learned: true),
                                                                      Replacement(from: "Seneca", to: "Santa Clara", learned: true)])
        expect(LearnToast.lines(for: suggestedOutcome)?.title ?? "", "Suggested: “Wort” → “Duarte”  +1 more", "toast: counts the rest")
        expect((LearnToast.lines(for: suggestedOutcome)?.detail ?? "").contains("Not applied yet"), "toast: a suggestion is not a rule yet")
        expect(LearnToast.lines(for: CorrectionLearning.Outcome()) == nil, "toast: nothing learned, nothing shown")

        // A misheard name is phonetically distant by nature, so it can never be auto-learned --
        // but throwing it away silently is what made the dictionary feel broken. It is offered.
        func offered(_ wrote: String, _ now: String) -> String {
            LearnedCorrections.scored(wrote: wrote, now: now, existing: [])
                .map { "\($0.replacement.from)=>\($0.replacement.to)\($0.confidence == .suggest ? "?" : "")" }
                .joined(separator: "|")
        }
        expect(offered("draft a better email to Wort.", "draft a better email to Duarte."), "Wort=>Duarte?",
               "learn: a misheard name is offered, not applied")
        expect(learned("draft a better email to Wort.", "draft a better email to Duarte."), "",
               "learn: and auto-learning still refuses it")
        expect(LearnedCorrections.worthOffering(from: "Wort", to: "Duarte"), "offer: a capitalized one-word name")
        expect(!LearnedCorrections.worthOffering(from: "email", to: "message"), "offer: not an ordinary reword")
        expect(!LearnedCorrections.worthOffering(from: "Wort", to: "Duarte Silva"), "offer: not a phrase")
        expect(!LearnedCorrections.worthOffering(from: "that", to: "Duarte"), "offer: not from a stopword")
        expect(!LearnedCorrections.worthOffering(from: "Wort", to: "Duar7e"), "offer: letters only")
        expect(LearnedCorrections.worthOffering(from: "Obrien", to: "O’Brien"), "offer: apostrophes are names too")

        // An edit that teaches nothing is now reported rather than dropped in silence. lonePair
        // is what the notice says; it judges nothing, it just names the one word that changed.
        func pair(_ a: String, _ b: String) -> String {
            guard let p = CorrectionLearning.lonePair(wrote: a, now: b) else { return "" }
            return "\(p.from)=>\(p.to)"
        }
        expect(pair("draft an email to Wort.", "draft an email to Duarte."), "Wort=>Duarte",
               "lonePair: the one word that changed")
        expect(pair("his friends in each of those roles?", "his friends in each of those departmetns?"),
               "roles=>departmetns", "lonePair: a retype is still named, judgement is John's")
        expect(pair("Ask John about it.", "Ask John about it."), "", "lonePair: nothing changed")
        expect(pair("Ask John about it.", "Ask Jane about the other thing."), "",
               "lonePair: more than one change is not a pair")
        expect(pair("Ask John.", "Ask John about it."), "", "lonePair: appended text is not a substitution")
        // The real one, 2026-09-14: a name misheard as a single glued word, fixed into two.
        // Both learning tiers refuse it (7 letters against 11, skeletons "jns" vs "jnts") and
        // lonePair used to refuse to even name it, so John fixed his wife's name and nothing
        // anywhere said a word.
        expect(pair("Just use the Marisvo 6 Repos that was made in 2020.",
                    "Just use the Marisa Vuong 6 Repos that was made in 2020."),
               "Marisvo=>Marisa Vuong", "lonePair: one word split into two is still one change")
        expect(pair("Ask Marissa Vo about it.", "Ask Marisa Vuong about it."), "Marissa Vo=>Marisa Vuong",
               "lonePair: two words for two words")
        expect(pair("meet Marisa Vuong and Mark at noon", "meet Marisa Vuong and Marc at 12"), "",
               "lonePair: two separate changes are not one pair")
        expect(pair("", "something"), "", "lonePair: empty input")
    }
}
