using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;

namespace LinFlow.Core;

// One dictionary across every computer John dictates on. Sources/LinFlowCore/DictionarySync.swift
// is the spec, and SYNC-PLAN.md has the reasoning.
//
// vocab.txt and replacements.txt stay the files the app reads, and stay hand-editable. What is
// shared is one row per term and per rule in the table `dictionary_entries`, in the same Supabase
// project as the word totals. A deletion is a row marked deleted, so it reaches the computers that
// still have the entry instead of being brought back by them.
//
// Each computer keeps dictionary-sync.json: every entry as it last agreed with the table. A sync
// compares the local files, that record and the table for each entry. What differs from the record
// locally is this computer's change and is sent; what differs in the table is another computer's
// and is taken. When both changed the same entry, this computer's is sent and wins, so the last
// computer to sync a change wins. updated_at is only ever compared for equality, so the computers'
// clocks do not have to agree.

public enum DictionaryKind { Term, Rule }

/// One term, or one "heard => meant" rule, as the table holds it. UpdatedAt is as the table wrote
/// it, empty before it has been sent.
public sealed record DictionaryEntry(DictionaryKind Kind, string Text, string Target = "", bool Learned = false,
                                     bool Deleted = false, string UpdatedAt = "")
{
    public static DictionaryEntry OfTerm(string text) => new(DictionaryKind.Term, text);
    public static DictionaryEntry OfRule(Replacement r) => new(DictionaryKind.Rule, r.From, r.To, r.Learned);

    public string KindName => Kind == DictionaryKind.Term ? "term" : "rule";
    /// A term and a rule's left side are one entry whatever their case, as Replacement.Id has it.
    public string Key => Text.ToLowerInvariant();
    public string Id => KindName + "|" + Key;

    /// Equal apart from when it was written.
    public bool SameContent(DictionaryEntry o) =>
        Kind == o.Kind && Text == o.Text && Target == o.Target && Learned == o.Learned && Deleted == o.Deleted;

    public Replacement AsReplacement() => new(Text, Target, Learned);

    public static DictionaryKind? ParseKind(string? s) => s switch
    {
        "term" => DictionaryKind.Term,
        "rule" => DictionaryKind.Rule,
        _ => null,
    };
}

/// Terms and Rules are the files after the sync, in file order with what was taken at the end.
/// Upload is this computer's changes, deletions as deleted rows, not yet stamped. Taken is other
/// computers' changes that altered the files here. Snapshot is the agreed state not counting
/// Upload, which the table's answer adds.
public sealed record DictionaryMerge(List<string> Terms, List<Replacement> Rules, List<DictionaryEntry> Upload,
                                     List<DictionaryEntry> Taken, Dictionary<string, DictionaryEntry> Snapshot,
                                     int RefusedDeletions);

public static class DictionaryMerger
{
    /// More deletions than this in one sync, when they are also most of what this computer had,
    /// look like a file emptied by accident rather than words removed one by one.
    public const int DeletionLimit = 5;

