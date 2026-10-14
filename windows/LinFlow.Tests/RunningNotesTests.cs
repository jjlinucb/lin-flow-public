using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// The running-notes logic, pinned to the Mac's selftest cases, plus the timer around it with a
/// fake writer, and the Ollama client's parsing. A live Ollama test runs only when
/// LINFLOW_OLLAMA_TEST=1 and a server answers.
public class RunningNotesTests
{
    private static TranscriptSegment Seg(string id, double start, int words) =>
        new() { Id = id, Start = start, End = start + 5, Speaker = "Others", Text = string.Join(' ', Enumerable.Repeat("word", words)) };

    private static readonly List<TranscriptSegment> Segs = new() { Seg("c", 30, 10), Seg("a", 10, 10), Seg("b", 20, 10), Seg("d", 40, 10), Seg("e", 50, 10) };

    [Fact]
    public void Window_is_the_unnoted_segments_in_time_order()
    {
        Assert.Equal(new[] { "c", "d", "e" }, RunningNotes.Window(Segs, new HashSet<string> { "a", "b" }).Select(s => s.Id));
        Assert.Equal(new[] { "a", "b" }, RunningNotes.Window(Segs, new HashSet<string>(), maxWords: 25).Select(s => s.Id));
        Assert.Single(RunningNotes.Window(Segs, new HashSet<string>(), maxWords: 3));
        Assert.Equal(50, RunningNotes.WordCount(Segs));
    }

    [Theory]
    [InlineData(50, 61, false, true)]
    [InlineData(50, 30, false, false)]
    [InlineData(20, 120, false, false)]
    [InlineData(20, 0, true, true)]
    [InlineData(5, 0, true, false)]
    public void Is_due(int words, double since, bool final, bool expected) => Assert.Equal(expected, RunningNotes.IsDue(words, since, final));

    [Fact]
    public void Format_stamps_each_bullet_with_the_stretchs_start()
    {
        Assert.Equal("- [12:05] Ship the batch Friday.\n- [12:05] Ask Dana for the figures.\n",
            RunningNotes.Format(new[] { "Ship the batch Friday.", "Ask Dana for the figures." }, 725));
        Assert.Equal("", RunningNotes.Format(Array.Empty<string>(), 725));
    }

    [Fact]
    public void Recent_returns_the_last_bullets_without_stamps()
    {
        var md = string.Concat(Enumerable.Range(1, 12).Select(i => $"- [0:0{i % 10}] Note number {i}.\n"));
        var recent = RunningNotes.Recent(md, 8);
        Assert.Equal(8, recent.Count);
        Assert.Equal("Note number 5.", recent[0]);
        Assert.Equal("Note number 12.", recent[^1]);
    }

    [Fact]
    public void Repeats_and_markers_are_dropped()
    {
        Assert.Equal(new[] { "Budget is 40k." }, RunningNotes.DropRepeats(new[] { "Ship the batch Friday", "Budget is 40k.", "budget is 40K" }, new[] { "Ship the batch Friday." }));
        Assert.Equal(new[] { "Ship Friday.", "Ask Dana." }, RunningNotes.Tidy(new[] { "- **Ship Friday.**", "2) Ask Dana.", "None", "" }));
        Assert.Empty(RunningNotes.DropRepeats(new[] { "David J. Lamb overviewing business questions" }, new[] { "David J. Lamb will overview business questions." }));
    }

    [Fact]
    public void Fragments_and_labels_are_not_notes()
    {
        Assert.Null(RunningNotes.WorthKeeping("Name: Ted"));
        Assert.Null(RunningNotes.WorthKeeping("I got one."));
        Assert.Equal("Send the OTA draft to Ted tomorrow", RunningNotes.WorthKeeping("Task: send the OTA draft to Ted tomorrow"));
        Assert.Equal("National security due diligence responses are due today.", RunningNotes.WorthKeeping("National security due diligence responses are due today."));
        const string stretch = "[3:00] Others: Document review extends to Wednesday for everyone, and the pilot budget is $40,000. We will open 2 engineering roles in October. Dana owns the vendor contract.";
        Assert.Equal(new[] { "Document review extends to Wednesday for everyone." },
            RunningNotes.Filter(new[] { "Question: profit pool and equipment", "Document review extends to Wednesday for everyone.", "document review extends to wednesday for everyone" }, Array.Empty<string>(), stretch));
    }

