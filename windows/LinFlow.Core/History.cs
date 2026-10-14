using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace LinFlow.Core;

/// One row of history.jsonl. The keys and the encoding match HistoryEntry in
/// ../../Sources/LinFlowCore/History.swift, so the file copies between the Mac and Windows
/// unchanged: camelCase keys, ISO 8601 UTC timestamp, uppercase UUID, nulls omitted.
public sealed class HistoryEntry
{
    public string Id { get; init; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public string Timestamp { get; init; } = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
    public string Raw { get; init; } = "";
    public string Text { get; init; } = "";
    public string Model { get; init; } = "";
    public double AudioSeconds { get; init; }
    public double InferenceSeconds { get; init; }
    public string? AudioFile { get; init; }
    public string? Original { get; init; }
    public string? Transform { get; init; }

    /// How the take was made, kept with it because app.log is not forever and these are the
    /// numbers a decision gets made from. Same keys as the Mac's (5884622), so a file still
    /// copies between the machines.
    ///
    /// The Mac also stores `snrDB`, `noiseFloor` and `app`. Windows has no SNR estimator yet
    /// (`AudioIO.snrEstimate` is Mac-only) and does not read the app it pasted into, so those
    /// three are left out rather than written as invented nulls-that-look-like-data. Old rows
    /// decode without any of this: every field is optional and nulls are omitted on write.
    public string? InputDevice { get; init; }
    public double? FirstAudioSeconds { get; init; }
}

/// The local-only dictation log, one JSON object per line, appended after each dictation.
///
/// The window's Dictation list reads it, and a data folder copied to the Mac shows its history
/// window straight away.
public static class History
{
    private static readonly object Gate = new();

    /// Raised after a row is on disk, so the window can show it straight away. The Mac's
    /// History.didChange, which its window reloads on for the same reason.
    ///
    /// Until 2026-09-23 nothing was raised, and the window read the file only when it was shown:
    /// a dictation made while the window was already open did not appear until John closed it
    /// and opened it again. It is raised on the writer's thread, which for a dictation is the
    /// hotkey's worker, so a listener that touches controls has to marshal.
    public static event Action? DidChange;

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        // Keep names and CJK readable in the file rather than \uXXXX-escaping every non-ASCII
        // character. The file is local and is meant to be greppable by hand.
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static string Serialize(HistoryEntry entry) => JsonSerializer.Serialize(entry, Options);

    public static void Append(HistoryEntry entry) => Append(entry, Paths.HistoryFile);

    /// The most recent dictations, newest first, for the window's Dictations list.
    ///
    /// history.jsonl is meant to be greppable and hand-editable, so it has to be read line by
    /// line and a line that will not parse is skipped rather than throwing: one bad row must
    /// never cost the user the rest of their history. `limit` is a cap on what is returned, not
    /// on what is read, because the newest rows are at the end of the file.
    public static List<HistoryEntry> Load(string? path = null, int limit = 500)
    {
        var file = path ?? Paths.HistoryFile;
        var entries = new List<HistoryEntry>();
        try
        {
            if (!File.Exists(file)) return entries;
            lock (Gate)
            {
                // Shared read/write: the app appends to this file while the window is open.
                using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                using var reader = new StreamReader(fs, Encoding.UTF8);
                while (reader.ReadLine() is { } line)
                {
                    if (string.IsNullOrWhiteSpace(line)) continue;
                    try
                    {
                        var entry = JsonSerializer.Deserialize<HistoryEntry>(line, Options);
                        if (entry is not null) entries.Add(entry);
                    }
                    catch (JsonException) { /* a hand-edited row: skip it, keep the rest */ }
                }
            }
        }
        catch (Exception e)
        {
            Log.Info($"could not read history: {e.Message}");
        }
        entries.Reverse();
        return limit > 0 && entries.Count > limit ? entries.GetRange(0, limit) : entries;
    }

    /// `onError` exists so a test can drive the failure path without writing a line into the
    /// live %APPDATA%\Lin Flow\app.log. It defaults to the real log, which is what the app uses.
    /// Everything in this repo that touches John's data folder gets a seam like this: a test run
    /// on his own machine must be indistinguishable from not having run.
    public static void Append(HistoryEntry entry, string path, Action<string>? onError = null)
    {
        var report = onError ?? (m => Log.Info(m));
        try
        {
            lock (Gate)
            {
                var dir = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                using var fs = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read);
                // A hand-edited file may have lost its final newline; never glue two rows
                // together. Same guard as the Mac's FileHandle path.
                if (fs.Length > 0)
                {
                    fs.Seek(-1, SeekOrigin.End);
                    if (fs.ReadByte() != '\n') fs.WriteByte((byte)'\n');
                }
                fs.Seek(0, SeekOrigin.End);
                var bytes = Encoding.UTF8.GetBytes(Serialize(entry) + "\n");
                fs.Write(bytes, 0, bytes.Length);
            }
        }
        catch (Exception e)
        {
            // History is a convenience. Failing to write it must never cost a dictation.
            report($"history: {e.Message}");
            return;
        }

        // Outside the lock and the file, so a listener can read the row straight back. Its
        // failure is caught here for the same reason as the write's: the caller is the dictation,
        // and a window that failed to refresh must not turn it into "Dictation failed".
        try { DidChange?.Invoke(); }
        catch (Exception e) { report($"history: a listener failed: {e.Message}"); }
    }
}
