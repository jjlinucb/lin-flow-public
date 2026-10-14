using System.Reflection;
using System.Text;

namespace LinFlow.Core;

/// Snaps a misheard word onto a known term: "Lend Flow" becomes "Lin Flow", "githubs" becomes
/// "GitHubs", "Linflow" becomes "Lin Flow".
///
/// Ported from GlossaryMatcher in ../../Sources/LinFlowCore/TextCleaner.swift. Every guard below
/// exists because of a specific wrong rewrite in real dictation, and the reason is kept beside it.
/// Changing one without reading the reason is how "clause" becomes "Claude" again.
public sealed class GlossaryMatcher
{
    public IReadOnlyList<string> Terms { get; }

    public GlossaryMatcher(IEnumerable<string> terms) => Terms = terms.ToList();

    /// Longer terms first so "Claude Code" wins over "Claude".
    private IEnumerable<string> OrderedTerms =>
        Terms.OrderByDescending(t => WordCount(t)).ThenByDescending(t => t.Length);

    private static int WordCount(string s) =>
        s.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;

    public string Apply(string text)
    {
        if (Terms.Count == 0) return text;
        var tokens = Tokenize(text);
        var wordIdx = Enumerable.Range(0, tokens.Count).Where(i => tokens[i].IsWord).ToList();
        var consumed = new HashSet<int>();
        var termSet = new HashSet<string>(Terms, StringComparer.Ordinal);

        foreach (var term in OrderedTerms)
        {
            var termWords = term.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            // Windows of the term's own word count plus the glued one-word form ("Linflow");
            // for one-word terms also the split two-word form ("work brain", "Sunny Veil").
            var sizes = termWords.Length > 1 ? new[] { termWords.Length, 1 } : new[] { 1, 2 };
            foreach (var n in sizes)
            {
                var joinerIsEmpty = termWords.Length == 1 && n == 2;
                var i = 0;
                while (i + n <= wordIdx.Count)
                {
                    var idxs = wordIdx.GetRange(i, n);
                    if (idxs.Any(consumed.Contains)) { i += 1; continue; }
                    var cores = idxs.Select(k => tokens[k].Core).ToList();
                    if (cores.Any(string.IsNullOrEmpty)) { i += 1; continue; }
                    // Two words split by a period are two words ("whisper.cpp. It").
                    if (joinerIsEmpty && tokens[idxs[0]].Trailing.Length > 0) { i += 1; continue; }

                    var replacement = Correction(cores, joinerIsEmpty, term, termSet);
                    if (replacement is not null)
                    {
                        int first = idxs[0], last = idxs[^1];
                        var t0 = tokens[first];
                        tokens[first] = t0 with { Text = t0.Leading + replacement + tokens[last].Trailing };
                        for (var k = first + 1; k <= last; k++) tokens[k] = tokens[k] with { Text = "" };
                        foreach (var k in idxs) consumed.Add(k);
                        i += n;
                    }
                    else i += 1;
                }
            }
        }
        return string.Concat(tokens.Select(t => t.Text));
    }

    /// Endings a speaker adds to a name: "Parakeets", "Lin Flow's", "Cambodian", "Cambodians".
    internal static readonly string[] Inflections = { "'s", "\u2019s", "s'", "s\u2019", "es", "s", "an", "n" };
    internal static readonly string[] PluralOrPossessive = { "'s", "\u2019s", "s'", "s\u2019", "es", "s" };

