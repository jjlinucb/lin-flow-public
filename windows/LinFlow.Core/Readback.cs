namespace LinFlow.Core;

/// The deciding half of the Mac's PasteWatcher.swift: whether a field still holds the dictation,
/// whether John has edited it, and what the edited phrase now reads. The reading half is
/// LinFlow.App's PasteWatcher, over UI Automation; everything here is pure so the tests can run
/// it, which on the Mac only the functions at the bottom of that file could be.
public static class Readback
{
    /// One phrase Lin Flow pasted, and the order it went out in.
    public sealed record Paste(int Seq, string Text);

    /// How long to keep watching after a paste, and how often to look. The window is long
    /// because noticing a wrong word takes far longer than fixing one; the interval is short
    /// because the fix should reach the dictionary while you are still looking at the field.
    public const double WatchWindow = 15;
    public const double PollInterval = 0.8;

    /// Early looks that only try to find the field, before any edit could have happened.
    /// Chromium needs several of these: its tree is not there the instant it is asked for.
    public static readonly IReadOnlyList<double> AnchorDelays = new[] { 0.6, 1.5, 3.0 };

    /// Every moment after the anchor attempts, one poll apart, plus two past the window so an
    /// edit made at the very end still gets the two looks it needs to settle.
    public static List<double> CheckDelays(double watchWindow = WatchWindow, double pollInterval = PollInterval,
                                           IReadOnlyList<double>? anchorDelays = null)
    {
        var anchors = anchorDelays ?? AnchorDelays;
        if (pollInterval <= 0) return new List<double>();
        var start = (anchors.Count > 0 ? anchors[^1] : 0) + pollInterval;
        // Counted rather than accumulated: adding 0.8 repeatedly drifts and drops the last look.
        // Away from zero, as Swift's rounded() does; C#'s default rounds a half to even.
        var steps = Math.Max(0, (int)Math.Round((watchWindow - start) / pollInterval, MidpointRounding.AwayFromZero) + 2);
        return Enumerable.Range(0, steps + 1).Select(i => start + i * pollInterval).ToList();
    }

    /// The whole schedule for one paste, anchor attempts first.
    public static List<double> Delays() => AnchorDelays.Concat(CheckDelays()).ToList();

    /// Whether a dictation later than `mine` is now sitting in this field.
    public static bool Superseded(IEnumerable<Paste> pastes, int mine, string fieldNow) =>
        pastes.Any(p => p.Seq > mine && fieldNow.Contains(p.Text, StringComparison.Ordinal));

    /// The pasted phrase as it now reads, or null when it is gone or untouched.
    public static string? EditedVersion(string wrote, string now)
    {
        var current = now.Trim();
        if (current.Length == 0 || current.Contains(wrote, StringComparison.Ordinal)) return null;
        var wroteWords = LearnedCorrections.Words(wrote);
        if (wroteWords.Count == 0) return null;
        // A field holding little more than the dictation: compare the whole thing -- but only
        // while it still reads like that dictation. Sending a message empties the field and the
        // app drops its own placeholder in ("Type / for commands"), and a wholesale retype is
        // not a correction either. Same budget the long-document path below uses.
        if (current.Length <= Math.Max(200, wrote.Length * 3))
        {
            var currentWords = LearnedCorrections.Words(current);
            if (WordDistance(wroteWords, currentWords) <= Math.Max(1, wroteWords.Count / 2)) return current;
            // A short dictation has almost no word budget: "Merissa Wong." is two words, so the
            // budget is one, and fixing a first and last name at once blows it. That is the
            // whole point of dictating a name to test it, and on the Mac on 2026-09-14 it was
            // refused here. Characters still separate a fix from a placeholder where words
            // cannot -- "merissa wong." to "marisa vuong" is 4 edits over 12 characters, while
            // "you can merge it in now." to "type / for commands" is 18 over 19.
            if (wrote.Length > 2_000 || current.Length > 2_000) return null;
            var charDistance = GlossaryMatcher.Levenshtein(wrote.ToLowerInvariant(), current.ToLowerInvariant());
            // Three quarters, measured rather than guessed. Across John's real cases the fixes
            // sit at 0.04 to 0.62 of the shorter string and everything that must be refused --
            // composer placeholders, an unrelated field, a wholesale retype -- sits at 1.00 to
            // 1.93. Half was the first guess and it cut through the middle of the fixes.
            return charDistance * 4 <= Math.Min(wrote.Length, current.Length) * 3 ? current : null;
        }
        // A longer document: find the phrase by its own words, then take a window around it.
        var words = LearnedCorrections.Words(current);
        if (words.Count > 20_000) return null;
        var width = wroteWords.Count;
        (int Score, int Start, int End)? best = null;
        foreach (var anchor in Anchors(wroteWords))
        {
            var offset = wroteWords.IndexOf(anchor);
            if (offset < 0) continue;
            for (var i = 0; i < words.Count; i++)
            {
                if (!string.Equals(words[i], anchor, StringComparison.Ordinal)) continue;
                var start = Math.Max(0, i - offset);
                foreach (var slack in new[] { 0, -2, -1, 1, 2 })
                {
                    var end = Math.Min(words.Count, start + Math.Max(1, width + slack));
                    if (start >= end) continue;
                    var score = WordDistance(wroteWords, words.GetRange(start, end - start));
                    if (best is null || score < best.Value.Score) best = (score, start, end);
                }
            }
        }
        // Too different to be the same phrase edited.
        if (best is not { } found || found.Score > Math.Max(1, width / 2)) return null;
        return string.Join(' ', words.GetRange(found.Start, found.End - found.Start));
    }

