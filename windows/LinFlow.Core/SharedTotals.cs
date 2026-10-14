using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;

namespace LinFlow.Core;

/// Shared word totals: one number across every computer John dictates on, instead of one per
/// computer. The Mac's TotalsSync.swift is the same design, and SYNC-PLAN.md has the reasoning.
///
/// What leaves the machine is one row per computer per day: its name, the date, and three counts.
/// Transcripts, audio, the dictionary and the app names never do. Each row is rebuilt from the
/// local history.jsonl and sent whole, so a retry or a double send can only write the same numbers
/// again, and the other computers' rows come back from the same table.

/// Where the shared totals live and what this computer is called there: sync.env in the data
/// folder, KEY=VALUE lines that scripts/setup-sync.sh writes. The same file and keys on the Mac.
public sealed record SyncConfig(string Url, string Key, string Device)
{
    /// The old anon keys are JWTs and also go in Authorization. The publishable keys that replace
    /// them go in apikey only: Supabase says so, and accepts them in Authorization only for migration.
    public bool KeyIsJwt => Key.StartsWith("eyJ", StringComparison.Ordinal);

    public string RestBase => Url + "/rest/v1";

    /// What "already sent" is remembered against. A new project or a new name starts over.
    public string Identity => Url + "|" + Device;

    public static string DefaultDevice() => Environment.MachineName;

    /// Null with a reason when the file is there but unusable, and null with no reason when there
    /// is no file, which is the normal state of a computer that has not been set up.
    public static SyncConfig? Read(string? path, string? defaultDevice, out string? problem)
    {
        problem = null;
        var file = path ?? Paths.SyncFile;
        try
        {
            if (!File.Exists(file)) return null;
            return Parse(File.ReadAllText(file), defaultDevice ?? DefaultDevice(), out problem);
        }
        catch (Exception e)
        {
            problem = $"could not read {Path.GetFileName(file)}: {e.Message}";
            return null;
        }
    }

    public static SyncConfig? Parse(string text, string defaultDevice, out string? problem)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var eq = line.IndexOf('=');
            if (eq <= 0) continue;
            var value = line[(eq + 1)..].Trim();
            if (value.Length >= 2 && ((value[0] == '"' && value[^1] == '"') || (value[0] == '\'' && value[^1] == '\'')))
                value = value[1..^1];
            values[line[..eq].Trim()] = value;
        }

        values.TryGetValue("SUPABASE_URL", out var url);
        values.TryGetValue("SUPABASE_KEY", out var key);
        values.TryGetValue("DEVICE", out var device);
        if (string.IsNullOrWhiteSpace(url) || string.IsNullOrWhiteSpace(key))
        {
            problem = "sync.env needs both SUPABASE_URL and SUPABASE_KEY";
            return null;
        }
        url = url.Trim().TrimEnd('/');
        // The dashboard shows the project URL; a copy of the API URL with its path is the same place.
        if (url.EndsWith("/rest/v1", StringComparison.OrdinalIgnoreCase)) url = url[..^"/rest/v1".Length];
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps)
        {
            problem = $"SUPABASE_URL is not an https address: {url}";
            return null;
        }
        if (key.Trim().StartsWith("sb_secret_", StringComparison.Ordinal))
        {
            // A secret key skips every row rule in the table. It must never sit in a file the app reads.
            problem = "SUPABASE_KEY is a secret key; use the project's publishable key";
            return null;
        }
        device = string.IsNullOrWhiteSpace(device) ? defaultDevice : device.Trim();
        if (device.Length > 64) device = device[..64];
        problem = null;
        return new SyncConfig(url, key.Trim(), device);
    }
}

/// One computer's dictation totals for one local calendar day. This, and nothing else, is sent.
public sealed record DayTotal(string Device, string Day, int Words, int Dictations, double AudioSeconds)
{
    public bool IsEmpty => Words == 0 && Dictations == 0 && AudioSeconds == 0;
}

public sealed record DeviceTotal(string Device, int Words, int Dictations);

