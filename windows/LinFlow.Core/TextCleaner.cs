using System.Globalization;
using System.Text.RegularExpressions;

namespace LinFlow.Core;

/// Deterministic, instant post-processing for dictated text. This replaces
/// the old Lin Flow LLM cleanup pass: Apple's on-device model was measured at
/// 4-11 s per call on that machine (and still missed the glossary fixes),
/// which is far too slow to sit between "release key" and "text appears".
///
/// Whisper already produces cased, punctuated prose and rarely emits "um",
/// so the rules here are the safe leftovers: filler tokens, spoken commands,
/// glossary spelling, and John's own style rules (no em dashes, no
/// semicolons). Nothing here rewrites meaning.
///
/// Every regex carries CultureInvariant: with a Turkish culture loaded, an IgnoreCase "I" stops
/// matching "i", which would silently break the "I mean," rule and the a.m./p.m. clock fixup.
public sealed class TextCleaner
{
    public List<string> Glossary { get; set; }
    public List<Replacement> Replacements { get; set; }
    public bool RemoveFillers { get; set; } = true;
    public bool SpokenCommands { get; set; } = true;
    public bool StyleRules { get; set; } = true;
    public bool NumbersAsDigits { get; set; } = true;

    public TextCleaner(IEnumerable<string>? glossary = null, IEnumerable<Replacement>? replacements = null)
    {
        // Fully qualified: the `Glossary` property above shadows the type name inside this class.
        Glossary = glossary?.ToList() ?? LinFlow.Core.Glossary.Load();
        Replacements = replacements?.ToList() ?? LinFlow.Core.Glossary.LoadReplacements();
    }

    public string Clean(string raw)
    {
        var text = raw.Trim();
        if (text.Length == 0) return "";
        text = StripBracketedNoise(text);
        if (text.Length == 0) return "";
        text = ApplyReplacements(text, Replacements);
        if (RemoveFillers) text = StripFillers(text);
        if (SpokenCommands) text = ApplySpokenCommands(text);
        text = new GlossaryMatcher(Glossary).Apply(text);
        // After the glossary, so a term that contains a number word still matches.
        if (NumbersAsDigits) text = NumberWords.Apply(text);
        if (StyleRules) text = ApplyStyleRules(text);
        text = TidyWhitespaceAndPunctuation(text);
        text = CapitalizeSentences(text);
        return text;
    }

    /// John's style rules alone (em dashes and semicolons) for text a model wrote.
    public static string ApplyStyle(string s) => ApplyStyleRules(s);

    // ---- pieces (public so the test project can reach them; no InternalsVisibleTo here) ----