    /// The term, keeping any inflection the speaker used, if the window sounds like it.
    internal static string? Correction(List<string> cores, bool glued, string term, HashSet<string> termSet)
    {
        var termLower = term.ToLowerInvariant();
        if (glued)
        {
            // Two words that should be one ("work brain", "git hub"). Two everyday English words
            // are two words ("work again", "another epic"): only a part that is not a word can
            // be a mangled name, and even then within the term's edit tolerance.
            if (!cores.All(c => c.Length >= 3)) return null;
            var candidateG = string.Concat(cores);
            if (termSet.Contains(candidateG)) return null;
            var cg = candidateG.ToLowerInvariant();
            foreach (var suffix in PluralOrPossessive)
                if (cg.EndsWith(suffix, StringComparison.Ordinal) &&
                    cg[..^suffix.Length] == termLower) return term + suffix;
            if (cg == termLower) return term;
            var allWords = cores.All(c => IsDictionaryWord(c));
            if (allWords || cg.Length == 0 || termLower.Length == 0) return null;
            if (cg[0] != termLower[0]) return null;
            if (Math.Abs(cg.Length - termLower.Length) > Tolerance(termLower.Length)) return null;
            return Levenshtein(cg, termLower) <= Tolerance(termLower.Length) ? term : null;
        }

        var candidate = string.Join(" ", cores);
        if (termSet.Contains(candidate)) return null;                       // already right
        if (string.Equals(candidate, termLower, StringComparison.OrdinalIgnoreCase)) return term;  // casing only

        // Inflections of a term that is already right stay ("Parakeets", "Lin Flow's",
        // "Cambodians"); inflections of a lowercase or glued term keep their ending.
        var termGlued = termLower.Replace(" ", "");
        var stems = new List<string> { candidate };
        for (var round = 0; round < 2; round++)
        {
            var next = new List<string>();
            foreach (var s in stems)
                foreach (var suffix in Inflections)
                    if (s.Length > suffix.Length + 2 && s.EndsWith(suffix, StringComparison.Ordinal))
                        next.Add(s[..^suffix.Length]);
            foreach (var s in next)
            {
                if (termSet.Contains(s)) return null;
                var l = s.ToLowerInvariant();
                if (l == termLower || l == termGlued) return term + candidate[s.Length..];   // "githubs" -> "GitHubs"
            }
            if (next.Count == 0) break;
            stems = next;
        }

        // The whole word first ("John Lynn" -> "John Lin"), then a plural or possessive of a
        // near miss ("Lend Flow's" -> "Lin Flow's").
        if (Matches(candidate, term)) return term;
        foreach (var suffix in PluralOrPossessive)
            if (candidate.Length > suffix.Length + 2 && candidate.EndsWith(suffix, StringComparison.Ordinal) &&
                Matches(candidate[..^suffix.Length], term)) return term + suffix;
        return null;
    }

    public static bool Matches(string candidate, string term)
    {
        if (candidate == term) return false;
        var c = candidate.ToLowerInvariant();
        var t = term.ToLowerInvariant();
        if (c == t) return true;
        var cWords = c.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var tWords = t.Split(' ', StringSplitOptions.RemoveEmptyEntries);

        if (cWords.Length == 1 && tWords.Length > 1)
        {
            // "linflow" / "whisperflow" vs "lin flow" / "wispr flow": the word has to split into
            // the term's words, each part starting with its word's letter, within the whole
            // term's tolerance. "johnlyn" is "john" + "lyn"; "Johnson" has no "l" part.
            var glued = string.Concat(tWords);
            if (IsDictionaryWord(c)) return false;
            if (c == glued) return true;
            var d = GluedDistance(c, tWords, 0);
            return d is not null && d <= Tolerance(glued.Length);
        }

        if (cWords.Length != tWords.Length) return false;
        for (var i = 0; i < cWords.Length; i++)
        {
            string a = cWords[i], b = tWords[i];
            if (a.Length == 0 || b.Length == 0) return false;
            if (a[0] != b[0]) return false;
            // "Claude's code" is about Claude's code, not "Claude Code".
            if (a.Any(ch => ch is '\'' or '\u2019') && !b.Any(ch => ch is '\'' or '\u2019')) return false;
            // A verb form is a verb, not a name: "Claude coded" stays.
            if ((a.EndsWith("ed", StringComparison.Ordinal) && !b.EndsWith("ed", StringComparison.Ordinal)) ||
                (a.EndsWith("ing", StringComparison.Ordinal) && !b.EndsWith("ing", StringComparison.Ordinal))) return false;
            // "John Lee" and "John Lin" are two different people. A word that is itself a
            // real name only becomes another name when it actually sounds like one -- same
            // consonant skeleton, and the target is a name too. Plain near-misses that are
            // nobody's name ("Lend Flow", "Whisper Flow", "Cloud Code") are untouched by this.
            if (a != b && PersonalNames.Contains(a) &&
                (NameKey(a) != NameKey(b) || !PersonalNames.Contains(b))) return false;
        }

        if (cWords.Length == 1)
        {
            // An ordinary English word is never a misspelling of a name: "clause" and "cloud" stay
            // themselves even though they are one edit from "Claude", and "multi-team" is not
            // "Northwind". (Wrong words the recognizer keeps producing belong in the Dictionary's
            // corrections instead.)
            if (IsDictionaryWord(c)) return false;
            if (c.Contains('-') && c.Split('-').All(p => IsDictionaryWord(p))) return false;
        }

        // Edit distance scaled to the term's length. Matching on the consonant skeleton
        // alone used to turn "could", "cold" and "cloud" into "Claude".
        return Levenshtein(c, t) <= Tolerance(t.Length);
    }

