using System.Text.Json;
using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// history.jsonl has to stay readable by the Mac's window, which decodes it with a JSONDecoder
/// using camelCase keys and .iso8601 dates. These cases pin the shape rather than the values:
/// HistoryEntry in ../../Sources/LinFlowCore/History.swift is the spec.
///
/// Nothing here goes near the real %APPDATA%\Lin Flow\history.jsonl. The append tests write to a
/// temp file and delete it.
public class HistoryTests
{
    private static JsonElement Parse(HistoryEntry e) =>
        JsonDocument.Parse(History.Serialize(e)).RootElement;

    [Fact]
    public void Keys_are_camel_case_and_match_the_swift_names()
    {
        var json = Parse(new HistoryEntry { Raw = "r", Text = "t", Model = "m" });
        foreach (var key in new[] { "id", "timestamp", "raw", "text", "model", "audioSeconds", "inferenceSeconds" })
            Assert.True(json.TryGetProperty(key, out _), $"missing key: {key}");
    }

    [Fact]
    public void How_the_take_was_made_uses_the_swift_key_names()
    {
        // The Mac added these in 5884622 and decodes them with decodeIfPresent, so a row
        // written here has to spell them its way or they read as absent over there.
        var json = Parse(new HistoryEntry
        {
            Raw = "r", Text = "t", Model = "m",
            InputDevice = "Microphone Array on SoundWire Device", FirstAudioSeconds = 0.183,
        });
        Assert.Equal("Microphone Array on SoundWire Device", json.GetProperty("inputDevice").GetString());
        Assert.Equal(0.183, json.GetProperty("firstAudioSeconds").GetDouble());
    }

    [Fact]
    public void A_take_with_no_measurements_writes_neither_key()
    {
        // Every take before 2026-09-22 has none of this, and so does any take with
        // LINFLOW_TEST_AUDIO set. An absent key is honest; a null that decodes as a value is not.
        var json = Parse(new HistoryEntry { Raw = "r", Text = "t", Model = "m" });
        Assert.False(json.TryGetProperty("inputDevice", out _));
        Assert.False(json.TryGetProperty("firstAudioSeconds", out _));
    }

    [Fact]
    public void Absent_optionals_are_omitted_not_null()
    {
        // Swift's decodeIfPresent copes with either, but a null reads as a real value in every
        // other tool that opens this file, so match the Mac's encoder and leave them out.
        var json = Parse(new HistoryEntry());
        Assert.False(json.TryGetProperty("audioFile", out _));
        Assert.False(json.TryGetProperty("original", out _));
        Assert.False(json.TryGetProperty("transform", out _));
    }

    [Fact]
    public void Present_optionals_are_written()
    {
        var json = Parse(new HistoryEntry { Original = "before", Transform = "Email" });
        Assert.Equal("before", json.GetProperty("original").GetString());
        Assert.Equal("Email", json.GetProperty("transform").GetString());
    }

    [Fact]
    public void Timestamp_is_iso8601_utc_that_swift_can_decode()
    {
        var ts = Parse(new HistoryEntry()).GetProperty("timestamp").GetString()!;
        // .iso8601 wants no fractional seconds and a Z, e.g. 2026-09-16T20:31:04Z
        Assert.Matches(@"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", ts);
    }

    [Fact]
    public void Non_ascii_survives_unescaped()
    {
        // A dictation naming a person should be greppable by eye in the log.
        var json = History.Serialize(new HistoryEntry { Text = "Marisa Vuong 你好" });
        Assert.Contains("Marisa Vuong 你好", json);
    }

    [Fact]
    public void Serialized_row_is_one_line()
    {
        Assert.DoesNotContain("\n", History.Serialize(new HistoryEntry { Text = "a b c" }));
    }

    [Fact]
    public void Append_writes_one_row_per_call()
    {
        var path = Path.Combine(Path.GetTempPath(), $"linflow-history-{Guid.NewGuid():N}.jsonl");
        try
        {
            History.Append(new HistoryEntry { Text = "first" }, path);
            History.Append(new HistoryEntry { Text = "second" }, path);
            var lines = File.ReadAllLines(path);
            Assert.Equal(2, lines.Length);
            Assert.Equal("first", JsonDocument.Parse(lines[0]).RootElement.GetProperty("text").GetString());
            Assert.Equal("second", JsonDocument.Parse(lines[1]).RootElement.GetProperty("text").GetString());
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void Append_repairs_a_hand_edited_file_with_no_trailing_newline()
    {
        var path = Path.Combine(Path.GetTempPath(), $"linflow-history-{Guid.NewGuid():N}.jsonl");
        try
        {
            File.WriteAllText(path, "{\"text\":\"edited by hand\"}");   // no trailing newline
            History.Append(new HistoryEntry { Text = "next" }, path);
            var lines = File.ReadAllLines(path);
            Assert.Equal(2, lines.Length);
            Assert.Equal("next", JsonDocument.Parse(lines[1]).RootElement.GetProperty("text").GetString());
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void Append_never_throws_when_the_path_is_unusable()
    {
        // A dictation must not be lost because its log line could not be written.
        //
        // The failure is captured here rather than logged. Without the onError seam this test
        // wrote "history: Null character in path" into the real %APPDATA%\Lin Flow\app.log on
        // whichever machine ran it, which is the file John reads first when a dictation goes
        // wrong. A test must leave no trace in live data.
        var path = Path.Combine(Path.GetTempPath(), $"linflow-{Guid.NewGuid():N}", "nope\0bad.jsonl");
        var errors = new List<string>();

        History.Append(new HistoryEntry { Text = "x" }, path, errors.Add);

        var reported = Assert.Single(errors);
        Assert.StartsWith("history: ", reported);
    }

    [Fact]
    public void Append_raises_DidChange_once_the_row_can_be_read()
    {
        // The window reloads its list on this, so it has to come after the row is on disk.
        // Other test classes append in parallel and raise it too, which is why this records what
        // each call could see rather than counting the calls.
        var path = Path.Combine(Path.GetTempPath(), $"linflow-history-{Guid.NewGuid():N}.jsonl");
        var seen = new List<int>();
        void OnChange() { lock (seen) seen.Add(File.Exists(path) ? History.Load(path).Count : 0); }
        History.DidChange += OnChange;
        try
        {
            History.Append(new HistoryEntry { Text = "shown straight away" }, path);
            lock (seen) Assert.Contains(1, seen);
        }
        finally
        {
            History.DidChange -= OnChange;
            File.Delete(path);
        }
    }

    [Fact]
    public void A_listener_that_throws_does_not_fail_the_dictation()
    {
        // Append's caller is the dictation itself. A window that failed to refresh would
        // otherwise surface as "Dictation failed" on a take that had already pasted.
        var path = Path.Combine(Path.GetTempPath(), $"linflow-history-{Guid.NewGuid():N}.jsonl");
        var errors = new List<string>();
        void Broken() => throw new InvalidOperationException("the window is gone");
        History.DidChange += Broken;
        try
        {
            History.Append(new HistoryEntry { Text = "x" }, path, errors.Add);
            Assert.Single(History.Load(path));
            Assert.Contains(errors, e => e.Contains("the window is gone"));
        }
        finally
        {
            History.DidChange -= Broken;
            File.Delete(path);
        }
    }
}
