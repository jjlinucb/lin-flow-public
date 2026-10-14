using System.Text.Json;
using System.Text.Json.Serialization;

namespace LinFlow.Core;

/// One meeting note's metadata: note.json. The keys and the date format are the Mac's
/// (MeetingNote in ../../Sources/LinFlowCore/NotesStore.swift), so a note folder copied between
/// the two machines opens unchanged on either.
public sealed class MeetingNote
{
    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public string Title { get; set; } = "";
    public string CreatedAt { get; set; } = NotesStore.Now();
    public string? EndedAt { get; set; }
    public double DurationSeconds { get; set; }
    public bool UsedMicrophone { get; set; } = true;
    public bool UsedSystemAudio { get; set; } = true;
    public string? SummaryModel { get; set; }
    /// Set once the transcript was rewritten from the saved audio.
    public string? TranscribedFromAudioAt { get; set; }
    public string? TranscriptModel { get; set; }
    /// The app did not stop this recording; the next start closed it from what was on disk.
    public bool? Recovered { get; set; }
}

public sealed class TranscriptSegment
{
    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    /// Seconds from the start of the note.
    public double Start { get; set; }
    public double End { get; set; }
    /// "You" (microphone) or "Others" (system audio).
    public string Speaker { get; set; } = "You";
    public string Text { get; set; } = "";

    public string TimestampLabel
    {
        get
        {
            var s = (int)Start;
            return s >= 3600 ? $"{s / 3600}:{s % 3600 / 60:D2}:{s % 60:D2}" : $"{s / 60}:{s % 60:D2}";
        }
    }
}

/// One folder per meeting note under %APPDATA%\Lin Flow\notes\: note.json, transcript.jsonl
/// (segments as they land, then rewritten from the audio once the meeting ends, the live version
/// kept as transcript-live.jsonl), notes.md, summary.md, events.log (gaps, restarts, failures)
/// and the audio as WAV. Plain files on purpose, and the same names as the Mac.
public sealed class NotesStore
{
    public string Root { get; }
    private readonly object _gate = new();

