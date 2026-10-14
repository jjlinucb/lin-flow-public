using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace LinFlow.Core;

/// What Lin Flow does with a correction it worked out from an edit you made.
///
/// The Mac stores this as the strings "auto" / "ask" / "off" in UserDefaults and settings.json
/// keeps the same three strings here. The app's default is Auto, and Settings supplies that
/// explicitly: `default(LearnMode)` is Off, so nothing should lean on the zero value.
public enum LearnMode { Off, Ask, Auto }

/// Turns "what Lin Flow wrote" and "what the text says now" into dictionary corrections.
/// Wispr Flow does this silently; here the same thing happens either automatically or as a
/// suggestion, per `Settings.LearnCorrections`.
///
/// The hard part is telling a mishearing from an edit. "K Wynn E D F" becoming "kkwinedf" is
/// worth learning forever; "Thursday" becoming "Friday" is a change of mind and would be a
/// destructive rule. The test is the consonant skeleton (the same one the fuzzy matcher uses)
/// plus an edit-distance fallback, so only pairs that plausibly sound alike are kept.
public static class LearnedCorrections
{
    /// Words too common to ever become a rule: one bad auto-add here would rewrite everything.
    public static readonly IReadOnlySet<string> Stopwords = new HashSet<string>(StringComparer.Ordinal)
    {
        "the", "and", "but", "for", "not", "you", "your", "our", "its", "it's", "this", "that", "these", "those",
        "with", "from", "have", "has", "had", "was", "were", "will", "would", "should", "could", "can", "are",
        "been", "being", "they", "them", "their", "there", "then", "than", "when", "what", "who", "how", "why",
        "all", "any", "some", "one", "two", "just", "like", "get", "got", "make", "made", "want", "know", "think",
        "now", "here", "out", "about", "into", "over", "more", "most", "very", "too", "also", "yes", "yeah", "okay",
    };

    /// At most this many rules from one dictation: a heavily rewritten one is not a mishearing.
    public const int MaxPerDictation = 3;
    /// Longest phrase either side of a rule may be.
    public const int MaxPhraseWords = 6;

    /// How much an edit is worth: a rule to write, or a rule to offer.
    public enum Confidence { Apply, Suggest }

    /// One rule an edit implies, with how sure Lin Flow is of it.
    public readonly record struct ScoredRule(Replacement Replacement, Confidence Confidence);

    /// Only the rules Lin Flow is confident enough to write by itself.
    public static List<Replacement> Candidates(string wrote, string now, IEnumerable<Replacement> existing) =>
        Scored(wrote, now, existing)
            .Where(s => s.Confidence == Confidence.Apply)
            .Select(s => s.Replacement)
            .ToList();

    /// A fix too distant to write, but too clean to throw away.
    ///
    /// A badly misheard name is *by definition* phonetically distant -- "Duarte" came back as
    /// "Wort", four edits on a four-letter word, different consonant skeleton -- so `Plausible`
    /// can never accept one, and before this every such correction vanished without a word.
    /// The narrow shape that survives here: exactly one word swapped for exactly one word, and
    /// the replacement is capitalized, which is what a name looks like and what ASR actually
    /// gets wrong. It is only ever offered, never applied, so a wrong guess costs one click
    /// rather than every future dictation.
    public static bool WorthOffering(string from, string to)
    {
        var f = TrimPunctuation(from);
        var t = TrimPunctuation(to);
        if (f.Contains(' ') || t.Contains(' ')) return false;
        if (f.Length < 4 || t.Length < 4) return false;
        if (string.Equals(f.ToLowerInvariant(), t.ToLowerInvariant(), StringComparison.Ordinal)) return false;
        if (Stopwords.Contains(f.ToLowerInvariant())) return false;
        if (t.Length == 0 || !char.IsUpper(t[0])) return false;
        return f.All(Nameish) && t.All(Nameish);

        // Apostrophes and hyphens are part of a name ("O'Brien", "Anne-Marie"); a digit is not.
        static bool Nameish(char c) => char.IsLetter(c) || c == '\'' || c == '’' || c == '-';
    }

