// window-probe: Lin Flow's real window, built from the Release DLLs and driven where nobody can
// see it, so a change to the window can be checked without touching the app John dictates with.
//
// Why it exists. A test instance of LinFlow.exe cannot run beside the installed one: the second
// launch finds the first, asks it to show its window, and exits. Driving John's own window is a
// live interaction with the app he is using. So this builds the Dashboard itself, by reflection
// since it is internal, and keeps three promises:
//
//   - Its own desktop. CreateDesktop and SetThreadDesktop, so the window is never on John's
//     screen or in his taskbar, and cannot take the focus from whatever he is typing into.
//   - Its own data folder. It refuses to run unless LINFLOW_DATA_DIR names a folder with
//     "probe-data" in it, so the history it appends to is a copy.
//   - Never his clipboard. DictationRow.SetClipboard is swapped for a list before anything is
//     copied. The clipboard belongs to the window station, not the desktop, so the desktop alone
//     would not protect it.
//
// Run from windows/ after a Release build of LinFlow.sln (NOTES.md says where dotnet is):
//
//   $env:LINFLOW_DATA_DIR = "$env:TEMP\probe-data"
//   New-Item -ItemType Directory -Force $env:LINFLOW_DATA_DIR
//   Copy-Item "$env:APPDATA\Lin Flow\history.jsonl" $env:LINFLOW_DATA_DIR
//   dotnet run --project scripts\probes\window-probe -c Release -- "$env:TEMP\probe-shots"
//
// It prints ok or FAIL for each check, saves three screenshots, and exits 0 only if every check
// passed. The first run after a new build can take seconds before the window fills: Datto AV
// examines new DLLs the first time they load (NOTES.md, 2026-09-23).
using System.Diagnostics;
using System.Drawing.Imaging;
using System.Reflection;
using System.Runtime.InteropServices;
using LinFlow.Core;