/// Every computer's rows added up, with this computer's taken from its own history rather than
/// from the last copy the table sent back, so a dictation made a second ago is already in it.
public sealed record CombinedTotals(int Words, int Dictations, double AudioSeconds, int StreakDays,
                                    IReadOnlyList<DeviceTotal> Devices, string ThisDevice)
{
    /// Computers with at least one dictation. A name that only ever sent zeros is not a computer.
    public int Computers => Devices.Count;
    public DeviceTotal? This => Devices.FirstOrDefault(d => d.Device == ThisDevice);

    /// "DESK-01 15,002 · LAPTOP-02 6,091 · Mac 20,110", most words first.
    public string Breakdown() => string.Join(" · ", Devices.Select(d => $"{d.Device} {d.Words:N0}"));
}

public static class DailyTotals
{
    /// Words as the Mac counts them: runs of anything that is not whitespace. The window used to
    /// split on spaces only, so a spoken "enter" glued the words either side of it into one.
    public static int WordCount(string text) => text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;

    /// "2026-09-25", the local calendar date of a history timestamp, or null if it will not parse.
    public static string? DayOf(string timestamp, TimeZoneInfo zone)
    {
        if (!DateTimeOffset.TryParse(timestamp, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var when)) return null;
        return TimeZoneInfo.ConvertTimeFromUtc(when.UtcDateTime, zone).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    }

    /// This computer's days, oldest first, one row per date with at least one dictation.
    public static List<DayTotal> FromHistory(IEnumerable<HistoryEntry> entries, string device, TimeZoneInfo? zone = null)
    {
        var tz = zone ?? TimeZoneInfo.Local;
        var days = new SortedDictionary<string, (int Words, int Dictations, double Audio)>(StringComparer.Ordinal);
        foreach (var e in entries)
        {
            if (DayOf(e.Timestamp, tz) is not { } day) continue;
            days.TryGetValue(day, out var t);
            days[day] = (t.Words + WordCount(e.Text), t.Dictations + 1, t.Audio + e.AudioSeconds);
        }
        // Rounded so the same history always makes an equal row: "changed since it was sent" is
        // decided by comparing rows, and a sum of doubles is not worth a resend in its last digit.
        return days.Select(d => new DayTotal(device, d.Key, d.Value.Words, d.Value.Dictations, Math.Round(d.Value.Audio, 2))).ToList();
    }

    public static CombinedTotals Combine(IEnumerable<DayTotal> remote, IEnumerable<DayTotal> local, string device, string today)
    {
        var rows = remote.Where(r => r.Device != device).Concat(local).ToList();
        var devices = rows.GroupBy(r => r.Device)
            .Select(g => new DeviceTotal(g.Key, g.Sum(r => r.Words), g.Sum(r => r.Dictations)))
            .Where(d => d.Dictations > 0)
            .OrderByDescending(d => d.Words).ThenBy(d => d.Device, StringComparer.Ordinal)
            .ToList();
        var active = rows.Where(r => r.Dictations > 0).Select(r => r.Day).ToHashSet(StringComparer.Ordinal);
        return new CombinedTotals(rows.Sum(r => r.Words), rows.Sum(r => r.Dictations),
            Math.Round(rows.Sum(r => r.AudioSeconds), 2), Streak(active, today), devices, device);
    }