    /// The most distinctive words of the phrase, longest first: those are the ones most likely
    /// to survive an edit and least likely to appear elsewhere in the document.
    public static List<string> Anchors(IReadOnlyList<string> words) =>
        words.Distinct(StringComparer.Ordinal)
            .OrderByDescending(w => w.Length)
            .ThenByDescending(w => w, StringComparer.Ordinal)
            .Take(3)
            .ToList();

    /// Levenshtein over words rather than characters.
    public static int WordDistance(IReadOnlyList<string> a, IReadOnlyList<string> b)
    {
        if (a.Count == 0) return b.Count;
        if (b.Count == 0) return a.Count;
        var prev = new int[b.Count + 1];
        var cur = new int[b.Count + 1];
        for (var j = 0; j <= b.Count; j++) prev[j] = j;
        for (var i = 1; i <= a.Count; i++)
        {
            cur[0] = i;
            for (var j = 1; j <= b.Count; j++)
            {
                var cost = string.Equals(a[i - 1], b[j - 1], StringComparison.Ordinal) ? 0 : 1;
                cur[j] = Math.Min(Math.Min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
            }
            (prev, cur) = (cur, prev);
        }
        return prev[b.Count];
    }

    /// Field text as UI Automation hands it over, in the form the dictation was written in.
    /// A Win32 edit box stores a new line as "\r\n" and Word as a bare "\r" (a line break as
    /// "\v"), where the dictation has "\n"; and a web composer can turn a space into a
    /// non-breaking one. Left alone, the field never "contains" a two-line dictation, and the
    /// watch gives up on the one field it was looking at.
    public static string Normalize(string field) =>
        field.Replace("\r\n", "\n").Replace('\r', '\n').Replace('\v', '\n').Replace(' ', ' ');
}

/// One field under watch after a paste: the Mac's Anchor box together with the body of each
/// checkpoint in PasteWatcher.begin, minus the reading of the field. Its caller finds the field,
/// reads it, and hands the text to Look; Look says what that reading means.
public sealed class ReadbackWatch
{
    public ReadbackWatch(string wrote, int seq)
    {
        Wrote = wrote;
        Seq = seq;
    }

    /// The phrase as pasted, trimmed.
    public string Wrote { get; }
    public int Seq { get; }
    /// Whether a field holding the paste has been found. From then on only that field is read.
    public bool Anchored { get; private set; }
    public bool Done { get; private set; }

    private string? _pending;       // an edit seen, waiting to prove it has settled
    private int _stable;            // how many looks in a row have read it the same
    private readonly HashSet<string> _reported = new(StringComparer.Ordinal);   // edits already handed over

