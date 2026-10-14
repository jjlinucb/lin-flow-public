namespace LinFlow.Core;

/// Running notes: a few bullets a minute, written while the meeting is still going. Every pass
/// hands the model the newest stretch of the live transcript and the notes already taken, and
/// gets back zero to three new bullets, each stamped with where in the meeting it came from and
/// appended to the note's running-notes.md. Ported from ../../Sources/LinFlowCore/RunningNotes.swift;
/// the same file format on both machines. This is the pure half; the model is an INoteWriter and
/// the timer is RunningNotesTaker.
public static class RunningNotes
{
    /// Seconds between passes.
    public static double Interval = 60;
    /// A pass with less new material than this waits.
    public static int MinimumNewWords = 40;
    /// One pass reads at most this much; the rest waits for the next pass, oldest first.
    public static int MaximumWindowWords = 600;
    /// The last stretch of the meeting gets a pass with less than the usual minimum.
    public static int FinalMinimumWords = 12;
    /// How many earlier bullets the model sees, so it does not write the same thing twice.
    public static int ContextBullets = 10;

    /// The unprocessed segments in time order, capped to a word budget (never a partial
    /// segment, always at least one).
    public static List<TranscriptSegment> Window(IEnumerable<TranscriptSegment> segments, ISet<string> processed, int? maxWords = null)
    {
        var budget = maxWords ?? MaximumWindowWords;
        var result = new List<TranscriptSegment>();
        var words = 0;
        foreach (var s in segments.OrderBy(s => s.Start).Where(s => !processed.Contains(s.Id)))
        {
            var n = WordCount(s.Text);
            if (result.Count > 0 && words + n > budget) break;
            result.Add(s);
            words += n;
        }
        return result;
    }

    public static int WordCount(string text) => text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
    public static int WordCount(IEnumerable<TranscriptSegment> segments) => segments.Sum(s => WordCount(s.Text));

    /// Whether to run a pass now: enough new words and enough time since the last pass, or the
    /// meeting has ended and anything of substance is still unnoted.
    public static bool IsDue(int newWords, double sinceLastSeconds, bool final) =>
        final ? newWords >= FinalMinimumWords : newWords >= MinimumNewWords && sinceLastSeconds >= Interval;

    /// One pass as Markdown: a bullet per note, stamped with where the stretch began.
    public static string Format(IReadOnlyList<string> bullets, double startSeconds)
    {
        if (bullets.Count == 0) return "";
        var stamp = new TranscriptSegment { Start = startSeconds }.TimestampLabel;
        return string.Concat(bullets.Select(b => $"- [{stamp}] {b}\n"));
    }

    /// The most recent bullets of running-notes.md, stamps removed, as context for the model.
    public static List<string> Recent(string notes, int? count = null)
    {
        var all = new List<string>();
        foreach (var raw in notes.Split('\n'))
        {
            var s = raw.Trim();
            if (!(s.StartsWith("- ") || s.StartsWith("* "))) continue;
            s = s[2..].Trim();
            if (s.StartsWith('['))
            {
                var close = s.IndexOf(']');
                if (close >= 0) s = s[(close + 1)..].Trim();
            }
            if (s.Length > 0) all.Add(s);
        }
        var n = count ?? ContextBullets;
        return all.Count <= n ? all : all.GetRange(all.Count - n, n);
    }

    /// What the model gave back, made fit to keep: fragments and labels gone, anything the
    /// stretch never said gone, repeats gone.
    public static List<string> Filter(IEnumerable<string> bullets, IReadOnlyList<string> previous, string transcript) =>
        DropRepeats(bullets.Select(WorthKeeping).Where(b => b is not null).Select(b => b!).Where(b => Grounded(b, transcript, previous)), previous);

