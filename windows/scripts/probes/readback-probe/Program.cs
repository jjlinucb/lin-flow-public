// readback-probe: the readback that learns corrections from edits, run for real against real
// Windows text fields, where nobody can see it and nothing of John's is touched.
//
// It builds a window of its own with four fields - a single-line edit box, a multi-line one, a
// rich edit box and a password box - "pastes" a dictation into one, starts Lin Flow's own
// PasteWatcher on it, then makes the fix John would make and checks what the learner did. Then it
// shows the learning toast and the Dictionary's Suggested rows and clicks them.
//
// The promises are window-probe's, and one more:
//
//   - Its own desktop, and the whole process on it. Windows only lets threads on the same desktop
//     exchange window messages, and UI Automation reads a field with them, so the watcher's own
//     thread has to be on the desktop the fields are on. SetThreadDesktop moves one thread; a
//     process started with STARTUPINFO.lpDesktop has every thread there. So this starts a copy of
//     itself on a desktop it creates, waits for it, and prints what it wrote.
//   - Its own data folder. It refuses to run unless LINFLOW_DATA_DIR names a folder with
//     "probe-data" in it, and it empties that folder's corrections, suggestions and settings
//     before it starts. The rules it learns are learned there.
//   - Never John's clipboard, and never a keystroke: the "paste" sets the field's text directly.
//
// Run from windows/ after a Release build of LinFlow.sln (NOTES.md says where dotnet is):
//
//   $env:LINFLOW_DATA_DIR = "$env:TEMP\probe-data"
//   New-Item -ItemType Directory -Force $env:LINFLOW_DATA_DIR
//   dotnet run --project scripts\probes\readback-probe -c Release -- "$env:TEMP\probe-shots"
//
// It prints ok or FAIL for each check, saves screenshots of the toast and the Dictionary, and
// exits 0 only if every check passed. It takes about 40 s, most of it waiting out a watch window.
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing.Imaging;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using LinFlow.Core;
using LinFlow.Engine;

