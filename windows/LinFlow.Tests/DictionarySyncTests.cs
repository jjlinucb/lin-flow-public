using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// The shared dictionary: what each sync sends, what it takes, and what it must never do. The
/// Mac's selftest cases (Sources/LinFlow/SelfTest/SelfTest+Dictionary.swift), in the same order.
/// A fake table stands in for Supabase and each "computer" is its own temp folder; nothing here
/// reads a real vocab.txt, replacements.txt or sync.env.
public class DictionarySyncTests
{
    private static DictionaryEntry Term(string t, string stamp = "t0", bool deleted = false) =>
        new(DictionaryKind.Term, t, Deleted: deleted, UpdatedAt: stamp);

    private static DictionaryEntry Rule(string from, string to, bool learned = false, string stamp = "t0", bool deleted = false) =>
        new(DictionaryKind.Rule, from, to, learned, deleted, stamp);

    private static Dictionary<string, DictionaryEntry> Table(params DictionaryEntry[] entries) =>
        entries.ToDictionary(e => e.Id, StringComparer.Ordinal);

    private static List<string> Texts(IEnumerable<DictionaryEntry> entries) =>
        entries.Select(e => (e.Deleted ? "-" : "") + e.Text).OrderBy(t => t, StringComparer.Ordinal).ToList();

    private static Replacement R(string from, string to, bool learned = false) => new(from, to, learned);

    private static readonly Dictionary<string, DictionaryEntry> Agreed = Table(Term("Alpha"), Term("Beta"), Rule("x", "y"));

    [Fact]
    public void A_first_sync_to_an_empty_table_sends_everything_and_changes_nothing_here()
    {
        var m = DictionaryMerger.Merge(new[] { "Claude", "Jev" }, new[] { R("Lynn", "Lin"), R("super base", "Supabase", true) },
                                       null, Table());
        Assert.Equal(new[] { "Claude", "Jev", "Lynn", "super base" }, Texts(m.Upload));
        Assert.Empty(m.Taken);
        Assert.Equal(new[] { "Claude", "Jev" }, m.Terms);
        Assert.Equal(new[] { R("Lynn", "Lin"), R("super base", "Supabase", true) }, m.Rules);
        Assert.True(m.Upload.Single(e => e.Text == "super base").Learned);
    }

    [Fact]
    public void A_second_computers_first_sync_takes_the_tables_copy_and_sends_only_what_it_lacked()
    {
        var m = DictionaryMerger.Merge(new[] { "Claude", "LAPTOP-02" }, new[] { R("Lynn", "Linn") }, null,
            Table(Term("Claude"), Term("Jev"), Rule("Lynn", "Lin"), Rule("Dwart", "Duarte", learned: true), Term("Old", deleted: true)));
        Assert.Equal(new[] { "Claude", "LAPTOP-02", "Jev" }, m.Terms);
        Assert.Equal(new[] { R("Lynn", "Lin"), R("Dwart", "Duarte", true) }, m.Rules);
        Assert.Equal(new[] { "LAPTOP-02" }, Texts(m.Upload));
        Assert.Equal(new[] { "Dwart", "Jev", "Lynn" }, Texts(m.Taken));
    }

    [Fact]
    public void Nothing_changed_anywhere_sends_nothing()
    {
        var m = DictionaryMerger.Merge(new[] { "Alpha", "Beta" }, new[] { R("x", "y") }, Agreed, Agreed);
        Assert.Empty(m.Upload);
        Assert.Empty(m.Taken);
        Assert.Equal(new[] { "Alpha", "Beta" }, m.Terms);
    }

    [Fact]
    public void An_add_a_deletion_and_an_edit_here_are_sent()
    {
        var m = DictionaryMerger.Merge(new[] { "Alpha", "Gamma" }, new[] { R("x", "z") }, Agreed, Agreed);
        Assert.Equal(new[] { "-Beta", "Gamma", "x" }, Texts(m.Upload));
        Assert.Equal("z", m.Upload.Single(e => e.Text == "x").Target);
        Assert.Empty(m.Taken);
    }

    [Fact]
    public void A_change_of_case_is_an_edit_not_a_second_entry()
    {
        var m = DictionaryMerger.Merge(new[] { "alpha", "Beta" }, new[] { R("x", "y") }, Agreed, Agreed);
        Assert.Equal(new[] { "alpha" }, Texts(m.Upload));
    }

