using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// history.jsonl is meant to stay greppable and hand-editable, so the window's reader has to
/// survive a file somebody has been editing in Notepad.
public class HistoryLoadTests : IDisposable
{
    private readonly string _dir;
    private readonly string _file;

    public HistoryLoadTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "linflow-history-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_dir);
        _file = Path.Combine(_dir, "history.jsonl");
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    private void Write(params string[] lines) => File.WriteAllLines(_file, lines);

    private static string Row(string text, string stamp) =>
        History.Serialize(new HistoryEntry { Text = text, Raw = text, Timestamp = stamp, AudioSeconds = 2, InferenceSeconds = 0.2 });

    [Fact]
    public void A_missing_file_is_empty_rather_than_an_error()
    {
        Assert.Empty(History.Load(Path.Combine(_dir, "nope.jsonl")));
    }

    [Fact]
    public void Newest_comes_first_because_that_is_what_the_window_shows()
    {
        Write(Row("first", "2026-09-18T10:00:00Z"),
              Row("second", "2026-09-18T11:00:00Z"),
              Row("third", "2026-09-18T12:00:00Z"));
        var got = History.Load(_file);
        Assert.Equal(new[] { "third", "second", "first" }, got.Select(e => e.Text));
    }

    [Fact]
    public void A_hand_edited_row_that_will_not_parse_is_skipped_and_the_rest_survive()
    {
        Write(Row("good one", "2026-09-18T10:00:00Z"),
              "{ this line got mangled in Notepad",
              Row("good two", "2026-09-18T11:00:00Z"));
        var got = History.Load(_file);
        Assert.Equal(new[] { "good two", "good one" }, got.Select(e => e.Text));
    }

    [Fact]
    public void Blank_lines_are_ignored()
    {
        Write(Row("one", "2026-09-18T10:00:00Z"), "", "   ", Row("two", "2026-09-18T11:00:00Z"));
        Assert.Equal(2, History.Load(_file).Count);
    }

    [Fact]
    public void The_limit_keeps_the_newest_not_the_oldest()
    {
        var rows = Enumerable.Range(0, 10).Select(i => Row($"line {i}", $"2026-09-18T{10 + i:00}:00:00Z")).ToArray();
        Write(rows);
        var got = History.Load(_file, limit: 3);
        Assert.Equal(new[] { "line 9", "line 8", "line 7" }, got.Select(e => e.Text));
    }

    [Fact]
    public void A_row_written_by_Append_reads_back_whole()
    {
        var entry = new HistoryEntry
        {
            Raw = "lin flow test",
            Text = "Lin Flow test",
            Model = "parakeet-tdt-0.6b-v3-q8_0",
            AudioSeconds = 3.5,
            InferenceSeconds = 0.25,
        };
        History.Append(entry, _file);
        var got = Assert.Single(History.Load(_file));
        Assert.Equal("Lin Flow test", got.Text);
        Assert.Equal("lin flow test", got.Raw);
        Assert.Equal("parakeet-tdt-0.6b-v3-q8_0", got.Model);
        Assert.Equal(3.5, got.AudioSeconds, 3);
        Assert.Equal(0.25, got.InferenceSeconds, 3);
    }

    [Fact]
    public void The_file_can_be_read_while_the_app_holds_it_open_for_appending()
    {
        History.Append(new HistoryEntry { Text = "while open" }, _file);
        using var held = new FileStream(_file, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);
        var got = History.Load(_file);
        Assert.Single(got);
    }
}