    /// Every rule an edit implies, each marked with how sure Lin Flow is of it.
    public static List<ScoredRule> Scored(string wrote, string now, IEnumerable<Replacement> existing)
    {
        var rules = existing as IReadOnlyList<Replacement> ?? existing.ToList();
        var a = Words(wrote);
        var b = Words(now);
        var output = new List<ScoredRule>();
        if (a.Count == 0 || b.Count == 0) return output;
        if (a.SequenceEqual(b, StringComparer.Ordinal)) return output;
        // A near-total rewrite is not a set of mishearings.
        if (a.Count > 400 || b.Count > 400) return output;

        var seen = new HashSet<string>(rules.Select(r => r.Id), StringComparer.Ordinal);
        foreach (var (aStart, aEnd, bStart, bEnd) in Substitutions(a, b))
        {
            if (aEnd <= aStart || bEnd <= bStart) continue;
            if (aEnd - aStart > MaxPhraseWords || bEnd - bStart > MaxPhraseWords) continue;
            var from = TrimPhrase(string.Join(" ", a.GetRange(aStart, aEnd - aStart)));
            var to = TrimPhrase(string.Join(" ", b.GetRange(bStart, bEnd - bStart)));
            Confidence confidence;
            if (Plausible(from, to)) confidence = Confidence.Apply;
            else if (WorthOffering(from, to)) confidence = Confidence.Suggest;
            else continue;
            // Already handled, either by this exact rule or by the rules as a whole.
            var candidate = new Replacement(from, to, learned: true);
            if (seen.Contains(candidate.Id)) continue;
            if (string.Equals(TextCleaner.ApplyReplacements(from, rules), to, StringComparison.Ordinal)) continue;
            seen.Add(candidate.Id);
            output.Add(new ScoredRule(candidate, confidence));
            if (output.Count == MaxPerDictation) break;
        }
        return output;
    }

    /// Whether one phrase plausibly became the other by mishearing rather than by editing.
    public static bool Plausible(string from, string to)
    {
        var f = from.ToLowerInvariant();
        var t = to.ToLowerInvariant();
        if (f.Length == 0 || t.Length == 0) return false;
        // Same word, same casing: nothing was corrected.
        if (string.Equals(f, t, StringComparison.Ordinal) && string.Equals(from, to, StringComparison.Ordinal)) return false;
        // Something has to be left after punctuation, and a rule on punctuation alone is noise.
        if (!from.Any(LetterOrNumber) || !to.Any(LetterOrNumber)) return false;
        var fWords = f.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        // A single short or everyday word is too dangerous to bind globally.
        if (fWords.Length == 1)
        {
            if (f.Length < 4) return false;
            if (Stopwords.Contains(TrimPunctuation(f))) return false;
        }
        // Same letters and digits in the same order: only the spacing or the punctuation
        // moved. "Q 3" -> "Q3", "10 1" -> "10/1", "spider riders" -> "spiderriders",
        // "cant" -> "can't". A rule that keeps every letter cannot destroy a word.
        var fBody = new string(f.Where(LetterOrNumber).ToArray());
        var tBody = new string(t.Where(LetterOrNumber).ToArray());
        if (string.Equals(fBody, tBody, StringComparison.Ordinal)
            && !string.Equals(f, t, StringComparison.Ordinal)) return true;
        // An everyday English word on the left is a word John might have meant, so a global
        // rule on it rewrites his own writing. On 2026-09-18 the Mac's dictionary held
        // "cloud => Claude", "clod => Claude" and "threat => thread", every one of them
        // written by this function and firing on every dictation: "I saved it to the cloud."
        // came out as "I saved it to the Claude." The skeleton test is what let them in --
        // Key("cloud") and Key("claude") are both "cld" -- and the same test is what makes
        // "k wynn e d f" work, so it stays; what it may no longer do is bind an ordinary
        // word. The fuzzy matcher has refused to touch a dictionary word since it was
        // written; the learner was simply never given the same guard.
        //
        // The one everyday word worth binding is a name spelled another way. "Lynn" => "Lin"
        // is John's own rule, and "lynn" is in that 1934 word list by accident. NameKey is
        // the matcher's test for one name written two ways, and the replacement has to look
        // like a name. "cloud" and "Claude" are not respellings of each other, nor are
        // "Claudia" and "Claude", so neither comes back in this way.
        var sameName = char.IsUpper(to[0])
            && string.Equals(GlossaryMatcher.NameKey(f), GlossaryMatcher.NameKey(t), StringComparison.Ordinal);
        if (EverydayEnglish(from) && !sameName) return false;
        if (string.Equals(f, t, StringComparison.Ordinal)) return true;                     // capitalization only
        // The consonant skeleton is what makes "k wynn e d f" and "kkwinedf" the same word.
        if (string.Equals(GlossaryMatcher.Key(f), GlossaryMatcher.Key(t), StringComparison.Ordinal)) return true;
        var distance = GlossaryMatcher.Levenshtein(f, t);
        return distance <= GlossaryMatcher.Tolerance(Math.Min(f.Length, t.Length));

        static bool LetterOrNumber(char c) => char.IsLetter(c) || char.IsNumber(c);
    }