    /// Smallest total edit distance over every way of cutting `c` into the remaining words'
    /// parts whose first letters match, or null when no cut lines up.
    internal static int? GluedDistance(string c, string[] words, int from)
    {
        if (from >= words.Length) return null;
        var word = words[from];
        if (c.Length == 0 || word.Length == 0 || c[0] != word[0]) return null;
        if (from == words.Length - 1) return Levenshtein(c, word);
        if (c.Length < 2) return null;
        int? best = null;
        for (var cut = 1; cut < c.Length; cut++)
        {
            var rest = GluedDistance(c[cut..], words, from + 1);
            if (rest is null) continue;
            var d = Levenshtein(c[..cut], word) + rest.Value;
            if (best is null || d < best.Value) best = d;
        }
        return best;
    }

    /// A name reduced to its spelling variants: "Lynn" and "Lin" are the same name written
    /// two ways, "Lane" and "Lin" are not. `Key`'s consonant skeleton is too lossy here --
    /// it throws away every vowel, so "Lane", "Lin", "Lynn" and "Loon" all collapse to "ln".
    public static string NameKey(string s)
    {
        var sb = new StringBuilder();
        char? prev = null;
        foreach (var ch in s.ToLowerInvariant())
        {
            var c = ch == 'y' ? 'i' : ch;
            if (prev == c) continue;               // "Lynn" -> "lin"
            sb.Append(c);
            prev = c;
        }
        if (sb.Length > 2 && sb[^1] == 'e') sb.Length -= 1;   // silent "e": "Lane" -> "lan"
        return sb.ToString();
    }

    public static int Tolerance(int length) => length switch
    {
        < 4 => 0,
        <= 6 => 1,
        <= 11 => 2,
        _ => 3,
    };

    /// Consonant skeleton: "Wispr Flow" -> "wsprflw", "Whisper Flow" -> "whsprflw",
    /// "Lin Flow" -> "lnflw", "Line Flow" -> "lnflw". Leading vowel kept, and so is a
    /// trailing consonant - the Swift's comment used to drop it and was wrong.
    public static string Key(string s)
    {
        var sb = new StringBuilder();
        char? prev = null;
        foreach (var c in s.ToLowerInvariant())
        {
            if (!char.IsLetterOrDigit(c)) continue;
            var isVowel = "aeiouy".Contains(c);
            if (isVowel && sb.Length > 0) continue;
            if (prev == c) continue;
            sb.Append(c);
            prev = c;
        }
        return sb.ToString();
    }

    public static int Levenshtein(string a, string b)
    {
        if (a.Length == 0) return b.Length;
        if (b.Length == 0) return a.Length;
        var prev = new int[b.Length + 1];
        var cur = new int[b.Length + 1];
        for (var j = 0; j <= b.Length; j++) prev[j] = j;
        for (var i = 1; i <= a.Length; i++)
        {
            cur[0] = i;
            for (var j = 1; j <= b.Length; j++)
            {
                var cost = a[i - 1] == b[j - 1] ? 0 : 1;
                cur[j] = Math.Min(Math.Min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
            }
            (prev, cur) = (cur, prev);
        }
        return prev[b.Length];
    }

    // MARK: the two word lists

    /// The Mac reads /usr/share/dict/words lazily; here the same BSD web2 list is embedded in the
    /// assembly, because Windows ships no dictionary file.
    private static readonly Lazy<HashSet<string>> EnglishWords = new(() =>
    {
        var set = new HashSet<string>(StringComparer.Ordinal);
        using var stream = Assembly.GetExecutingAssembly()
            .GetManifestResourceStream("LinFlow.Core.Resources.words.txt");
        if (stream is null) return set;              // no list: the guard simply never fires
        using var reader = new StreamReader(stream);
        while (reader.ReadLine() is { } line)
        {
            var w = line.Trim();
            if (w.Length > 0) set.Add(w.ToLowerInvariant());
        }
        return set;
    }, isThreadSafe: true);

    public static bool IsDictionaryWord(string word) => EnglishWords.Value.Contains(word.ToLowerInvariant());

    /// Common personal names, for the rule in `Matches`: one real name is never rewritten
    /// into a different real name. Weighted toward the names John actually dictates.
    /// Without this, "John Lee", "John Liu", "John Lim", "John Liang", "John Lam" and
    /// "John Lang" all became "John Lin" -- the matching "John" donated enough of the
    /// phrase's edit budget to cover the whole surname.
    public static IReadOnlySet<string> PersonalNames { get; } = new HashSet<string>(
        NameBlock.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries), StringComparer.Ordinal);

