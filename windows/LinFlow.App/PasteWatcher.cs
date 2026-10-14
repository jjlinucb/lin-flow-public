using System.Diagnostics;
using LinFlow.Core;
using LinFlow.Engine;

namespace LinFlow.App;

/// Reads back the field Lin Flow just pasted into, so a fix typed by hand can become a dictionary
/// correction. The Mac's PasteWatcher.swift over UI Automation instead of Accessibility.
///
/// Until 2026-09-23 there was none. The learner and all of its guards were ported in the first
/// week, and nothing ever called them, because nothing read the text back after a paste: John
/// fixed words for nine days and not one correction was learned. What a reading means - found the
/// field, an edit that has settled, a newer dictation in the same box - is decided by Core's
/// ReadbackWatch, where the tests can reach it. This file finds the field, reads it and keeps
/// time.
///
/// Everything runs on one thread of its own, as the Mac's does on its own queue: one read of a
/// busy app can take the whole UI Automation timeout, and neither the hotkey nor the window may
/// wait on that. The learner's answer is the one thing handed back, through `onEdit`.
internal sealed class PasteWatcher
{
    public static PasteWatcher Shared { get; } = new();

    /// How the probe points the watcher at a field of its own. A field on a desktop nobody is
    /// looking at never has the real keyboard focus, so the focused element is not something a
    /// test can arrange; everything after finding the field is the same code either way. Set by
    /// reflection, as the window probe sets DictationRow.SetClipboard.
    internal static Func<FieldReader, FieldReader.Field?>? FindFieldForTest = null;

    private readonly object _gate = new();
    private readonly PriorityQueue<Action, (long Due, long Order)> _queue = new();
    private long _order;
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private Thread? _thread;

    // Touched only on the watcher's thread.
    private FieldReader? _reader;
    private bool _readerFailed;
    /// Every field still being watched, oldest first. More than one at a time on purpose: two
    /// dictations into the same box inside the window is John's normal rhythm, and canceling the
    /// first on the second key press threw away its chance to be corrected, on the Mac.
    private readonly List<Live> _live = new();
    /// Past this many at once the oldest is retired, so a burst cannot pile the queue up.
    private const int MaxLive = 3;
    /// The recent pastes, newest last. An older watch reads this to tell John editing its field
    /// from Lin Flow pasting into that same field again.
    private readonly List<Readback.Paste> _pastes = new();
    private int _pasteSeq;

    private sealed class Live
    {
        public Live(ReadbackWatch watch, string app, int timeoutsAtStart)
        {
            Watch = watch;
            App = app;
            TimeoutsAtStart = timeoutsAtStart;
        }

        public ReadbackWatch Watch { get; }
        public string App { get; }
        public int TimeoutsAtStart { get; }
        public FieldReader.Field? Field { get; set; }
    }

    /// Watches the field `app` (process `pid`) just took the paste in, and checks back for 15 s.
    /// `onEdit(wrote, now)` gets the phrase as pasted and as it stands afterwards, and says
    /// whether it made something of it. False leaves the field under watch for the rest of the
    /// window, so a later, better edit still gets its turn.
    public void Watch(string pasted, int pid, string app, Func<string, string, bool> onEdit)
    {
        var wrote = pasted.Trim();
        if (wrote.Length == 0) return;
        Post(0, () => Begin(wrote, pid, app, onEdit));
    }

    private void Begin(string wrote, int pid, string app, Func<string, string, bool> onEdit)
    {
        var reader = Reader();
        if (reader is null) return;
        // Chromium and Electron build their accessibility tree only once something asks for it,
        // and not at once: asked cold, Chrome answers with its window's bare pane. So ask now,
        // at the paste, and the tree is there by the first look - the Mac primes Chromium at the
        // same moment with its own switch. On 2026-09-23 focus-test in John's Chrome found only
        // the window pane the first time and the page itself when run again.
        Find(reader)?.Dispose();
        _pasteSeq++;
        var mine = _pasteSeq;
        _pastes.Add(new Readback.Paste(mine, wrote));
        while (_pastes.Count > 8) _pastes.RemoveAt(0);
        var live = new Live(new ReadbackWatch(wrote, mine), $"{app} (pid {pid})", reader.Timeouts);
        _live.Add(live);
        while (_live.Count > MaxLive) Retire(_live[0]);
        var delays = Readback.Delays();
        for (var i = 0; i < delays.Count; i++)
        {
            var delay = delays[i];
            var last = i == delays.Count - 1;
            Post(delay, () => Look(live, delay, last, onEdit));
        }
    }