    /// Whether a phrase is made of ordinary English words -- words John might have meant.
    ///
    /// The word list is the same embedded web2 the fuzzy matcher uses to keep "cloud" and
    /// "clause" from becoming "Claude". Two things about it shape this test. It stops in
    /// 1934, so "laptop" and "fridge" are absent: this is a floor, not a fence. And it lists
    /// few inflections -- "fail" is there, "failed" is not -- which is why IsEnglish strips
    /// the common endings; an inflected word is still a word he might have meant, and
    /// "failed" => "filled" is as destructive a rule as "cloud" => "Claude".
    ///
    /// A single letter never counts, whatever the list says, and a phrase carrying one is not
    /// English prose: that is how "K Wynn E D F" => "kkwinedf", the rule this whole feature
    /// was built for, stays learnable even though "lynn" is in the list. A phrase also needs
    /// one word of real length -- "Q 3" and "10 1" are not English either way.
    public static bool EverydayEnglish(string phrase)
    {
        var words = new List<string>();
        var current = new StringBuilder();
        foreach (var c in phrase.ToLowerInvariant() + " ")
        {
            if (char.IsLetter(c) || c == '\'' || c == '\u2019') { current.Append(c); continue; }
            var word = current.ToString().Trim('\'', '\u2019');
            if (word.Length > 0) words.Add(word);
            current.Clear();
        }
        if (!words.Any(w => w.Length >= 3)) return false;
        return words.All(w => w.Length >= 2 && IsEnglish(w));
    }

    /// One word, or an ordinary inflection of one.
    internal static bool IsEnglish(string w)
    {
        if (GlossaryMatcher.IsDictionaryWord(w)) return true;
        foreach (var suffix in new[] { "s", "es", "ed", "d", "ing" })
        {
            if (w.Length <= suffix.Length + 2 || !w.EndsWith(suffix, StringComparison.Ordinal)) continue;
            var stem = w[..^suffix.Length];
            if (GlossaryMatcher.IsDictionaryWord(stem)) return true;
            if (GlossaryMatcher.IsDictionaryWord(stem + "e")) return true;                  // "saving" -> "save"
            if (stem.Length >= 2 && stem[^1] == stem[^2]                                    // "stopped" -> "stop"
                && GlossaryMatcher.IsDictionaryWord(stem[..^1])) return true;
            if (stem.EndsWith('i') && GlossaryMatcher.IsDictionaryWord(stem[..^1] + "y")) return true;
        }
        return false;
    }