    [Fact]
    public void Invented_facts_are_not_grounded()
    {
        const string stretch = "[3:00] Others: Document review extends to Wednesday for everyone, and the pilot budget is $40,000. We will open 2 engineering roles in October. Dana owns the vendor contract.";
        Assert.False(RunningNotes.Grounded("The deadline is Friday, October 18th.", stretch));
        Assert.False(RunningNotes.Grounded("Five deals were done the week before.", stretch));
        Assert.True(RunningNotes.Grounded("The budget is 40,000 dollars.", stretch));
        Assert.True(RunningNotes.Grounded("Two engineering roles open in October.", stretch));
        Assert.True(RunningNotes.Grounded("Dana owns the vendor contract.", stretch));
        Assert.False(RunningNotes.Grounded("The contract is owned by Marc.", stretch));
        Assert.True(RunningNotes.Grounded("Review runs to Wednesday, as You noted.", stretch));
        Assert.False(RunningNotes.Grounded("Anna agreed to help with the paperwork review.", stretch));
        Assert.Equal("## Open questions\n- The genesis of the strategy.", OllamaClient.TidySummary("## Open questions\n- The genesis of the strategy.\n\nNone\n"));
        Assert.Equal("## Decisions\n- None", OllamaClient.TidySummary("## Decisions\n- None\n"));
    }

    [Fact]
    public void Ollama_answers_parse_as_json_or_as_bullets()
    {
        Assert.Equal(new[] { "A", "B" }, OllamaClient.ParseNotes("""{"notes": ["A", "- B"]}"""));
        Assert.Equal(new[] { "A" }, OllamaClient.ParseNotes("```json\n{\"notes\":[\"A\"]}\n```"));
        Assert.Equal(new[] { "First point", "Second point" }, OllamaClient.ParseNotes("Here you go:\n- First point\n- Second point\nHope that helps"));
        Assert.Empty(OllamaClient.ParseNotes("""{"notes": []}"""));
    }

    private sealed class FakeWriter : INoteWriter
    {
        public string Name => "fake";
        public int Calls;
        public Task<List<string>> RunningNotesAsync(IReadOnlyList<string> previous, string transcript, string title, CancellationToken ct = default)
        {
            Calls++;
            return Task.FromResult(new List<string> { $"Bullet {Calls} covering {transcript.Split('\n').Length} lines" });
        }
        public Task<string> SummaryAsync(string runningNotes, string lastStretch, string title, CancellationToken ct = default) => Task.FromResult("## Summary\n- fake\n");
    }

    [Fact]
    public async Task Taker_runs_a_pass_once_a_minute_of_speech_is_there_and_drains_at_the_end()
    {
        var root = Path.Combine(Path.GetTempPath(), "linflow-running-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new NotesStore(root);
            var note = store.Create("Test");
            var now = new DateTime(2026, 9, 17, 12, 0, 0, DateTimeKind.Utc);
            var writer = new FakeWriter();
            using var taker = new RunningNotesTaker(store, note.Id, writer, note.Title, () => now);
            taker.Start();
            for (var i = 0; i < 5; i++) store.AppendSegment(Seg($"s{i}", i * 10, 10), note.Id);   // 50 words

            await taker.TickAsync();                        // 30 s in: not due
            now = now.AddSeconds(30);
            Assert.Equal(0, writer.Calls);
            now = now.AddSeconds(31);
            await taker.TickAsync();                        // 61 s: due
            Assert.Equal(1, writer.Calls);
            Assert.Equal("- [0:00] Bullet 1 covering 5 lines\n", store.RunningNotes(note.Id));

            store.AppendSegment(Seg("tail", 60, 15), note.Id);
            await taker.StopAsync();                        // the final pass takes the short tail
            Assert.Equal(2, writer.Calls);
            Assert.Contains("- [1:00] Bullet 2 covering 1 lines", store.RunningNotes(note.Id));
            Assert.Contains("## Running notes", store.Markdown(note));
        }
        finally { try { Directory.Delete(root, true); } catch (IOException) { } }
    }