    /// A null snapshot means this computer has never synced with this project: the table's copy
    /// wins wherever the two differ, and whatever only this computer has is sent. The same happens
    /// when a file could not be read, which the caller passes as null, so an unreadable file can
    /// never send deletions.
    public static DictionaryMerge Merge(IReadOnlyList<string>? terms, IReadOnlyList<Replacement>? rules,
                                        IReadOnlyDictionary<string, DictionaryEntry>? snapshot,
                                        IReadOnlyDictionary<string, DictionaryEntry> remote)
    {
        var local = new Dictionary<string, DictionaryEntry>(StringComparer.Ordinal);
        foreach (var t in terms ?? Array.Empty<string>()) { var e = DictionaryEntry.OfTerm(t); local.TryAdd(e.Id, e); }
        foreach (var r in rules ?? Array.Empty<Replacement>()) { var e = DictionaryEntry.OfRule(r); local.TryAdd(e.Id, e); }

        var agreed = terms is null || rules is null ? null : snapshot;
        var refused = 0;
        if (agreed is not null)
        {
            // Counted per kind: an emptied vocab.txt must not hide behind a long replacements.txt.
            foreach (var kind in new[] { DictionaryKind.Term, DictionaryKind.Rule })
            {
                var live = agreed.Values.Where(e => e.Kind == kind && !e.Deleted).ToList();
                var gone = live.Count(e => !local.ContainsKey(e.Id));
                if (gone >= DeletionLimit && gone * 2 > live.Count) refused += gone;
            }
            if (refused > 0) agreed = null;
        }

        var final = new Dictionary<string, DictionaryEntry>(StringComparer.Ordinal);
        var upload = new List<DictionaryEntry>();
        var taken = new List<DictionaryEntry>();
        var snap = new Dictionary<string, DictionaryEntry>(StringComparer.Ordinal);
        var ids = new SortedSet<string>(local.Keys, StringComparer.Ordinal);
        ids.UnionWith((IEnumerable<string>?)agreed?.Keys ?? snapshot?.Keys ?? Enumerable.Empty<string>());
        ids.UnionWith(remote.Keys);

        foreach (var id in ids)
        {
            local.TryGetValue(id, out var l);
            remote.TryGetValue(id, out var r);
            var result = l;
            if (agreed is not null)
            {
                agreed.TryGetValue(id, out var s);
                var localChanged = l is not null ? s is null || s.Deleted || !l.SameContent(s) : s is not null && !s.Deleted;
                var remoteChanged = r is not null && (s is null || r.UpdatedAt != s.UpdatedAt || !r.SameContent(s));
                if (localChanged)
                {
                    var mine = l ?? (s! with { Deleted = true });
                    if (r is not null && r.SameContent(mine)) snap[id] = r; else upload.Add(mine);
                }
                else if (remoteChanged)
                {
                    result = r!.Deleted ? null : r;
                    snap[id] = r;
                }
                else if (r is not null)
                {
                    snap[id] = r;
                }
                else if (l is not null)
                {
                    // Gone from the table, most likely by hand in the dashboard: put it back.
                    upload.Add(l);
                }
            }
            else if (r is not null)
            {
                if (l is not null && r.SameContent(l)) snap[id] = r;
                else { result = r.Deleted ? null : r; snap[id] = r; }
            }
            else if (l is not null)
            {
                upload.Add(l);
            }
            if (result is not null) final[id] = result;
            var changedHere = (result is null) != (l is null) || (result is not null && l is not null && !result.SameContent(l));
            if (changedHere && r is not null) taken.Add(r);
        }

        // The files' own order, so a sync moves nothing; what arrived goes at the end, as a rule
        // learned here would.
        var outTerms = new List<string>();
        var outRules = new List<Replacement>();
        var placed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var t in terms ?? Array.Empty<string>())
        {
            var id = DictionaryEntry.OfTerm(t).Id;
            if (final.TryGetValue(id, out var e) && placed.Add(id)) outTerms.Add(e.Text);
        }
        foreach (var r in rules ?? Array.Empty<Replacement>())
        {
            var id = DictionaryEntry.OfRule(r).Id;
            if (final.TryGetValue(id, out var e) && placed.Add(id)) outRules.Add(e.AsReplacement());
        }
        foreach (var id in final.Keys.Where(id => !placed.Contains(id)).OrderBy(id => id, StringComparer.Ordinal))
        {
            var e = final[id];
            if (e.Kind == DictionaryKind.Term) outTerms.Add(e.Text); else outRules.Add(e.AsReplacement());
        }
        return new DictionaryMerge(outTerms, outRules, upload, taken, snap, refused);
    }
}