    /// A note that names a number, a date, a month, a weekday or a person the stretch never
    /// mentioned is an invention, and an invented deadline is worse than no note (the Mac's
    /// on-device model produced "Friday, October 18th" for a transcript with neither word).
    /// Numbers are compared as digits ("two" and "2" match, "40,000" and "$40,000" match),
    /// names and dates as words.
    public static bool Grounded(string bullet, string transcript, IReadOnlyList<string>? previous = null)
    {
        var sourceWords = WordsOf(transcript + " " + string.Join(' ', previous ?? Array.Empty<string>()));
        var sourceNumbers = new HashSet<string>(sourceWords.Select(NumberValue).Where(n => n is not null).Select(n => n!));
        var parts = bullet.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < parts.Length; i++)
        {
            var w = parts[i].Trim(parts[i].Where(c => !char.IsLetterOrDigit(c)).ToArray());
            if (w.Length == 0) continue;
            var lower = w.ToLowerInvariant();
            var n = NumberValue(lower);
            if (n is not null)
            {
                if (!sourceNumbers.Contains(n)) return false;
            }
            else if (DateWords.Contains(lower))
            {
                if (!sourceWords.Contains(lower)) return false;
            }
            else if (i > 0 && char.IsUpper(w[0]) && w.Length > 1 && !Pronouns.Contains(w))
            {
                if (!sourceWords.Contains(lower)) return false;
            }
            else if (i == 0 && char.IsUpper(w[0]) && GlossaryMatcher.PersonalNames.Contains(lower))
            {
                // A sentence's first word is capitalized whatever it is, so only a word that is a
                // known personal name is checked there ("Anna agreed to help" for a stretch with no Anna).
                if (!sourceWords.Contains(lower)) return false;
            }
        }
        return true;
    }

    internal static HashSet<string> WordsOf(string text)
    {
        var joined = System.Text.RegularExpressions.Regex.Replace(text.ToLowerInvariant(), @"(\d),(\d)", "$1$2");
        return new HashSet<string>(joined.Split(joined.Where(c => !char.IsLetterOrDigit(c)).Distinct().ToArray(), StringSplitOptions.RemoveEmptyEntries));
    }

    /// "18th" -> "18", "40,000" -> "40000"; null when the word is not a number.
    internal static string? Digits(string word)
    {
        var w = word.Replace(",", "");
        foreach (var suffix in new[] { "st", "nd", "rd", "th" })
            if (w.EndsWith(suffix) && w.Length > suffix.Length && w[..^suffix.Length].All(char.IsDigit)) w = w[..^suffix.Length];
        return w.Length > 0 && w.All(char.IsDigit) ? w : null;
    }

    private static readonly Dictionary<string, string> Spelled = new()
    {
        ["zero"] = "0", ["one"] = "1", ["two"] = "2", ["three"] = "3", ["four"] = "4", ["five"] = "5", ["six"] = "6", ["seven"] = "7", ["eight"] = "8", ["nine"] = "9",
        ["ten"] = "10", ["eleven"] = "11", ["twelve"] = "12", ["thirteen"] = "13", ["fourteen"] = "14", ["fifteen"] = "15", ["sixteen"] = "16", ["seventeen"] = "17",
        ["eighteen"] = "18", ["nineteen"] = "19", ["twenty"] = "20", ["thirty"] = "30", ["forty"] = "40", ["fifty"] = "50", ["sixty"] = "60", ["seventy"] = "70",
        ["eighty"] = "80", ["ninety"] = "90", ["hundred"] = "100", ["thousand"] = "1000", ["million"] = "1000000", ["billion"] = "1000000000",
        ["first"] = "1", ["second"] = "2", ["third"] = "3", ["fourth"] = "4", ["fifth"] = "5", ["sixth"] = "6", ["seventh"] = "7", ["eighth"] = "8", ["ninth"] = "9", ["tenth"] = "10",
    };
    internal static string? NumberValue(string word) => Spelled.TryGetValue(word, out var v) ? v : Digits(word);

    private static readonly HashSet<string> DateWords = new()
    {
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "tomorrow", "yesterday", "tonight",
    };
    private static readonly HashSet<string> Pronouns = new() { "You", "Others", "I", "We", "They", "He", "She", "It", "The", "A", "An", "This", "That", "There", "No", "Yes", "OK" };

    /// A note worth keeping is a sentence, not a label or a fragment. A small model likes to
    /// answer "Task: I" or "Name: Ted": a leading label of up to three words is stripped, and
    /// what is left needs at least five words.
    public static string? WorthKeeping(string bullet)
    {
        var s = bullet.Trim();
        var colon = s.IndexOf(':');
        if (colon > 0)
        {
            var label = s[..colon];
            if (label.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length <= 3 && label.All(c => char.IsLetter(c) || c == ' '))
                s = s[(colon + 1)..].Trim();
        }
        if (WordCount(s) < 5 || !s.Any(char.IsLetter) || s.EndsWith(':')) return null;
        return char.ToUpperInvariant(s[0]) + s[1..];
    }

    /// Drops bullets that say what an earlier bullet already says. Two notes are the same when
    /// seven in ten of the shorter one's words (crudely stemmed, so "overviewing" is
    /// "overview") are in the other. Small models repeat themselves in new words.
    public static List<string> DropRepeats(IEnumerable<string> bullets, IEnumerable<string> previous)
    {
        var kept = previous.Select(Words).ToList();
        var result = new List<string>();
        foreach (var b in bullets)
        {
            var w = Words(b);
            if (w.Count == 0) continue;
            var repeats = kept.Any(other =>
            {
                var smaller = Math.Min(w.Count, other.Count);
                if (smaller == 0) return false;
                if (w.SetEquals(other)) return true;
                return smaller >= 3 && w.Intersect(other).Count() / (double)smaller >= 0.7;
            });
            if (repeats) continue;
            kept.Add(w);
            result.Add(b);
        }
        return result;
    }

    internal static HashSet<string> Words(string s) =>
        new(s.ToLowerInvariant().Split(s.Where(c => !char.IsLetterOrDigit(c)).Distinct().ToArray(), StringSplitOptions.RemoveEmptyEntries).Select(Stem).Where(w => w.Length > 0));

    internal static string Stem(string word)
    {
        if (word.Length > 5 && word.EndsWith("ing")) return word[..^3];
        if (word.Length > 4 && word.EndsWith("ed")) return word[..^2];
        if (word.Length > 3 && word.EndsWith('s')) return word[..^1];
        return word;
    }

    /// Strings a model generated into a clean list: markers, numbering and bold stripped,
    /// empty entries and "None" dropped. The Windows edition of NotesMerge.tidy.
    public static List<string> Tidy(IEnumerable<string> items)
    {
        var result = new List<string>();
        foreach (var raw in items)
        {
            var s = raw.Trim();
            while (s.StartsWith("- ") || s.StartsWith("* ") || s.StartsWith("• ")) s = s[2..].Trim();
            var i = 0;
            while (i < s.Length && char.IsDigit(s[i])) i++;
            if (i > 0 && i < s.Length && (s[i] == '.' || s[i] == ')')) s = s[(i + 1)..].Trim();
            s = s.Replace("**", "").Trim();
            if (s.Length == 0 || s.Equals("none", StringComparison.OrdinalIgnoreCase) || s.Equals("none.", StringComparison.OrdinalIgnoreCase)) continue;
            result.Add(s);
        }
        return result;
    }
}