    /// Contiguous runs where the two word lists disagree, as half-open ranges into each list:
    /// words a[AStart..AEnd) were replaced by words b[BStart..BEnd).
    public static List<(int AStart, int AEnd, int BStart, int BEnd)> Substitutions(IReadOnlyList<string> a, IReadOnlyList<string> b)
    {
        // Longest common subsequence over words, then the gaps between the matches.
        var table = new int[a.Count + 1, b.Count + 1];
        for (var i = a.Count - 1; i >= 0; i--)
        {
            for (var j = b.Count - 1; j >= 0; j--)
            {
                table[i, j] = string.Equals(a[i], b[j], StringComparison.Ordinal)
                    ? table[i + 1, j + 1] + 1
                    : Math.Max(table[i + 1, j], table[i, j + 1]);
            }
        }
        var pairs = new List<(int, int, int, int)>();
        int x = 0, y = 0;
        while (x < a.Count || y < b.Count)
        {
            if (x < a.Count && y < b.Count && string.Equals(a[x], b[y], StringComparison.Ordinal)) { x++; y++; continue; }
            int startX = x, startY = y;
            while (x < a.Count || y < b.Count)
            {
                if (x < a.Count && y < b.Count && string.Equals(a[x], b[y], StringComparison.Ordinal)) break;
                if (y >= b.Count) x++;
                else if (x >= a.Count) y++;
                else if (table[x + 1, y] >= table[x, y + 1]) x++;
                else y++;
            }
            pairs.Add((startX, x, startY, y));
        }
        return pairs;
    }

    public static List<string> Words(string s) =>
        s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToList();

    /// Drops the punctuation a phrase picked up from its sentence. Inner marks survive
    /// ("whisper.cpp"), and "#" is kept at either end so "C#" stays itself.
    public static string TrimPhrase(string s)
    {
        int start = 0, end = s.Length;
        while (start < end && !Keep(s[start])) start++;
        while (end > start && !Keep(s[end - 1])) end--;
        return s.Substring(start, end - start);

        static bool Keep(char c) => char.IsLetter(c) || char.IsNumber(c) || c == '#';
    }

    /// The Mac's `trimmingCharacters(in: .punctuationCharacters)`: the Unicode P* categories,
    /// so a trailing "." or "," goes but a "$" or "+" stays.
    private static string TrimPunctuation(string s)
    {
        int start = 0, end = s.Length;
        while (start < end && char.IsPunctuation(s[start])) start++;
        while (end > start && char.IsPunctuation(s[end - 1])) end--;
        return s.Substring(start, end - start);
    }
}

/// Applies the learning setting to one edit, and holds suggestions until they are answered.
public static class CorrectionLearning
{
    /// The waiting list changed: the Dictionary's "Suggested" rows redraw from this.
    public static event Action? DidChange;

    /// Raised whenever an edit taught something. The dictation lands in some other app with the
    /// window shut, so without this a learned rule existed only as a line in the log and John
    /// had no way to know it had happened.
    public static event Action<Outcome>? DidLearn;

    /// Raised when an edit WAS seen but produced no rule, carrying from/to when the edit was
    /// one clean word-for-word change. A dictionary that never grows looks exactly like a
    /// readback that never runs; this is what tells the two apart on screen, and it gives the
    /// one case worth keeping a way in that costs a single click.
    public static event Action<string, string>? DidDecline;

    /// What came of an edit: rules added outright, and rules waiting to be confirmed.
    public sealed class Outcome : IEquatable<Outcome>
    {
        public List<Replacement> Added { get; set; }
        public List<Replacement> Suggested { get; set; }
        public bool IsEmpty => Added.Count == 0 && Suggested.Count == 0;

        public Outcome(List<Replacement>? added = null, List<Replacement>? suggested = null)
        {
            Added = added ?? new List<Replacement>();
            Suggested = suggested ?? new List<Replacement>();
        }

        public bool Equals(Outcome? other) =>
            other is not null && Added.SequenceEqual(other.Added) && Suggested.SequenceEqual(other.Suggested);

        public override bool Equals(object? obj) => Equals(obj as Outcome);
        public override int GetHashCode() => HashCode.Combine(Added.Count, Suggested.Count);
    }