internal static class WindowProbe
{
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr devmode, int flags, uint access, IntPtr sa);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SetThreadDesktop(IntPtr desktop);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern uint GetDpiForSystem();

    private const uint GENERIC_ALL = 0x10000000;
    private const int WM_MOUSEWHEEL = 0x020A, WM_MOUSEMOVE = 0x0200, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202, MK_LBUTTON = 1;
    private const int EM_GETLINECOUNT = 0x00BA, EM_GETFIRSTVISIBLELINE = 0x00CE, EM_POSFROMCHAR = 0x00D6;
    private const BindingFlags Any = BindingFlags.Instance | BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;

    private static readonly List<string> Failures = new();
    private static readonly List<string> Copied = new();

    private static int Main(string[] args)
    {
        var desktop = CreateDesktop($"linflow-probe-{Environment.ProcessId}", IntPtr.Zero, IntPtr.Zero, 0, GENERIC_ALL, IntPtr.Zero);
        if (desktop == IntPtr.Zero)
        {
            Console.WriteLine($"could not create a desktop ({Marshal.GetLastWin32Error()}); stopping rather than draw on John's");
            return 2;
        }
        var result = 2;
        // A thread that owns a window cannot change desktop, and a thread initialized for COM as
        // STA owns one, so the desktop is set first thing on a fresh thread. The runtime then
        // makes it MTA; nothing checked here needs STA, and the clipboard, which would, is swapped.
        var ui = new Thread(() =>
        {
            if (!SetThreadDesktop(desktop))
            {
                Console.WriteLine($"could not move to the probe's desktop ({Marshal.GetLastWin32Error()}); stopping");
                return;
            }
            if (!Paths.DataDir.Contains("probe-data", StringComparison.OrdinalIgnoreCase))
            {
                Console.WriteLine($"LINFLOW_DATA_DIR is {Paths.DataDir}, not a probe-data folder; stopping");
                return;
            }
            Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Console.WriteLine($"data {Paths.DataDir}, {GetDpiForSystem()} dpi");
            var shots = args.Length > 0 ? args[0] : Path.Combine(Path.GetTempPath(), "probe-shots");
            Directory.CreateDirectory(shots);
            try { Run(shots); }
            catch (Exception e) { Fail($"threw: {e}"); }
            Console.WriteLine(Failures.Count == 0 ? "ALL OK" : $"{Failures.Count} FAILED");
            result = Failures.Count == 0 ? 0 : 1;
        });
        ui.Start();
        ui.Join();
        return result;
    }

    private static void Check(bool ok, string what)
    {
        Console.WriteLine($"  {(ok ? "ok  " : "FAIL")} {what}");
        if (!ok) Failures.Add(what);
    }

    private static void Fail(string what) => Check(false, what);

    private static IntPtr LParam(int x, int y) => (IntPtr)((y << 16) | (x & 0xFFFF));

    /// Runs the message loop for a while, so posted work (a BeginInvoke, a paint) happens.
    private static void Pump(int ms = 50)
    {
        var clock = Stopwatch.StartNew();
        do { Application.DoEvents(); Thread.Sleep(5); } while (clock.ElapsedMilliseconds < ms);
    }

    private static void Run(string shots)
    {
        var app = Assembly.Load("LinFlow");
        var dashboardType = app.GetType("LinFlow.App.Dashboard", throwOnError: true)!;
        var rowType = app.GetType("LinFlow.App.DictationRow", throwOnError: true)!;
        rowType.GetField("SetClipboard", Any)!.SetValue(null, new Action<string>(Copied.Add));

        var form = (Form)Activator.CreateInstance(dashboardType, nonPublic: true)!;
        form.ShowInTaskbar = false;
        var list = (Panel)dashboardType.GetField("_history", Any)!.GetValue(form)!;

        List<Panel> Rows() => list.Controls.Cast<Control>().Reverse().Where(c => c.GetType() == rowType).Cast<Panel>().ToList();
        TextBox Words(Panel row) => row.Controls.OfType<TextBox>().Single();
        string Dictation(Panel row) => (string)rowType.GetField("_dictation", Any)!.GetValue(row)!;
        int LineHeight() => (int)rowType.GetProperty("LineHeight", Any)!.GetValue(null)!;
        string Short(string s) => s.Length <= 40 ? s : s[..40] + "...";

        var clock = Stopwatch.StartNew();
        form.Show();
        Pump(10);
        Console.WriteLine($"shown and filled in {clock.ElapsedMilliseconds} ms");
        Pump(300);

        // ---------- the list matches the file
        var rows = Rows();
        var inFile = History.Load(limit: 300);
        Console.WriteLine($"{rows.Count} rows, {inFile.Count} dictations in the file, list {list.ClientSize.Width}x{list.ClientSize.Height}");
        Check(rows.Count == inFile.Count, "one row per dictation");
        Check(rows.Count > 0 && Dictation(rows[0]) == inFile[0].Text, "the newest dictation is the top row");

        // Every row shows all of its text: no line hidden, none scrolled away, and the row as
        // wide as the list.
        void CheckFit(string when)
        {
            var bad = 0;
            var line = LineHeight();
            var spare = (int)Math.Round(2 * GetDpiForSystem() / 96f);
            foreach (var row in Rows())
            {
                var words = Words(row);
                var lines = (int)SendMessage(words.Handle, EM_GETLINECOUNT, IntPtr.Zero, IntPtr.Zero);
                var first = (int)SendMessage(words.Handle, EM_GETFIRSTVISIBLELINE, IntPtr.Zero, IntPtr.Zero);
                var lastY = words.TextLength == 0 ? 0
                    : (short)(((int)SendMessage(words.Handle, EM_POSFROMCHAR, words.TextLength - 1, IntPtr.Zero) >> 16) & 0xFFFF);
                var problems = new List<string>();
                if (first != 0) problems.Add($"scrolled to line {first}");
                if (lastY + line > words.ClientSize.Height) problems.Add($"last line at {lastY}+{line} in a {words.ClientSize.Height} box");
                if (lines * line + spare != words.Height) problems.Add($"{lines} lines in a {words.Height} box");
                if (words.Bottom > row.Height) problems.Add($"text ends at {words.Bottom} in a {row.Height} row");
                if (row.Width != list.ClientSize.Width) problems.Add($"row {row.Width} wide in a {list.ClientSize.Width} list");
                if (problems.Count > 0 && bad++ < 5) Console.WriteLine($"    \"{Short(Dictation(row))}\": {string.Join("; ", problems)}");
            }
            Check(bad == 0, $"every row shows all of its text ({when})");
        }
        CheckFit("first show");
        Shot(form, Path.Combine(shots, "1-shown.png"));

        foreach (var width in new[] { 720, 1400, 1000 })
        {
            clock.Restart();
            form.Width = (int)Math.Round(width * GetDpiForSystem() / 96f);
            Pump(10);
            Console.WriteLine($"resized to {width} in {clock.ElapsedMilliseconds} ms");
            CheckFit($"at {width}");
        }

        // ---------- a dictation saved while the window is open shows up at once
        var keep = Words(rows.Count > 1 ? rows[1] : rows[0]);
        keep.Focus();
        keep.Select(0, Math.Min(5, keep.TextLength));
        var before = Rows().ToHashSet();
        const string whileOpen = "Probe: saved while the window is open, so it has to show up now.";
        clock.Restart();
        // On a pool thread, the way the hotkey's worker saves a dictation in the app.
        Task.Run(() => History.Append(new HistoryEntry { Raw = whileOpen, Text = whileOpen, Model = "probe", AudioSeconds = 3, InferenceSeconds = 0.2 })).Wait();
        Pump(10);
        Console.WriteLine($"a new dictation was in the list {clock.ElapsedMilliseconds} ms after it was saved");
        var after = Rows();
        Check(after.Count == Math.Min(300, rows.Count + 1), "one more row");
        Check(after.Count > 0 && Dictation(after[0]) == whileOpen, "the new dictation is the top row");
        Check(after.Skip(1).All(before.Contains), "every other row was kept, not rebuilt");
        Check(!keep.IsDisposed && keep.SelectionLength == Math.Min(5, keep.TextLength), "a selection in another row survived");
        CheckFit("after a new dictation");
        Shot(form, Path.Combine(shots, "2-new-dictation.png"));

        // ---------- a closed window does no work, and is up to date when it opens
        form.Hide();
        Pump(20);
        const string whileClosed = "Probe: saved while the window was closed.";
        Task.Run(() => History.Append(new HistoryEntry { Raw = whileClosed, Text = whileClosed, Model = "probe", AudioSeconds = 2, InferenceSeconds = 0.2 })).Wait();
        Pump(20);
        Check(Dictation(Rows()[0]) == whileOpen, "a closed window does not reload");
        form.Show();
        Pump(50);
        Check(Dictation(Rows()[0]) == whileClosed, "opening it brings it up to date");

        // ---------- the copy button
        var top = Rows()[0];
        var button = (Rectangle)rowType.GetProperty("ButtonBox", Any)!.GetValue(top)!;
        var center = LParam(button.X + button.Width / 2, button.Y + button.Height / 2);
        Copied.Clear();
        SendMessage(top.Handle, WM_MOUSEMOVE, IntPtr.Zero, center);
        SendMessage(top.Handle, WM_LBUTTONDOWN, MK_LBUTTON, center);
        SendMessage(top.Handle, WM_LBUTTONUP, IntPtr.Zero, center);
        Pump(20);
        Check(Copied.SequenceEqual(new[] { whileClosed }), "the copy button copies the whole dictation");
        Check((string?)rowType.GetField("_flash", Any)!.GetValue(top) == "Copied", "and the row says Copied");
        Shot(form, Path.Combine(shots, "3-copied.png"));
        Pump(1700);
        Check(rowType.GetField("_flash", Any)!.GetValue(top) is null, "then stops saying it");

        // ---------- Ctrl+C
        var words = Words(top);
        var processCmdKey = words.GetType().GetMethod("ProcessCmdKey", Any)!;
        void CtrlC() => processCmdKey.Invoke(words, new object[] { Message.Create(words.Handle, 0x0100, (IntPtr)Keys.C, IntPtr.Zero), Keys.Control | Keys.C });
        words.Focus();
        words.Select(0, 5);
        Copied.Clear();
        CtrlC();
        Check(Copied.SequenceEqual(new[] { whileClosed[..5] }), "Ctrl+C copies the selection");
        words.Select(0, 0);
        Copied.Clear();
        CtrlC();
        Check(Copied.SequenceEqual(new[] { whileClosed }), "Ctrl+C with nothing selected copies the whole dictation");

        // ---------- the right-click menu
        var menu = (ContextMenuStrip)rowType.GetField("_menu", Any)!.GetValue(null)!;
        words.Focus();
        words.Select(7, 8);
        menu.Show(words, new Point(4, 4));
        Pump(20);
        Check(menu.Items[0].Text == "Copy", "over a selection the menu says Copy");
        Copied.Clear();
        menu.Items[0].PerformClick();
        menu.Close();
        Pump(20);
        Check(Copied.SequenceEqual(new[] { whileClosed.Substring(7, 8) }), "and copies the selection");
        words.Select(0, 0);
        var other = Rows()[2];
        menu.Show(other, new Point(4, 4));
        Pump(20);
        Check(menu.Items[0].Text == "Copy dictation", "with nothing selected it says Copy dictation");
        Copied.Clear();
        menu.Items[0].PerformClick();
        menu.Close();
        Pump(20);
        Check(Copied.SequenceEqual(new[] { Dictation(other) }), "and copies that row's dictation");

        // ---------- the wheel over the text still scrolls the list
        list.AutoScrollPosition = new Point(0, 0);
        Pump(20);
        var under = Words(Rows()[1]);
        var at = under.PointToScreen(new Point(5, 5));
        SendMessage(under.Handle, WM_MOUSEWHEEL, (IntPtr)(-120 << 16), LParam(at.X, at.Y));
        Pump(20);
        Check(list.AutoScrollPosition.Y < 0, "the wheel over a dictation's text scrolls the list");

        // ---------- dragging a selection past the end of a long dictation
        var tall = Rows().OrderByDescending(r => r.Height).First();
        var tallWords = Words(tall);
        list.ScrollControlIntoView(tall);
        Pump(20);
        tallWords.Focus();
        SendMessage(tallWords.Handle, WM_LBUTTONDOWN, MK_LBUTTON, LParam(2, 2));
        for (var y = 10; y < tallWords.Height + 80; y += 12)
        {
            SendMessage(tallWords.Handle, WM_MOUSEMOVE, MK_LBUTTON, LParam(40, y));
            Pump(15);
        }
        Pump(200);
        SendMessage(tallWords.Handle, WM_LBUTTONUP, IntPtr.Zero, LParam(40, tallWords.Height + 80));
        Pump(20);
        Check(tallWords.SelectionLength > 0, "dragging selects text");
        Check(SendMessage(tallWords.Handle, EM_GETFIRSTVISIBLELINE, IntPtr.Zero, IntPtr.Zero) == 0, "and the text does not scroll up inside its row");

        // ---------- clicking into a row half off the bottom does not move the list
        list.AutoScrollPosition = new Point(0, 0);
        Pump(20);
        var partly = Rows().First(r => r.Top < list.ClientSize.Height && r.Bottom > list.ClientSize.Height);
        var scrolled = list.AutoScrollPosition.Y;
        Words(partly).Focus();
        Pump(20);
        Check(list.AutoScrollPosition.Y == scrolled, "focusing a row half off the bottom leaves the list where it was");

        CheckCorrections(form, dashboardType, shots);

        form.Dispose();
    }

    private static int Scaled(int v) => (int)Math.Round(v * GetDpiForSystem() / 96f);

    /// The Dictionary's corrections: a click puts one in the two fields to be changed, and Save
    /// writes the change over the rule where it stands in the probe's replacements.txt.
    private static void CheckCorrections(Form form, Type dashboardType, string shots)
    {
        const int WM_KEYDOWN = 0x0100, VK_RETURN = 0x0D, VK_ESCAPE = 0x1B;
        object Get(string name) => dashboardType.GetField(name, Any)!.GetValue(form)!;
        TextBox Box(string name) { var f = Get(name); return (TextBox)f.GetType().GetProperty("Box", Any)!.GetValue(f)!; }
        var list = (Panel)Get("_corrections");
        var heard = Box("_heard");
        var meant = Box("_meant");
        var save = (Button)Get("_addRep");
        var cancel = (Button)Get("_cancelRep");

        List<Panel> Rows() => list.Controls.Cast<Control>().Reverse().Cast<Panel>().ToList();
        Replacement RuleOf(Panel row) => (Replacement)row.Tag!;
        Panel RowFor(string from) => Rows().Single(r => RuleOf(r).From == from);
        bool Marked(Panel row) => (bool)row.GetType().GetProperty("Selected", Any)!.GetValue(row)!;
        void ClickAt(Panel row, int x)
        {
            // The handle is taken once: the trash's click reloads the list, which disposes the row
            // before the button comes up.
            var handle = row.Handle;
            var at = LParam(x, row.Height / 2);
            SendMessage(handle, WM_LBUTTONDOWN, MK_LBUTTON, at);
            SendMessage(handle, WM_LBUTTONUP, IntPtr.Zero, at);
            Pump(30);
        }
        void Open(string from) => ClickAt(RowFor(from), Scaled(10));
        void Press(TextBox box, int key) { SendMessage(box.Handle, WM_KEYDOWN, key, IntPtr.Zero); Pump(30); }
        string File() => string.Join(" | ", Glossary.LoadReplacements().Select(r => r.Learned ? $"{r} (learned)" : r.ToString()));
        bool Adding() => save.Text == "Add" && !cancel.Visible && heard.TextLength == 0 && meant.TextLength == 0 && !Rows().Any(Marked);

        Glossary.SaveReplacements(new[]
        {
            new Replacement("wisper flow", "Wispr Flow"),
            new Replacement("cloud code", "Claude Code"),
            new Replacement("lynn", "Lin", learned: true),
        });
        dashboardType.GetMethod("ShowSection", Any)!.Invoke(form, new object[] { 2 });
        Pump(100);
        Console.WriteLine($"corrections: {string.Join(" | ", Rows().Select(r => RuleOf(r).ToString()))}");
        Check(Rows().Select(r => RuleOf(r).From).SequenceEqual(new[] { "lynn", "wisper flow", "cloud code" }),
            "the corrections show learned first, then the ones written by hand");

        // ---------- a click opens a correction to be changed
        Open("wisper flow");
        Check(heard.Text == "wisper flow" && meant.Text == "Wispr Flow", "clicking a correction puts it in the two fields");
        Check(save.Text == "Save" && cancel.Visible, "and Add becomes Save, with Cancel beside it");
        Check(Marked(RowFor("wisper flow")) && Rows().Count(Marked) == 1, "and only that row is marked");
        // Cancel was first drawn past the column's right edge, where nobody could click it.
        bool Inside(Control c) => c.Left >= 0 && c.Top >= 0 && c.Right <= c.Parent!.ClientSize.Width && c.Bottom <= c.Parent.ClientSize.Height;
        bool BarFits() => Inside(heard.Parent!) && Inside(meant.Parent!) && Inside(save) && Inside(cancel);
        Check(BarFits(), "and the fields, Save and Cancel all fit in the column");
        Shot(form, Path.Combine(shots, "4-changing-a-correction.png"));
        var width = form.Width;
        form.Width = Scaled(720);
        Pump(50);
        Check(BarFits(), "in the narrowest window too, where the buttons wrap");
        Shot(form, Path.Combine(shots, "5-changing-a-correction-narrow.png"));
        form.Width = width;
        Pump(50);

        // ---------- Enter saves it in place
        meant.Text = "Wispr Flow app";
        Press(meant, VK_RETURN);
        Console.WriteLine($"  file: {File()}");
        Check(File() == "wisper flow => Wispr Flow app | cloud code => Claude Code | lynn => Lin (learned)",
            "Enter saves the change over the rule, on the same line");
        Check(Adding(), "then the fields empty, Save is Add again, and nothing is marked");

        // ---------- Save with nothing changed writes nothing, and a learned rule stays learned
        Open("lynn");
        save.PerformClick();
        Pump(30);
        Check(File().EndsWith("lynn => Lin (learned)", StringComparison.Ordinal) && Adding(), "saving an unchanged rule leaves it learned");

        // ---------- a learned rule that is changed is John's
        Open("lynn");
        meant.Text = "Lin Flow";
        save.PerformClick();
        Pump(30);
        Check(File() == "wisper flow => Wispr Flow app | cloud code => Claude Code | lynn => Lin Flow",
            "a changed learned rule keeps its line and loses the learned mark");

        // ---------- changing the heard side to one another rule has replaces that rule
        Open("cloud code");
        heard.Text = "Wisper Flow";
        meant.Text = "Wispr Flow";
        Press(heard, VK_RETURN);
        Check(File() == "Wisper Flow => Wispr Flow | lynn => Lin Flow",
            "a change that collides with another rule replaces it, in the changed rule's place");

        // ---------- Esc leaves it as it was
        var before = File();
        Open("lynn");
        meant.Text = "not this";
        Press(meant, VK_ESCAPE);
        Check(File() == before && Adding(), "Esc leaves the correction as it was");

        // ---------- the trash on the row being changed ends the change
        Open("lynn");
        var row = RowFor("lynn");
        ClickAt(row, row.Width - Scaled(21));
        Check(File() == "Wisper Flow => Wispr Flow" && Adding(), "the trash removes the rule and ends the change");

        // ---------- adding still adds, at the end
        heard.Text = "cube cuttle";
        meant.Text = "kubectl";
        Press(heard, VK_RETURN);
        Check(File() == "Wisper Flow => Wispr Flow | cube cuttle => kubectl" && Adding(), "Enter in the fields adds a new correction at the end");
    }

    private static void Shot(Form form, string path)
    {
        using var bitmap = new Bitmap(form.Width, form.Height);
        form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
        bitmap.Save(path, ImageFormat.Png);
        Console.WriteLine($"  saved {path}");
    }
}
