using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace LinFlow.Core;

/// Something that can take notes on a stretch of transcript. The Mac's is Apple Intelligence;
/// here it is a local model behind Ollama. Tests use a fake.
public interface INoteWriter
{
    string Name { get; }
    /// Zero to three new bullets about the newest stretch, given the bullets already taken.
    Task<List<string>> RunningNotesAsync(IReadOnlyList<string> previous, string transcript, string title, CancellationToken ct = default);
    /// The meeting's final notes as Markdown, from the running notes and the last stretch.
    Task<string> SummaryAsync(string runningNotes, string lastStretch, string title, CancellationToken ct = default);
}

/// Ollama's local HTTP API (http://127.0.0.1:11434 by default) with a small instruct model.
/// Nothing leaves the machine: Ollama runs on this PC and the model is downloaded once with
/// `ollama pull`. Windows has no on-device model the way macOS 26 has Apple Intelligence, and
/// binding llama.cpp directly would put a second copy of ggml next to whisper.cpp's, so the
/// notetaker talks to Ollama instead. The client is plain HTTP and JSON, which is why it lives
/// in Core and is tested on the Mac against a real Ollama.
public sealed class OllamaClient : INoteWriter
{
    /// 127.0.0.1 rather than localhost, deliberately. Ollama binds IPv4 only, and Windows resolves
    /// localhost to ::1 first: the connection to ::1 has to fail before the IPv4 one is tried, and
    /// measured on John's laptop on 2026-09-18 that took 2.14 s against 14 ms direct. CheckAsync
    /// gives up after two seconds, so every meeting would have reported "Ollama is not answering"
    /// with Ollama running perfectly well - and the message tells you to install what you already
    /// have. A name that resolves to an address nothing is listening on is a slow failure, which
    /// is the worst kind to put a short timeout in front of.
    public const string DefaultHost = "http://127.0.0.1:11434";
    public const string DefaultModel = "qwen2.5:3b";

    public string Host { get; }
    public string Model { get; }
    public string Name => $"Ollama · {Model}";

    private readonly HttpClient _http;
    private bool _schemaUnsupported;

