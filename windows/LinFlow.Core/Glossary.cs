using System.Globalization;
using System.Text;

namespace LinFlow.Core;

/// The user's proper-noun list. One term per line in %APPDATA%\Lin Flow\vocab.txt (seeded on
/// first run). Used two ways: fed to whisper as the initial prompt so it spells names right in
/// the first place, and as a fuzzy-match fixup afterwards.
/// replacements.txt holds explicit corrections, one "wrong => right" per line.
///
/// Both files are plain text on purpose: they are meant to be opened in a text editor and edited
/// by hand. That is also why the two formats here are byte-for-byte the Mac's — a vocab.txt or
/// replacements.txt copied off John's Mac has to load unchanged, and anything written here has
/// to load back on the Mac.
public static class Glossary
{
    /// Marks a correction Lin Flow learned from an edit, in replacements.txt.
    public const string LearnedMarker = "# learned";

    private const string VocabHeader = "# Lin Flow glossary: one name or term per line.\n";

    /// The seeded file gets the longer two-line header explaining what the list is for; a later
    /// SaveTerms rewrites it with the short one. That asymmetry is the Mac's, kept so a round
    /// trip through this port does not produce a file the Mac would write differently.
    private const string SeedHeader =
        "# Lin Flow glossary: one name or term per line. Whisper is primed with these and\n"
        + "# the cleanup pass snaps near-misses to this exact spelling.\n";

    private const string ReplacementsHeader =
        "# Lin Flow corrections: what was heard => what you meant, one per line.\n";

    /// Heads the lines ReplacementsFile carries forward because it could not read them.
    private const string KeptHeader = "# Lines Lin Flow could not read, kept as you wrote them.\n";

    /// Posted after either file is written, so the dashboard can reload. The Mac's
    /// Notification.Name("LinFlow.Glossary.didChange").
    public static event Action? DidChange;

    public static IReadOnlyList<string> Defaults { get; } = new[]
    {
        "John Lin", "Lin Flow", "Wispr Flow", "Parakeet", "whisper.cpp", "MLX",
        "WORKBRAIN", "MINISTRYBRAIN", "Claude", "Claude Code", "Anthropic", "GitHub",
        "Northwind", "Sunnyvale", "Santa Cruz", "Cambodia", "Khmer",
    };

    public static List<string> Load()
    {
        var text = ReadAllTextOrNull(Paths.VocabFile);
        if (text is not null)
        {
            var terms = ParseTerms(text);
            // An empty or comments-only file means "I have not set this up", not "I want no
            // glossary" — fall through to the defaults rather than dictating with none.
            if (terms.Count > 0) return terms;
        }
        // A fresh List every call: callers append to what they get back (the dashboard does
        // `SaveTerms(terms + [t])`), and Swift's array value semantics gave them a copy for free.
        return new List<string>(Defaults);
    }

    public static void SaveTerms(IEnumerable<string> terms)
    {
        Write(Paths.VocabFile, TermsFile(terms));
        DidChange?.Invoke();
    }

    /// The terms a vocab.txt holds, without falling back to the defaults the way Load does: the
    /// shared dictionary has to tell an emptied list from one never written. The Mac's parseTerms.
    public static List<string> ParseTerms(string text)
    {
        var terms = new List<string>();
        foreach (var line in SplitLines(text))
        {
            var t = TrimSpaces(line);
            if (t.Length == 0 || t.StartsWith('#')) continue;
            terms.Add(t);
        }
        return terms;
    }

    /// The vocab.txt SaveTerms writes for these terms. The Mac's termsFile.
    public static string TermsFile(IEnumerable<string> terms)
    {
        var body = new StringBuilder(VocabHeader);
        // Trim and drop blanks here rather than on load, so the file a human opens is tidy.
        var kept = terms.Select(TrimSpaces).Where(t => t.Length > 0);
        body.Append(string.Join('\n', kept)).Append('\n');
        return body.ToString();
    }

    /// For a writer outside this class, the shared dictionary, to say the files changed.
    public static void NotifyChanged() => DidChange?.Invoke();

    /// The Dictionary's reading order: what Lin Flow learned most recently first, then the
    /// rules John wrote himself, in the order he wrote them.
    ///
    /// Recency is file order, not a timestamp. Every rule is appended -- by SaveReplacements
    /// when one is learned and by accepting a suggestion -- so the last learned line is the
    /// newest. A list that only grows downward buries the rule he just watched being learned,
    /// which is the one he opens this tab to check. Same order as the Mac's Glossary.displayOrder.
    public static List<Replacement> DisplayOrder(IReadOnlyList<Replacement> replacements)
    {
        var learned = replacements.Where(r => r.Learned).Reverse();
        var written = replacements.Where(r => !r.Learned);
        return learned.Concat(written).ToList();
    }

    public static List<Replacement> LoadReplacements()
    {
        var text = ReadAllTextOrNull(Paths.ReplacementsFile);
        return text is null ? new List<Replacement>() : ParseReplacements(text);
    }

    public static List<Replacement> ParseReplacements(string text)
    {
        var result = new List<Replacement>();
        foreach (var line in SplitLines(text))
        {
            var s = TrimSpaces(line);
            if (s.Length == 0 || s.StartsWith('#')) continue;
            // First "=>" wins, so a right-hand side may itself contain one.
            var arrow = s.IndexOf("=>", StringComparison.Ordinal);
            if (arrow < 0) continue;

            var from = TrimSpaces(s[..arrow]);
            var to = TrimSpaces(s[(arrow + 2)..]);

            // Rules Lin Flow added itself carry a trailing marker so the window can label them.
            var learned = false;
            if (to.EndsWith(LearnedMarker, StringComparison.Ordinal))
            {
                learned = true;
                to = TrimSpaces(to[..^LearnedMarker.Length]);
            }

            // A rule with nothing on the left can never fire; an empty right-hand side is legal
            // and means "delete this word", which is why only `from` is checked.
            if (from.Length == 0) continue;
            result.Add(new Replacement(from, to, learned));
        }
        return result;
    }

