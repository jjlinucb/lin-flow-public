using System.Text;
using System.Text.RegularExpressions;

namespace LinFlow.Core;

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
public static class NumberWords
{
    private static readonly Dictionary<string, int> Units = new(StringComparer.Ordinal)
    {
        ["zero"] = 0, ["one"] = 1, ["two"] = 2, ["three"] = 3, ["four"] = 4,
        ["five"] = 5, ["six"] = 6, ["seven"] = 7, ["eight"] = 8, ["nine"] = 9,
    };

    private static readonly Dictionary<string, int> Teens = new(StringComparer.Ordinal)
    {
        ["ten"] = 10, ["eleven"] = 11, ["twelve"] = 12, ["thirteen"] = 13, ["fourteen"] = 14,
        ["fifteen"] = 15, ["sixteen"] = 16, ["seventeen"] = 17, ["eighteen"] = 18, ["nineteen"] = 19,
    };

    private static readonly Dictionary<string, int> Tens = new(StringComparer.Ordinal)
    {
        ["twenty"] = 20, ["thirty"] = 30, ["forty"] = 40, ["fifty"] = 50,
        ["sixty"] = 60, ["seventy"] = 70, ["eighty"] = 80, ["ninety"] = 90,
    };

    private static readonly Dictionary<string, int> Scales = new(StringComparer.Ordinal)
    {
        ["hundred"] = 100, ["thousand"] = 1_000, ["million"] = 1_000_000, ["billion"] = 1_000_000_000,
    };

    /// The scale words that "a" turns into a figure. Not million or billion: "one in a
    /// million" and "thanks a million" are idiom, and 1000000 reads worse than the words.
    private static readonly HashSet<string> CountedAfterA = new(StringComparer.Ordinal) { "hundred", "thousand" };

    /// An ordinal right after a number means the number was part of it: "the twenty second".
    private static readonly HashSet<string> Ordinals = new(StringComparer.Ordinal)
    {
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
        "eighteenth", "nineteenth", "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth",
        "seventieth", "eightieth", "ninetieth", "hundredth", "thousandth", "millionth",
        "half", "halves", "thirds", "quarter", "quarters", "fourths", "fifths", "sixths", "eighths",
    };

    /// What makes a lone "one" a count rather than a pronoun.
    private static readonly HashSet<string> UnitsOfMeasure = new(StringComparer.Ordinal)
    {
        "percent", "dollar", "dollars", "cent", "cents", "euro", "euros", "pound", "pounds",
        "second", "seconds", "minute", "minutes", "hour", "hours", "day", "days", "week", "weeks",
        "month", "months", "year", "years", "time", "times", "o'clock", "degree", "degrees",
        "mile", "miles", "kilometer", "kilometers", "meter", "meters", "foot", "feet", "inch", "inches",
        "gram", "grams", "kilogram", "kilograms", "ounce", "ounces", "liter", "liters", "gallon", "gallons",
        "byte", "bytes", "kilobyte", "megabyte", "gigabyte", "terabyte", "page", "pages", "point", "points",
        "person", "people", "copy", "copies", "star", "stars", "line", "lines", "word", "words",
    };

    /// The apostrophe is in the word pattern on purpose: "o'clock" is one token, and it is one of
    /// the unit nouns that turns a lone "one" into a figure.
    private static readonly Regex WordPattern =
        new("[A-Za-z][A-Za-z']*", RegexOptions.CultureInvariant | RegexOptions.Compiled);

    /// A word of the source text. Start/End are offsets into the original string. The Mac walks
    /// the text as an NSString, whose offsets are UTF-16 units, so these indices line up with the
    /// Swift's NSRanges exactly -- no grapheme/code-unit divergence to reconcile.
    private readonly record struct Token(int Start, int Length, string Lower)
    {
        public int End => Start + Length;
    }

    /// One number spelled by run[Start..End) -- End exclusive, as the Swift's Range<Int> is.
    private readonly record struct Group(int Value, int Start, int End);

    private static readonly HashSet<string> Months = new(StringComparer.Ordinal)
    {
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    };

    /// The ordinals a day of the month is made of. "twenty first" is 20 and 1.
    private static readonly Dictionary<string, int> DayOrdinals = new(StringComparer.Ordinal)
    {
        ["first"] = 1, ["second"] = 2, ["third"] = 3, ["fourth"] = 4, ["fifth"] = 5, ["sixth"] = 6,
        ["seventh"] = 7, ["eighth"] = 8, ["ninth"] = 9, ["tenth"] = 10, ["eleventh"] = 11, ["twelfth"] = 12,
        ["thirteenth"] = 13, ["fourteenth"] = 14, ["fifteenth"] = 15, ["sixteenth"] = 16, ["seventeenth"] = 17,
        ["eighteenth"] = 18, ["nineteenth"] = 19, ["twentieth"] = 20, ["thirtieth"] = 30,
    };