    [Fact]
    public void Another_computers_add_deletion_and_edit_arrive_here()
    {
        var m = DictionaryMerger.Merge(new[] { "Alpha", "Beta" }, new[] { R("x", "y") }, Agreed,
            Table(Term("Alpha"), Term("Beta", "t1", deleted: true), Rule("x", "w", stamp: "t1"), Term("Delta", "t1")));
        Assert.Equal(new[] { "Alpha", "Delta" }, m.Terms);
        Assert.Equal(new[] { R("x", "w") }, m.Rules);
        Assert.Empty(m.Upload);
        Assert.Equal(new[] { "-Beta", "Delta", "x" }, Texts(m.Taken));
    }

    [Fact]
    public void When_both_changed_a_rule_this_syncs_change_is_sent_and_wins()
    {
        var m = DictionaryMerger.Merge(new[] { "Alpha", "Beta" }, new[] { R("x", "z") }, Agreed,
            Table(Term("Alpha"), Term("Beta"), Rule("x", "w", stamp: "t1")));
        Assert.Equal(new[] { R("x", "z") }, m.Rules);
        Assert.Equal(new[] { "x" }, Texts(m.Upload));
    }

    [Fact]
    public void The_same_change_made_on_both_is_not_sent_again()
    {
        var m = DictionaryMerger.Merge(new[] { "Alpha", "Beta" }, new[] { R("x", "w") }, Agreed,
            Table(Term("Alpha"), Term("Beta"), Rule("x", "w", stamp: "t1")));
        Assert.Empty(m.Upload);
        Assert.Equal("t1", m.Snapshot["rule|x"].UpdatedAt);
    }

    [Fact]
    public void A_vocab_file_that_could_not_be_read_deletes_nothing_anywhere()
    {
        var m = DictionaryMerger.Merge(null, new[] { R("x", "y") }, Agreed, Agreed);
        Assert.DoesNotContain(m.Upload, e => e.Deleted);
        Assert.Equal(new[] { "Alpha", "Beta" }, m.Terms);
    }

    [Fact]
    public void An_emptied_replacements_file_is_refilled_from_the_table_not_sent_as_six_deletions()
    {
        var six = Table(Enumerable.Range(1, 6).Select(i => Rule($"w{i}", $"v{i}")).ToArray());
        var m = DictionaryMerger.Merge(Array.Empty<string>(), Array.Empty<Replacement>(), six, six);
        Assert.Equal(6, m.RefusedDeletions);
        Assert.Empty(m.Upload);
        Assert.Equal(6, m.Rules.Count);

        m = DictionaryMerger.Merge(Array.Empty<string>(), Enumerable.Range(1, 5).Select(i => R($"w{i}", $"v{i}")).ToArray(), six, six);
        Assert.Equal(0, m.RefusedDeletions);
        Assert.Equal(new[] { "-w6" }, Texts(m.Upload));
    }

    [Fact]
    public void An_entry_missing_from_the_table_is_put_back()
    {
        var m = DictionaryMerger.Merge(new[] { "Alpha", "Beta" }, new[] { R("x", "y") }, Agreed, Table(Term("Alpha"), Rule("x", "y")));
        Assert.Equal(new[] { "Beta" }, Texts(m.Upload));
    }