    /// Exact phrase corrections from the dictionary ("wisper flow" -> "Wispr Flow"),
    /// case-insensitive, whole words only. Runs before the fuzzy glossary pass.
    public static string ApplyReplacements(string s, IEnumerable<Replacement> replacements)
    {
        var outText = s;
        foreach (var r in replacements)
        {
            var from = TrimSpaces(r.From);
            if (from.Length == 0) continue;
            var pattern = @"(?<![\w'])" + Regex.Escape(from) + @"(?![\w'])";
            var to = r.To;
            // A MatchEvaluator inserts `to` literally. Handing it to Replace as a template would
            // read "$1" or "$&" in a correction as a backreference, which is what the Swift's
            // escapedTemplate(for:) guards against.
            outText = new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)
                .Replace(outText, _ => to);
        }
        return outText;
    }

    private static readonly Regex SquareBrackets = new(@"\[([^\]]*)\]", RegexOptions.CultureInvariant);
    private static readonly Regex RoundBrackets = new(@"\(([^)]*)\)", RegexOptions.CultureInvariant);
    private static readonly Regex Asterisked = new(@"\*[^*]*\*", RegexOptions.CultureInvariant);
    private static readonly Regex MusicNotes = new("♪+", RegexOptions.CultureInvariant);

    /// Whisper marks non-speech with bracketed tags: [BLANK_AUDIO], (music),
    /// *laughs*, the music note. Drop those; dictated parentheses such as "(408) 555-1234" or
    /// "(Parakeet)" stay. If nothing else is left the clip was empty.
    public static string StripBracketedNoise(string s)
    {
        var outText = s;
        outText = SquareBrackets.Replace(outText, m => IsNoiseTag(m.Groups[1].Value) ? " " : m.Value);
        outText = RoundBrackets.Replace(outText, m => IsNoiseTag(m.Groups[1].Value) ? " " : m.Value);
        outText = Asterisked.Replace(outText, " ");
        outText = MusicNotes.Replace(outText, " ");
        outText = outText.Trim();
        // Known whole-output hallucinations on silence.
        var lowered = TrimPunctuationAndSpaces(outText.ToLowerInvariant());
        if (SilenceHallucinations.Contains(lowered)) return "";
        return outText;
    }

    /// The contents of a bracket the recognizer used as a non-speech tag, not dictated text.
    public static bool IsNoiseTag(string inner)
    {
        var t = TrimSpaces(inner);
        if (t.Length == 0 || t.Contains('_')) return true;                  // [BLANK_AUDIO]
        foreach (var c in t) if (char.IsNumber(c)) return false;            // (408)
        var words = t.ToLowerInvariant().Split(new[] { ' ', '-' }, StringSplitOptions.RemoveEmptyEntries);
        return words.Length <= 3 && words.All(NoiseWords.Contains);
    }

    public static readonly IReadOnlySet<string> NoiseWords = new HashSet<string>(StringComparer.Ordinal)
    {
        "music", "laughs", "laughter", "laughing", "chuckles", "applause", "clapping", "cheering", "inaudible",
        "unintelligible", "indistinct", "silence", "blank", "audio", "noise", "background", "coughs", "coughing",
        "sighs", "sigh", "speaking", "foreign", "language", "crosstalk", "typing", "pause", "static", "beep",
        "door", "phone", "ringing", "upbeat", "soft", "gentle", "dramatic", "breathing", "sniffs", "mumbles",
        "murmurs", "speech", "sound", "sounds", "instrumental", "singing", "humming", "whispering", "clicking",
        "wind", "rain", "crying", "screaming", "gasps", "groans", "grunts", "whistling", "bell", "bells",
        "chime", "chimes", "intro", "outro", "no", "clears", "throat", "sneezes", "yawns", "engine", "traffic",
    };

    public static readonly IReadOnlySet<string> SilenceHallucinations = new HashSet<string>(StringComparer.Ordinal)
    {
        "thank you", "thanks for watching", "thank you for watching", "you", "bye", "the end",
        "subtitles by the amara.org community", "please subscribe", "so", "oh", "hmm", "mm", "mhm", "uh", "um",
    };

    // "um", "uh", "er", "erm", "ah", "hmm", "mm-hmm", "mhm", together with the comma before
    // and/or after it, so "the ER, uh, was full" loses no more than the filler. Spelled case
    // by case rather than IgnoreCase so all-caps acronyms (ER, UM, AH) survive, hyphens excluded
    // so "uh-huh" stays whole, "err" excluded by [Ee]r(?:m+)?. A following period stays.
    private static readonly Regex FillerTokens = new(
        @"(?:,[ \t]*)?(?<![\w'-])(?:[Uu]+m+|[Uu]+h+|[Ee]r(?:m+)?|[Aa]+h+|[Hh]+m+|[Mm]m+-?[Hh]+m+|[Mm]hm)(?![\w'-]),?\s*",
        RegexOptions.CultureInvariant);

    // "you know," as an aside (followed by a comma) -- the meaningful use ("you know the answer") has no comma.
    private static readonly Regex YouKnowAside = new(
        @"(?:,[ \t]*)?(?<![\w'])you know,\s*", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    // "I mean," at the start of a sentence.
    private static readonly Regex IMeanOpener = new(
        @"(^|[.!?]\s+)I mean,\s*", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// Only tokens that are filler in every context. "like" and "so" are
    /// deliberately left alone: they carry meaning too often.
    ///
    /// Named StripFillers rather than RemoveFillers because C# will not let the bool property of
    /// that name and a method share it; the Swift `removeFillers` var and static func can.
    public static string StripFillers(string s)
    {
        var outText = s;
        outText = FillerTokens.Replace(outText, " ");
        outText = YouKnowAside.Replace(outText, " ");
        outText = TrimSpaces(outText);
        outText = IMeanOpener.Replace(outText, "$1");
        return outText;
    }

    // A comma before the command goes; a period stays (it ends the sentence).
    // "new line" runs first so "new paragraph" next to it still yields a blank line.
    private static readonly (Regex Pattern, string Replacement)[] SpokenCommandTable =
    {
        (new Regex(@",?\s*\bnew line\b[,.]?\s*", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant), "\n"),
        (new Regex(@",?\s*\bnew paragraph\b[,.]?\s*", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant), "\n\n"),
        (new Regex(@"\s*[,.]?\s*\bexclamation (?:mark|point)\b[,.]?", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant), "!"),
        (new Regex(@"\s*[,.]?\s*\bquestion mark\b[,.]?", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant), "?"),
    };

    private static readonly Regex BangOrQueryThenDot = new(@"([!?])\s*[.,]", RegexOptions.CultureInvariant);

    /// Phrases nobody says literally in prose. "period" and "comma" are
    /// intentionally not here: whisper punctuates from prosody already, and
    /// both words are common in ordinary sentences.
    public static string ApplySpokenCommands(string s)
    {
        var outText = ApplyEnterRuns(s);
        foreach (var (pattern, replacement) in SpokenCommandTable)
            outText = pattern.Replace(outText, replacement);
        // "That's great!." -> "That's great!"  and  "really?." -> "really?"
        return BangOrQueryThenDot.Replace(outText, "$1");
    }

    /// "Hi Solomon comma enter enter where's that" -> "Hi Solomon,\n\nwhere's that". Port of the
    /// Mac's `applyEnterRuns`; its comment has John's words and the reasoning. Only a run of two
    /// or more command words with at least one "enter" counts, so "press enter" stays a word.
    private const string EnterRunWord = @"(?:comma|period|full stop|colon|question mark|exclamation (?:mark|point)|enter)";
    private static readonly Regex EnterRun = new(
        @"[ \t]*([,.;:!?]?)[ \t]*(?<![\w'])(" + EnterRunWord + @"(?:[ \t]*[,.;:!?]?[ \t]+" + EnterRunWord + @")+)(?![\w'])[,.;:!?]?[ \t]*",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly (string Word, string Mark)[] EnterRunMarks =
        { ("comma", ","), ("period", "."), ("stop", "."), ("colon", ":"), ("question", "?"), ("exclamation", "!") };

    public static string ApplyEnterRuns(string s) => EnterRun.Replace(s, m =>
    {
        var words = Regex.Split(m.Groups[2].Value.ToLowerInvariant(), @"[^a-z]+").Where(w => w.Length > 0).ToList();
        var breaks = words.Count(w => w == "enter");
        if (breaks == 0) return m.Value;
        // One "enter" with a mark before it is prose: "after the trial period, enter your card".
        if (breaks == 1 && m.Groups[2].Value.IndexOfAny(",.;:!?".ToCharArray()) >= 0) return m.Value;
        // The last mark said wins; with none, the model's own mark before the run stays.
        var spoken = Enumerable.Reverse(words)
            .Select(w => EnterRunMarks.FirstOrDefault(p => p.Word == w).Mark)
            .FirstOrDefault(mark => mark is not null);
        return (spoken ?? m.Groups[1].Value) + new string('\n', breaks);
    });

    // Em/en dashes used as punctuation become a comma (mid-sentence) -- John never writes them.
    // Horizontal whitespace only, so a newline a spoken command just inserted survives.
    private static readonly Regex DashPunctuation = new(@"[ \t]*[—–][ \t]*", RegexOptions.CultureInvariant);
    private static readonly Regex SpacedHyphen = new(@"[ \t]+-[ \t]+", RegexOptions.CultureInvariant);
    // Semicolons become periods, and the next word gets capitalized later.
    private static readonly Regex Semicolon = new(@";[ \t]*", RegexOptions.CultureInvariant);

    public static string ApplyStyleRules(string s)
    {
        var outText = s;
        outText = DashPunctuation.Replace(outText, ", ");
        outText = SpacedHyphen.Replace(outText, ", ");
        outText = Semicolon.Replace(outText, ". ");
        return outText;
    }

    public const string SentenceEnders = ".!?\n。！？…។؟";
    public const string ClosingMarks = "\"'”’)]";
    /// Opening quotes and brackets do not end the run of "still waiting to capitalize".
    private const string OpeningMarks = "\"'“‘(";

    private static readonly Regex HorizontalRuns = new(@"[ \t]+", RegexOptions.CultureInvariant);
    private static readonly Regex SpaceAroundNewline = new(" ?\n ?", RegexOptions.CultureInvariant);
    private static readonly Regex SpaceBeforePunctuation = new(@"[ \t]+([,.!?:;])", RegexOptions.CultureInvariant);
    private static readonly Regex CommaAfterNewline = new(@"\n[ \t]*,[ \t]*", RegexOptions.CultureInvariant);
    private static readonly Regex DoubledPunctuation = new(@"([,.!?:])\1+", RegexOptions.CultureInvariant);
    private static readonly Regex CommaThenPeriod = new(@",\s*\.", RegexOptions.CultureInvariant);
    private static readonly Regex ClockTime = new(@"\b(\d{1,2})[ .](\d{2})(?=\s*[ap]\.?m\b)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex LeadingJunk = new(@"^[,.\s]+", RegexOptions.CultureInvariant);
    private static readonly Regex TrailingJunk = new(@"[,:;\s]+$", RegexOptions.CultureInvariant);

    public static string TidyWhitespaceAndPunctuation(string s)
    {
        var outText = s;
        outText = HorizontalRuns.Replace(outText, " ");
        outText = SpaceAroundNewline.Replace(outText, "\n");
        outText = SpaceBeforePunctuation.Replace(outText, "$1");
        outText = CommaAfterNewline.Replace(outText, "\n");   // a dash that became ", " after a spoken new line
        outText = DoubledPunctuation.Replace(outText, "$1");
        outText = CommaThenPeriod.Replace(outText, ".");
        // Clock times the models write without a colon: "3 45 p.m." / "7.15 am" -> "3:45 p.m." / "7:15 am".
        outText = ClockTime.Replace(outText, "$1:$2");
        outText = LeadingJunk.Replace(outText, "");
        outText = outText.Trim();
        // A trailing comma or colon (usually where a filler was cut off) is not an ending.
        outText = TrailingJunk.Replace(outText, "");
        // A dictation is a sentence; make sure it ends like one. Closing quotes and brackets
        // don't count, and neither does a Chinese, Japanese or Khmer full stop already there.
        var i = outText.Length - 1;
        while (i >= 0 && ClosingMarks.Contains(outText[i])) i--;
        // i < 0 means the text was empty or nothing but closing marks: no last letter, nothing to add.
        if (i >= 0 && !SentenceEnders.Contains(outText[i])) outText += FullStopAfter(outText, i);
        return outText;
    }

    /// The full stop that belongs to the script of the last letter: the ideographic one after
    /// Chinese or Japanese, the Khmer khan after Khmer, "." otherwise.
    public static string FullStopAfter(string s, int index)
    {
        // C# indexes UTF-16 code units where Swift indexes graphemes, so recombine a surrogate
        // pair before testing the range; every range below is BMP, so a lone surrogate would
        // otherwise fall through to "." by accident rather than by decision.
        int v = s[index];
        if (char.IsLowSurrogate(s[index]) && index > 0 && char.IsHighSurrogate(s[index - 1]))
            v = char.ConvertToUtf32(s[index - 1], s[index]);
        return v switch
        {
            >= 0x3040 and <= 0x30FF => "。",
            >= 0x3400 and <= 0x4DBF => "。",
            >= 0x4E00 and <= 0x9FFF => "。",
            >= 0xF900 and <= 0xFAFF => "。",
            >= 0x3000 and <= 0x303F => "。",
            >= 0x1780 and <= 0x17FF => "។",
            _ => ".",
        };
    }

    /// Words a period does not end a sentence after: "p.m.", "e.g.", "etc.", titles. (The
    /// models already capitalize the name after "Mr.", so nothing is lost by not forcing it.)
    public static readonly IReadOnlySet<string> Abbreviations = new HashSet<string>(StringComparer.Ordinal)
    {
        "p.m", "a.m", "e.g", "i.e", "etc", "vs", "approx", "dept", "mr", "mrs", "ms", "dr", "prof",
        "st", "mt", "jr", "sr", "inc", "ltd",
    };

    public static string CapitalizeSentences(string s)
    {
        if (s.Length == 0) return s;
        var chars = s.ToCharArray();
        var capitalizeNext = true;
        for (var i = 0; i < chars.Length; i++)
        {
            var c = chars[i];
            if (capitalizeNext && char.IsLetter(c))
            {
                // "ß" uppercases to "SS" and ligatures to two letters; leave those alone rather than
                // splice two characters into one slot. char.ToUpperInvariant hands back the original
                // whenever the uppercase form is not a single char, which is exactly that guard.
                chars[i] = char.ToUpperInvariant(c);
                capitalizeNext = false;
            }
            else if (c == '\n')
            {
                capitalizeNext = true;
            }
            else if (c is '.' or '!' or '?')
            {
                // Only a terminator that ends the token ends a sentence: not the dots in
                // "example.com", "whisper.cpp" or "p.m.", nor the "?" in a URL query.
                char? next = i + 1 < chars.Length ? chars[i + 1] : null;
                var endsToken = next is null || char.IsWhiteSpace(next.Value) || ClosingMarks.Contains(next.Value);
                if (endsToken)
                {
                    if (!(c == '.' && IsAbbreviation(i, chars))) capitalizeNext = true;
                }
                else
                {
                    capitalizeNext = false;
                }
            }
            else if (!char.IsWhiteSpace(c) && !OpeningMarks.Contains(c))
            {
                capitalizeNext = false;
            }
        }
        return new string(chars);
    }

    /// Is the word before index `i` (letters and dots) an abbreviation or an initial?
    public static bool IsAbbreviation(int i, char[] chars)
    {
        var j = i - 1;
        var word = new List<char>();
        while (j >= 0 && (char.IsLetter(chars[j]) || chars[j] == '.')) { word.Add(chars[j]); j--; }
        if (word.Count == 0) return false;
        word.Reverse();
        var w = new string(word.ToArray()).ToLowerInvariant();
        if (Abbreviations.Contains(w)) return true;
        // "u.s", "a.m", "e.g": single letters separated by dots.
        return w.Contains('.') && w.Split('.', StringSplitOptions.RemoveEmptyEntries).All(p => p.Length == 1);
    }

    // ---- trimming helpers ----

    /// Swift's CharacterSet.whitespaces: tab plus the Unicode space separators, and deliberately
    /// NOT newlines. string.Trim() would take the newlines too and change what survives a filler cut.
    private static bool IsSpaceOnly(char c) =>
        c == '\t' || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;

    private static string TrimSpaces(string s)
    {
        var start = 0;
        var end = s.Length - 1;
        while (start <= end && IsSpaceOnly(s[start])) start++;
        while (end >= start && IsSpaceOnly(s[end])) end--;
        return s.Substring(start, end - start + 1);
    }

    private static string TrimPunctuationAndSpaces(string s)
    {
        var start = 0;
        var end = s.Length - 1;
        while (start <= end && (char.IsPunctuation(s[start]) || IsSpaceOnly(s[start]))) start++;
        while (end >= start && (char.IsPunctuation(s[end]) || IsSpaceOnly(s[end]))) end--;
        return s.Substring(start, end - start + 1);
    }
}
