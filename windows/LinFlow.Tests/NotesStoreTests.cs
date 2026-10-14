using System.Text.Json;
using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// note.json and transcript.jsonl have to stay readable by the Mac (MeetingNote and
/// TranscriptSegment in ../../Sources/LinFlowCore/NotesStore.swift are the spec), and a note the
/// process never stopped has to come back on the next start. Nothing here touches the real
/// %APPDATA%\Lin Flow\notes.
public class NotesStoreTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "linflow-notes-" + Guid.NewGuid().ToString("N"));
    private readonly NotesStore _store;
    public NotesStoreTests() { _store = new NotesStore(_root); }
    public void Dispose() { try { Directory.Delete(_root, true); } catch (IOException) { } }

    [Fact]
    public void Note_json_uses_the_macs_keys_and_omits_absent_optionals()
    {
        var note = _store.Create("Meeting");
        var json = JsonDocument.Parse(File.ReadAllText(_store.NotePath(note.Id))).RootElement;
        foreach (var key in new[] { "id", "title", "createdAt", "durationSeconds", "usedMicrophone", "usedSystemAudio" })
            Assert.True(json.TryGetProperty(key, out _), $"missing key: {key}");
        Assert.False(json.TryGetProperty("endedAt", out _));
        Assert.False(json.TryGetProperty("recovered", out _));
        Assert.Matches(@"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", json.GetProperty("createdAt").GetString());
    }

    /// The summary the model returns already opens with "## Summary", so note.md used to carry
    /// the heading twice, one line after the other.
    [Fact]
    public void A_summary_that_brings_its_own_heading_does_not_get_a_second_one()
    {
        var note = _store.Create("Meeting");
        _store.SaveSummary("## Summary\n- Shipped the thing\n\n## Decisions\n- None", note.Id);
        var md = _store.Markdown(_store.Load(note.Id)!);
        Assert.Equal(1, md.Split("## Summary").Length - 1);
        Assert.Contains("- Shipped the thing", md);
    }

    [Fact]
    public void A_summary_without_a_heading_still_gets_one()
    {
        var note = _store.Create("Meeting");
        _store.SaveSummary("We agreed to ship on Friday.", note.Id);
        var md = _store.Markdown(_store.Load(note.Id)!);
        Assert.Contains("## Summary\n\nWe agreed to ship on Friday.", md);
    }

    [Fact]
    public void Segments_append_in_the_macs_shape_and_read_back_sorted()
    {
        var note = _store.Create("Meeting");
        _store.AppendSegment(new TranscriptSegment { Start = 10, End = 12, Speaker = "Others", Text = "second" }, note.Id);
        _store.AppendSegment(new TranscriptSegment { Start = 1, End = 3, Speaker = "You", Text = "first" }, note.Id);
        var line = File.ReadLines(_store.TranscriptPath(note.Id)).First();
        var json = JsonDocument.Parse(line).RootElement;
        foreach (var key in new[] { "id", "start", "end", "speaker", "text" }) Assert.True(json.TryGetProperty(key, out _), key);
        var back = _store.Transcript(note.Id);
        Assert.Equal(new[] { "first", "second" }, back.Select(s => s.Text));
        Assert.Equal("0:01", back[0].TimestampLabel);
    }

    [Fact]
    public void Replacing_the_transcript_keeps_the_live_one()
    {
        var note = _store.Create("Meeting");
        _store.AppendSegment(new TranscriptSegment { Start = 1, End = 3, Text = "live" }, note.Id);
        _store.ReplaceTranscript(new[] { new TranscriptSegment { Start = 0.8, End = 3.2, Text = "from the audio" } }, note.Id, "Parakeet");
        Assert.Equal("live", NotesStore.ReadSegments(_store.LiveTranscriptPath(note.Id)).Single().Text);
        Assert.Equal("from the audio", _store.Transcript(note.Id).Single().Text);
        var saved = _store.Load(note.Id)!;
        Assert.NotNull(saved.TranscribedFromAudioAt);
        Assert.Equal("Parakeet", saved.TranscriptModel);
        Assert.Contains("transcript rewritten from the audio", File.ReadAllText(_store.EventsPath(note.Id)));
    }

    [Fact]
    public void An_unfinished_note_is_closed_from_its_audio_and_an_empty_one_left_alone()
    {
        var crashed = _store.Create("Crashed mid-meeting");
        var w = new WavWriter(_store.AudioPath(crashed.Id, "mic"));
        w.Append(new float[16_000 * 3].Select(_ => 0.1f).ToArray());
        w.Append(new float[8_000]);          // header still says 3.0 s
        // no Close(): the process died here
        var empty = _store.Create("Created, never recorded");

        var recovered = _store.RecoverUnfinished();

        Assert.Equal(crashed.Id, recovered.Single().Id);
        var saved = _store.Load(crashed.Id)!;
        Assert.True(saved.Recovered);
        Assert.NotNull(saved.EndedAt);
        Assert.Equal(3.5, saved.DurationSeconds, 3);
        Assert.Equal(3.5, WavWriter.Duration(_store.AudioPath(crashed.Id, "mic"))!.Value, 6);
        Assert.Contains("recovered after an unclean stop", File.ReadAllText(_store.EventsPath(crashed.Id)));
        Assert.Null(_store.Load(empty.Id)!.EndedAt);
        w.Close();
    }

    [Fact]
    public void Markdown_has_the_title_notes_and_transcript()
    {
        var note = _store.Create("Board call");
        _store.AppendSegment(new TranscriptSegment { Start = 65, End = 70, Speaker = "Others", Text = "We agreed." }, note.Id);
        File.WriteAllText(_store.NotesPath(note.Id), "ask about Q4");
        var md = _store.Markdown(note);
        Assert.StartsWith("# Board call", md);
        Assert.Contains("## My notes\n\nask about Q4", md);
        Assert.Contains("[1:05] Others: We agreed.", md);
    }
}