    public enum Action
    {
        /// Nothing to do this time.
        None,
        /// This is the field that received the paste: keep it and read only it from now on.
        Anchor,
        /// An edit to hand to the learner. Retire the watch if the learner made something of it.
        Report,
        /// A newer dictation is in this field; the watch is over.
        StandDown,
    }

    public readonly record struct Step(Action Action, string? Edited = null, string? Log = null);

    /// One look at the field. `now` is its text: the anchored field's, or while none is anchored
    /// yet the focused one's. `last` is the final look of the window.
    public Step Look(string now, bool last, IReadOnlyList<Readback.Paste> pastes, TimeSpan at,
                     double watchWindow = Readback.WatchWindow)
    {
        if (Done) return default;
        // Lin Flow pasted into this field again. From here an older watch cannot tell John's
        // typing from the new dictation's text, and reading one ASR output as an edit of another
        // learns rules from nothing he did: re-dictating over a selection turned "Let's meet
        // Thursday." into "Let's meet Tuesday." and that is one word apart, so it would have
        // auto-written Thursday => Tuesday -- the exact destructive rule this exists to prevent.
        if (Readback.Superseded(pastes, Seq, now))
        {
            var said = Anchored ? "readback: a newer dictation landed in this field; standing down" : null;
            Done = true;
            return new Step(Action.StandDown, Log: said);
        }
        // Only ever compare against the field that actually received the paste.
        if (!Anchored)
        {
            if (now.Contains(Wrote, StringComparison.Ordinal))
            {
                Anchored = true;
                return new Step(Action.Anchor, Log: $"readback: watching the field ({(int)at.TotalMilliseconds}ms)");
            }
            return last
                ? new Step(Action.None, Log: "readback: never found the pasted text in a field; nothing can be learned from this one")
                : default;
        }
        var intact = now.Contains(Wrote, StringComparison.Ordinal);
        var edited = intact ? null : Readback.EditedVersion(Wrote, now);
        if (edited is null)
        {
            // The field stopped looking like the dictation while an edit was still waiting to
            // settle. That is exactly what hitting send looks like: on the Mac on 2026-09-14 John
            // fixed "Siena" to "Verona" and pressed Enter inside the 1.6 s the settle gate needs,
            // the composer emptied, and the correction was dropped. Two looks protect against a
            // half-typed word; they must not cost the fix of anyone who types quickly. Take the
            // candidate rather than lose it.
            if (!intact && _pending is { } candidate && !_reported.Contains(candidate))
            {
                _pending = null;
                _stable = 0;
                _reported.Add(candidate);
                return new Step(Action.Report, candidate,
                    $"readback: the field was cleared mid-edit; taking \"{Wrote}\" as \"{candidate}\"");
            }
            _pending = null;
            _stable = 0;   // back to the phrase as pasted
            // Say why nothing came of this, once, at the end of the window. Until the Mac had
            // this line its log recorded only successes, so a readback that watched the field
            // and then quietly decided nothing looked exactly like one that never ran.
            if (!last) return default;
            return new Step(Action.None, Log: intact
                ? $"readback: field unchanged after {(int)watchWindow}s, nothing to learn"
                : "readback: field changed but it is not recognizably an edit of the dictation");
        }
        // Handed over once already; wait for John to type something different.
        if (_reported.Contains(edited)) return default;
        // A fix takes several keystrokes and a pause mid-word is ordinary. One look 0.8 s apart
        // was not enough on the Mac: it caught "earl" on the way to "early", offered that, and
        // -- worse -- stopped watching. Two in a row.
        if (!string.Equals(_pending, edited, StringComparison.Ordinal))
        {
            _pending = edited;
            _stable = 1;
            return default;
        }
        _stable++;
        if (_stable < 2) return default;
        _reported.Add(edited);
        return new Step(Action.Report, edited, $"readback: edit seen, \"{Wrote}\" is now \"{edited}\"");
    }

    /// Stop watching. Only an edit that taught something ends the watch early; before the Mac
    /// learned that, three of seven readbacks on 2026-09-14 spent their window on a half-typed
    /// word, and the correction that followed a second later was never looked at.
    public void Retire() => Done = true;
}