internal static class ReadbackProbe
{
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr devmode, int flags, uint access, IntPtr sa);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string? lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcess(string? application, StringBuilder commandLine, IntPtr processAttributes,
        IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string? directory,
        ref STARTUPINFO startup, out PROCESS_INFORMATION info);
    [DllImport("kernel32.dll")] private static extern uint WaitForSingleObject(IntPtr handle, uint ms);
    [DllImport("kernel32.dll")] private static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll")] private static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);

    private const uint GENERIC_ALL = 0x10000000, CREATE_NO_WINDOW = 0x08000000;
    private const int WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202, MK_LBUTTON = 1;
    private const BindingFlags Any = BindingFlags.Instance | BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;

    private static readonly List<string> Failures = new();

    [STAThread]
    private static int Main(string[] args)
    {
        if (!Paths.DataDir.Contains("probe-data", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine($"LINFLOW_DATA_DIR is {Paths.DataDir}, not a probe-data folder; stopping");
            return 2;
        }
        return args.Length >= 3 && args[0] == "--child" ? Child(args[1], args[2]) : Parent(args);
    }

    // ---------- the parent: a desktop, a copy of itself on it, and its report

    private static int Parent(string[] args)
    {
        var shots = args.Length > 0 ? args[0] : Path.Combine(Path.GetTempPath(), "probe-shots");
        Directory.CreateDirectory(shots);
        var report = Path.Combine(shots, "readback-probe.txt");
        File.Delete(report);

        var name = $"linflow-readback-{Environment.ProcessId}";
        var desktop = CreateDesktop(name, IntPtr.Zero, IntPtr.Zero, 0, GENERIC_ALL, IntPtr.Zero);
        if (desktop == IntPtr.Zero)
        {
            Console.WriteLine($"could not create a desktop ({Marshal.GetLastWin32Error()}); stopping rather than draw on John's");
            return 2;
        }
        try
        {
            var self = Environment.ProcessPath!;
            var command = Path.GetFileName(self).Equals("dotnet.exe", StringComparison.OrdinalIgnoreCase)
                ? $"\"{self}\" \"{typeof(ReadbackProbe).Assembly.Location}\""
                : $"\"{self}\"";
            var line = new StringBuilder($"{command} --child \"{shots}\" \"{report}\"");
            var startup = new STARTUPINFO { cb = Marshal.SizeOf<STARTUPINFO>(), lpDesktop = $"WinSta0\\{name}" };
            if (!CreateProcess(null, line, IntPtr.Zero, IntPtr.Zero, false, CREATE_NO_WINDOW, IntPtr.Zero, null, ref startup, out var child))
            {
                Console.WriteLine($"could not start the probe on its desktop ({Marshal.GetLastWin32Error()})");
                return 2;
            }
            uint code;
            try
            {
                if (WaitForSingleObject(child.hProcess, 180_000) != 0)
                {
                    TerminateProcess(child.hProcess, 3);
                    Console.WriteLine("the probe did not finish in 3 minutes; stopped it");
                }
                GetExitCodeProcess(child.hProcess, out code);
            }
            finally
            {
                CloseHandle(child.hThread);
                CloseHandle(child.hProcess);
            }
            if (File.Exists(report)) Console.Write(File.ReadAllText(report));
            return (int)code;
        }
        finally
        {
            CloseDesktop(desktop);
        }
    }

    // ---------- the child: everything else, on the probe's desktop

    private static int Child(string shots, string report)
    {
        using var output = new StreamWriter(report) { AutoFlush = true };
        Console.SetOut(output);
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Console.WriteLine($"data {Paths.DataDir}");
        try { Run(shots); }
        catch (Exception e) { Fail($"threw: {e}"); }
        Console.WriteLine(Failures.Count == 0 ? "ALL OK" : $"{Failures.Count} FAILED");
        return Failures.Count == 0 ? 0 : 1;
    }

    private static void Check(bool ok, string what)
    {
        Console.WriteLine($"  {(ok ? "ok  " : "FAIL")} {what}");
        if (!ok) Failures.Add(what);
    }

    private static void Fail(string what) => Check(false, what);

    /// Runs the message loop for a while, so posted work (an Invoke from the watcher, a paint)
    /// happens and UI Automation's messages to the fields are answered.
    private static void Pump(int ms = 50)
    {
        var clock = Stopwatch.StartNew();
        do { Application.DoEvents(); Thread.Sleep(5); } while (clock.ElapsedMilliseconds < ms);
    }

    private static bool WaitFor(Func<bool> done, int ms)
    {
        var clock = Stopwatch.StartNew();
        while (clock.ElapsedMilliseconds < ms)
        {
            if (done()) return true;
            Pump(20);
        }
        return done();
    }

    /// Everything the log gained after `mark`. The watcher says what it saw there, as it does in
    /// the app, so that is what these checks read.
    private static string LogSince(long mark)
    {
        if (!File.Exists(Paths.LogFile)) return "";
        using var stream = new FileStream(Paths.LogFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (mark > stream.Length) return "";
        stream.Seek(mark, SeekOrigin.Begin);
        return new StreamReader(stream).ReadToEnd();
    }

    private static long LogMark() => File.Exists(Paths.LogFile) ? new FileInfo(Paths.LogFile).Length : 0;

    /// Runs `work` on a thread of its own, MTA as UI Automation clients should be, on this
    /// process's desktop.
    private static T OnMta<T>(Func<T> work)
    {
        T result = default!;
        Exception? failed = null;
        var thread = new Thread(() =>
        {
            try { result = work(); }
            catch (Exception e) { failed = e; }
        });
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
        while (!thread.Join(10)) Application.DoEvents();
        if (failed is not null) throw failed;
        return result;
    }

    private static volatile IntPtr _target;

    private static void Run(string shots)
    {
        // Nothing learned, nothing waiting and no settings, in the probe's folder only.
        File.Delete(Paths.ReplacementsFile);
        File.Delete(Paths.PendingCorrectionsFile);
        File.Delete(Paths.SettingsFile);

        var app = Assembly.Load("LinFlow");
        var watcherType = app.GetType("LinFlow.App.PasteWatcher", throwOnError: true)!;
        var programType = app.GetType("LinFlow.App.Program", throwOnError: true)!;
        var dashboardType = app.GetType("LinFlow.App.Dashboard", throwOnError: true)!;
        var watcher = watcherType.GetProperty("Shared", Any)!.GetValue(null)!;
        var watchMethod = watcherType.GetMethod("Watch", Any)!;
        watcherType.GetField("FindFieldForTest", Any)!.SetValue(null,
            new Func<FieldReader, FieldReader.Field?>(reader => _target == IntPtr.Zero ? null : reader.FromHandle(_target)));

        var form = new Form
        {
            Text = "readback probe",
            ShowInTaskbar = false,
            StartPosition = FormStartPosition.Manual,
            Location = new Point(0, 0),
            Size = new Size(Ui(900), Ui(560)),
        };
        var single = new TextBox { Location = new Point(Ui(10), Ui(10)), Width = Ui(860) };
        var multi = new TextBox { Multiline = true, Location = new Point(Ui(10), Ui(50)), Size = new Size(Ui(860), Ui(120)) };
        var rich = new RichTextBox { Location = new Point(Ui(10), Ui(180)), Size = new Size(Ui(860), Ui(120)) };
        var secret = new TextBox { UseSystemPasswordChar = true, Location = new Point(Ui(10), Ui(310)), Width = Ui(400) };
        form.Controls.AddRange(new Control[] { single, multi, rich, secret });
        form.Show();
        Pump(300);

        // Every edit the watcher hands over, and the learner's answer, on this thread: the app
        // runs CorrectionLearning.Handle on its UI thread the same way.
        var handedOver = new ConcurrentQueue<(string Wrote, string Now)>();
        var onEdit = new Func<string, string, bool>((wrote, now) =>
        {
            handedOver.Enqueue((wrote, now));
            return form.Invoke(() => !CorrectionLearning.Handle(wrote, now, LearnMode.Auto).IsEmpty);
        });
        var clock = new Stopwatch();
        void Watch(Control field, string pasted)
        {
            _target = field.Handle;
            clock.Restart();
            watchMethod.Invoke(watcher, new object[] { pasted, 0, "probe", onEdit });
        }
        bool Learned(string from) => Glossary.LoadReplacements().Any(r => r.From == from && r.Learned);

        // ---------- reading a field at all
        Console.WriteLine("reading fields through UI Automation:");
        single.Text = "One line of text.";
        multi.Text = "Two\r\nlines.";
        rich.Text = "Rich text.";
        secret.Text = "hunter2";
        Pump(50);
        // Handles taken here, on the thread that owns the fields.
        var (hSingle, hMulti, hRich, hSecret) = (single.Handle, multi.Handle, rich.Handle, secret.Handle);
        var reads = OnMta(() =>
        {
            var reader = FieldReader.TryCreate(out var why) ?? throw new InvalidOperationException(why);
            string? Read(IntPtr hwnd)
            {
                using var field = reader.FromHandle(hwnd);
                return field is null ? null : reader.Text(field);
            }
            using var described = reader.FromHandle(hRich);
            return (Single: Read(hSingle), Multi: Read(hMulti), Rich: Read(hRich),
                    Secret: reader.FromHandle(hSecret), Kind: described is null ? "?" : reader.Describe(described));
        });
        Check(reads.Single == "One line of text.", $"an edit box reads back (\"{reads.Single}\")");
        Check(reads.Multi == "Two\r\nlines.", "a multi-line one reads back, with its own line ends");
        Check(reads.Rich is not null && reads.Rich.TrimEnd('\r', '\n') == "Rich text.", $"a rich edit box reads back ({reads.Kind})");
        Check(reads.Secret is null, "a password box is never read");
        reads.Secret?.Dispose();

        // The real focused element, for the record: this desktop is not the one being looked at,
        // so the keyboard focus here may mean nothing to UI Automation.
        form.Activate();
        single.Focus();
        Pump(50);
        var focused = OnMta(() =>
        {
            var reader = FieldReader.TryCreate(out _)!;
            using var field = reader.Focused();
            return field is null ? "nothing" : reader.Describe(field);
        });
        Console.WriteLine($"  (the focused element on the probe's desktop: {focused})");

        // ---------- a fix in an edit box is learned
        Console.WriteLine("a word fixed after a paste:");
        var mark = LogMark();
        const string wrote1 = "Ask John Lynn about it.";
        single.Text = wrote1 + " ";   // as pasted, with Lin Flow's trailing space
        Watch(single, wrote1);
        Check(WaitFor(() => LogSince(mark).Contains("readback: watching the field"), 4000), "the watcher finds the field it pasted into");
        Console.WriteLine($"    {LogSince(mark).Trim().Split('\n').LastOrDefault()?.Trim()}");
        single.Text = "Ask John Lin about it. ";
        var learnedIn = WaitFor(() => Learned("Lynn"), 6000);
        Check(learnedIn, $"Lynn => Lin is learned, {clock.Elapsed.TotalSeconds:F1}s after the paste");
        Check(File.Exists(Paths.ReplacementsFile) && File.ReadAllText(Paths.ReplacementsFile).Contains("Lynn => Lin\t# learned"),
            "and written to replacements.txt with the learned marker");
        Check(handedOver.Any(e => e.Wrote == wrote1 && e.Now == "Ask John Lin about it."), "the learner was given the phrase as pasted and as fixed");
        Check(LogSince(mark).Contains("learned correction: Lynn => Lin"), "the log says what was learned");

        // ---------- a two-line dictation in a multi-line box, among other text
        mark = LogMark();
        const string wrote2 = "Notes for today.\nWe need to triadge the bugs.";
        multi.Text = "Agenda:\r\n" + wrote2.Replace("\n", "\r\n") + " ";
        Watch(multi, wrote2);
        Check(WaitFor(() => LogSince(mark).Contains("readback: watching the field"), 4000),
            "a two-line dictation is found, though the box stores its line ends as \\r\\n");
        multi.Text = multi.Text.Replace("triadge", "triage");
        Check(WaitFor(() => Learned("triadge"), 6000), "and triadge => triage is learned from it");

        // ---------- a rich edit box
        mark = LogMark();
        const string wrote3 = "Send it to github.";
        rich.Text = wrote3 + " ";
        Watch(rich, wrote3);
        Check(WaitFor(() => LogSince(mark).Contains("readback: watching the field"), 4000), "a rich edit box is watched");
        rich.Text = "Send it to GitHub. ";
        Check(WaitFor(() => Learned("github"), 6000), "and github => GitHub is learned from it");

        // ---------- sending the message before the fix has settled
        mark = LogMark();
        const string wrote5 = "Book the Siena for Friday.";
        single.Text = wrote5 + " ";
        Watch(single, wrote5);
        Check(WaitFor(() => LogSince(mark).Contains("readback: watching the field"), 4000), "a field that is about to be sent is watched");
        single.Text = "Book the Verona for Friday. ";
        // One look has to have seen the fix, and the second not yet, when the composer empties.
        var settling = WaitFor(() => Pending(watcherType, watcher, wrote5) == "Book the Verona for Friday.", 4000);
        Check(settling, "the fix is seen once and is settling");
        single.Text = "";
        Check(WaitFor(() => Learned("Siena"), 4000), "the field emptied by a send still teaches Siena => Verona");
        Check(LogSince(mark).Contains("readback: the field was cleared mid-edit"), "and the log says the field was cleared mid-edit");

        // ---------- dictating over the same text again teaches nothing
        mark = LogMark();
        const string first = "Let's meet Thursday at noon.";
        const string second = "Let's meet Tuesday at noon.";
        single.Text = first + " ";
        Watch(single, first);
        Check(WaitFor(() => LogSince(mark).Contains("readback: watching the field"), 4000), "a dictation is watched");
        var secondWatch = Stopwatch.StartNew();
        single.Text = second + " ";   // selected and dictated again; Parakeet heard Tuesday this time
        Watch(single, second);
        Check(WaitFor(() => LogSince(mark).Contains("a newer dictation landed in this field; standing down"), 4000),
            "the first watch stands down when the next dictation lands in its field");
        Pump(2500);
        Check(!CorrectionLearning.Pending().Any(r => r.From == "Thursday") && !Learned("Thursday"),
            "and Thursday => Tuesday is neither learned nor offered");

        // ---------- the toast
        Console.WriteLine("the toast:");
        var announce = programType.GetMethod("Announce", Any)!;
        var offer = programType.GetMethod("Offer", Any)!;
        var toastField = programType.GetField("_toast", Any)!;
        announce.Invoke(null, new object[] { new CorrectionLearning.Outcome(added: new() { new Replacement("Lynn", "Lin", true) }) });
        Pump(100);
        var toast = (Form?)toastField.GetValue(null);
        Check(toast is { Visible: true }, "a learned rule puts a toast up");
        if (toast is not null)
        {
            var area = Screen.PrimaryScreen!.WorkingArea;
            Check(area.Contains(toast.Bounds), $"inside the screen's working area ({toast.Bounds} in {area})");
            Check(Form.ActiveForm != toast, "and it did not take the focus");
            Shot(toast, Path.Combine(shots, "readback-1-learned.png"));
            offer.Invoke(null, new object[] { "Marisvo", "Marisa Vuong" });
            Pump(100);
            Shot(toast, Path.Combine(shots, "readback-2-offer.png"));
            var middle = (IntPtr)((toast.Height / 2 << 16) | (toast.Width / 2));
            SendMessage(toast.Handle, WM_LBUTTONDOWN, MK_LBUTTON, middle);
            SendMessage(toast.Handle, WM_LBUTTONUP, IntPtr.Zero, middle);
            Pump(100);
            Check(Learned("Marisvo"), "clicking an offer adds the rule");
            Check(toast.Visible, "and a second toast says it was added");
            Shot(toast, Path.Combine(shots, "readback-3-added.png"));
        }

        // ---------- the Dictionary
        Console.WriteLine("the window:");
        CorrectionLearning.Handle("Then draft a better email to Wort.", "Then draft a better email to Duarte.", LearnMode.Auto);
        var window = (Form)Activator.CreateInstance(dashboardType, nonPublic: true)!;
        window.ShowInTaskbar = false;
        window.StartPosition = FormStartPosition.Manual;
        window.Location = new Point(0, 0);
        window.Show();
        dashboardType.GetMethod("ShowSection", Any)!.Invoke(window, new object[] { (int)dashboardType.GetField("DictionarySection", Any)!.GetValue(null)! });
        Pump(300);
        var suggested = (Panel)dashboardType.GetField("_suggested", Any)!.GetValue(window)!;
        var rowType = dashboardType.GetNestedType("SuggestionRow", Any)!;
        var rows = suggested.Controls.Cast<Control>().Where(c => c.GetType() == rowType).ToList();
        Check(suggested.Visible && rows.Count == 1, $"the Dictionary shows the waiting suggestion ({rows.Count} row)");
        var corrections = (Panel)dashboardType.GetField("_corrections", Any)!.GetValue(window)!;
        Check(corrections.Controls.Count == Glossary.LoadReplacements().Count,
            $"and every learned rule in the corrections ({corrections.Controls.Count})");
        Shot(window, Path.Combine(shots, "readback-4-dictionary.png"));
        if (rows.Count == 1)
        {
            rows[0].Controls.OfType<Button>().Single(b => b.Text == "Add").PerformClick();
            Pump(300);
            Check(Learned("Wort") && CorrectionLearning.Pending().Count == 0, "Add moves it into the corrections");
            Check(!suggested.Visible, "and the Suggested block goes away");
        }

        // ---------- the setting
        var learn = (ComboBox)dashboardType.GetField("_learn", Any)!.GetValue(window)!;
        Check(learn.Text == "Add it automatically", $"the setting reads Add it automatically with no settings.json ({learn.Text})");
        learn.SelectedIndex = 1;
        Pump(50);
        Check(LearnSettings.Load() == LearnMode.Ask, "choosing Suggest it first saves ask");
        learn.SelectedIndex = 0;
        Pump(50);
        Check(LearnSettings.Load() == LearnMode.Auto, "and choosing Add it automatically saves auto");
        dashboardType.GetMethod("ShowSection", Any)!.Invoke(window, new object[] { 3 });
        Pump(300);
        Shot(window, Path.Combine(shots, "readback-5-settings.png"));
        window.Dispose();

        // ---------- the end of a window
        // The second Thursday/Tuesday dictation was never touched, so its watch runs to the end.
        var left = (int)(17_500 - secondWatch.ElapsedMilliseconds);
        if (left > 0) Pump(left);
        Check(LogSince(mark).Contains("readback: field unchanged after 15s, nothing to learn"),
            "a field left alone says so when its window ends");

        form.Dispose();
        Console.WriteLine("what the probe's replacements.txt ended up holding:");
        foreach (var line in File.ReadAllLines(Paths.ReplacementsFile)) Console.WriteLine($"    {line}");
    }

    /// The edit a live watch is waiting to see settle. Read from this thread while the watcher's
    /// changes the list, so a read that collides with a change is simply tried again.
    private static string? Pending(Type watcherType, object watcher, string wrote)
    {
        try
        {
            var live = (System.Collections.IList)watcherType.GetField("_live", Any)!.GetValue(watcher)!;
            foreach (var entry in live.Cast<object>().ToArray())
            {
                var watch = (ReadbackWatch)entry.GetType().GetProperty("Watch", Any)!.GetValue(entry)!;
                if (watch.Wrote == wrote) return (string?)typeof(ReadbackWatch).GetField("_pending", Any)!.GetValue(watch);
            }
        }
        catch (InvalidOperationException) { }
        catch (ArgumentException) { }
        return null;
    }

    private static int Ui(int px) => (int)Math.Round(px * DeviceDpi() / 96f);

    private static float DeviceDpi()
    {
        using var g = Graphics.FromHwnd(IntPtr.Zero);
        return g.DpiX;
    }

    private static void Shot(Form form, string path)
    {
        using var bitmap = new Bitmap(form.Width, form.Height);
        form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
        bitmap.Save(path, ImageFormat.Png);
        Console.WriteLine($"  saved {path}");
    }
}
