using System.Net;
using System.Text.Json;
using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// The shared totals leave the machine, so these pin what leaves: counts only, the headers
/// Supabase asks for, a changed day and nothing more. A fake server stands in for Supabase; no
/// test here opens a socket or reads the real sync.env.
public class SharedTotalsTests
{
    private static readonly TimeZoneInfo Pacific =
        TimeZoneInfo.CreateCustomTimeZone("test-pdt", TimeSpan.FromHours(-7), "test-pdt", "test-pdt");

    private static readonly DateTime Now = new(2026, 9, 25, 19, 0, 0, DateTimeKind.Utc); // noon on the 25th, Pacific

    private static readonly SyncConfig Config = new("https://abcdefgh.supabase.co", "sb_publishable_test", "LAPTOP-02");

    private static HistoryEntry Take(string utc, string text, double seconds = 2) =>
        new() { Timestamp = utc, Raw = text, Text = text, Model = "t", AudioSeconds = seconds };

    private sealed class FakeServer : HttpMessageHandler
    {
        public readonly List<(HttpMethod Method, string Url, Dictionary<string, string> Headers, string Body)> Requests = new();
        public Func<HttpRequestMessage, HttpResponseMessage> Respond = _ => new HttpResponseMessage(HttpStatusCode.Created);

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(ct);
            var headers = request.Headers.ToDictionary(h => h.Key, h => string.Join(",", h.Value), StringComparer.OrdinalIgnoreCase);
            Requests.Add((request.Method, request.RequestUri!.ToString(), headers, body));
            return Respond(request);
        }
    }

    private static (TotalsSync Sync, FakeServer Server, List<string> Log) Make(
        Func<IReadOnlyList<HistoryEntry>> history, Func<SyncConfig?>? config = null)
    {
        var server = new FakeServer();
        var log = new List<string>();
        var sync = new TotalsSync(new HttpClient(server), config ?? (() => Config), history, log.Add, () => Now, Pacific);
        return (sync, server, log);
    }

    private static List<JsonElement> Rows(string body) =>
        JsonDocument.Parse(body).RootElement.EnumerateArray().ToList();

    // ---------- sync.env

    [Fact]
    public void Config_reads_the_three_keys_past_comments_quotes_and_crlf()
    {
        var text = "# written by setup-sync.sh\r\nSUPABASE_URL=https://abcdefgh.supabase.co/\r\nSUPABASE_KEY=\"sb_publishable_x\"\r\nDEVICE= DESK-01 \r\n";
        var c = SyncConfig.Parse(text, "fallback", out var problem);
        Assert.Null(problem);
        Assert.Equal(new SyncConfig("https://abcdefgh.supabase.co", "sb_publishable_x", "DESK-01"), c);
        Assert.Equal("https://abcdefgh.supabase.co/rest/v1", c!.RestBase);
    }

    [Fact]
    public void Config_without_a_name_uses_the_computer_name()
    {
        var c = SyncConfig.Parse("SUPABASE_URL=https://a.supabase.co\nSUPABASE_KEY=k\n", "LAPTOP-02", out _);
        Assert.Equal("LAPTOP-02", c!.Device);
    }

    [Fact]
    public void Config_takes_the_api_url_with_its_path_too()
    {
        var c = SyncConfig.Parse("SUPABASE_URL=https://a.supabase.co/rest/v1\nSUPABASE_KEY=k\n", "d", out _);
        Assert.Equal("https://a.supabase.co", c!.Url);
    }

    [Theory]
    [InlineData("SUPABASE_URL=https://a.supabase.co\n", "needs both")]
    [InlineData("SUPABASE_KEY=k\n", "needs both")]
    [InlineData("SUPABASE_URL=http://a.supabase.co\nSUPABASE_KEY=k\n", "not an https")]
    [InlineData("SUPABASE_URL=https://a.supabase.co\nSUPABASE_KEY=sb_secret_abc\n", "secret key")]
    public void A_config_it_cannot_use_is_off_and_says_why(string text, string why)
    {
        Assert.Null(SyncConfig.Parse(text, "d", out var problem));
        Assert.Contains(why, problem);
    }

    [Fact]
    public void No_file_is_off_with_nothing_to_report()
    {
        var path = Path.Combine(Path.GetTempPath(), $"lin-flow-no-sync-{Guid.NewGuid():N}.env");
        Assert.Null(SyncConfig.Read(path, "d", out var problem));
        Assert.Null(problem);
    }

    [Fact]
    public void Only_an_old_anon_jwt_is_a_bearer_token()
    {
        Assert.False(Config.KeyIsJwt);
        Assert.True((Config with { Key = "eyJhbGciOiJIUzI1NiJ9.e30.x" }).KeyIsJwt);
    }

    // ---------- counting

    [Fact]
    public void Words_split_on_any_whitespace_as_the_mac_counts_them()
    {
        Assert.Equal(5, DailyTotals.WordCount("one two,\nthree\tfour  five "));
        Assert.Equal(0, DailyTotals.WordCount("  \n "));
    }

    [Fact]
    public void A_day_is_the_local_date_the_dictation_was_made_on()
    {
        // 03:30 UTC on the 25th is 20:30 on the 24th in Pacific daylight time.
        var days = DailyTotals.FromHistory(new[]
        {
            Take("2026-09-25T03:30:00Z", "late one night", 1.5),
            Take("2026-09-24T16:00:00Z", "morning", 1.25),
            Take("2026-09-25T17:00:00Z", "the next day"),
            Take("not a date", "skipped"),
        }, "LAPTOP-02", Pacific);
        Assert.Equal(new[]
        {
            new DayTotal("LAPTOP-02", "2026-09-24", 4, 2, 2.75),
            new DayTotal("LAPTOP-02", "2026-09-25", 3, 1, 2),
        }, days);
    }

    // ---------- what is sent

    [Fact]
    public async Task The_payload_carries_counts_and_nothing_said()
    {
        var rows = DailyTotals.FromHistory(new[] { Take("2026-09-25T17:00:00Z", "the quarterly numbers are confidential") }, "LAPTOP-02", Pacific);
        using var request = TotalsSync.UpsertRequest(Config, rows, Now);
        var body = await request.Content!.ReadAsStringAsync();
        Assert.DoesNotContain("confidential", body);
        var row = Assert.Single(Rows(body));
        Assert.Equal(new[] { "audio_seconds", "day", "device", "dictations", "updated_at", "words" },
                     row.EnumerateObject().Select(p => p.Name).OrderBy(n => n, StringComparer.Ordinal));
        Assert.Equal(5, row.GetProperty("words").GetInt32());
        Assert.Equal("2026-09-25", row.GetProperty("day").GetString());
        Assert.Equal("2026-09-25T19:00:00Z", row.GetProperty("updated_at").GetString());
    }

    [Fact]
    public void An_upsert_is_a_post_that_merges_on_computer_and_day()
    {
        using var request = TotalsSync.UpsertRequest(Config, Array.Empty<DayTotal>(), Now);
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal("https://abcdefgh.supabase.co/rest/v1/daily_totals?on_conflict=device,day", request.RequestUri!.ToString());
        Assert.Equal("resolution=merge-duplicates,return=minimal", string.Join(",", request.Headers.GetValues("Prefer")));
        Assert.Equal("application/json", request.Content!.Headers.ContentType!.MediaType);
    }

    [Fact]
    public void A_publishable_key_goes_in_apikey_only()
    {
        using var request = TotalsSync.PageRequest(Config, 0, 1000);
        Assert.Equal("sb_publishable_test", request.Headers.GetValues("apikey").Single());
        Assert.Null(request.Headers.Authorization);
    }

    [Fact]
    public void An_old_anon_key_also_goes_in_authorization()
    {
        using var request = TotalsSync.PageRequest(Config with { Key = "eyJx.y.z" }, 0, 1000);
        Assert.Equal("eyJx.y.z", request.Headers.GetValues("apikey").Single());
        Assert.Equal("Bearer eyJx.y.z", request.Headers.Authorization!.ToString());
    }

    [Fact]
    public async Task The_first_push_sends_every_day_and_the_next_only_the_changed_one()
    {
        var history = new List<HistoryEntry>
        {
            Take("2026-09-23T17:00:00Z", "one"),
            Take("2026-09-24T17:00:00Z", "one two"),
        };
        var (sync, server, log) = Make(() => history);

        Assert.True(await sync.PushAsync());
        Assert.Equal(2, Rows(server.Requests[0].Body).Count);
        Assert.Contains(log, l => l.Contains("sent 2 days as LAPTOP-02"));

        Assert.True(await sync.PushAsync());
        Assert.Single(server.Requests); // nothing changed, nothing sent

        history.Add(Take("2026-09-25T17:00:00Z", "three words here"));
        Assert.True(await sync.PushAsync());
        var row = Assert.Single(Rows(server.Requests[1].Body));
        Assert.Equal("2026-09-25", row.GetProperty("day").GetString());
        Assert.Equal(3, row.GetProperty("words").GetInt32());
        Assert.True(sync.Status.On);
        Assert.Null(sync.Status.Error);
    }

    [Fact]
    public async Task A_day_whose_dictations_were_all_deleted_is_sent_as_zeros_once()
    {
        var history = new List<HistoryEntry> { Take("2026-09-24T17:00:00Z", "one two"), Take("2026-09-25T17:00:00Z", "three") };
        var (sync, server, _) = Make(() => history);
        await sync.PushAsync();

        history.RemoveAt(0);
        await sync.PushAsync();
        var row = Assert.Single(Rows(server.Requests[1].Body));
        Assert.Equal("2026-09-24", row.GetProperty("day").GetString());
        Assert.Equal(0, row.GetProperty("words").GetInt32());
        Assert.Equal(0, row.GetProperty("dictations").GetInt32());

        await sync.PushAsync();
        Assert.Equal(2, server.Requests.Count);
    }

    [Fact]
    public async Task An_empty_history_after_a_start_zeroes_nothing()
    {
        // An app that comes up against an empty or unreadable data folder has sent nothing this
        // run, so it has nothing to take back. What the table holds for this computer stays.
        var (sync, server, _) = Make(() => new List<HistoryEntry>());
        Assert.True(await sync.PushAsync());
        Assert.Empty(server.Requests);
    }

    [Fact]
    public async Task A_failed_send_is_sent_again_on_the_next_push()
    {
        var history = new List<HistoryEntry> { Take("2026-09-25T17:00:00Z", "one") };
        var (sync, server, log) = Make(() => history);
        server.Respond = _ => new HttpResponseMessage(HttpStatusCode.Unauthorized) { Content = new StringContent("{\"message\":\"Invalid API key\"}") };

        Assert.False(await sync.PushAsync());
        Assert.Contains("HTTP 401", sync.Status.Error);
        Assert.Contains(log, l => l.Contains("could not send") && l.Contains("Invalid API key"));

        server.Respond = _ => new HttpResponseMessage(HttpStatusCode.Created);
        Assert.True(await sync.PushAsync());
        Assert.Equal(2, server.Requests.Count);
        Assert.Equal(server.Requests[0].Body.Replace("\"updated_at\"", ""), server.Requests[1].Body.Replace("\"updated_at\"", ""));
        Assert.Null(sync.Status.Error);
    }

    [Fact]
    public async Task A_new_name_for_this_computer_sends_everything_again()
    {
        var history = new List<HistoryEntry> { Take("2026-09-25T17:00:00Z", "one") };
        var config = Config;
        var (sync, server, _) = Make(() => history, () => config);
        await sync.PushAsync();
        config = Config with { Device = "Laptop" };
        await sync.PushAsync();
        Assert.Equal(2, server.Requests.Count);
        Assert.Equal("Laptop", Rows(server.Requests[1].Body)[0].GetProperty("device").GetString());
    }

    [Fact]
    public async Task With_no_sync_env_nothing_is_sent_or_read()
    {
        var (sync, server, _) = Make(() => new List<HistoryEntry> { Take("2026-09-25T17:00:00Z", "one") }, () => null);
        Assert.False(await sync.PushAsync());
        Assert.False(await sync.PullAsync());
        Assert.Empty(server.Requests);
        Assert.False(sync.Status.On);
        Assert.Null(sync.Combined(new List<HistoryEntry>()));
    }

    // ---------- what is read

    [Fact]
    public async Task A_pull_reads_page_after_page_until_one_comes_back_empty()
    {
        var table = new[]
        {
            """{"device":"DESK-01","day":"2026-09-24","words":10,"dictations":2,"audio_seconds":4.5}""",
            """{"device":"DESK-01","day":"2026-09-25","words":20,"dictations":3,"audio_seconds":6}""",
            """{"device":"Mac","day":"2026-09-25","words":30,"dictations":4,"audio_seconds":7.25}""",
        };
        var (sync, server, _) = Make(() => new List<HistoryEntry>());
        // Two rows a page, the way a project whose "max rows" is below PageSize answers.
        server.Respond = request =>
        {
            var query = System.Web.HttpUtility.ParseQueryString(request.RequestUri!.Query);
            var offset = int.Parse(query["offset"]!);
            var page = table.Skip(offset).Take(2);
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("[" + string.Join(",", page) + "]") };
        };

        Assert.True(await sync.PullAsync());
        Assert.Equal(new[] { "offset=0", "offset=2", "offset=3" },
                     server.Requests.Select(r => r.Url[r.Url.IndexOf("offset=", StringComparison.Ordinal)..]));
        Assert.All(server.Requests, r => Assert.Contains("order=device.asc,day.asc", r.Url));
        var combined = sync.Combined(new List<HistoryEntry>())!;
        Assert.Equal(60, combined.Words);
        Assert.Equal(9, combined.Dictations);
    }

    [Fact]
    public async Task Combined_takes_this_computer_from_its_own_history()
    {
        var (sync, server, _) = Make(() => new List<HistoryEntry>());
        server.Respond = _ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("""
                [{"device":"DESK-01","day":"2026-09-25","words":100,"dictations":10,"audio_seconds":40},
                 {"device":"LAPTOP-02","day":"2026-09-25","words":1,"dictations":1,"audio_seconds":1},
                 {"device":"Old name","day":"2026-09-20","words":0,"dictations":0,"audio_seconds":0}]
                """),
        };
        await sync.PullAsync();
        server.Respond = _ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("[]") };

        // The table still holds this computer's older row; the history already has two more words.
        var combined = sync.Combined(new[] { Take("2026-09-25T17:00:00Z", "one two three") })!;
        Assert.Equal(103, combined.Words);
        Assert.Equal(2, combined.Computers);
        Assert.Equal(3, combined.This!.Words);
        Assert.Equal("DESK-01 100 · LAPTOP-02 3", combined.Breakdown());
    }

    [Fact]
    public void Combined_is_null_until_the_first_read_comes_back()
    {
        var (sync, _, _) = Make(() => new List<HistoryEntry>());
        Assert.Null(sync.Combined(new List<HistoryEntry>()));
    }

    [Fact]
    public void The_streak_counts_a_day_dictated_on_any_computer()
    {
        var combined = DailyTotals.Combine(new[]
        {
            new DayTotal("Mac", "2026-09-23", 5, 1, 1),
            new DayTotal("DESK-01", "2026-09-24", 5, 1, 1),
            new DayTotal("Mac", "2026-09-21", 5, 1, 1),
            new DayTotal("DESK-01", "2026-09-22", 0, 0, 0), // zeroed: not a day with a dictation
        }, new[] { new DayTotal("LAPTOP-02", "2026-09-25", 5, 1, 1) }, "LAPTOP-02", "2026-09-25");
        Assert.Equal(3, combined.StreakDays);
    }

    [Fact]
    public void A_streak_still_stands_before_the_first_dictation_of_the_day()
    {
        var days = new HashSet<string> { "2026-09-23", "2026-09-24" };
        Assert.Equal(2, DailyTotals.Streak(days, "2026-09-25"));
        Assert.Equal(0, DailyTotals.Streak(days, "2026-09-27"));
    }

    [Fact]
    public void A_row_that_will_not_read_is_skipped()
    {
        var rows = TotalsSync.ParseRows("""[{"device":"Mac","day":"2026-09-25","words":"many"},{"device":"Mac","day":"2026-09-24","words":2,"dictations":1,"audio_seconds":1},{"day":"2026-09-23"}]""");
        Assert.Equal(new[] { new DayTotal("Mac", "2026-09-24", 2, 1, 1) }, rows);
    }
}