    public static void SaveReplacements(IEnumerable<Replacement> replacements)
    {
        var existing = ReadAllTextOrNull(Paths.ReplacementsFile) ?? "";
        Write(Paths.ReplacementsFile, ReplacementsFile(replacements, existing));
        DidChange?.Invoke();
    }

    /// The file to write, carrying forward every line the parser could not read. The Mac's
    /// Glossary.replacementsFile(_:keeping:).
    ///
    /// This is a plain text file John edits by hand, so it collects grouping comments and the
    /// occasional typo -- an arrow written "->" instead of "=>". The loader drops all of those,
    /// and the writer used to rebuild the file from only what survived, so the next saved
    /// correction deleted them from disk with no click and no message. That mattered little
    /// while only the window saved this file. Now every correction learned from an edit saves
    /// it, unasked. A line Lin Flow does not understand is not a line it may throw away.
    ///
    /// The kept section's own heading is not carried forward. The Mac's version keeps it as a
    /// comment like any other, so each save after the first adds another copy of it.
    public static string ReplacementsFile(IEnumerable<Replacement> replacements, string keeping)
    {
        var header = ReplacementsHeader.TrimEnd('\n');
        var keptHeader = KeptHeader.TrimEnd('\n');
        var kept = SplitLines(keeping).Where(line =>
        {
            var s = TrimSpaces(line);
            if (s.Length == 0 || s == header || s == keptHeader) return false;
            // A rule the writer is about to emit itself, or a comment or typo it cannot parse.
            return s.StartsWith('#') || !s.Contains("=>", StringComparison.Ordinal);
        }).ToList();

        var body = new StringBuilder(ReplacementsHeader);
        // No trimming or filtering on this side: the list came from the dashboard or from
        // LearnedCorrections, both of which have already vetted it, and silently dropping a
        // rule the user just typed would be worse than writing an odd-looking line.
        var lines = replacements.Select(r => r.Learned
            ? $"{r.From} => {r.To}\t{LearnedMarker}"
            : $"{r.From} => {r.To}");
        body.Append(string.Join('\n', lines)).Append('\n');
        if (kept.Count > 0) body.Append('\n').Append(KeptHeader).Append(string.Join('\n', kept)).Append('\n');
        return body.ToString();
    }

    /// Write the default list if the user doesn't have one yet.
    public static void SeedIfMissing()
    {
        // Existence, not emptiness: a user who deliberately emptied the file gets to keep it
        // empty instead of having the defaults handed back every launch.
        if (File.Exists(Paths.VocabFile)) return;
        Write(Paths.VocabFile, SeedHeader + string.Join('\n', Defaults) + "\n");
        // Deliberately no DidChange here, matching the Mac: seeding happens during startup,
        // before anything is listening, and firing it would reload a dashboard mid-construction.
    }

    /// The decoder prompt: a plain comma list reads as "here is how these are spelled".
    public static string InitialPrompt(IEnumerable<string> terms)
    {
        var joined = string.Join(", ", terms);
        // Empty stays empty: whisper treats a lone "." as content and will transcribe it.
        return joined.Length == 0 ? "" : joined + ".";
    }

    // MARK: - file plumbing

    private static string? ReadAllTextOrNull(string path)
    {
        try
        {
            return File.ReadAllText(path);
        }
        catch
        {
            // Missing, locked, or unreadable all mean the same thing to the caller: no list.
            // The Mac's `try? String(contentsOf:)` swallows these the same way.
            return null;
        }
    }

    private static void Write(string path, string contents)
    {
        try
        {
            Paths.WriteAtomic(path, contents);
        }
        catch (Exception e)
        {
            // A dictionary that cannot be saved must not take dictation down with it — the Mac's
            // `try?` drops this on the floor. Logged rather than silent so the reason survives:
            // the symptom otherwise is edits that quietly revert on the next reload.
            Log.Info($"glossary: could not write {path}: {e.Message}");
        }
    }

    /// Both files are written with "\n" regardless of platform so the Mac and Windows copies are
    /// identical — but they are read back tolerantly, because a user who edits replacements.txt
    /// in Notepad saves it with CRLF and that file still has to load.
    /// Swift got this free: `split(whereSeparator: \.isNewline)` treats "\r\n" as one Character
    /// and drops empty lines.
    private static List<string> SplitLines(string text)
    {
        var lines = new List<string>();
        var start = 0;
        for (var i = 0; i < text.Length; i++)
        {
            if (!IsNewline(text[i])) continue;
            if (i > start) lines.Add(text[start..i]);   // empty runs are skipped, as in Swift
            start = i + 1;
        }
        if (start < text.Length) lines.Add(text[start..]);
        return lines;
    }

    private static bool IsNewline(char c) =>
        c is '\n' or '\r' or '\v' or '\f' or '\u0085' or '\u2028' or '\u2029';

    /// Swift's `.whitespaces` is space, tab and Unicode Zs — it does NOT include newlines, so
    /// this is not C#'s `Trim()`. It matters for a term typed with a trailing non-breaking space
    /// (pasted from a web page), which must be trimmed, and it keeps the two ports agreeing on
    /// what the key of a replacement is.
    private static string TrimSpaces(string s)
    {
        int start = 0, end = s.Length;
        while (start < end && IsSpace(s[start])) start++;
        while (end > start && IsSpace(s[end - 1])) end--;
        return start == 0 && end == s.Length ? s : s[start..end];
    }

    private static bool IsSpace(char c) =>
        c == '\t' || char.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;
}