    /// Consecutive days with a dictation on any computer, ending today, or yesterday when today
    /// has none yet. The Mac's HistoryStats.streakDays, counted over every computer.
    public static int Streak(IReadOnlySet<string> days, string today)
    {
        if (!DateOnly.TryParseExact(today, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day)) return 0;
        string Key(DateOnly d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        if (!days.Contains(Key(day))) day = day.AddDays(-1);
        var streak = 0;
        while (days.Contains(Key(day))) { streak++; day = day.AddDays(-1); }
        return streak;
    }
}

/// What the Settings page says about the shared totals.
public sealed record SyncStatus(bool On, string? Device, DateTime? LastSyncUtc, string? Error)
{
    public static readonly SyncStatus Off = new(false, null, null, null);
}

/// Sends this computer's changed days and reads everyone's. One instance runs for the app's life.
///
/// "Changed" is decided against what this run has already sent, kept in memory: the first send
/// after a start is every day in the history, which is also how a new computer backfills, and
/// after that a dictation sends only its own day. A day that vanishes from the history (the Mac
/// can delete a dictation) is sent as zeros. A day that is simply absent is never zeroed: an app
/// that started against an empty or unreadable data folder must not wipe what the table holds.
public sealed class TotalsSync
{
    public const string Table = "daily_totals";
    public const int PageSize = 1000;
    /// Rows per upsert. A first send is a few hundred days at most; this keeps each request small.
    public const int BatchSize = 500;

    public static TotalsSync Shared { get; } = new();

    private readonly HttpClient _http;
    private readonly Func<SyncConfig?> _config;
    private readonly Func<IReadOnlyList<HistoryEntry>> _history;
    private readonly Action<string> _log;
    private readonly Func<DateTime> _utcNow;
    private readonly TimeZoneInfo _zone;

    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly object _state = new();
    private Dictionary<string, DayTotal> _sent = new(StringComparer.Ordinal);
    private string? _sentFor;
    private List<DayTotal> _remote = new();
    private string? _remoteFor;
    private SyncStatus _status = SyncStatus.Off;
    private string? _lastProblem;

    private readonly object _requests = new();
    private bool _pushRunning, _pushAgain, _pullRunning;

    /// Raised on a pool thread after a pull or a push finishes, whether or not it worked.
    public event Action? Changed;

    public TotalsSync(HttpClient? http = null, Func<SyncConfig?>? config = null,
                      Func<IReadOnlyList<HistoryEntry>>? history = null, Action<string>? log = null,
                      Func<DateTime>? utcNow = null, TimeZoneInfo? zone = null)
    {
        _http = http ?? new HttpClient(new HttpClientHandler { AutomaticDecompression = DecompressionMethods.All })
        {
            Timeout = TimeSpan.FromSeconds(20),
        };
        _log = log ?? Log.Info;
        _config = config ?? ReadConfig;
        _history = history ?? (() => History.Load(limit: 0));
        _utcNow = utcNow ?? (() => DateTime.UtcNow);
        _zone = zone ?? TimeZoneInfo.Local;
    }

    /// sync.env, read fresh each time so the setup script takes effect with no restart. A problem
    /// with the file is logged once, not on every dictation.
    private SyncConfig? ReadConfig()
    {
        var config = SyncConfig.Read(null, null, out var problem);
        lock (_state)
        {
            if (problem != _lastProblem && problem is not null) _log($"shared totals are off: {problem}");
            _lastProblem = problem;
        }
        return config;
    }

    public SyncStatus Status { get { lock (_state) return _status; } }

    public string Today() =>
        TimeZoneInfo.ConvertTimeFromUtc(_utcNow(), _zone).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    /// Every computer's totals, or null while sync is off or before the first read has come back.
    public CombinedTotals? Combined(IReadOnlyList<HistoryEntry> localHistory)
    {
        var config = _config();
        if (config is null) return null;
        List<DayTotal> remote;
        lock (_state)
        {
            if (_remoteFor != config.Identity) return null;
            remote = _remote;
        }
        var local = DailyTotals.FromHistory(localHistory, config.Device, _zone);
        return DailyTotals.Combine(remote, local, config.Device, Today());
    }

    /// The rows to send: each day whose totals differ from what was sent, and zeros for a day that
    /// was sent this run and has since gone from the history.
    public static List<DayTotal> Plan(IReadOnlyList<DayTotal> local, IReadOnlyDictionary<string, DayTotal> sent)
    {
        var rows = local.Where(r => !sent.TryGetValue(r.Day, out var was) || was != r).ToList();
        var present = local.Select(r => r.Day).ToHashSet(StringComparer.Ordinal);
        rows.AddRange(sent.Values.Where(s => !present.Contains(s.Day) && !s.IsEmpty)
                                 .Select(s => new DayTotal(s.Device, s.Day, 0, 0, 0)));
        return rows;
    }