    private const string NameBlock = @"
        lee li lim lin ling liang liu lam lang long lu lui loo law lo loh luk lai lau leung liao lien chan chen
        cheng chang chiang chin ching cho choi chou chow chu chun chung tsai tsang tsao tse tseng tsui tu tuan
        tung fan fang feng fong foo fu gao ge gong gu guo han hao he ho hong hou hsu hu hua huang hui hung hwang
        jang jeong ji jiang jin jung kang kao ke khoo kim ko koh kong ku kuo kwan kwok kwon ma mak mao mei meng
        min ming mo moon mun na nam ng ngo nguyen ni ning niu ou ouyang pak pan pang park pei peng pham phan qi
        qian qin qiu quach ran rao ren ruan sam sang seo seok seong sha shan shang shao shen sheng shi shin shu
        shum sim sin sit siu son song su sui sun sung sze tai tam tan tang tao teng teo thai tian tien ting to
        tong tran trinh truong wan wang wei wen weng wong woo wu xie xin xing xiong xu xue yan yang yao ye yee
        yeh yen yeo yeoh yeung yi yim yin ying yip yiu yoo yoon you young yu yuan yue yuen yun zeng zhan zhang
        zhao zhen zheng zhong zhou zhu cody coty coady brady casey blake drew reese rowan sloan tate wade avery
        jody jodi cory corey kody len lenn linn lynne lyn linh minh mai loan lien nhan bao dao hao thao chau chi
        levin levine lund lind lian lok low lowe loy luce lund lindy lindsay lindsey leland lenny leona leonel
        levi lew liam lila lily lina lino lionel lola lonnie lora loren lorena lorenzo loretta lorna lorraine
        lottie lou louie lowell lucia lucille lucinda luis luisa luther lyle lyman lynda lyndon lynette lund
        lange lantz landry landon claudia claudette claudine jan jann joann johann johanna jens jenny jess jodie
        joni juana juanita jorge jules julius jude junior kaylee kayla adams allen anderson bailey baker barnes
        bell bennett brooks brown bryant burns butler campbell carter chase clark cole collins cook cooper cox
        craig cruz curtis davis dean diaz dixon duncan dunn edwards ellis evans fisher fleming ford foster fox
        freeman fuller garcia gibson gordon graham grant gray green griffin hall hamilton harris hart hayes
        henderson hill holmes hopkins howard hughes hunt hunter jackson james jenkins johnson jones jordan kelly
        kennedy king knight lane lawrence lawson leonard lewis lloyd logan lopez lucas lynch lynn mason mccarthy
        miller mills mitchell moore morgan morris murphy murray nelson newman nichols norris owens palmer parker
        patterson payne perez perry peters phillips pierce porter powell price quinn reed reeves reid reyes
        reynolds rice richards riley roberts robinson rogers rose ross russell ryan sanders scott shaw shelton
        simmons simpson sims smith snyder spencer stevens stewart stone sullivan sutton taylor thomas thompson
        todd torres tucker turner vaughn wagner walker wallace walsh ward warren watson watts weaver webb
        webster wells west wheeler white wilson wood woods wright aaron adam adrian alan albert alex alexander
        alice amanda amy andrea andrew angela anna anne anthony april arthur ashley audrey barbara benjamin beth
        betty brandon brenda brian bruce bryan calvin cameron carl carol caroline catherine charles charlotte
        cheryl chris christian christina christine christopher cindy claire clara clarence claude cliff colin
        connie crystal cynthia dale dan daniel danny darren dave david dawn debbie deborah debra dennis derek
        diana diane don donald donna doris doug douglas dylan earl eddie edith edward edwin eileen
        elaine eleanor elena eli elizabeth ellen emily emma eric erica erin ernest esther ethan eugene eva evan
        evelyn frances frank fred frederick gabriel gail gary gene george gerald gina glen glenn gloria grace
        greg gregory hannah harold harry heather helen henry herbert holly hugh ian irene isaac isabel ivan jack
        jackie jacob jacqueline jamie jane janet janice jason jay jean jeff jeffrey jenna jennifer jeremy jerry
        jesse jessica jill jimmy joan joanne joel john johnny jon jonathan jose joseph josh joshua joy joyce
        juan judith judy julia julie justin karen kate katherine kathleen kathy katie keith ken kenneth kevin
        kimberly kyle larry laura lauren leo leon leslie linda lisa lois lori louis louise lucy luke lydia
        madison marc marcus margaret maria marie marilyn marion mark marvin mary matthew maureen max maxine
        megan melanie melissa michael michelle mike mildred miriam molly monica nancy naomi natalie nathan neil
        nicholas nick nicole noah norma norman olivia oscar owen pam pamela pat patricia patrick paul paula
        pearl peggy peter phil philip phyllis rachel ralph randy ray raymond rebecca regina rene rhonda richard
        rick rita rob robert roberta robin rodney roger ron ronald rosemary roy ruby ruth sally sam samantha
        samuel sandra sara sarah sean seth shane shannon sharon shawn sheila shelly sherry shirley sidney simon
        sophia stacy stan stanley stella stephanie stephen steve steven stuart sue susan suzanne sydney sylvia
        tammy tara ted teresa terry theodore theresa tiffany tim timothy tina tom tommy tony tracy travis trevor
        tyler valerie vanessa vera vernon veronica vicki victor victoria vincent violet virginia vivian wade
        walter wanda wayne wendy wesley will william willie wilma yvonne zachary";

