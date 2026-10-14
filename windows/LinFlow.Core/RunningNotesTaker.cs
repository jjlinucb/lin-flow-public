namespace LinFlow.Core;

/// The timer around RunningNotes: every ten seconds it looks at what the live transcript has
/// gained, and once a minute's worth of new speech is there it runs one pass through the note
/// writer and appends the result to running-notes.md. `StopAsync` drains what is left after the
/// meeting ends. The Mac's DashboardModel does the same job; this one is shared by the console
/// command and, later, a window.
public sealed class RunningNotesTaker : IDisposable
{
    /// A block of Markdown was appended to running-notes.md (worker thread).
    public event Action<string>? NotesAdded;
    /// A pass failed; the stretch stays unnoted and the next pass picks it up.
    public event Action<string>? Failed;

    public int Passes { get; private set; }

    private readonly NotesStore _store;
    private readonly string _noteId;
    private readonly INoteWriter _writer;
    private readonly string _title;
    private readonly Func<DateTime> _clock;
    private readonly HashSet<string> _noted = new();
    private readonly SemaphoreSlim _busy = new(1, 1);
    private Timer? _timer;
    private DateTime _lastPassAt;
    private bool _stopped;

    public RunningNotesTaker(NotesStore store, string noteId, INoteWriter writer, string title, Func<DateTime>? clock = null)
    {
        _store = store;
        _noteId = noteId;
        _writer = writer;
        _title = title;
        _clock = clock ?? (() => DateTime.UtcNow);
    }

    /// Anything already in the transcript (a note recorded a second time) counts as noted.
    public void Start()
    {
        foreach (var s in _store.Transcript(_noteId)) _noted.Add(s.Id);
        _lastPassAt = _clock();
        _timer = new Timer(_ => _ = TickAsync(), null, 10_000, 10_000);
    }

    /// Runs a pass if one is due. Safe to call from anywhere; overlapping calls are dropped.
    public async Task TickAsync()
    {
        if (_stopped || !await _busy.WaitAsync(0)) return;
        try
        {
            var fresh = RunningNotes.Window(_store.Transcript(_noteId), _noted);
            var since = (_clock() - _lastPassAt).TotalSeconds;
            if (RunningNotes.IsDue(RunningNotes.WordCount(fresh), since, final: false)) await PassAsync(fresh);
        }
        finally { _busy.Release(); }
    }

    /// Stops the timer and drains the backlog, in as many passes as it takes (at most six).
    public async Task StopAsync()
    {
        _stopped = true;
        _timer?.Dispose(); _timer = null;
        await _busy.WaitAsync();
        try
        {
            for (var i = 0; i < 6; i++)
            {
                var fresh = RunningNotes.Window(_store.Transcript(_noteId), _noted);
                if (!RunningNotes.IsDue(RunningNotes.WordCount(fresh), 0, final: true)) break;
                if (!await PassAsync(fresh)) break;
            }
        }
        finally { _busy.Release(); }
    }

    private async Task<bool> PassAsync(List<TranscriptSegment> fresh)
    {
        if (fresh.Count == 0) return false;
        var previous = RunningNotes.Recent(_store.RunningNotes(_noteId));
        var words = RunningNotes.WordCount(fresh);
        var t0 = _clock();
        try
        {
            var bullets = await _writer.RunningNotesAsync(previous, NotesStore.TranscriptText(fresh), _title);
            foreach (var s in fresh) _noted.Add(s.Id);
            _lastPassAt = _clock();
            Passes++;
            var block = RunningNotes.Format(bullets, fresh[0].Start);
            if (block.Length > 0)
            {
                _store.AppendRunningNotes(block, _noteId);
                NotesAdded?.Invoke(block);
            }
            Log.Info($"running notes: {words} words in, {bullets.Count} bullet(s) out, {(_clock() - t0).TotalSeconds:F1} s");
            return true;
        }
        catch (Exception e)
        {
            _lastPassAt = _clock();
            Log.Info($"running notes: {e.Message}");
            Failed?.Invoke(e.Message);
            return false;
        }
    }

    public void Dispose()
    {
        _stopped = true;
        _timer?.Dispose();
    }
}