    private void Look(Live live, double delay, bool last, Func<string, string, bool> onEdit)
    {
        var reader = _reader!;
        try
        {
            if (live.Watch.Done) return;
            var field = live.Field;
            var borrowed = field is null;
            field ??= Find(reader);
            if (field is null)
            {
                if (last) Log.Info($"readback: no focused element in {live.App}; nothing can be learned from an edit here");
                return;
            }
            try
            {
                var text = reader.Text(field);
                if (text is null) return;
                var step = live.Watch.Look(Readback.Normalize(text), last, _pastes, TimeSpan.FromSeconds(delay));
                if (step.Log is { } line) Log.Info(step.Action == ReadbackWatch.Action.Anchor ? $"{line} in {live.App}" : line);
                switch (step.Action)
                {
                    case ReadbackWatch.Action.Anchor:
                        live.Field = field;
                        borrowed = false;
                        break;
                    case ReadbackWatch.Action.Report:
                        // Only an edit that taught something ends the watch.
                        if (onEdit(live.Watch.Wrote, step.Edited!)) Retire(live);
                        break;
                    case ReadbackWatch.Action.StandDown:
                        Retire(live);
                        break;
                }
            }
            finally
            {
                if (borrowed) field.Dispose();
            }
        }
        catch (Exception e)
        {
            Log.Info($"readback: {e.Message}");
        }
        finally
        {
            if (last)
            {
                Retire(live);
                var slow = reader.Timeouts - live.TimeoutsAtStart;
                if (slow > 0) Log.Info($"readback: {slow} UI Automation read(s) got no answer within {FieldReader.TimeoutMs}ms");
            }
        }
    }

    /// The focused field, unless it is one of Lin Flow's own. A fix typed into its own window is
    /// not a correction of anything, and reading it would be this thread asking the window's
    /// thread about itself.
    private static FieldReader.Field? Find(FieldReader reader)
    {
        var field = FindFieldForTest is { } find ? find(reader) : reader.Focused();
        if (field is null || FindFieldForTest is not null) return field;
        if (reader.ProcessId(field) == Environment.ProcessId)
        {
            field.Dispose();
            return null;
        }
        return field;
    }

    /// Stop watching one field. Idempotent: the end of the window and a successful edit both
    /// call it, and either may come first.
    private void Retire(Live live)
    {
        live.Watch.Retire();
        live.Field?.Dispose();
        live.Field = null;
        _live.Remove(live);
    }

    private FieldReader? Reader()
    {
        if (_reader is not null || _readerFailed) return _reader;
        _reader = FieldReader.TryCreate(out var why);
        if (_reader is null)
        {
            // Once, not per dictation: nothing can be learned from an edit until a restart.
            _readerFailed = true;
            Log.Info($"readback: {why}; nothing can be learned from an edit");
        }
        return _reader;
    }

    // MARK: the thread

    /// Runs `work` on the watcher's thread `seconds` from now. Work due at the same moment runs
    /// in the order it was posted, which is what keeps a paste's looks in order.
    private void Post(double seconds, Action work)
    {
        lock (_gate)
        {
            var due = _clock.ElapsedTicks + (long)(seconds * Stopwatch.Frequency);
            _queue.Enqueue(work, (due, _order++));
            if (_thread is null)
            {
                // MTA, and a background thread so it never holds the app open at quit. The
                // default for a new thread, stated because UI Automation depends on it.
                _thread = new Thread(Run) { IsBackground = true, Name = "linflow-readback" };
                _thread.SetApartmentState(ApartmentState.MTA);
                _thread.Start();
            }
            Monitor.Pulse(_gate);
        }
    }

    private void Run()
    {
        while (true)
        {
            Action work;
            lock (_gate)
            {
                while (true)
                {
                    if (_queue.TryPeek(out _, out var key))
                    {
                        var wait = key.Due - _clock.ElapsedTicks;
                        if (wait <= 0) break;
                        Monitor.Wait(_gate, TimeSpan.FromSeconds((double)wait / Stopwatch.Frequency));
                    }
                    else
                    {
                        Monitor.Wait(_gate);
                    }
                }
                work = _queue.Dequeue();
            }
            try { work(); }
            catch (Exception e) { Log.Info($"readback: {e.Message}"); }
        }
    }
}