    /// "st", "nd", "rd" or "th": 1st, 22nd, 13th.
    private static string OrdinalSuffix(int n)
    {
        if (n % 100 is >= 11 and <= 13) return "th";
        return (n % 10) switch { 1 => "st", 2 => "nd", 3 => "rd", _ => "th" };
    }

    /// Nothing but spaces between tokens a and b.
    private static bool Spaced(List<Token> tokens, int a, int b, string text)
    {
        var gap = text.AsSpan(tokens[a].End, tokens[b].Start - tokens[a].End);
        return gap.Length > 0 && gap.Trim(' ').IsEmpty;
    }

    /// The day of the month spelled from token k, and how many tokens it takes: "thirtieth" is 30
    /// in one, "twenty first" 21 in two. Nothing past 31.
    private static (int Value, int Count)? Day(List<Token> tokens, int k, string text)
    {
        if (k >= tokens.Count) return null;
        if (Tens.TryGetValue(tokens[k].Lower, out var t) && (t == 20 || t == 30) && k + 1 < tokens.Count
            && Spaced(tokens, k, k + 1, text) && DayOrdinals.TryGetValue(tokens[k + 1].Lower, out var o) && o <= 9 && t + o <= 31)
            return (t + o, 2);
        if (DayOrdinals.TryGetValue(tokens[k].Lower, out var d)) return (d, 1);
        return null;
    }

    /// A month as the engines write it, capitalized, so "you may first" and "march on" stay words.
    private static bool IsMonth(List<Token> tokens, int k, string text) =>
        k >= 0 && k < tokens.Count && Months.Contains(tokens[k].Lower) && char.IsUpper(text[tokens[k].Start]);

    /// Days written as figures, and the tokens they used: "September thirtieth" and "the
    /// thirtieth of September".
    private static HashSet<int> Dates(List<Token> tokens, string text, List<(int Start, int End, string Text)> edits)
    {
        var used = new HashSet<int>();
        for (var k = 0; k < tokens.Count; k++)
        {
            if (used.Contains(k)) continue;
            int? start = null;
            if (IsMonth(tokens, k - 1, text) && Spaced(tokens, k - 1, k, text))
            {
                start = k;                                                  // September thirtieth
            }
            else if (k > 0 && tokens[k - 1].Lower == "the" && Day(tokens, k, text) is { } d0
                     && k + d0.Count + 1 < tokens.Count && Spaced(tokens, k + d0.Count - 1, k + d0.Count, text)
                     && tokens[k + d0.Count].Lower == "of" && IsMonth(tokens, k + d0.Count + 1, text))
            {
                start = k;                                                  // the thirtieth of September
            }
            if (start is not { } s || Day(tokens, s, text) is not { } d) continue;
            edits.Add((tokens[s].Start, tokens[s + d.Count - 1].End, d.Value + OrdinalSuffix(d.Value)));
            for (var u = s; u < s + d.Count; u++) used.Add(u);
        }
        return used;
    }

    /// The digit words after "point" that follow token end: "point five" is "5", "point one four"
    /// is "14". Null when "point" is not there or no digit follows it.
    private static (string Digits, int Last)? Decimal(List<Token> tokens, int end, HashSet<int> used, string text)
    {
        var p = end + 1;
        if (p + 1 >= tokens.Count || tokens[p].Lower != "point" || !Spaced(tokens, end, p, text)) return null;
        var digits = new StringBuilder();
        int last = p, k = p + 1;
        while (k < tokens.Count && !used.Contains(k) && Spaced(tokens, last, k, text))
        {
            // "two point oh" is 2.0.
            int? d = tokens[k].Lower == "oh" ? 0 : Units.TryGetValue(tokens[k].Lower, out var u) ? u : null;
            if (d is null) break;
            digits.Append(d.Value);
            last = k; k += 1;
        }
        return digits.Length == 0 ? null : (digits.ToString(), last);
    }

    private static int? Value(string word)
    {
        if (Units.TryGetValue(word, out var u)) return u;
        if (Teens.TryGetValue(word, out var t)) return t;
        if (Tens.TryGetValue(word, out var n)) return n;
        return null;
    }

    private static bool IsNumberWord(string word) => Value(word) is not null || Scales.ContainsKey(word);