    /// Replays a real transcript through the Ollama client a minute at a time and writes the
    /// bullets to LINFLOW_OLLAMA_REPLAY_OUT, so the prompt can be judged on the Mac against the
    /// same meeting the Mac's pass is judged on. Runs only when LINFLOW_OLLAMA_REPLAY names a
    /// transcript.jsonl.
    [Fact]
    public async Task Live_ollama_replays_a_transcript()
    {
        var path = Environment.GetEnvironmentVariable("LINFLOW_OLLAMA_REPLAY");
        var outPath = Environment.GetEnvironmentVariable("LINFLOW_OLLAMA_REPLAY_OUT");
        if (string.IsNullOrEmpty(path) || string.IsNullOrEmpty(outPath)) return;
        var client = new OllamaClient();
        Assert.Null(await client.CheckAsync());
        var segments = NotesStore.ReadSegments(path);
        var notes = "";
        var processed = new HashSet<string>();
        var report = new System.Text.StringBuilder();
        var window = RunningNotes.Interval;
        var last = segments[^1].End;
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var calls = 0;
        for (var windowEnd = window; windowEnd < last + window; windowEnd += window)
        {
            var final = windowEnd >= last;
            while (true)
            {
                var due = segments.Where(s => !processed.Contains(s.Id) && s.End <= windowEnd).ToList();
                var fresh = RunningNotes.Window(due, processed);
                var words = RunningNotes.WordCount(fresh);
                if (fresh.Count == 0 || !RunningNotes.IsDue(words, window, final)) break;
                var t0 = sw.Elapsed;
                var bullets = await client.RunningNotesAsync(RunningNotes.Recent(notes), NotesStore.TranscriptText(fresh), "Meeting");
                calls++;
                foreach (var s in fresh) processed.Add(s.Id);
                var block = RunningNotes.Format(bullets, fresh[0].Start);
                notes += block;
                report.Append($"-- pass at {fresh[0].TimestampLabel}: {words} words in, {bullets.Count} bullet(s), {(sw.Elapsed - t0).TotalSeconds:F1} s\n").Append(block.Length == 0 ? "   (nothing worth noting)\n" : block);
            }
            if (final) break;
        }
        report.Append($"\n{calls} call(s), {sw.Elapsed.TotalSeconds:F1} s total [{client.Name}]\n");
        var summary = await client.SummaryAsync(notes, NotesStore.TranscriptText(segments.Where(s => s.End >= last - 180)), "Meeting");
        report.Append("\n==== summary ====\n").Append(summary).Append('\n');
        File.WriteAllText(outPath, report.ToString());
        Assert.True(calls > 0);
    }

    /// A meeting that recorded silence must not come back with invented action items. On
    /// 2026-09-18 a 28 s note with an empty transcript and no running notes produced two, both
    /// dated. The model is never asked now, so there is nothing for it to invent - and this needs
    /// no server, which is the point: it is the one case that must hold whether Ollama is there
    /// or not.
    [Fact]
    public async Task Nothing_said_and_nothing_noted_gives_no_summary()
    {
        // A host nothing is listening on: reaching the network at all would fail this test.
        var client = new OllamaClient("http://127.0.0.1:1");
        Assert.Equal("", await client.SummaryAsync("", "", "Empty meeting"));
        Assert.Equal("", await client.SummaryAsync("   ", "\n  \n", "Empty meeting"));
    }

    [Fact]
    public async Task Live_ollama_takes_notes_when_asked_to()
    {
        if (Environment.GetEnvironmentVariable("LINFLOW_OLLAMA_TEST") != "1") return;
        var client = new OllamaClient();
        var problem = await client.CheckAsync();
        Assert.Null(problem);
        var bullets = await client.RunningNotesAsync(new[] { "The batch ships Friday." },
            "[0:05] Others: So the budget for the pilot is forty thousand dollars, and Dana owns the vendor contract.\n[0:20] You: Okay, I will send the figures by Tuesday.",
            "Pilot planning");
        Assert.NotEmpty(bullets);
        Assert.True(bullets.Count <= 3);
    }
}