    // MARK: tokens

    /// Runs of whitespace and runs of non-whitespace, in order, so the original spacing
    /// (including newlines) survives a rebuild.
    internal readonly record struct Token(string Text, bool IsWord)
    {
        /// Opening quotes/brackets glued to the front of a word.
        public string Leading
        {
            get
            {
                var n = 0;
                while (n < Text.Length && char.IsPunctuation(Text[n]) && Text[n] != '\'') n++;
                return Text[..n];
            }
        }

        /// Commas, periods, closing quotes glued to the end. Apostrophes stay with the
        /// word ("Claude's"); dots inside a word ("whisper.cpp", "p.m") stay in the core.
        public string Trailing
        {
            get
            {
                var body = Text[Leading.Length..];
                var end = body.Length;
                while (end > 0 && char.IsPunctuation(body[end - 1]) &&
                       body[end - 1] != '\'' && body[end - 1] != '\u2019') end--;
                var t = body[end..];
                // A closing quote or a bare possessive apostrophe ("Parakeets'") is trailing too.
                if (end > 0 && (body[end - 1] == '\'' || body[end - 1] == '\u2019')) t = body[end - 1] + t;
                return t;
            }
        }

        public string Core
        {
            get
            {
                var start = Leading.Length;
                var end = Text.Length - Trailing.Length;
                return start <= end ? Text[start..end] : "";
            }
        }
    }

    internal static List<Token> Tokenize(string s)
    {
        var tokens = new List<Token>();
        var current = new StringBuilder();
        var currentIsWord = false;
        foreach (var c in s)
        {
            var isWordChar = !char.IsWhiteSpace(c);
            if (current.Length == 0)
            {
                current.Append(c);
                currentIsWord = isWordChar;
            }
            else if (isWordChar == currentIsWord) current.Append(c);
            else
            {
                tokens.Add(new Token(current.ToString(), currentIsWord));
                current.Clear().Append(c);
                currentIsWord = isWordChar;
            }
        }
        if (current.Length > 0) tokens.Add(new Token(current.ToString(), currentIsWord));
        return tokens;
    }
}