    /// The text with spoken numbers written as digits.
    public static string Apply(string text)
    {
        if (string.IsNullOrEmpty(text)) return text;

        var matches = WordPattern.Matches(text);
        if (matches.Count == 0) return text;

        var tokens = new List<Token>(matches.Count);
        foreach (Match m in matches) tokens.Add(new Token(m.Index, m.Length, m.Value.ToLowerInvariant()));

        var edits = new List<(int Start, int End, string Text)>();
        var used = Dates(tokens, text, edits);
        var i = 0;
        while (i < tokens.Count)
        {
            if (used.Contains(i) || !IsNumberWord(tokens[i].Lower)) { i += 1; continue; }

            // The longest run of number words, with "and" allowed between two of them.
            var end = i;
            while (end + 1 < tokens.Count && !used.Contains(end + 1))
            {
                var next = tokens[end + 1].Lower;
                if (IsNumberWord(next)) { end += 1; continue; }
                if (next == "and" && end + 2 < tokens.Count && IsNumberWord(tokens[end + 2].Lower)) { end += 2; continue; }
                break;
            }

            var run = tokens.GetRange(i, end - i + 1);
            if (end + 1 < tokens.Count && Ordinals.Contains(tokens[end + 1].Lower))
            {
                i = end + 1; continue;                                  // "the twenty second"
            }
            if (Hyphenated(run, text)) { i = end + 1; continue; }       // "one-on-one"
            // A bare scale word is speech, not a figure: "a few hundred", "thousands of them".
            // After "a" it counts, which John asked for on 2026-09-25: "a hundred" is 100 and
            // "a hundred forty volts" is 140 volts. The "a" goes with it.
            int? article = null;
            if (Scales.ContainsKey(run[0].Lower))
            {
                if (!CountedAfterA.Contains(run[0].Lower) || ArticleBefore(i, tokens, text) is not { } a) { i = end + 1; continue; }
                article = a;
            }

            var lowered = new List<string>(run.Count);
            foreach (var t in run) lowered.Add(t.Lower);

            // Each number in the run replaces exactly the words that spell it, so the
            // separators between separate numbers ("1, 2, 3") are left as spoken.
            var after = end + 1;
            foreach (var group in MergeYears(Parse(lowered)))
            {
                var first = group.Start == 0 && article is { } at ? at : run[group.Start].Start;
                // The run's last number may go on as a decimal: "five point five" is 5.5, and
                // "one point five" is 1.5 though a lone "one" is otherwise a pronoun.
                if (group.End == run.Count && Decimal(tokens, end, used, text) is { } dec)
                {
                    edits.Add((first, tokens[dec.Last].End, $"{group.Value}.{dec.Digits}"));
                    after = dec.Last + 1;
                    continue;
                }
                if (!Convertible(lowered, group, run.Count, tokens, i + group.Start)) continue;
                var last = run[group.End - 1];
                edits.Add((first, last.End, group.Value.ToString()));
            }
            i = after;
        }

        if (edits.Count == 0) return text;
        edits.Sort((a, b) => a.Start.CompareTo(b.Start));
        var outText = new StringBuilder(text);
        // Back to front, so an earlier edit's offsets are still the ones we measured.
        for (var k = edits.Count - 1; k >= 0; k--)
        {
            var (start, stop, replacement) = edits[k];
            outText.Remove(start, stop - start);
            outText.Insert(start, replacement);
        }
        return outText.ToString();
    }

    /// A lone "one" is only a number when it is counting something.
    private static bool Convertible(List<string> lowered, Group group, int run, List<Token> tokens, int index)
    {
        var alone = group.End - group.Start == 1 && lowered[group.Start] == "one" && run == 1;
        if (!alone) return true;
        if (index + 1 >= tokens.Count) return false;
        return UnitsOfMeasure.Contains(tokens[index + 1].Lower);
    }

    /// Where the "a" right before tokens[index] starts, with nothing but spaces between the two.
    private static int? ArticleBefore(int index, List<Token> tokens, string text)
    {
        if (index == 0 || tokens[index - 1].Lower != "a") return null;
        var a = tokens[index - 1];
        var gap = text.AsSpan(a.End, tokens[index].Start - a.End);
        return gap.Length > 0 && gap.Trim(' ').IsEmpty ? a.Start : null;
    }

    /// True when the run sits inside a hyphenated compound.
    private static bool Hyphenated(List<Token> run, string text)
    {
        var before = run[0].Start - 1;
        var after = run[run.Count - 1].End;
        if (before >= 0 && text[before] == '-') return true;
        if (after < text.Length && text[after] == '-') return true;
        return false;
    }