    public static Outcome Handle(string wrote, string now, LearnMode mode)
    {
        if (mode == LearnMode.Off) return new Outcome();
        var existing = Glossary.LoadReplacements();
        var scored = LearnedCorrections.Scored(wrote, now, existing);
        // Never suggest the same thing twice.
        var waiting = new HashSet<string>(Pending().Select(r => r.Id), StringComparer.Ordinal);
        scored.RemoveAll(s => waiting.Contains(s.Replacement.Id));
        if (scored.Count == 0)
        {
            Decline(wrote, now);
            return new Outcome();
        }
        // A rule Lin Flow is sure of goes straight in; one it only suspects waits for a click.
        // "ask" adds caution and never removes it, so there everything waits.
        var confident = mode == LearnMode.Auto
            ? scored.Where(s => s.Confidence == LearnedCorrections.Confidence.Apply).Select(s => s.Replacement).ToList()
            : new List<Replacement>();
        var offered = scored
            .Where(s => mode == LearnMode.Ask || s.Confidence == LearnedCorrections.Confidence.Suggest)
            .Select(s => s.Replacement)
            .ToList();
        if (confident.Count > 0)
        {
            Glossary.SaveReplacements(existing.Concat(confident));
            foreach (var c in confident) Log.Info($"learned correction: {c.From} => {c.To}");
        }
        if (offered.Count > 0)
        {
            SavePending(Pending().Concat(offered));
            foreach (var c in offered) Log.Info($"suggested correction: {c.From} => {c.To}");
        }
        return Announce(new Outcome(confident, offered));
    }

    /// The one thing that changed in an edit, when exactly one thing did.
    ///
    /// The span on each side may be several words, and that matters more than it sounds: the
    /// commonest way a name is misheard is as one glued word, so the fix splits it in two.
    /// "Marisvo" -> "Marisa Vuong" is exactly the correction worth keeping.
    ///
    /// Used only to say what was seen. A misheard name ("Wort" -> "Duarte") and a plain retype
    /// are indistinguishable here on purpose: this decides nothing, it shows John the pair.
    public static (string From, string To)? LonePair(string wrote, string now)
    {
        var a = LearnedCorrections.Words(wrote);
        var b = LearnedCorrections.Words(now);
        if (a.Count == 0 || b.Count == 0 || a.SequenceEqual(b, StringComparer.Ordinal)) return null;
        if (a.Count > 400 || b.Count > 400) return null;
        var subs = LearnedCorrections.Substitutions(a, b);
        if (subs.Count != 1) return null;
        var (aStart, aEnd, bStart, bEnd) = subs[0];
        if (aEnd <= aStart || bEnd <= bStart) return null;
        if (aEnd - aStart > LearnedCorrections.MaxPhraseWords) return null;
        if (bEnd - bStart > LearnedCorrections.MaxPhraseWords) return null;
        var from = LearnedCorrections.TrimPhrase(string.Join(' ', a.GetRange(aStart, aEnd - aStart)));
        var to = LearnedCorrections.TrimPhrase(string.Join(' ', b.GetRange(bStart, bEnd - bStart)));
        if (from.Length == 0 || to.Length == 0) return null;
        var f = from.ToLowerInvariant();
        var t = to.ToLowerInvariant();
        if (string.Equals(f, t, StringComparison.Ordinal)) return null;
        // Carrying on typing after a dictation reads as a substitution, because the last word
        // carried a full stop and the new words did not: "Ask John." -> "Ask John about it."
        // arrives here as "John" -> "John about it". Continuing a sentence is not a correction.
        if (t.StartsWith(f + " ", StringComparison.Ordinal)) return null;
        if (f.StartsWith(t + " ", StringComparison.Ordinal)) return null;
        return (from, to);
    }