/// Runs the merge against the table and the files. One instance runs for the app's life.
///
/// A sync reads the whole table (a few hundred rows at most), merges, sends this computer's
/// changes, and only then writes the files and the record, so a failed send changes nothing here.
/// Syncs run one at a time; any asked for while one runs become one more.
public sealed class DictionarySync
{
    public const string Table = "dictionary_entries";
    public const int PageSize = 1000;
    public const int BatchSize = 500;
    /// How often the app syncs with nothing else asking it to, so a word added on another computer
    /// arrives while this one sits unused.
    public static readonly TimeSpan Interval = TimeSpan.FromMinutes(10);

    public static DictionarySync Shared { get; } = new();

    private readonly HttpClient _http;
    private readonly Func<SyncConfig?> _config;
    private readonly string _vocab;
    private readonly string _rules;
    private readonly string _state;
    private readonly Action<string> _log;
    private readonly Func<DateTime> _utcNow;
    private readonly Action _notify;

    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly object _requests = new();
    private bool _running, _again;
    private string? _lastProblem;

    public DictionarySync(HttpClient? http = null, Func<SyncConfig?>? config = null, string? vocab = null,
                          string? replacements = null, string? state = null, Action<string>? log = null,
                          Func<DateTime>? utcNow = null, Action? notify = null)
    {
        _http = http ?? new HttpClient(new HttpClientHandler { AutomaticDecompression = DecompressionMethods.All })
        {
            Timeout = TimeSpan.FromSeconds(20),
        };
        // TotalsSync logs a problem with sync.env; saying it twice adds nothing.
        _config = config ?? (() => SyncConfig.Read(null, null, out _));
        _vocab = vocab ?? Paths.VocabFile;
        _rules = replacements ?? Paths.ReplacementsFile;
        _state = state ?? Paths.DictionaryStateFile;
        _log = log ?? Log.Info;
        _utcNow = utcNow ?? (() => DateTime.UtcNow);
        _notify = notify ?? Glossary.NotifyChanged;
    }

