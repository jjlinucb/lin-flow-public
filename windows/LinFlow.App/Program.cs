using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using LinFlow.Core;
using LinFlow.Engine;
using System.Runtime.InteropServices;

namespace LinFlow.App;

/// The tray app: hold the hotkey, talk, let go, and the cleaned text is pasted where the cursor
/// is. The same loop as DictationController.swift, minus the parts that need a local LLM.
internal static class Program
{
    private static NotifyIcon _tray = null!;
    private static Indicator? _pill;
    private static Dashboard? _window;
    private static Toast? _toast;
    /// A windowless control made on the UI thread, so work from other threads can be handed to
    /// that thread without depending on the pill or the window having been built.
    private static Control? _ui;
    // Rooted deliberately. A named EventWaitHandle that gets collected takes the listener thread
    // waiting on it with it, and the symptom is a shortcut that silently stops opening the window.
    private static EventWaitHandle? _showRequest;
    private static string _state = "starting";
    private static Hotkey? _hotkey;
    /// Held so the ten-minute dictionary sync is not collected.
    private static System.Threading.Timer? _dictionaryTimer;
    private static Recorder? _recorder;
    private static ParakeetEngine? _engine;
    private static TextCleaner _cleaner = new();
    private static string _modelId = "";
    private static DateTime _vocabStamp, _replacementsStamp;
    private static bool _pressed;                 // only ever touched on the hotkey worker thread

    /// The Mac's two test hooks, same names and the same meaning. LINFLOW_TEST_AUDIO makes a WAV
    /// stand in for the microphone, so the whole hotkey -> engine -> cleanup path can run with
    /// nobody talking, and LINFLOW_NO_PASTE logs the text instead of pasting it, so a test can
    /// never type into whatever window happens to have focus. Without these the only way to
    /// exercise the press-record-paste path was a live microphone pasting into a live window.
    /// Never leave an instance running with either set: on the Mac, 2026-09-09, John dictated
    /// into one and nothing pasted.
    private static readonly string? TestAudio = Environment.GetEnvironmentVariable("LINFLOW_TEST_AUDIO");
    private static readonly bool NoPaste = Environment.GetEnvironmentVariable("LINFLOW_NO_PASTE") is not null;
    private static readonly object _engineGate = new();
    private static volatile bool _busy;