    /// A year said as two numbers is one number: "nineteen eighty four" is 1984 and
    /// "twenty twenty six" is 2026. Kept narrow, because "twenty thirty" is usually a range.
    private static List<Group> MergeYears(List<Group> groups)
    {
        if (groups.Count < 2) return groups;
        var merged = new List<Group>(groups.Count);
        var i = 0;
        while (i < groups.Count)
        {
            var a = groups[i];
            if (i + 1 < groups.Count)
            {
                var b = groups[i + 1];
                var century = (a.Value >= 13 && a.Value <= 19) || a.Value == 20;
                var decade = a.Value == 20 ? b.Value is >= 20 and <= 29 : b.Value is >= 20 and <= 99;
                if (century && decade && a.End == b.Start)
                {
                    merged.Add(new Group(a.Value * 100 + b.Value, a.Start, b.End));
                    i += 2;
                    continue;
                }
            }
            merged.Add(a);
            i += 1;
        }
        return merged;
    }

    /// Splits a run of number words into the numbers it actually spells. "twenty two" is one
    /// number, "one two three" is three, "two thousand twenty six" is one, and a word that
    /// cannot join what is already built starts a new number.
    private static List<Group> Parse(List<string> words)
    {
        var groups = new List<Group>();
        int start = 0, taken = 0, total = 0, current = 0;
        // The last of thousand, million and billion this number used. Each one after it has to
        // be smaller, so a second "thousand" belongs to the next number.
        int? smallestBig = null;
        bool ones = false, tenslot = false, hundreds = false, pending = false;

        // Ends the number at the last word it took, so an "and" between two numbers stays in
        // the text: "panels one and two" is "panels 1 and 2", not "panels 1 2".
        void Flush()
        {
            if (taken <= start || !pending) return;
            groups.Add(new Group(total + current, start, taken));
            total = 0; current = 0; smallestBig = null;
            ones = false; tenslot = false; hundreds = false; pending = false;
        }

        var i = 0;
        while (i < words.Count)
        {
            var w = words[i];
            if (w == "and") { i += 1; continue; }
            if (Scales.TryGetValue(w, out var scale))
            {
                if (scale == 100)
                {
                    current = (current == 0 ? 1 : current) * 100;
                    hundreds = true; ones = false; tenslot = false;
                }
                else
                {
                    total += (current == 0 && total == 0 ? 1 : current) * scale;
                    current = 0; ones = false; tenslot = false; hundreds = false;
                    smallestBig = scale;
                }
                pending = true;
                i += 1; taken = i;
                continue;
            }
            var v = Value(w);
            if (v is null) break;
            // "above" means there is already a bigger place to slot into, which is what lets
            // "twenty" follow "two thousand" but not follow another bare "twenty".
            var above = hundreds || total > 0;
            bool canJoin;
            if (Tens.ContainsKey(w)) canJoin = !tenslot && !ones && above;
            else if (Teens.ContainsKey(w)) canJoin = !ones && !tenslot && above;
            else canJoin = !ones && (tenslot || above);
            // A number never says the same place twice, so a word that leads into one starts
            // the next number: "eight hundred and seven hundred" is 800 and 700, not 80700.
            if (canJoin && RepeatsAPlace(words, i, ones, tenslot, hundreds, smallestBig)) canJoin = false;
            if (pending && !canJoin) { Flush(); start = i; }
            current += v.Value;
            if (Tens.ContainsKey(w)) tenslot = true; else ones = true;
            pending = true;
            i += 1; taken = i;
        }
        Flush();
        return groups;
    }

    /// True when joining words[index] to the number being built would give that number a place
    /// it already has: a second hundreds, or a thousand after a thousand. It looks only as far
    /// as the words could still belong to this number, so "two thousand five, three thousand"
    /// is still 2005 and 3000.
    private static bool RepeatsAPlace(List<string> words, int index, bool ones, bool tenslot, bool hundreds, int? smallestBig)
    {
        if (Tens.ContainsKey(words[index])) tenslot = true; else ones = true;
        for (var j = index + 1; j < words.Count; j++)
        {
            var w = words[j];
            if (w == "and") continue;
            if (Scales.TryGetValue(w, out var scale))
            {
                if (scale != 100) return smallestBig is { } big && scale >= big;
                if (hundreds) return true;
                hundreds = true; ones = false; tenslot = false;
                continue;
            }
            // A word that cannot join ends this number, and nothing after it is this number's.
            var joins = Tens.ContainsKey(w) || Teens.ContainsKey(w) ? !tenslot && !ones : !ones;
            if (!joins) return false;
            if (Tens.ContainsKey(w)) tenslot = true; else ones = true;
        }
        return false;
    }
}