    public static HttpRequestMessage UpsertRequest(SyncConfig config, IEnumerable<DayTotal> rows, DateTime utcNow)
    {
        var stamp = utcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        var body = new JsonArray();
        foreach (var r in rows)
        {
            body.Add(new JsonObject
            {
                ["device"] = r.Device,
                ["day"] = r.Day,
                ["words"] = r.Words,
                ["dictations"] = r.Dictations,
                ["audio_seconds"] = r.AudioSeconds,
                ["updated_at"] = stamp,
            });
        }
        var request = new HttpRequestMessage(HttpMethod.Post, $"{config.RestBase}/{Table}?on_conflict=device,day")
        {
            Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        Authorize(request, config);
        request.Headers.TryAddWithoutValidation("Prefer", "resolution=merge-duplicates,return=minimal");
        return request;
    }

    public static HttpRequestMessage PageRequest(SyncConfig config, int offset, int limit)
    {
        var request = new HttpRequestMessage(HttpMethod.Get,
            $"{config.RestBase}/{Table}?select=device,day,words,dictations,audio_seconds&order=device.asc,day.asc&limit={limit}&offset={offset}");
        Authorize(request, config);
        return request;
    }

    private static void Authorize(HttpRequestMessage request, SyncConfig config)
    {
        request.Headers.TryAddWithoutValidation("apikey", config.Key);
        if (config.KeyIsJwt) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", config.Key);
    }

    /// The table's rows. A row that will not read is skipped rather than failing the rest.
    public static List<DayTotal> ParseRows(string json)
    {
        var rows = new List<DayTotal>();
        if (JsonNode.Parse(json) is not JsonArray array) return rows;
        foreach (var node in array)
        {
            try
            {
                var device = node?["device"]?.GetValue<string>();
                var day = node?["day"]?.GetValue<string>();
                if (string.IsNullOrEmpty(device) || string.IsNullOrEmpty(day)) continue;
                rows.Add(new DayTotal(device, day,
                    node?["words"]?.GetValue<int>() ?? 0,
                    node?["dictations"]?.GetValue<int>() ?? 0,
                    node?["audio_seconds"]?.GetValue<double>() ?? 0));
            }
            catch (Exception e) when (e is InvalidOperationException or FormatException) { /* skip the row */ }
        }
        return rows;
    }

    /// Sends what changed. False when sync is off or the send failed; the failure is kept in
    /// Status and the log, and the next push sends the same rows again.
    public async Task<bool> PushAsync(CancellationToken ct = default)
    {
        var config = _config();
        if (config is null) { SetStatus(SyncStatus.Off); RaiseChanged(); return false; }
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            Dictionary<string, DayTotal> sent;
            lock (_state)
            {
                if (_sentFor != config.Identity) { _sent = new(StringComparer.Ordinal); _sentFor = config.Identity; }
                sent = _sent;
            }
            var local = DailyTotals.FromHistory(_history(), config.Device, _zone);
            var rows = Plan(local, sent);
            if (rows.Count == 0)
            {
                // Nothing to send is still news when the file has just appeared: the totals are on.
                if (!Status.On) SetStatus(new SyncStatus(true, config.Device, null, null));
                return true;
            }
            var first = sent.Count == 0;
            foreach (var batch in rows.Chunk(BatchSize))
            {
                using var request = UpsertRequest(config, batch, _utcNow());
                using var response = await _http.SendAsync(request, ct).ConfigureAwait(false);
                if (!response.IsSuccessStatusCode)
                    throw new HttpRequestException(await Describe(response, ct).ConfigureAwait(false));
                lock (_state)
                {
                    foreach (var r in batch)
                        if (r.IsEmpty) sent.Remove(r.Day); else sent[r.Day] = r;
                }
            }
            _log(first
                ? $"shared totals: sent {rows.Count} day{(rows.Count == 1 ? "" : "s")} as {config.Device}, the first send since Lin Flow started"
                : $"shared totals: sent {string.Join(", ", rows.Select(r => r.Day))} as {config.Device}");
            SetStatus(new SyncStatus(true, config.Device, _utcNow(), null));
            return true;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or InvalidOperationException)
        {
            Fail(config, "could not send this computer's totals", e);
            return false;
        }
        finally
        {
            _gate.Release();
            RaiseChanged();
        }
    }