    public NotesStore(string? root = null) { Root = root ?? Paths.NotesDir; }

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true,
    };
    private static readonly JsonSerializerOptions Line = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static string Now() => DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
    public static DateTime Parse(string iso) => DateTime.Parse(iso, null, System.Globalization.DateTimeStyles.RoundtripKind).ToUniversalTime();

    public string Folder(string id) => Path.Combine(Root, id);
    public string NotePath(string id) => Path.Combine(Folder(id), "note.json");
    public string TranscriptPath(string id) => Path.Combine(Folder(id), "transcript.jsonl");
    public string LiveTranscriptPath(string id) => Path.Combine(Folder(id), "transcript-live.jsonl");
    public string NotesPath(string id) => Path.Combine(Folder(id), "notes.md");
    public string SummaryPath(string id) => Path.Combine(Folder(id), "summary.md");
    public string EventsPath(string id) => Path.Combine(Folder(id), "events.log");
    public string RunningNotesPath(string id) => Path.Combine(Folder(id), "running-notes.md");
    public string AudioPath(string id, string source) => Path.Combine(Folder(id), $"audio-{source}.wav");

    public static readonly (string File, string Speaker)[] Sources = { ("mic", "You"), ("system", "Others") };

    public bool HasAudio(string id) => Sources.Any(s => File.Exists(AudioPath(id, s.File)));

    /// Newest first.
    public List<MeetingNote> List()
    {
        if (!Directory.Exists(Root)) return new List<MeetingNote>();
        var notes = new List<MeetingNote>();
        foreach (var dir in Directory.EnumerateDirectories(Root))
        {
            var n = Load(Path.GetFileName(dir));
            if (n is not null) notes.Add(n);
        }
        return notes.OrderByDescending(n => n.CreatedAt, StringComparer.Ordinal).ToList();
    }

    public MeetingNote? Load(string id)
    {
        try
        {
            var path = NotePath(id);
            return File.Exists(path) ? JsonSerializer.Deserialize<MeetingNote>(File.ReadAllText(path), Json) : null;
        }
        catch (Exception) { return null; }
    }

    public MeetingNote Create(string title)
    {
        var note = new MeetingNote { Title = title };
        Directory.CreateDirectory(Folder(note.Id));
        Save(note);
        return note;
    }

    public void Save(MeetingNote note)
    {
        lock (_gate)
        {
            Directory.CreateDirectory(Folder(note.Id));
            Paths.WriteAtomic(NotePath(note.Id), JsonSerializer.Serialize(note, Json));
        }
    }

    public void AppendSegment(TranscriptSegment segment, string id)
    {
        lock (_gate) AppendLine(TranscriptPath(id), JsonSerializer.Serialize(segment, Line));
    }

    /// One dated line in the note's events.log: starts and stops, gaps filled with silence,
    /// source restarts, write failures, recoveries. The audit trail for "what happened to the
    /// recording", readable in any text editor.
    public void AppendEvent(string text, string id)
    {
        lock (_gate) AppendLine(EventsPath(id), $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {text}");
    }

    private void AppendLine(string path, string line)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.AppendAllText(path, line + "\n", new System.Text.UTF8Encoding(false));
        }
        catch (Exception e) { Log.Info($"notes: appending to {Path.GetFileName(path)}: {e.Message}"); }
    }

    public List<TranscriptSegment> Transcript(string id) => ReadSegments(TranscriptPath(id));

    public static List<TranscriptSegment> ReadSegments(string path)
    {
        var list = new List<TranscriptSegment>();
        if (!File.Exists(path)) return list;
        foreach (var line in File.ReadLines(path))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            try { var s = JsonSerializer.Deserialize<TranscriptSegment>(line, Line); if (s is not null) list.Add(s); }
            catch (JsonException) { /* a half-written last line after a crash */ }
        }
        return list.OrderBy(s => s.Start).ToList();
    }

    /// Replaces the transcript with one made from the saved audio. The first time, the live
    /// transcript is kept next to it as transcript-live.jsonl; nothing is thrown away.
    public void ReplaceTranscript(IEnumerable<TranscriptSegment> segments, string id, string model)
    {
        var list = segments.OrderBy(s => s.Start).ToList();
        lock (_gate)
        {
            var main = TranscriptPath(id);
            var live = LiveTranscriptPath(id);
            if (File.Exists(main) && !File.Exists(live)) File.Move(main, live);
            var sb = new System.Text.StringBuilder();
            foreach (var s in list) sb.Append(JsonSerializer.Serialize(s, Line)).Append('\n');
            Paths.WriteAtomic(main, sb.ToString());
        }
        var note = Load(id);
        if (note is not null)
        {
            note.TranscribedFromAudioAt = Now();
            note.TranscriptModel = model;
            Save(note);
        }
        AppendEvent($"transcript rewritten from the audio: {list.Count} segments ({model})", id);
    }

    /// Closes notes the app never stopped: a crash, a force quit, a dead battery. Repairs the WAV
    /// headers from the file sizes (see WavWriter), takes the duration from the longest track or
    /// the last transcript line, and stamps an approximate end. A note that was created but never
    /// recorded is left as it is. Call once at start, before anything records.
    public List<MeetingNote> RecoverUnfinished()
    {
        var recovered = new List<MeetingNote>();
        foreach (var note in List().Where(n => n.EndedAt is null))
        {
            double duration = 0;
            var hadAudio = false;
            foreach (var s in Sources)
            {
                var path = AudioPath(note.Id, s.File);
                if (!File.Exists(path)) continue;
                hadAudio = true;
                try { if (WavWriter.RepairHeader(path)) Log.Info($"notes: repaired the header of {Path.GetFileName(path)} in {note.Id}"); }
                catch (Exception e) { Log.Info($"notes: could not repair {Path.GetFileName(path)}: {e.Message}"); }
                duration = Math.Max(duration, WavWriter.Duration(path) ?? 0);
            }
            var lastLine = Transcript(note.Id).LastOrDefault()?.End ?? 0;
            duration = Math.Max(duration, lastLine);
            if (!hadAudio && lastLine <= 0) continue;
            note.DurationSeconds = duration;
            note.EndedAt = Parse(note.CreatedAt).AddSeconds(duration).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
            note.Recovered = true;
            Save(note);
            AppendEvent($"recovered after an unclean stop with {(int)duration} s of audio", note.Id);
            Log.Info($"notes: recovered {note.Id} ({(int)duration} s) after an unclean stop");
            recovered.Add(note);
        }
        return recovered;
    }

    public string NotesText(string id) => File.Exists(NotesPath(id)) ? File.ReadAllText(NotesPath(id)) : "";

    /// The bullets written during the meeting (see RunningNotes), appended a pass at a time so
    /// they are on disk the moment they exist.
    public string RunningNotes(string id) => File.Exists(RunningNotesPath(id)) ? File.ReadAllText(RunningNotesPath(id)) : "";
    public void AppendRunningNotes(string markdown, string id)
    {
        if (string.IsNullOrEmpty(markdown)) return;
        lock (_gate)
        {
            try { Directory.CreateDirectory(Folder(id)); File.AppendAllText(RunningNotesPath(id), markdown, new System.Text.UTF8Encoding(false)); }
            catch (Exception e) { Log.Info($"notes: appending running notes: {e.Message}"); }
        }
    }
    public void SaveSummary(string markdown, string id)
    {
        lock (_gate) Paths.WriteAtomic(SummaryPath(id), markdown);
    }
    public string? Summary(string id) => File.Exists(SummaryPath(id)) ? File.ReadAllText(SummaryPath(id)) : null;

    /// Transcript as readable lines, e.g. "[3:05] You: ...".
    public static string TranscriptText(IEnumerable<TranscriptSegment> segments, bool timestamps = true) =>
        string.Join("\n", segments.Select(s => timestamps ? $"[{s.TimestampLabel}] {s.Speaker}: {s.Text}" : $"{s.Speaker}: {s.Text}"));

    /// Everything about a note as one Markdown document.
    public string Markdown(MeetingNote note)
    {
        var sb = new System.Text.StringBuilder();
        sb.Append("# ").Append(note.Title).Append("\n\n");
        sb.Append(Parse(note.CreatedAt).ToLocalTime().ToString("dddd, MMMM d, yyyy h:mm tt"));
        if (note.DurationSeconds > 0) sb.Append(" · ").Append((int)(note.DurationSeconds / 60)).Append(" min");
        sb.Append("\n\n");
        var summary = Summary(note.Id);
        if (!string.IsNullOrWhiteSpace(summary))
        {
            // The model is asked for "## Summary" as its first heading, so adding one here gave
            // note.md two of them, one straight after the other.
            var body = summary.Trim();
            if (!body.StartsWith("## ", StringComparison.Ordinal)) sb.Append("## Summary\n\n");
            sb.Append(body).Append("\n\n");
        }
        var notes = NotesText(note.Id);
        if (!string.IsNullOrWhiteSpace(notes)) sb.Append("## My notes\n\n").Append(notes.Trim()).Append("\n\n");
        var running = RunningNotes(note.Id);
        if (!string.IsNullOrWhiteSpace(running)) sb.Append("## Running notes\n\n").Append(running.Trim()).Append("\n\n");
        var segments = Transcript(note.Id);
        if (segments.Count > 0) sb.Append("## Transcript\n\n").Append(TranscriptText(segments)).Append('\n');
        return sb.ToString();
    }
}