    public OllamaClient(string? host = null, string? model = null, HttpClient? http = null)
    {
        Host = (host ?? DefaultHost).TrimEnd('/');
        Model = model ?? DefaultModel;
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(120) };
    }

    /// Null when the server answers and the model is there; otherwise one sentence saying what
    /// to do about it. Quick (two seconds at most), for `doctor` and for the start of a meeting.
    public async Task<string?> CheckAsync(CancellationToken ct = default)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(2));
            var tags = await _http.GetFromJsonAsync<JsonNode>($"{Host}/api/tags", cts.Token);
            var names = tags?["models"]?.AsArray().Select(m => m?["name"]?.GetValue<string>() ?? "").ToList() ?? new List<string>();
            var have = names.Any(n => n == Model || n == Model + ":latest" || (Model.Contains(':') ? false : n.StartsWith(Model + ":")));
            return have ? null : $"Ollama is running but the model is not there. Run: ollama pull {Model}";
        }
        catch (Exception)
        {
            return $"Ollama is not answering at {Host}. Install it from ollama.com, then run: ollama pull {Model}";
        }
    }

    /// The same instructions as the Mac's Summarizer.runningInstructions.
    public const string RunningInstructions =
        "You take running notes during a meeting, a minute or two at a time. Lines look like \"[m:ss] Speaker: words\". " +
        "\"You\" is the note-taker, \"Others\" are the other participants. You are given the notes already taken and the newest " +
        "stretch of transcript. Write down only what is new in the newest stretch and worth remembering afterwards: something decided, " +
        "something someone agreed to do and who, a number, a date, a deadline, a question left open, a fact that matters. Each note is " +
        "one complete sentence, under 20 words, in your own words, that a colleague who missed this minute would understand on its own: " +
        "say who and what. Not a label, not a heading, not a name or a number on its own, never a transcript line copied out, never " +
        "\"Task:\" or \"Question:\" in front. Most stretches deserve one note or none: greetings, small talk, filler, thinking aloud " +
        "and anything already in the notes get nothing. Something asked but not settled is written as a question, not as a fact. " +
        "Keep names, numbers, dates and product names exactly as written, and never add a number, a date or a name the stretch does " +
        "not contain. Do not add commentary, do not infer what was not said, do not use em dashes. " +
        "Answer as JSON: {\"notes\": [\"...\"]} with zero to three strings, usually one, often none.";

    public const string SummaryInstructions =
        "You write the final notes for a meeting. Output plain Markdown with exactly these four headings in this order: " +
        "## Summary (3 to 6 bullets, each under 25 words, covering what the meeting was about and what happened), ## Decisions, " +
        "## Action items (who does what, with any dates mentioned), ## Open questions. Under a heading with nothing to report write a " +
        "single bullet \"None\". \"You\" in the transcript is the person whose notes these are; refer to them as \"you\". Be concrete " +
        "and short. Keep names, numbers and dates exactly as given. A decision is only something the participants agreed to do; never " +
        "turn a question, a proposal or an open point into a decision. If a date or number is not stated, do not compute or infer one. " +
        "Do not invent anything that is not in the text, do not add commentary, do not use em dashes or semicolons.";

    private static readonly JsonNode NotesSchema = JsonNode.Parse(
        """{"type":"object","properties":{"notes":{"type":"array","items":{"type":"string"},"maxItems":3}},"required":["notes"]}""")!;

    public async Task<List<string>> RunningNotesAsync(IReadOnlyList<string> previous, string transcript, string title, CancellationToken ct = default)
    {
        var text = transcript.Trim();
        if (text.Length == 0) return new List<string>();
        var taken = previous.Count == 0 ? "(none yet)" : string.Join("\n", previous.Select(p => "* " + p));
        var prompt = $"Meeting: {title}\nNotes already taken:\n{taken}\n\nNewest stretch of the transcript:\n\n{text}";
        var content = await ChatAsync(RunningInstructions, prompt, NotesSchema, maxTokens: 240, ct);
        return RunningNotes.Filter(ParseNotes(content), previous, text);
    }

    public async Task<string> SummaryAsync(string runningNotes, string lastStretch, string title, CancellationToken ct = default)
    {
        // Nothing said, nothing noted: do not ask. On 2026-09-18 a 28 s meeting that recorded
        // silence - an empty transcript.jsonl and no running notes - came back with two action
        // items, both invented, both with dates: "send out the meeting minutes by September 20"
        // and "schedule the next meeting for October 2nd at 8:30 AM". The model fills every
        // heading it is given, which is the same padding the Mac's notes filter exists for; asked
        // to summarize nothing, invention is the only thing it can do. An empty summary is the
        // honest answer and the caller already treats "" as "there is none".
        if (runningNotes.Trim().Length == 0 && lastStretch.Trim().Length == 0) return "";

        var notes = runningNotes.Trim().Length == 0 ? "(none were taken)" : runningNotes.Trim();
        var prompt = $"Meeting: {title}\nRunning notes taken during the meeting, in order:\n\n{notes}\n\nThe last stretch of the transcript:\n\n{lastStretch.Trim()}";
        return TidySummary(await ChatAsync(SummaryInstructions, prompt, null, maxTokens: 900, ct));
    }

    /// A small model likes to close a list with a lone "None" as well; that line goes.
    public static string TidySummary(string markdown)
    {
        var lines = markdown.Trim().Split('\n').Select(l => l.TrimEnd()).ToList();
        for (var i = lines.Count - 1; i > 0; i--)
        {
            if (!lines[i].Trim().Equals("None", StringComparison.OrdinalIgnoreCase) && !lines[i].Trim().Equals("- None", StringComparison.OrdinalIgnoreCase)) continue;
            var j = i - 1;
            while (j >= 0 && lines[j].Trim().Length == 0) j--;
            if (j >= 0 && (lines[j].TrimStart().StartsWith("- ") || lines[j].TrimStart().StartsWith("* "))) lines.RemoveAt(i);
        }
        return string.Join('\n', lines).Trim();
    }

    /// The model's answer as a list: the JSON object it was asked for, or, when it answered in
    /// prose anyway, its bullet lines.
    public static List<string> ParseNotes(string content)
    {
        var s = content.Trim();
        if (s.StartsWith("```")) { var nl = s.IndexOf('\n'); s = nl >= 0 ? s[(nl + 1)..] : s; if (s.EndsWith("```")) s = s[..^3]; s = s.Trim(); }
        try
        {
            var node = JsonNode.Parse(s);
            if (node is JsonObject obj && obj["notes"] is JsonArray arr)
                return RunningNotes.Tidy(arr.Select(n => n?.GetValue<string>() ?? ""));
            if (node is JsonArray bare) return RunningNotes.Tidy(bare.Select(n => n?.GetValue<string>() ?? ""));
        }
        catch (JsonException) { /* prose; fall through */ }
        var lines = s.Split('\n').Select(l => l.Trim()).Where(l => l.StartsWith("- ") || l.StartsWith("* ") || l.StartsWith("• ") || (l.Length > 2 && char.IsDigit(l[0]) && (l[1] == '.' || l[1] == ')')));
        return RunningNotes.Tidy(lines);
    }

    private async Task<string> ChatAsync(string system, string user, JsonNode? schema, int maxTokens, CancellationToken ct)
    {
        var body = new JsonObject
        {
            ["model"] = Model,
            ["stream"] = false,
            ["keep_alive"] = "15m",
            ["options"] = new JsonObject { ["temperature"] = 0.1, ["num_predict"] = maxTokens },
            ["messages"] = new JsonArray(
                new JsonObject { ["role"] = "system", ["content"] = system },
                new JsonObject { ["role"] = "user", ["content"] = user }),
        };
        if (schema is not null) body["format"] = _schemaUnsupported ? "json" : schema.DeepClone();
        using var response = await _http.PostAsJsonAsync($"{Host}/api/chat", body, ct);
        if (!response.IsSuccessStatusCode)
        {
            var detail = await response.Content.ReadAsStringAsync(ct);
            // Ollama before 0.5 knows format: "json" but not a schema; say so once and retry plain.
            if (schema is not null && !_schemaUnsupported && (int)response.StatusCode == 400)
            {
                _schemaUnsupported = true;
                Log.Info($"ollama: this server does not take a JSON schema ({detail.Trim()}); using format json");
                return await ChatAsync(system, user, schema, maxTokens, ct);
            }
            throw new InvalidOperationException($"Ollama {(int)response.StatusCode}: {detail.Trim()}");
        }
        var json = await response.Content.ReadFromJsonAsync<JsonNode>(cancellationToken: ct);
        return json?["message"]?["content"]?.GetValue<string>() ?? "";
    }
}

/// The two keys the notetaker reads from settings.json, with the defaults above. The file is
/// shared with the tray app; unknown keys are left alone.
public static class NoteWriterSettings
{
    public static (string Host, string Model) Load(string? path = null)
    {
        try
        {
            var file = path ?? Paths.SettingsFile;
            if (!File.Exists(file)) return (OllamaClient.DefaultHost, OllamaClient.DefaultModel);
            var node = JsonNode.Parse(File.ReadAllText(file));
            var host = node?["ollamaHost"]?.GetValue<string>();
            var model = node?["notesModel"]?.GetValue<string>();
            return (string.IsNullOrWhiteSpace(host) ? OllamaClient.DefaultHost : host, string.IsNullOrWhiteSpace(model) ? OllamaClient.DefaultModel : model);
        }
        catch (Exception e)
        {
            Log.Info($"settings: could not read notetaker keys: {e.Message}");
            return (OllamaClient.DefaultHost, OllamaClient.DefaultModel);
        }
    }
}