    /// A dictionary_entries table in memory, answering reads and upserts as PostgREST would. It
    /// stamps each write with its own updated_at, not the one sent, the way Postgres rewrites it.
    private sealed class FakeTable : HttpMessageHandler
    {
        public readonly List<(HttpMethod Method, string Url, string Prefer, string Body)> Requests = new();
        public bool FailPosts;
        private readonly SortedDictionary<string, JsonObject> _rows = new(StringComparer.Ordinal);
        private int _clock;

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(ct);
            var prefer = request.Headers.TryGetValues("Prefer", out var p) ? string.Join(",", p) : "";
            lock (Requests) Requests.Add((request.Method, request.RequestUri!.ToString(), prefer, body));
            if (request.Method == HttpMethod.Post)
            {
                if (FailPosts) return new HttpResponseMessage(HttpStatusCode.InternalServerError) { Content = new StringContent("{\"message\":\"down\"}") };
                var back = new JsonArray();
                foreach (var node in JsonNode.Parse(body)!.AsArray())
                {
                    var row = node!.AsObject().DeepClone().AsObject();
                    row["updated_at"] = $"2026-09-25T19:00:00.{++_clock}+00:00";
                    _rows[$"{row["kind"]}|{row["key"]}"] = row;
                    back.Add(row.DeepClone());
                }
                return new HttpResponseMessage(HttpStatusCode.Created) { Content = new StringContent(back.ToJsonString(), Encoding.UTF8, "application/json") };
            }
            var first = request.RequestUri!.Query.Contains("offset=0", StringComparison.Ordinal);
            var page = new JsonArray(first ? _rows.Values.Select(r => (JsonNode)r.DeepClone()).ToArray() : Array.Empty<JsonNode>());
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(page.ToJsonString(), Encoding.UTF8, "application/json") };
        }
    }

    private sealed class Computer
    {
        public readonly string Dir;
        public readonly DictionarySync Sync;
        public string Vocab => Path.Combine(Dir, "vocab.txt");
        public string Rules => Path.Combine(Dir, "replacements.txt");
        public string State => Path.Combine(Dir, "dictionary-sync.json");

        public Computer(string root, string name, FakeTable table)
        {
            Dir = Path.Combine(root, name);
            Directory.CreateDirectory(Dir);
            var config = new SyncConfig("https://abcdefgh.supabase.co", "sb_publishable_test", name);
            Sync = new DictionarySync(new HttpClient(table), () => config, Vocab, Rules, State, _ => { }, notify: () => { });
        }

        public void Run() => Sync.SyncAsync().GetAwaiter().GetResult();
        public string Read(string path) => File.Exists(path) ? File.ReadAllText(path) : "";
    }

    [Fact]
    public void Two_computers_and_one_table()
    {
        var root = Path.Combine(Path.GetTempPath(), "linflow-dict-" + Guid.NewGuid().ToString("N"));
        try
        {
            var table = new FakeTable();
            var mac = new Computer(root, "Mac", table);
            var win = new Computer(root, "LAPTOP-02", table);
            File.WriteAllText(mac.Vocab, "# Lin Flow glossary: one name or term per line.\nClaude\nJev\n");
            File.WriteAllText(mac.Rules, "# Lin Flow corrections: what was heard => what you meant, one per line.\nLynn => Lin\nsuper base => Supabase\t# learned\n# work names\nTeams -> teams\n");
            File.WriteAllText(win.Vocab, "# Lin Flow glossary: one name or term per line.\nClaude\nLAPTOP-02\n");
            File.WriteAllText(win.Rules, "");

            mac.Run();
            var posts = table.Requests.Where(r => r.Method == HttpMethod.Post).ToList();
            var sent = posts.SelectMany(p => JsonNode.Parse(p.Body)!.AsArray()).ToList();
            Assert.Equal(4, sent.Count);
            Assert.Equal(new[] { "deleted", "device", "key", "kind", "learned", "target", "text", "updated_at" },
                         sent[0]!.AsObject().Select(kv => kv.Key).OrderBy(k => k, StringComparer.Ordinal));
            Assert.Equal("https://abcdefgh.supabase.co/rest/v1/dictionary_entries?on_conflict=kind,key", posts[0].Url);
            Assert.Equal("resolution=merge-duplicates,return=representation", posts[0].Prefer);
            Assert.True(File.Exists(mac.State));

            win.Run();
            Assert.Equal(new[] { "Claude", "LAPTOP-02", "Jev" }, Glossary.ParseTerms(win.Read(win.Vocab)));
            Assert.Equal(new[] { R("Lynn", "Lin"), R("super base", "Supabase", true) }, Glossary.ParseReplacements(win.Read(win.Rules)));

            table.Requests.Clear();
            mac.Run();
            Assert.Equal(new[] { "Claude", "Jev", "LAPTOP-02" }, Glossary.ParseTerms(mac.Read(mac.Vocab)));
            Assert.Contains("Teams -> teams", mac.Read(mac.Rules));
            Assert.Contains("# work names", mac.Read(mac.Rules));
            Assert.DoesNotContain(table.Requests, r => r.Method == HttpMethod.Post);
            table.Requests.Clear();
            mac.Run();
            Assert.NotEmpty(table.Requests);
            Assert.All(table.Requests, r => Assert.Equal(HttpMethod.Get, r.Method));

            File.WriteAllText(mac.Rules, "# Lin Flow corrections: what was heard => what you meant, one per line.\nsuper base => Supabase\t# learned\nDwart => Duarte\n");
            mac.Run();
            win.Run();
            Assert.Equal(new[] { R("super base", "Supabase", true), R("Dwart", "Duarte") }, Glossary.ParseReplacements(win.Read(win.Rules)));
            mac.Run();
            Assert.Equal(2, Glossary.ParseReplacements(mac.Read(mac.Rules)).Count);

            table.FailPosts = true;
            File.WriteAllText(win.Vocab, "# Lin Flow glossary: one name or term per line.\nClaude\nLAPTOP-02\nJev\nKhmer\n");
            var recordBefore = win.Read(win.State);
            win.Run();
            Assert.Equal(recordBefore, win.Read(win.State));
            table.FailPosts = false;
            win.Run();
            mac.Run();
            Assert.Contains("Khmer", Glossary.ParseTerms(mac.Read(mac.Vocab)));
        }
        finally
        {
            try { Directory.Delete(root, true); } catch (IOException) { }
        }
    }
}