    /// Whether a refused pair has earned a pop-up, as opposed to a line in the log. Every
    /// decline is logged; only one that could plausibly be a misheard word interrupts John.
    /// "go" -> "do" reached the screen on the Mac on 2026-09-14, and a toast that is usually
    /// noise is a toast he stops reading -- which costs more than the occasional missed offer.
    public static bool WorthShowing(string from, string to)
    {
        var fromTrimmed = LearnedCorrections.TrimPhrase(from);
        var toTrimmed = LearnedCorrections.TrimPhrase(to);
        var f = fromTrimmed.ToLowerInvariant();
        var t = toTrimmed.ToLowerInvariant();
        if (f.Length == 0 || t.Length == 0 || string.Equals(f, t, StringComparison.Ordinal)) return false;
        if (LearnedCorrections.Stopwords.Contains(f) || LearnedCorrections.Stopwords.Contains(t)) return false;
        // A capitalized replacement is what a name looks like, and a misheard name is the
        // entire point of this path. "Dor" -> "Duarte" is three letters becoming six and has
        // to get through; "go" -> "do" must not. A length floor cannot tell those apart, and
        // on the Mac on 2026-09-14 a four-character floor -- added that same day to stop
        // "go" -> "do" -- silently refused "Dor" -> "Duarte" while John was testing it.
        // ...but the replacement still has to be long enough to be a name. Dictated text is
        // capitalized at the start of every sentence, so without this floor the escape hatch
        // covers the commonest position for a change of mind: "We" => "He" would be offered,
        // and accepting it rewrites every future "we". The short side is the misheard one, so
        // the floor goes on the replacement and "Dor" => "Duarte" still gets through.
        // A misheard name or term is short. A retyped sentence is not, and the Mac's waiting
        // list on 2026-09-18 was four entries long with nothing in it worth keeping:
        // "growth" => "grove", "fruit" => "fridge", "Let's add them to" => "What's item",
        // "I will charge my laptop" => "passed sp". The last two are a readback catching
        // John mid-retype, and one stray click writes a rule that mangles every dictation.
        if (LearnedCorrections.Words(fromTrimmed).Count > 3) return false;
        if (LearnedCorrections.Words(toTrimmed).Count > 3) return false;
        if (char.IsUpper(toTrimmed[0]) && t.Length >= 4) return true;
        // Lowercase on both sides: a short swap is a change of mind far more often than a
        // mishearing, and it is the one a global rule would damage most widely...
        // ...and both sides being ordinary English is the signature of a change of mind.
        // A misheard word is usually not a word at all ("triadge", "Brona", "Marisvo"), and
        // when it is one, the fix is a name, which the capitalized path above already covers.
        if (LearnedCorrections.EverydayEnglish(fromTrimmed)) return false;
        return f.Length >= 4 && t.Length >= 4;
    }

    /// An edit was seen and refused. Say so: silence here is what made the dictionary feel
    /// broken on the Mac even while the readback was working.
    private static void Decline(string wrote, string now)
    {
        var pair = LonePair(wrote, now);
        if (pair is null)
        {
            Log.Info("readback: edit seen but nothing learnable in it");
            return;
        }
        var (from, to) = pair.Value;
        Log.Info($"declined correction: {from} => {to} (too far apart to learn on its own)");
        if (!WorthShowing(from, to)) return;
        // Keep it as well as show it. A pop-up lasts seconds and John is mid-sentence by
        // definition -- that is the entire premise of the readback -- so a pair that lived
        // only on screen was a pair he lost. It waits in the Dictionary's Suggested row until
        // he answers it. Accept() dismisses the pending copy, so the two paths cannot disagree.
        var candidate = new Replacement(from, to, true);
        var list = Merging(candidate, Pending(), Glossary.LoadReplacements());
        if (list is not null) SavePending(list);
        DidDecline?.Invoke(from, to);
    }

    /// The waiting list as it should be written once a refused pair arrives, or null to leave
    /// it alone. Pure, because the real one writes to John's live pending-corrections.json and
    /// no test may go near that.
    ///
    /// Replace rather than skip when the same left side is already waiting with a different
    /// right side. Replacement.Id is the left side alone, and the readback keeps watching
    /// after an edit that taught nothing, so several declines per dictation is the normal case
    /// rather than an edge one. Skipping let the first win permanently: "Marisvo" caught
    /// mid-word as "Marisa V" would squat the slot, the finished "Marisa Vuong" would be
    /// dropped as a duplicate, and the truncated pair would sit in the Suggested row waiting
    /// to be accepted by mistake. The newest reading is the one that saw him stop typing.
    public static List<Replacement>? Merging(Replacement candidate, List<Replacement> waiting,
                                             List<Replacement> accepted)
    {
        // A rule John has already accepted wins: never reopen a decision he made.
        if (accepted.Any(r => string.Equals(r.Id, candidate.Id, StringComparison.Ordinal))) return null;
        var i = waiting.FindIndex(r => string.Equals(r.Id, candidate.Id, StringComparison.Ordinal));
        if (i < 0) return waiting.Append(candidate).ToList();
        if (string.Equals(waiting[i].To, candidate.To, StringComparison.Ordinal)) return null;
        var output = new List<Replacement>(waiting);
        output[i] = candidate;
        return output;
    }