    /// Reads every computer's rows, page by page until one comes back empty. It does not stop at a
    /// short page: the project's "max rows" setting can be lower than PageSize, and stopping early
    /// would quietly drop the rest. False when off or unreachable; the last good copy is kept.
    public async Task<bool> PullAsync(CancellationToken ct = default)
    {
        var config = _config();
        if (config is null) { SetStatus(SyncStatus.Off); RaiseChanged(); return false; }
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var byKey = new Dictionary<(string, string), DayTotal>();
            // A hundred pages is 100,000 rows, about 90 years of three computers. The cap is there
            // for a server that ignores offset and answers every page with the first one.
            for (int offset = 0, pages = 0; pages < 100; pages++)
            {
                using var request = PageRequest(config, offset, PageSize);
                using var response = await _http.SendAsync(request, ct).ConfigureAwait(false);
                if (!response.IsSuccessStatusCode)
                    throw new HttpRequestException(await Describe(response, ct).ConfigureAwait(false));
                var page = ParseRows(await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
                if (page.Count == 0) break;
                // A row written by another computer mid-read can shift a page; the key keeps one copy.
                foreach (var r in page) byKey[(r.Device, r.Day)] = r;
                offset += page.Count;
            }
            lock (_state)
            {
                _remote = byKey.Values.ToList();
                _remoteFor = config.Identity;
            }
            SetStatus(new SyncStatus(true, config.Device, _utcNow(), null));
            return true;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or InvalidOperationException or System.Text.Json.JsonException)
        {
            Fail(config, "could not read the shared totals", e);
            return false;
        }
        finally
        {
            _gate.Release();
            RaiseChanged();
        }
    }

    /// A push for every history change, coalesced: while one runs, any number of requests become
    /// one more, which recomputes from the file as it is by then.
    public void RequestPush()
    {
        lock (_requests)
        {
            if (_pushRunning) { _pushAgain = true; return; }
            _pushRunning = true;
        }
        _ = Task.Run(async () =>
        {
            while (true)
            {
                try { await PushAsync().ConfigureAwait(false); }
                catch (Exception e) { _log($"shared totals: {e.Message}"); }
                lock (_requests)
                {
                    if (!_pushAgain) { _pushRunning = false; return; }
                    _pushAgain = false;
                }
            }
        });
    }

    /// A read, unless one is already under way.
    public void RequestPull()
    {
        lock (_requests)
        {
            if (_pullRunning) return;
            _pullRunning = true;
        }
        _ = Task.Run(async () =>
        {
            try { await PullAsync().ConfigureAwait(false); }
            catch (Exception e) { _log($"shared totals: {e.Message}"); }
            finally { lock (_requests) _pullRunning = false; }
        });
    }

    private void Fail(SyncConfig config, string what, Exception e)
    {
        var reason = e is TaskCanceledException ? "no answer in 20 seconds" : e.Message;
        _log($"shared totals: {what}: {reason}");
        SetStatus(new SyncStatus(true, config.Device, Status.LastSyncUtc, reason));
    }

    private static async Task<string> Describe(HttpResponseMessage response, CancellationToken ct)
    {
        var body = (await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false)).Trim();
        if (body.Length > 200) body = body[..200];
        return $"HTTP {(int)response.StatusCode}{(body.Length > 0 ? ": " + body : "")}";
    }

    private void SetStatus(SyncStatus status) { lock (_state) _status = status; }

    private void RaiseChanged()
    {
        try { Changed?.Invoke(); }
        catch (Exception e) { _log($"shared totals: a listener failed: {e.Message}"); }
    }
}