    public static HttpRequestMessage UpsertRequest(SyncConfig config, IEnumerable<DictionaryEntry> entries, DateTime utcNow)
    {
        var stamp = utcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
        var body = new JsonArray();
        foreach (var e in entries)
        {
            body.Add(new JsonObject
            {
                ["kind"] = e.KindName,
                ["key"] = e.Key,
                ["text"] = e.Text,
                ["target"] = e.Target,
                ["learned"] = e.Learned,
                ["deleted"] = e.Deleted,
                ["updated_at"] = stamp,
                ["device"] = config.Device,
            });
        }
        var request = new HttpRequestMessage(HttpMethod.Post, $"{config.RestBase}/{Table}?on_conflict=kind,key")
        {
            Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        Authorize(request, config);
        // The rows come back as the table stored them, so the record holds the table's own
        // updated_at and the next sync can tell this write from a later one.
        request.Headers.TryAddWithoutValidation("Prefer", "resolution=merge-duplicates,return=representation");
        return request;
    }

    public static HttpRequestMessage PageRequest(SyncConfig config, int offset, int limit)
    {
        var request = new HttpRequestMessage(HttpMethod.Get,
            $"{config.RestBase}/{Table}?select=kind,text,target,learned,deleted,updated_at&order=kind.asc,key.asc&limit={limit}&offset={offset}");
        Authorize(request, config);
        return request;
    }

    private static void Authorize(HttpRequestMessage request, SyncConfig config)
    {
        request.Headers.TryAddWithoutValidation("apikey", config.Key);
        if (config.KeyIsJwt) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", config.Key);
    }

    /// The entries in a list of rows, or null when the answer is not a list. A row that will not
    /// read is skipped rather than failing the rest.
    public static List<DictionaryEntry>? ParseRows(string json)
    {
        JsonNode? root;
        try { root = JsonNode.Parse(json); }
        catch (System.Text.Json.JsonException) { return null; }
        if (root is not JsonArray array) return null;
        var rows = new List<DictionaryEntry>();
        foreach (var node in array)
        {
            var e = Entry(node);
            if (e is not null) rows.Add(e);
        }
        return rows;
    }

    private static DictionaryEntry? Entry(JsonNode? node)
    {
        try
        {
            var kind = DictionaryEntry.ParseKind(node?["kind"]?.GetValue<string>());
            var text = node?["text"]?.GetValue<string>();
            var stamp = node?["updated_at"]?.GetValue<string>();
            if (kind is null || string.IsNullOrWhiteSpace(text) || stamp is null) return null;
            return new DictionaryEntry(kind.Value, text, node?["target"]?.GetValue<string>() ?? "",
                node?["learned"]?.GetValue<bool>() ?? false, node?["deleted"]?.GetValue<bool>() ?? false, stamp);
        }
        catch (Exception e) when (e is InvalidOperationException or FormatException)
        {
            return null;
        }
    }

    /// The record of what this computer last agreed with the table, or null when there is none
    /// for this project.
    public static Dictionary<string, DictionaryEntry>? ReadState(string path, string project)
    {
        try
        {
            if (!File.Exists(path)) return null;
            if (JsonNode.Parse(File.ReadAllText(path)) is not JsonObject o) return null;
            if (o["project"]?.GetValue<string>() != project || o["entries"] is not JsonArray rows) return null;
            var state = new Dictionary<string, DictionaryEntry>(StringComparer.Ordinal);
            foreach (var node in rows)
            {
                var e = Entry(node);
                if (e is not null) state[e.Id] = e;
            }
            return state;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Text.Json.JsonException or InvalidOperationException)
        {
            return null;
        }
    }

    public static string StateFile(IReadOnlyDictionary<string, DictionaryEntry> entries, string project)
    {
        var rows = new JsonArray();
        foreach (var id in entries.Keys.OrderBy(k => k, StringComparer.Ordinal))
        {
            var e = entries[id];
            rows.Add(new JsonObject
            {
                ["deleted"] = e.Deleted,
                ["kind"] = e.KindName,
                ["learned"] = e.Learned,
                ["target"] = e.Target,
                ["text"] = e.Text,
                ["updated_at"] = e.UpdatedAt,
            });
        }
        return new JsonObject { ["entries"] = rows, ["project"] = project }
            .ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true });
    }

    /// One sync. False when sync is off or it did not finish; the next one tries again.
    public async Task<bool> SyncAsync(CancellationToken ct = default)
    {
        var config = _config();
        if (config is null) return false;
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var vocabText = ReadOrNull(_vocab);
            var rulesText = ReadOrNull(_rules);
            var state = ReadState(_state, config.Url);

            var remote = new Dictionary<string, DictionaryEntry>(StringComparer.Ordinal);
            for (int offset = 0, pages = 0; pages < 100; pages++)
            {
                using var request = PageRequest(config, offset, PageSize);
                using var response = await _http.SendAsync(request, ct).ConfigureAwait(false);
                if (!response.IsSuccessStatusCode)
                    throw new HttpRequestException("could not read the shared dictionary: " + await Describe(response, ct).ConfigureAwait(false));
                var page = ParseRows(await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false))
                    ?? throw new HttpRequestException("could not read the shared dictionary: the table did not answer with a list of rows");
                if (page.Count == 0) break;
                foreach (var e in page) remote[e.Id] = e;
                offset += page.Count;
            }

            // A file that is not there yet reads as nothing. That is safe: null only ever takes
            // from the table, and an empty list with no record does the same.
            var terms = vocabText is not null ? Glossary.ParseTerms(vocabText) : File.Exists(_vocab) ? null : new List<string>();
            var rules = rulesText is not null ? Glossary.ParseReplacements(rulesText) : File.Exists(_rules) ? null : new List<Replacement>();
            var merge = DictionaryMerger.Merge(terms, rules, state, remote);

            var stored = new List<DictionaryEntry>();
            foreach (var batch in merge.Upload.Chunk(BatchSize))
            {
                using var request = UpsertRequest(config, batch, _utcNow());
                using var response = await _http.SendAsync(request, ct).ConfigureAwait(false);
                if (!response.IsSuccessStatusCode)
                    throw new HttpRequestException("could not send this computer's dictionary changes: " + await Describe(response, ct).ConfigureAwait(false));
                stored.AddRange(ParseRows(await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false)) ?? new List<DictionaryEntry>());
            }

            Finish(merge, stored, config, vocabText, rulesText, terms, rules);
            _lastProblem = null;
            return true;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or InvalidOperationException or IOException)
        {
            var line = "dictionary: " + (e is TaskCanceledException ? "no answer in 20 seconds" : e.Message);
            // Logged once until a sync works again, not on every dictation.
            if (line != _lastProblem) _log(line);
            _lastProblem = line;
            return false;
        }
        finally
        {
            _gate.Release();
        }
    }

    private void Finish(DictionaryMerge merge, List<DictionaryEntry> stored, SyncConfig config, string? vocabText,
                        string? rulesText, List<string>? terms, List<Replacement>? rules)
    {
        var snapshot = new Dictionary<string, DictionaryEntry>(merge.Snapshot, StringComparer.Ordinal);
        foreach (var e in stored) snapshot[e.Id] = e;
        // A file that is there but could not be read is never written over.
        var vocabChanged = terms is not null ? !merge.Terms.SequenceEqual(terms) : !File.Exists(_vocab) && merge.Terms.Count > 0;
        var rulesChanged = rules is not null ? !merge.Rules.SequenceEqual(rules) : !File.Exists(_rules) && merge.Rules.Count > 0;
        if (vocabChanged || rulesChanged)
        {
            // The learner or the window may have saved a file while the table answered. Writing
            // now would undo that; the next sync takes it in instead, and loses nothing, since the
            // record is not saved either.
            if (ReadOrNull(_vocab) != vocabText || ReadOrNull(_rules) != rulesText)
            {
                _log("dictionary: a file changed while syncing; the next sync takes it in");
                return;
            }
            if (vocabChanged) Paths.WriteAtomic(_vocab, Glossary.TermsFile(merge.Terms));
            if (rulesChanged) Paths.WriteAtomic(_rules, Glossary.ReplacementsFile(merge.Rules, rulesText ?? ""));
            try { _notify(); }
            catch (Exception e) { _log($"dictionary: a listener failed: {e.Message}"); }
        }
        Paths.WriteAtomic(_state, StateFile(snapshot, config.Url));
        if (merge.RefusedDeletions > 0)
            _log($"dictionary: {merge.RefusedDeletions} entries went missing here at once, so none was deleted anywhere and the shared copy was taken instead");
        if (merge.Upload.Count > 0 || merge.Taken.Count > 0)
            _log($"dictionary: sent {Describe(merge.Upload)}, took {Describe(merge.Taken)} as {config.Device}");
    }

    private static string Describe(List<DictionaryEntry> entries)
    {
        if (entries.Count == 0) return "nothing";
        var names = string.Join(", ", entries.Take(5).Select(e => (e.Deleted ? "-" : "") + e.Text));
        return entries.Count > 5 ? $"{entries.Count} ({names}, ...)" : names;
    }

    /// A sync for every change, coalesced: while one runs, any number of requests become one more,
    /// which reads the files as they are by then.
    public void Request()
    {
        lock (_requests)
        {
            if (_running) { _again = true; return; }
            _running = true;
        }
        _ = Task.Run(async () =>
        {
            while (true)
            {
                try { await SyncAsync().ConfigureAwait(false); }
                catch (Exception e) { _log($"dictionary: {e.Message}"); }
                lock (_requests)
                {
                    if (!_again) { _running = false; return; }
                    _again = false;
                }
            }
        });
    }

    private static string? ReadOrNull(string path)
    {
        try { return File.ReadAllText(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    private static async Task<string> Describe(HttpResponseMessage response, CancellationToken ct)
    {
        var body = (await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false)).Trim();
        if (body.Length > 200) body = body[..200];
        return $"HTTP {(int)response.StatusCode}{(body.Length > 0 ? ": " + body : "")}";
    }
}