    /// Tells the app what just happened so it can say so on screen.
    private static Outcome Announce(Outcome outcome)
    {
        if (outcome.IsEmpty) return outcome;
        // The Mac hops to the main queue here because AppKit insists on it. The event is raised
        // on whichever thread learned the rule; the UI layer marshals onto its own dispatcher.
        DidLearn?.Invoke(outcome);
        return outcome;
    }

    // MARK: the waiting list

    public static List<Replacement> Pending()
    {
        try
        {
            if (!File.Exists(Paths.PendingCorrectionsFile)) return new List<Replacement>();
            var json = File.ReadAllText(Paths.PendingCorrectionsFile);
            return JsonSerializer.Deserialize<List<Replacement>>(json, PendingJson) ?? new List<Replacement>();
        }
        catch
        {
            // A missing or half-written waiting list is not a reason to fail a dictation.
            return new List<Replacement>();
        }
    }

    public static void SavePending(IEnumerable<Replacement> list)
    {
        var items = list.ToList();
        try
        {
            Paths.EnsureDataDir();
            Paths.WriteAtomic(Paths.PendingCorrectionsFile, JsonSerializer.Serialize(items, PendingJson));
        }
        catch (Exception e)
        {
            Log.Info($"pending corrections not saved: {e.Message}");
        }
        // The Mac announces the change whether or not the write landed, so the window never
        // shows a suggestion the user has already answered.
        DidChange?.Invoke();
    }

    /// Accepts a suggestion into the corrections list.
    public static void Accept(Replacement replacement)
    {
        var existing = Glossary.LoadReplacements();
        if (!existing.Any(r => string.Equals(r.Id, replacement.Id, StringComparison.Ordinal)))
        {
            Glossary.SaveReplacements(existing.Concat(new[] { replacement }));
        }
        Dismiss(replacement);
    }

    public static void Dismiss(Replacement replacement) =>
        SavePending(Pending().Where(r => !string.Equals(r.Id, replacement.Id, StringComparison.Ordinal)));

    private static readonly JsonSerializerOptions PendingJson = new()
    {
        WriteIndented = true,
        Converters = { new PendingReplacementJson() },
    };

    /// pending-corrections.json is copied between machines, so it is written exactly as the
    /// Mac's `JSONEncoder` with `.sortedKeys` writes it: lowercase keys in alphabetical order.
    private sealed class PendingReplacementJson : JsonConverter<Replacement>
    {
        public override Replacement Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
        {
            using var doc = JsonDocument.ParseValue(ref reader);
            var o = doc.RootElement;
            var from = o.TryGetProperty("from", out var f) ? f.GetString() ?? "" : "";
            var to = o.TryGetProperty("to", out var t) ? t.GetString() ?? "" : "";
            // `learned` is optional, matching the Mac's `decodeIfPresent`, so a file written by
            // an older build (or by hand) still loads instead of throwing the whole list away.
            var learned = o.TryGetProperty("learned", out var l) && l.ValueKind == JsonValueKind.True;
            return new Replacement(from, to, learned);
        }

        public override void Write(Utf8JsonWriter writer, Replacement value, JsonSerializerOptions options)
        {
            writer.WriteStartObject();
            writer.WriteString("from", value.From);
            writer.WriteBoolean("learned", value.Learned);
            writer.WriteString("to", value.To);
            writer.WriteEndObject();
        }
    }
}