    [STAThread]
    private static void Main()
    {
        // One instance. Two keyboard hooks racing for the same key is a bad time.
        using var single = new Mutex(true, "LinFlow.SingleInstance", out var isFirst);
        if (!isFirst)
        {
            // "Look in the system tray" is useless advice on Windows 11, which files a new tray
            // icon behind the overflow chevron: on 2026-09-18 John could not find it at all, so
            // the window he asked for had no way in. Running the exe again - from the desktop
            // shortcut, the Start menu, or a taskbar pin - is the gesture every other app answers
            // by showing itself, so answer it the same way.
            if (SignalRunningInstance()) return;
            MessageBox.Show("Lin Flow is already running - look in the system tray.",
                            "Lin Flow", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        ApplicationConfiguration.Initialize();
        Application.ThreadException += (_, e) => Fatal(e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Fatal(e.ExceptionObject as Exception);

        Paths.EnsureDataDir();
        Log.Info("Lin Flow starting");
        if (TestAudio is not null) Log.Info($"LINFLOW_TEST_AUDIO set: microphone disabled, using {TestAudio}");
        if (NoPaste) Log.Info("LINFLOW_NO_PASTE set: text will be logged, not pasted");

        _tray = new NotifyIcon
        {
            Icon = MakeIcon(Color.FromArgb(120, 120, 128)),
            Text = "Lin Flow - starting",
            Visible = true,
            ContextMenuStrip = BuildMenu(),
        };

        _ui = new Control();
        _ = _ui.Handle;
        // What an edit taught, said on screen. Raised on whichever thread learned it.
        CorrectionLearning.DidLearn += outcome => OnUiLater(() => Announce(outcome));
        CorrectionLearning.DidDecline += (from, to) => OnUiLater(() => Offer(from, to));

        try
        {
            _pill = new Indicator();
            // Force the handle now, on the UI thread, so BeginInvoke works from the hook thread.
            _ = _pill.Handle;
        }
        catch (Exception e)
        {
            Log.Info($"indicator unavailable: {e.Message}");
        }

        // A separate try, deliberately. The pill and the window shared one until 2026-09-18, and
        // when a splitter in the new notetaker tab threw during the window's constructor the app
        // came up with no window, no double-click to open it and no listener for a second launch:
        // three ways in lost to one bug in a fourth. The full exception is logged, not just its
        // message, because the message alone did not say which control it came from.
        try
        {
            _window = new Dashboard();
            _ = _window.Handle;
            _tray.DoubleClick += (_, _) => ShowWindow();
            ListenForShowRequests();
        }
        catch (Exception e)
        {
            Log.Info($"the window could not be built: {e}");
        }

        try
        {
            _hotkey = new Hotkey(HotkeySettings.Load());
            _hotkey.Pressed += OnPressed;
            _hotkey.Released += OnReleased;
        }
        catch (Exception e)
        {
            Log.Info($"hotkey failed: {e.Message}");
            Notify("Hotkey unavailable", e.Message);
        }

        // Shared word totals (SharedTotals.cs), a no-op until sync.env exists. Each saved dictation
        // sends its own day, and the first push after a start sends every day, which is how a
        // computer set up today backfills. Not from a test instance: a test run must leave no trace.
        if (TestAudio is null && !NoPaste)
        {
            History.DidChange += TotalsSync.Shared.RequestPush;
            TotalsSync.Shared.RequestPush();
            // The shared dictionary (DictionarySync.cs), also a no-op until sync.env exists: at
            // start, after each dictation, after each change to vocab.txt or replacements.txt the
            // app makes itself, and every ten minutes for hand edits and other computers.
            History.DidChange += DictionarySync.Shared.Request;
            Glossary.DidChange += DictionarySync.Shared.Request;
            _dictionaryTimer = new System.Threading.Timer(_ => DictionarySync.Shared.Request(), null,
                DictionarySync.Interval, DictionarySync.Interval);
            DictionarySync.Shared.Request();
        }

        // Load the model off the UI thread so the tray icon appears at once.
        Task.Run(LoadEngine);

        Application.Run();
        Cleanup();
    }

    private static ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open Lin Flow", null, (_, _) => ShowWindow());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Open the data folder", null, (_, _) =>
            System.Diagnostics.Process.Start("explorer.exe", Paths.DataDir));
        menu.Items.Add("Open the log", null, (_, _) =>
        {
            if (File.Exists(Paths.LogFile))
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Paths.LogFile) { UseShellExecute = true });
        });
        menu.Items.Add("Edit the dictionary", null, (_, _) =>
        {
            Glossary.SeedIfMissing();
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Paths.ReplacementsFile) { UseShellExecute = true });
        });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Start a meeting note (console)", null, (_, _) =>
        {
            // The notetaker is the CLI's `meeting` command for now, since there is no window here
            // yet. It records the microphone and what the PC plays, prints lines as people speak,
            // and rebuilds the transcript from the saved audio when Enter is pressed.
            var cli = Path.Combine(AppContext.BaseDirectory, "linflow-cli.exe");
            if (!File.Exists(cli)) { Notify("Meeting notes", "linflow-cli.exe is not next to LinFlow.exe."); return; }
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(cli, "meeting") { UseShellExecute = true });
        });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => Application.Exit());
        return menu;
    }

    private static void LoadEngine()
    {
        try
        {
            var model = ModelCatalog.FirstUsable();
            if (model is null)
            {
                SetState("no model", Color.FromArgb(230, 150, 40));
                Notify("No model yet",
                       $"Run:  linflow download {ModelCatalog.DefaultModelId}\nThen restart Lin Flow.");
                return;
            }

            var check = ParakeetEngine.SelfCheck();
            Log.Info(check);
            if (check.StartsWith("NATIVE STRUCT"))
            {
                SetState("native mismatch", Color.FromArgb(220, 60, 60));
                Notify("Native layer mismatch", "Run 'linflow doctor' in a terminal for the details.");
                return;
            }

            lock (_engineGate) _engine = new ParakeetEngine(ModelCatalog.PathFor(model));
            _modelId = model.Id;
            Glossary.SeedIfMissing();
            _cleaner = LoadCleaner();
            // Cleanup checks words against a 235,000-word list that loads on first use, and
            // first use was the first dictation after every start. Load it with the model.
            var words = System.Diagnostics.Stopwatch.StartNew();
            GlossaryMatcher.IsDictionaryWord("ready");
            Log.Info($"word list loaded in {words.Elapsed.TotalSeconds:F2}s");
            SetState("ready", Color.FromArgb(76, 199, 107));
            // install-latest.ps1 waits for this exact line to time a restart.
            Log.Info("ready");
        }
        catch (Exception e)
        {
            Log.Info($"engine load failed: {e}");
            SetState("engine failed", Color.FromArgb(220, 60, 60));
            Notify("Could not start the engine", e.Message + "\nRun 'linflow doctor' for details.");
        }
    }

    private static void OnPressed()
    {
        if (_busy) return;
        ParakeetEngine? engine;
        lock (_engineGate) engine = _engine;
        if (engine is null) return;
        _pressed = true;

        // First, so the model comes back into memory while the microphone opens and he talks,
        // not after he lets go. See WarmInBackground.
        engine.WarmInBackground();

        if (TestAudio is null)
        {
            try
            {
                _recorder = new Recorder();
                _recorder.Start(Hotkey.PressedAt);
            }
            catch (Exception e)
            {
                var noMic = e is Recorder.NoInputDeviceException;
                Log.Info(noMic
                    ? "could not start recording: no microphone found. Plug one in, or set a default recording device in Sound settings."
                    : $"could not start recording: {e.Message}");
                SetState(noMic ? "no microphone" : "mic failed", Color.FromArgb(220, 60, 60));
                Notify(noMic ? "No microphone" : "Could not start recording",
                       noMic ? "Plug in a microphone, or pick a default recording device in Sound settings."
                             : e.Message);
                _recorder?.Dispose();
                _recorder = null;
                // Leave that on the tray. The release used to paint "ready" straight over it, so
                // a machine with no working microphone looked perfectly healthy.
                _pressed = false;
                return;
            }
        }
        SetState("recording", Color.FromArgb(230, 60, 60));
    }

    private static void OnReleased()
    {
        // Pairs with OnPressed. A release with no press of ours - the hook saw a key-up for a
        // key that went down before the app started, or the press bailed out - is not a clip.
        if (!_pressed) return;
        _pressed = false;

        // From the moment the key comes up to the moment the text lands. John called it "a little
        // slow" on 2026-09-18 and there was no number to hold that against: the existing line
        // times the model, which is only part of the wait.
        var sinceRelease = System.Diagnostics.Stopwatch.StartNew();

        var rec = _recorder;
        _recorder = null;
        var samples = rec?.Stop() ?? Array.Empty<float>();
        var recorderSeconds = sinceRelease.Elapsed.TotalSeconds;
        rec?.Dispose();

        if (TestAudio is not null)
        {
            try { samples = AudioIO.ReadWav(TestAudio); }
            catch (Exception e) { Log.Info($"LINFLOW_TEST_AUDIO could not be read: {e.Message}"); }
        }

        // How this take started. Only for a real recording: with LINFLOW_TEST_AUDIO the samples
        // came off disk and there is no microphone in the story.
        var take = TestAudio is null ? rec?.LastTake : null;
        if (take is not null) Log.Info(take.Describe());

        // A dead input sends digital zeros, and that is not the same as nobody talking. Without
        // this it falls into the drop below and reads as "you were too quiet" - which is how the
        // Mac lost eight takes in a row on 09-15 to an input that had stopped working.
        // Not under LINFLOW_TEST_AUDIO: the samples came off disk, no microphone was opened, and
        // a message naming one would be a lie. A silent test clip is a fine thing to feed it.
        if (TestAudio is null && Microphone.IsDead(samples, AudioIO.SampleRate))
        {
            var seconds = samples.Length / (double)AudioIO.SampleRate;
            var device = take?.Device ?? "the default input";
            Log.Info($"dead microphone: {seconds:F1}s of pure digital silence from {device}");
            SetState("mic sent nothing", Color.FromArgb(220, 60, 60));
            Notify("The microphone sent nothing",
                   $"{device} produced {seconds:F1}s of pure silence. Check it in Sound settings, " +
                   "or unplug and replug it. A new device is opened for every dictation, so the next one may work.");
            return;
        }

        // Too short to be speech: a stray tap of the key, not a dictation.
        if (samples.Length < AudioIO.SampleRate * 0.3 || AudioIO.Peak(samples) < 0.01f)
        {
            Log.Info($"dropped clip ({samples.Length / (double)AudioIO.SampleRate:F2}s, peak {AudioIO.Peak(samples):F3})");
            SetState("ready", Color.FromArgb(76, 199, 107));
            return;
        }

        _busy = true;
        SetState("transcribing", Color.FromArgb(240, 180, 50));
        try
        {
            ParakeetEngine engine;
            lock (_engineGate)
            {
                if (_engine is null) return;
                engine = _engine;
            }

            var transcribing = System.Diagnostics.Stopwatch.StartNew();
            var result = engine.Transcribe(samples);
            // Whatever Transcribe spent outside the model itself: a warm-up still running, or
            // the notetaker's live pass, holding the engine.
            var waitedSeconds = Math.Max(0, transcribing.Elapsed.TotalSeconds - result.InferenceSeconds);
            ReloadCleanerIfEdited();
            var cleaned = _cleaner.Clean(result.Text);
            Log.Info($"{result.AudioSeconds:F1}s audio -> {result.InferenceSeconds:F2}s Parakeet | " +
                     $"raw: {result.Text} | out: {cleaned}");
            if (string.IsNullOrWhiteSpace(cleaned))
            {
                // Silence here is indistinguishable from a broken hotkey. Measured 2026-09-20
                // (NOISE.md): in heavy babble - a cafe, a loud room - Parakeet returns an empty
                // transcript rather than a degraded one, and the whole response used to be this
                // bare return. John holds the key, speaks, and nothing happens.
                //
                // The Mac retries such a take on a second engine. This side cannot yet: only
                // Parakeet is wired up, and a second Parakeet fails on the same audio the same
                // way. whisper.dll is already in native/Release and is simply not shipped -
                // see NOTES.md. Until it is, say so rather than say nothing.
                if (string.IsNullOrWhiteSpace(result.Text))
                {
                    Log.Info("the engine heard no words in a clip that had speech in it");
                    Notify("Lin Flow heard nothing",
                           "Nothing was recognized in that recording. If you are somewhere loud, "
                         + "moving the microphone closer helps more than anything else.");
                }
                return;
            }

            // Same rule as the Mac: a trailing space so the next dictation does not run into this
            // one, but never after a newline the speaker actually asked for.
            var toPaste = cleaned.EndsWith('\n') ? cleaned : cleaned + " ";
            if (NoPaste) Log.Info($"LINFLOW_NO_PASTE set; not pasting: {toPaste}");
            else
            {
                Paste.Send(toPaste);
                WatchForEdit(cleaned);
            }
            // Split, so the next "it feels slow" can be read straight off the log. On 09-23 the
            // recorder was 0.3 s of every wait, and nothing said so.
            var landed = sinceRelease.Elapsed.TotalSeconds;
            var rest = Math.Max(0, landed - recorderSeconds - waitedSeconds - result.InferenceSeconds);
            Log.Info($"text landed {landed:F2}s after the key came up (recorder {recorderSeconds:F2}s, " +
                     $"waiting for the model {waitedSeconds:F2}s, model {result.InferenceSeconds:F2}s, rest {rest:F2}s)");

            History.Append(new HistoryEntry
            {
                Raw = result.Text,
                Text = cleaned,
                Model = _modelId,
                AudioSeconds = result.AudioSeconds,
                InferenceSeconds = result.InferenceSeconds,
                InputDevice = take?.Device,
                FirstAudioSeconds = take?.FirstAudioSeconds,
            });
            SaveLastRecording(samples);
        }
        catch (Exception e)
        {
            Log.Info($"dictation failed: {e}");
            Notify("Dictation failed", e.Message);
        }
        finally
        {
            _busy = false;
            SetState("ready", Color.FromArgb(76, 199, 107));
        }
    }

    /// The clip behind the last dictation, so a transcript that came out wrong can be replayed
    /// with `linflow-cli transcribe`. One file, overwritten each time, same name as the Mac's.
    private static void SaveLastRecording(float[] samples)
    {
        try { AudioIO.WriteWav(Path.Combine(Paths.DataDir, "last-recording.wav"), samples); }
        catch (Exception e) { Log.Info($"could not save last-recording.wav: {e.Message}"); }
    }

    // MARK: learning from edits

    /// Watches the field the dictation just went into: a fix typed by hand becomes a dictionary
    /// correction, as on the Mac. The previous dictation's watch deliberately keeps running: two
    /// dictations into the same box inside 15 s is normal, and canceling it meant a fix to the
    /// first one could never be learned.
    private static void WatchForEdit(string pasted)
    {
        var mode = LearnSettings.Load();
        if (mode == LearnMode.Off) return;
        var (pid, app) = FieldReader.ForegroundApp();
        // Nothing to read, or Lin Flow's own window, which is not a correction of anything.
        if (pid == 0 || pid == Environment.ProcessId) return;
        PasteWatcher.Shared.Watch(pasted, pid, app, (wrote, now) =>
            // Run where the window runs. The learner reads and rewrites replacements.txt and
            // pending-corrections.json, and so does the Dictionary when John adds or removes a
            // rule; one thread for both means neither can write over the other's change. The Mac
            // hands this to its main thread for the same reason. False keeps the field under
            // watch: an edit that taught nothing is very often a word still being typed, and the
            // real fix lands a moment later.
            OnUi(() => !CorrectionLearning.Handle(wrote, now, mode).IsEmpty));
    }

    /// Says on screen what an edit just taught Lin Flow. The window is usually shut and the
    /// dictation went into some other app, so this is the only place the rule is ever seen.
    private static void Announce(CorrectionLearning.Outcome outcome)
    {
        if (LearnToast.Lines(outcome) is not { } lines) return;
        ShowToast(lines.Title, lines.Detail, onClick: () => ShowWindow(Dashboard.DictionarySection));
    }

    /// An edit Lin Flow saw and would not learn on its own. Offering it is the point: a misheard
    /// name is phonetically far from what was said by definition, so the filters can never accept
    /// one. Clicking adds it.
    private static void Offer(string from, string to)
    {
        var lines = LearnToast.Declined(from, to);
        // Longer than a plain notice: this one asks for a decision.
        ShowToast(lines.Title, lines.Detail, seconds: 12, onClick: () =>
        {
            CorrectionLearning.Accept(new Replacement(from, to, learned: true));
            Log.Info($"added by hand from the toast: {from} => {to}");
            var added = LearnToast.Added(from, to);
            ShowToast(added.Title, added.Detail, onClick: () => ShowWindow(Dashboard.DictionarySection));
        });
    }

    /// UI thread only, which is where every caller already is.
    private static void ShowToast(string title, string detail, int seconds = 6, bool warning = false, Action? onClick = null)
    {
        try { (_toast ??= new Toast()).Show(title, detail, seconds, warning, onClick); }
        catch (Exception e) { Log.Info($"toast failed: {e.Message}"); }
    }

    /// Runs `work` on the UI thread and waits for its answer.
    private static T OnUi<T>(Func<T> work)
    {
        var ui = _ui;
        if (ui is null || ui.IsDisposed || !ui.IsHandleCreated || !ui.InvokeRequired) return work();
        return ui.Invoke(work);
    }

    /// Hands `work` to the UI thread without waiting for it.
    private static void OnUiLater(Action work)
    {
        var ui = _ui;
        try
        {
            if (ui is null || ui.IsDisposed || !ui.IsHandleCreated) return;
            if (ui.InvokeRequired) ui.BeginInvoke(work);
            else work();
        }
        catch (Exception e)
        {
            Log.Info($"could not reach the UI thread: {e.Message}");
        }
    }

    // MARK: dictionary

    /// vocab.txt and replacements.txt are read once into the cleaner, so an edit made through
    /// "Edit the dictionary" did nothing until the next restart - which makes the dictionary look
    /// broken while it is working. Re-read when either file's timestamp moves, checked once per
    /// dictation, which costs nothing next to the transcription that just ran.
    private static TextCleaner LoadCleaner()
    {
        _vocabStamp = Stamp(Paths.VocabFile);
        _replacementsStamp = Stamp(Paths.ReplacementsFile);
        var terms = Glossary.Load();
        var corrections = Glossary.LoadReplacements();
        Log.Info($"dictionary loaded: {terms.Count} terms, {corrections.Count} corrections");
        return new TextCleaner(terms, corrections);
    }

    private static void ReloadCleanerIfEdited()
    {
        if (Stamp(Paths.VocabFile) == _vocabStamp && Stamp(Paths.ReplacementsFile) == _replacementsStamp) return;
        try { _cleaner = LoadCleaner(); }
        catch (Exception e) { Log.Info($"dictionary reload failed, keeping the previous one: {e.Message}"); }
    }

    private static DateTime Stamp(string path) =>
        File.Exists(path) ? File.GetLastWriteTimeUtc(path) : DateTime.MinValue;

    // MARK: tray plumbing

    private static void SetState(string label, Color color)
    {
        _state = label;
        try
        {
            var previous = _tray.Icon;
            _tray.Icon = MakeIcon(color);
            previous?.Dispose();
            // NotifyIcon.Text throws above 63 characters.
            var t = $"Lin Flow - {label}";
            _tray.Text = t.Length > 62 ? t[..62] : t;
        }
        catch (Exception e)
        {
            Log.Info($"tray update failed: {e.Message}");
        }
        ShowPill(label, color);
    }

    /// The tray dot is not something a person can see: Windows 11 files a new tray icon away in
    /// the overflow flyout, so it is behind a chevron. The pill is the visible half of SetState,
    /// and it only appears for the two states worth interrupting the screen for.
    ///
    /// SetState is called from the hook's worker thread as well as the UI thread, and a Form may
    /// only be touched on the thread that created it, so everything marshals through _pill.
    private static void ShowPill(string label, Color color)
    {
        var pill = _pill;
        if (pill is null || pill.IsDisposed || !pill.IsHandleCreated) return;
        var visible = label is "recording" or "transcribing";
        var text = label switch
        {
            "recording" => "Listening...",
            "transcribing" => "Transcribing...",
            _ => label,
        };
        try
        {
            pill.BeginInvoke(() =>
            {
                if (visible) pill.Show(text, color);
                else pill.HidePill();
            });
        }
        catch (Exception e)
        {
            Log.Info($"indicator update failed: {e.Message}");
        }
    }

    /// Brings the window up, refreshed. Created once at startup and hidden rather than disposed,
    /// so opening it is instant and its lists survive being closed.
    private const string ShowRequestEvent = @"Local\LinFlow.ShowWindow";

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    /// Windows only lets the process the user just interacted with raise a window. The second
    /// instance is that process for the moment it lives, so it hands the right over before it
    /// signals and exits; without this the window would appear behind whatever is in front.
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AllowSetForegroundWindow(int dwProcessId);

    /// Waits for a later launch of the exe to ask for the window. A thread rather than a timer:
    /// it blocks, costs nothing while it waits, and dies with the process.
    private static void ListenForShowRequests()
    {
        try
        {
            // Local\ scopes the name to this login session, so two signed-in users each get their
            // own Lin Flow rather than one stealing the other's window.
            _showRequest = new EventWaitHandle(false, EventResetMode.AutoReset, ShowRequestEvent);
        }
        catch (Exception e)
        {
            Log.Info($"could not listen for open requests: {e.Message}");
            return;
        }

        var signal = _showRequest;
        new Thread(() =>
        {
            while (true)
            {
                signal.WaitOne();
                var w = _window;
                if (w is null || w.IsDisposed) continue;
                // The wait is on this thread; the window belongs to the UI thread.
                try { w.BeginInvoke(ShowWindow); }
                catch (Exception e) { Log.Info($"could not open the window on request: {e.Message}"); }
            }
        })
        { IsBackground = true, Name = "linflow-open" }.Start();
    }

    /// True if an instance was found and asked to show itself.
    private static bool SignalRunningInstance()
    {
        try
        {
            if (!EventWaitHandle.TryOpenExisting(ShowRequestEvent, out var signal)) return false;
            using (signal)
            {
                var me = System.Diagnostics.Process.GetCurrentProcess();
                foreach (var other in System.Diagnostics.Process.GetProcessesByName(me.ProcessName))
                {
                    using (other)
                        if (other.Id != me.Id) AllowSetForegroundWindow(other.Id);
                }
                signal.Set();
            }
            return true;
        }
        catch (Exception e)
        {
            Log.Info($"could not reach the running instance: {e.Message}");
            return false;
        }
    }

    /// The one loaded model, shared with the notetaker. ParakeetEngine.Transcribe takes its own
    /// lock, so a dictation and a meeting can both call it; they queue rather than collide, and a
    /// second copy of a 600 MB model to avoid a wait nobody would notice is not worth the RAM.
    internal static ParakeetEngine? SharedEngine()
    {
        lock (_engineGate) return _engine;
    }

    internal static void ShowWindow() => ShowWindow(null);

    /// Brings the window up at one section, as a click on a learning toast does.
    internal static void ShowWindow(int? section)
    {
        var w = _window;
        if (w is null || w.IsDisposed) return;
        try
        {
            if (section is { } s) w.ShowSection(s);
            w.Refresh(_state);
            if (!w.Visible) w.Show();
            if (w.WindowState == FormWindowState.Minimized) w.WindowState = FormWindowState.Normal;
            w.BringToFront();
            w.Activate();
            SetForegroundWindow(w.Handle);
        }
        catch (Exception e)
        {
            Log.Info($"could not open the window: {e.Message}");
        }
    }

    /// Takes the talk key off while Settings records a new one, so the keys pressed to be recorded
    /// do not start a dictation. RebindHotkey puts it back, as saved.
    internal static void PauseHotkey()
    {
        _hotkey?.Dispose();
        _hotkey = null;
    }

    /// Re-reads settings.json and installs the hook again, so a hotkey changed in the window
    /// takes effect without a restart. The old hook is disposed first: two live hooks would both
    /// fire and every dictation would run twice.
    internal static void RebindHotkey()
    {
        try
        {
            _hotkey?.Dispose();
            _hotkey = new Hotkey(HotkeySettings.Load());
            _hotkey.Pressed += OnPressed;
            _hotkey.Released += OnReleased;
        }
        catch (Exception e)
        {
            Log.Info($"could not rebind the hotkey: {e.Message}");
            Notify("Hotkey unavailable", e.Message);
        }
    }

    /// The tray dot, reused as the window's icon so the taskbar button is recognizable.
    private static Icon? _logo;

    /// The Mac app's mark, built into the assembly from assets/AppIcon-1024.png so there is no
    /// file to go missing beside the exe.
    private static Icon Logo() =>
        _logo ??= new Icon(typeof(Program).Assembly.GetManifestResourceStream("LinFlow.App.lin-flow.ico")
                           ?? throw new InvalidOperationException("the icon is not in the assembly"));

    internal static Icon WindowIcon() => Logo();

    /// The tray icon: the logo, with the state dot in its corner.
    ///
    /// It was the bare dot until 2026-09-18, which made Lin Flow unfindable among thirty tray
    /// icons - a gray circle is what a tray icon looks like when it has not loaded. The dot stays
    /// because the tray is still where the app says what it is doing, and it is drawn on a dark
    /// disc so a green dot is legible against the logo's pale letter.
    private static Icon MakeIcon(Color color)
    {
        const int size = 32, dot = 15;
        using var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.Clear(Color.Transparent);
            using (var mark = new Icon(Logo(), size, size))
                g.DrawIcon(mark, new Rectangle(0, 0, size, size));
            using (var ring = new SolidBrush(Color.FromArgb(28, 24, 34)))
                g.FillEllipse(ring, size - dot, size - dot, dot, dot);
            using var brush = new SolidBrush(color);
            g.FillEllipse(brush, size - dot + 2, size - dot + 2, dot - 4, dot - 4);
        }
        // GetHicon returns a handle that Icon.FromHandle does NOT own, so Dispose() never freed
        // it: one HICON and its two bitmaps leaked per tray state change, three changes per
        // dictation, against a per-process ceiling of 10,000 GDI objects. Measured on this
        // machine: 300 cycles leaked 909 GDI and 306 USER objects, and none with the version
        // below. Clone into an Icon that owns its handle, then destroy the original.
        var handle = bmp.GetHicon();
        try
        {
            using var borrowed = Icon.FromHandle(handle);
            return (Icon)borrowed.Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr hIcon);

    private static void Notify(string title, string body)
    {
        try
        {
            _tray.BalloonTipTitle = title;
            _tray.BalloonTipText = body;
            _tray.ShowBalloonTip(8000);
        }
        catch { /* a failed notification must not take the app down */ }
    }

    private static void Fatal(Exception? e)
    {
        Log.Info($"unhandled: {e}");
        try { Notify("Lin Flow hit an error", e?.Message ?? "unknown"); } catch { }
    }

    private static void Cleanup()
    {
        _hotkey?.Dispose();
        _recorder?.Dispose();
        lock (_engineGate) { _engine?.Dispose(); _engine = null; }
        if (_tray is not null) { _tray.Visible = false; _tray.Dispose(); }
        Log.Info("quitting");
    }
}
