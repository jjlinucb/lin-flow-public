import Foundation
import LinFlowCore

extension SelfTest {
    /// The cleanup pass: fillers, the glossary matcher, spoken commands, numbers, snippets.
    static func cleanup() {
        // fillers
        expect(cleaner.clean("um so this is a test uh of the cleanup, you know, pass"), "So this is a test of the cleanup pass.", "fillers")
        expect(cleaner.clean("Hmm, I mean, that works"), "That works.", "hmm + I mean")
        expect(cleaner.clean("I like this so much, you know the answer"), "I like this so much, you know the answer.", "keep like/so/you know")
        expect(cleaner.clean("Humdrum and Uhura are words"), "Humdrum and Uhura are words.", "no filler inside words")

        // glossary
        expect(cleaner.clean("This is a test of the Lend Flow local dictation spike."), "This is a test of the Lin Flow local dictation spike.", "Lend Flow")
        expect(cleaner.clean("Is Whisper Flow still open? Wisper flow, I mean."), "Is Wispr Flow still open? Wispr Flow, I mean.", "Whisper Flow")
        expect(cleaner.clean("open Linflow and the workbrain folder"), "Open Lin Flow and the WORKBRAIN folder.", "glued + casing")
        expect(cleaner.clean("ask claude code about the parakeet speech model"), "Ask Claude Code about the Parakeet speech model.", "Claude Code before Claude")
        expect(cleaner.clean("the cash in flow was fine"), "The cash in flow was fine.", "in flow untouched")
        expect(cleaner.clean("I whisper to the packet handler"), "I whisper to the packet handler.", "whisper/packet untouched")
        expect(cleaner.clean("Claude is here"), "Claude is here.", "exact term untouched")

        // spoken commands
        expect(cleaner.clean("That's great, exclamation mark."), "That's great!", "exclamation mark")
        expect(cleaner.clean("are you coming question mark"), "Are you coming?", "question mark")
        expect(cleaner.clean("first point new line second point"), "First point\nSecond point.", "new line")
        expect(cleaner.clean("Done here. New paragraph. Next topic."), "Done here.\n\nNext topic.", "new paragraph")
        expect(cleaner.clean("first, new line, second"), "First\nSecond.", "new line eats comma")
        // John's Gmail reply on 2026-09-25, as Parakeet heard it.
        expect(cleaner.clean("Hi Solomon, comma enter enter where's that data store?"),
               "Hi Solomon,\n\nWhere's that data store?", "comma enter enter")
        expect(cleaner.clean("Hi Solomon. Comma, enter, enter. Where's that?"), "Hi Solomon,\n\nWhere's that?", "enter run punctuated by the model")
        expect(cleaner.clean("Thanks, enter enter John"), "Thanks,\n\nJohn.", "enter enter keeps the model's comma")
        expect(cleaner.clean("that's all period enter see you"), "That's all.\nSee you.", "period enter")
        expect(cleaner.clean("Please enter the password and press enter."), "Please enter the password and press enter.", "a lone enter is a word")
        expect(cleaner.clean("Put a comma after the name."), "Put a comma after the name.", "a lone comma is a word")
        expect(cleaner.clean("After the trial period, enter your card details."), "After the trial period, enter your card details.", "period, enter is prose")

        // style
        expect(cleaner.clean("The plan worked—mostly; nobody noticed"), "The plan worked, mostly. Nobody noticed.", "em dash + semicolon")
        expect(cleaner.clean("well - that's odd"), "Well, that's odd.", "spaced hyphen")

        // hallucinations / noise
        expect(cleaner.clean("Thank you."), "", "thank you")
        expect(cleaner.clean("[BLANK_AUDIO]"), "", "blank audio tag")
        expect(cleaner.clean("(upbeat music) okay let's go"), "Okay let's go.", "parenthetical noise")
        expect(cleaner.clean(""), "", "empty")

        // capitalization / terminal punctuation
        expect(cleaner.clean("so lin flow should go. and then stop"), "So Lin Flow should go. And then stop.", "sentence caps")
        expect(cleaner.clean("already fine."), "Already fine.", "already fine")
        expect(cleaner.clean("\"quoted start\" works"), "\"Quoted start\" works.", "quote start")

        // the matcher
        expect(GlossaryMatcher.matches(candidate: "Linflow", term: "Lin Flow"), "match Linflow")
        expect(!GlossaryMatcher.matches(candidate: "in flow", term: "Lin Flow"), "no match in flow")
        expect(!GlossaryMatcher.matches(candidate: "Lin Flow", term: "Lin Flow"), "no self match")
        expect(GlossaryMatcher.levenshtein("kitten", "sitting") == 3, "levenshtein")

        // prompt echo filter
        expect(DictationController.looksLikePromptEcho("Lin, Lin, Flow, Parakeet.", glossary: glossary, peak: 0.001), "echo on silence")
        expect(!DictationController.looksLikePromptEcho("Lin Flow is great.", glossary: glossary, peak: 0.3), "not echo when loud")
        expect(!DictationController.looksLikePromptEcho("Please open GitHub now.", glossary: glossary, peak: 0.001), "not echo with other words")

        // regressions from the 2026-09-10 test sweep
        expect(cleaner.clean("I could do it"), "I could do it.", "could is not Claude")
        expect(cleaner.clean("no cloud, no account, no API bill"), "No cloud, no account, no API bill.", "cloud is not Claude")
        expect(cleaner.clean("he called yesterday"), "He called yesterday.", "called is not Claude")
        expect(cleaner.clean("the clause in the contract"), "The clause in the contract.", "clause is not Claude")
        expect(cleaner.clean("Claudia is here"), "Claudia is here.", "Claudia is not Claude")
        expect(cleaner.clean("Could you send the slides?"), "Could you send the slides?", "Could at sentence start")
        expect(cleaner.clean("Lin Flow's pill is green"), "Lin Flow's pill is green.", "possessive kept")
        expect(cleaner.clean("Parakeets are birds"), "Parakeets are birds.", "plural kept")
        expect(cleaner.clean("githubs"), "GitHubs.", "plural snapped keeps s")
        expect(cleaner.clean("I built it on whisper.cpp. It is fast."), "I built it on whisper.cpp. It is fast.", "whisper.cpp keeps its period")
        expect(cleaner.clean("the whisper.cpp library is fast"), "The whisper.cpp library is fast.", "whisper.cpp not recased")
        expect(cleaner.clean("Whisperflow was the app"), "Wispr Flow was the app.", "glued Whisperflow")
        expect(cleaner.clean("notes in work brain"), "Notes in WORKBRAIN.", "split work brain")
        expect(cleaner.clean("she went to the ER last night"), "She went to the ER last night.", "ER acronym")
        expect(cleaner.clean("I studied at UM in Ann Arbor"), "I studied at UM in Ann Arbor.", "UM acronym")
        expect(cleaner.clean("she said uh-huh and left"), "She said uh-huh and left.", "uh-huh whole")
        expect(cleaner.clean("I think, um. Then again"), "I think. Then again.", "filler keeps sentence end")
        expect(cleaner.clean("I think we should go there, um"), "I think we should go there.", "trailing filler")
        expect(cleaner.clean("go to https://example.com/path?q=1 now"), "Go to https://example.com/path?q=1 now.", "URL intact")
        expect(cleaner.clean("email john@example.com today"), "Email john@example.com today.", "email intact")
        expect(cleaner.clean("Dr. Smith arrived at 5 p.m. today"), "Dr. Smith arrived at 5 p.m. today.", "p.m. abbreviation")
        expect(cleaner.clean("Mr. and Mrs. Jones arrived"), "Mr. and Mrs. Jones arrived.", "titles")
        expect(cleaner.clean("I said no; she agreed"), "I said no. She agreed.", "semicolon then capital")
        expect(cleaner.clean("we chose plan B; it works"), "We chose plan B. It works.", "single letter is not an initial")
        // second sweep round
        expect(cleaner.clean("John Lynn wrote it"), "John Lin wrote it.", "John Lynn whole-word first")
        expect(cleaner.clean("Johnlin's desk"), "John Lin's desk.", "glued possessive keeps 's")
        expect(cleaner.clean("Johnson called"), "Johnson called.", "Johnson is a word")
        expect(cleaner.clean("John Lee called"), "John Lee called.", "John Lee stays John Lee")
        expect(cleaner.clean("I met John Liu and John Lam"), "I met John Liu and John Lam.", "two surnames stay")
        expect(cleaner.clean("John Lee's report"), "John Lee's report.", "surname possessive stays")
        expect(cleaner.clean("let's make it work again"), "Let's make it work again.", "two words stay two words")
        expect(cleaner.clean("that was another epic fail"), "That was another epic fail.", "another epic is not Anthropic")
        expect(cleaner.clean("Claude's code was fine"), "Claude's code was fine.", "possessive before second word")
        expect(cleaner.clean("Claude coded the whole thing"), "Claude coded the whole thing.", "verb form")
        expect(cleaner.clean("the Cambodians arrived"), "The Cambodians arrived.", "double inflection")
        expect(cleaner.clean("the Parakeets' cage"), "The Parakeets' cage.", "plural possessive")
        expect(cleaner.clean("he typed ‘Claude’ twice"), "He typed ‘Claude’ twice.", "closing curly quote kept")
        expect(cleaner.clean("a multi-team effort"), "A multi-team effort.", "hyphenated everyday words")
        expect(cleaner.clean("my number is (408) 555-1234"), "My number is (408) 555-1234.", "parentheses with digits kept")
        expect(cleaner.clean("the model (Parakeet) is fast"), "The model (Parakeet) is fast.", "parenthesized word kept")
        expect(cleaner.clean("um, the ER, uh, was full"), "The ER was full.", "filler between commas")
        expect(cleaner.clean("err on the side of caution"), "Err on the side of caution.", "err is a verb")
        expect(cleaner.clean("今天天气很好。我们去公园吧"), "今天天气很好。我们去公园吧。", "Chinese full stop added")
        expect(cleaner.clean("first new line — second"), "First\nSecond.", "em dash after new line")
        expect(cleaner.clean("bring fruit, e.g. apples"), "Bring fruit, e.g. apples.", "e.g. abbreviation")
        expect(cleaner.clean("I went to the U.S. on Monday"), "I went to the U.S. on Monday.", "U.S. abbreviation")
        expect(cleaner.clean("Meeting at 3 45 p.m. on March 14"), "Meeting at 3:45 p.m. on March 14.", "time colon")
        expect(cleaner.clean("the train leaves at 7.15 am"), "The train leaves at 7:15 am.", "time colon dot")
        expect(cleaner.clean("and then I said,"), "And then I said.", "trailing comma")
        expect(cleaner.clean("here is the list:"), "Here is the list.", "trailing colon")
        expect(cleaner.clean("he said \"hello.\""), "He said \"hello.\"", "closing quote after period")
        expect(cleaner.clean("今天天气很好。"), "今天天气很好。", "Chinese full stop")
        expect(cleaner.clean("សួស្តី។"), "សួស្តី។", "Khmer full stop")
        expect(cleaner.clean("so I was thinking…"), "So I was thinking…", "ellipsis ends")
        expect(cleaner.clean("ß is a letter"), "ß is a letter.", "sharp s does not crash")
        expect(cleaner.clean("ﬁne then"), "ﬁne then.", "ligature does not crash")
        expect(cleaner.clean("first new paragraph new line second"), "First\n\nSecond.", "paragraph + line")
        expect(cleaner.clean("first new line new paragraph second"), "First\n\nSecond.", "line + paragraph")
        expect(cleaner.clean("first new line - second"), "First\n- second.", "dash after new line keeps newline")
        for x in ["and then I said,", "I think we should go there, um", "um so this is a test", "Is Whisper Flow open? Wisper flow, I mean.", "first new line second"] {
            let once = cleaner.clean(x)
            expect(cleaner.clean(once), once, "idempotent: \(x)")
        }
        expect(!GlossaryMatcher.matches(candidate: "could", term: "Claude"), "no match could")
        expect(!GlossaryMatcher.matches(candidate: "cloud", term: "Claude"), "no match cloud")
        expect(GlossaryMatcher.matches(candidate: "Sunnyvail", term: "Sunnyvale"), "match Sunnyvail")
        expect(GlossaryMatcher.matches(candidate: "whisperflow", term: "Wispr Flow"), "match glued whisperflow")
        expect(GlossaryMatcher.matches(candidate: "Cloud Code", term: "Claude Code"), "match Cloud Code")

        // A real name is never rewritten into a different real name. The matching "John"
        // used to donate enough of the phrase's edit budget to cover the whole surname,
        // so every one of these became "John Lin".
        for surname in ["Lee", "Liu", "Long", "Lim", "Liang", "Lam", "Lang", "Ling", "Lane",
                        "Levin", "Lund", "Lind", "Lian", "Lok", "Low", "Ng", "Ho", "Ma"] {
            expect(!GlossaryMatcher.matches(candidate: "John \(surname)", term: "John Lin"),
                   "John \(surname) is not John Lin")
        }
        expect(!GlossaryMatcher.matches(candidate: "Jan Lin", term: "John Lin"), "Jan is not John")
        expect(!GlossaryMatcher.matches(candidate: "Claude Cody", term: "Claude Code"), "Cody is not Code")
        expect(!GlossaryMatcher.matches(candidate: "Claude Cole", term: "Claude Code"), "Cole is not Code")
        expect(!GlossaryMatcher.matches(candidate: "Claudia Code", term: "Claude Code"), "Claudia is not Claude")
        expect(!GlossaryMatcher.matches(candidate: "Lee Flow", term: "Lin Flow"), "Lee Flow is not Lin Flow")
        expect(!GlossaryMatcher.matches(candidate: "Parker", term: "Parakeet"), "Parker is not Parakeet")
        expect(!GlossaryMatcher.matches(candidate: "Kramer", term: "Khmer"), "Kramer is not Khmer")
        // Spelling variants of the same name still snap: same consonants, same vowel sounds.
        expect(GlossaryMatcher.matches(candidate: "John Lynn", term: "John Lin"), "Lynn respells Lin")
        expect(GlossaryMatcher.matches(candidate: "John Linn", term: "John Lin"), "Linn respells Lin")
        // A near miss that is nobody's name is still snapped -- the guard is about names only.
        expect(GlossaryMatcher.matches(candidate: "Lend Flow", term: "Lin Flow"), "Lend is not a name")
        expect(GlossaryMatcher.matches(candidate: "Whisper Flow", term: "Wispr Flow"), "Whisper is not a name")
        expect(GlossaryMatcher.nameKey("Lynn"), "lin", "nameKey folds y and doubles")
        expect(GlossaryMatcher.nameKey("Lane"), "lan", "nameKey drops silent e")

        // dictionary corrections run before the fuzzy pass
        let fixer = TextCleaner(glossary: glossary, replacements: [Replacement(from: "wisper flow", to: "Wispr Flow"), Replacement(from: "khmer", to: "Khmer")])
        expect(fixer.clean("open wisper flow and the khmer notes"), "Open Wispr Flow and the Khmer notes.", "replacements")
        expect(fixer.clean("Wisper Flowing is not a phrase"), "Wisper Flowing is not a phrase.", "replacement needs whole words")

        // snippets
        let snips = [Snippet(trigger: "my address", text: "123 Main St\nSunnyvale, CA 94085"),
                     Snippet(trigger: "my email", text: "john@example.com"),
                     Snippet(trigger: "sign off", text: "Best,\nJohn"),
                     Snippet(trigger: "the pitch", text: "Lin Flow is local dictation for the Mac.")]
        expect(Snippets.expand("My address.", snippets: snips), "123 Main St\nSunnyvale, CA 94085", "snippet: whole dictation, period dropped")
        expect(Snippets.expand("Insert my address.", snippets: snips), "123 Main St\nSunnyvale, CA 94085", "snippet: insert prefix")
        expect(Snippets.expand("Ship it to my address, thanks.", snippets: snips), "Ship it to 123 Main St\nSunnyvale, CA 94085 thanks.", "snippet: multi-line drops the comma")
        expect(Snippets.expand("Send it to my email.", snippets: snips), "Send it to john@example.com", "snippet: single token sheds the final period")
        expect(Snippets.expand("Send it to my email, thanks.", snippets: snips), "Send it to john@example.com, thanks.", "snippet: single token keeps a comma mid-sentence")
        expect(Snippets.expand("Thanks again. Sign off", snippets: snips), "Thanks again. Best,\nJohn", "snippet: at the end, no punctuation")
        expect(Snippets.expand("Here is the pitch. Questions?", snippets: snips), "Here is Lin Flow is local dictation for the Mac. Questions?", "snippet: self-punctuated drops the period")
        expect(Snippets.expand("My emails are late.", snippets: snips), "My emails are late.", "snippet: no partial word match")
        expect(Snippets.expand("Nothing here.", snippets: snips), "Nothing here.", "snippet: untouched")
        expect(Snippets.expand("my, address", snippets: snips), "123 Main St\nSunnyvale, CA 94085", "snippet: comma between trigger words")

        // spoken numbers as digits
        func num(_ s: String) -> String { NumberWords.apply(to: s) }
        expect(num("one two three four five"), "1 2 3 4 5", "numbers: a run of digits")
        expect(num("one, two, three"), "1, 2, 3", "numbers: separators kept")
        expect(num("twenty two"), "22", "numbers: tens plus unit")
        expect(num("three hundred"), "300", "numbers: hundred")
        expect(num("three hundred and five"), "305", "numbers: hundred and unit")
        expect(num("two thousand twenty six"), "2026", "numbers: thousands")
        expect(num("two hundred fifty thousand"), "250000", "numbers: compound scale")
        expect(num("fifteen hundred"), "1500", "numbers: teen hundred")
        expect(num("nineteen eighty four"), "1984", "numbers: year said as two")
        expect(num("twenty twenty six"), "2026", "numbers: this decade")
        expect(num("twenty thirty"), "20 30", "numbers: a range is not a year")
        expect(num("I have two questions"), "I have 2 questions", "numbers: plain count")
        expect(num("one of the reasons"), "one of the reasons", "numbers: 'one' as a pronoun")
        expect(num("the one that works"), "the one that works", "numbers: 'the one'")
        expect(num("no one knows"), "no one knows", "numbers: 'no one'")
        expect(num("one dollar"), "1 dollar", "numbers: 'one' before a unit")
        expect(num("one hundred"), "100", "numbers: 'one' inside a number")
        expect(num("the twenty second"), "the twenty second", "numbers: ordinal after a number")
        expect(num("one-on-one"), "one-on-one", "numbers: hyphenated compound")
        expect(num("a few hundred"), "a few hundred", "numbers: bare scale word")
        expect(num("a hundred"), "100", "numbers: 'a hundred' is a figure")
        expect(num("a hundred forty volts"), "140 volts", "numbers: 'a hundred' and more")
        expect(num("A hundred people came"), "100 people came", "numbers: 'a hundred' opening a sentence")
        expect(num("about a thousand of them"), "about 1000 of them", "numbers: 'a thousand'")
        expect(num("a hundred and five"), "105", "numbers: 'a hundred and' a unit")
        expect(num("one in a million"), "one in a million", "numbers: 'a million' stays words")
        expect(num("a hundred-year flood"), "a hundred-year flood", "numbers: 'a hundred' in a compound")
        expect(num("eight hundred and seven hundred"), "800 and 700", "numbers: a second hundreds is a new number")
        expect(num("a thousand, two thousand"), "1000, 2000", "numbers: a second thousand is a new number")
        expect(num("five hundred thousand, two hundred thousand"), "500000, 200000", "numbers: a second thousand after a hundred")
        expect(num("two thousand five, three thousand"), "2005, 3000", "numbers: a number that ends before the next thousand")
        expect(num("one million two hundred thousand"), "1200000", "numbers: a smaller scale after a bigger one")
        expect(num("panels one and two"), "panels 1 and 2", "numbers: 'and' between two numbers stays")
        expect(num("thousands of people"), "thousands of people", "numbers: plural scale")
        expect(num("someone anyone"), "someone anyone", "numbers: no partial word match")
        expect(num("version three"), "version 3", "numbers: after a counter word")
        // Dates and decimals, John on 2026-09-29.
        expect(num("I already got my September thirtieth invoice."), "I already got my September 30th invoice.", "numbers: a day after a month")
        expect(num("September twenty first"), "September 21st", "numbers: a two-word day")
        expect(num("March second, May third, June twelfth"), "March 2nd, May 3rd, June 12th", "numbers: day suffixes")
        expect(num("October first one move in date"), "October 1st one move in date", "numbers: a day, then a pronoun 'one'")
        expect(num("September thirty first, twenty twenty six"), "September 31st, 2026", "numbers: a day, then a year")
        expect(num("the thirtieth of September"), "the 30th of September", "numbers: the day of a month")
        expect(num("my first job"), "my first job", "numbers: an ordinal with no month stays a word")
        expect(num("you may first check"), "you may first check", "numbers: 'may' that is not the month")
        expect(num("Claude Opus five point five"), "Claude Opus 5.5", "numbers: a decimal")
        expect(num("three point one four"), "3.14", "numbers: several decimal digits")
        expect(num("one point five hours"), "1.5 hours", "numbers: 'one point five'")
        expect(num("version two point oh"), "version 2.0", "numbers: 'point oh'")
        expect(num("five point five million"), "5.5 million", "numbers: a decimal before a scale word")
        expect(num("we made two points"), "we made 2 points", "numbers: 'points' is not a decimal")
        expect(num("no numbers here at all"), "no numbers here at all", "numbers: untouched")
        expect(cleaner.clean("um so I need twenty two of them"), "So I need 22 of them.", "numbers: through the whole pass")
        expect(cleaner.clean("I already got my September thirtieth invoice and five point five needs to be exact"),
               "I already got my September 30th invoice and 5.5 needs to be exact.", "numbers: dates and decimals through the whole pass")

        // A spelling the user chose on purpose must survive the sentence-capitalizer, which
        // runs last. John's own two rules produce "kkwinedf" and "gws cli".
        let lower = TextCleaner.lowercaseTerms(
            [Replacement(from: "K Wynn E D F", to: "kkwinedf"), Replacement(from: "GWS C L I", to: "gws cli")],
            ["whisper.cpp", "Lin Flow"])
        expect(lower.contains("kkwinedf") && lower.contains("gws") && lower.contains("whisper.cpp"),
               "capitalize: deliberate lowercase terms are collected")
        expect(!lower.contains("Lin"), "capitalize: a capitalized glossary term is not protected")
        expect(TextCleaner.capitalizeSentences("kkwinedf is my handle.", keepingLowercase: lower),
               "kkwinedf is my handle.", "capitalize: a username opening a sentence is left alone")
        expect(TextCleaner.capitalizeSentences("gws cli runs it.", keepingLowercase: lower),
               "gws cli runs it.", "capitalize: a command opening a sentence is left alone")
        expect(TextCleaner.capitalizeSentences("I use kkwinedf. kkwinedf is mine.", keepingLowercase: lower),
               "I use kkwinedf. kkwinedf is mine.", "capitalize: also after a full stop")
        expect(TextCleaner.capitalizeSentences("this should still capitalize.", keepingLowercase: lower),
               "This should still capitalize.", "capitalize: everything else is unchanged")
    }
}
