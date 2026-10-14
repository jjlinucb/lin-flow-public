using LinFlow.Core;

namespace LinFlow.App;

/// The window, laid out and drawn like the Mac's.
///
/// It started as a TabControl with four tabs of stock WinForms controls, which worked and looked
/// like a utility from 1998 beside the thing it is a port of. John asked on 2026-09-19 for the
/// Windows app to match the Mac in look and style, so the shell is now the Mac's: a grey sidebar
/// of sections down the left, a white content pane, a bold section title with a grey sentence
/// under it, and hairline lists with no grid and no column headers. `design/README.md` at the
/// repo root holds the seven reference screenshots, the sampled colors and the measurements;
/// `Mac` and `MacControls` hold the tokens and the painted controls.
///
/// Four sections, not the Mac's seven. Snippets, Style and Transforms have no counterpart in
/// LinFlow.Core - there is no snippet store, no transform runner and no rewriter on this side -
/// and a section that cannot do anything is worse than an absent one. The design README records
/// what each would need.
///
/// Closing hides rather than exits, the same rule as the Mac's `windowShouldClose`. Quitting is
/// the tray menu's job: a dictation tool that ends when you close its window would be lost the
/// first time you tidied your desktop.
internal sealed class Dashboard : Form
{
    private readonly MacSidebar _sidebar;
    private readonly MacTitle _title = new();
    private readonly Panel _pages = new() { Dock = DockStyle.Fill, BackColor = Mac.Content };
    private readonly Label _status = new();
    private readonly NotetakerTab _notetaker = new();

    private readonly MacList _history = new();
    private readonly MacEmpty _empty = new(Mac.GlyphMic, "Nothing dictated yet",
        "Hold your talk key, say something, and it will show up here.");
    private readonly Label _stats = new();
    private readonly MacList _words = new();
    private readonly MacList _corrections = new();
    private readonly Panel _suggested = new() { Dock = DockStyle.Top, BackColor = Mac.Content, Visible = false };
    private MacField _newWord = null!;
    private MacField _heard = null!;
    private MacField _meant = null!;
    private MacButton _addRep = null!;
    private MacButton _cancelRep = null!;
    private FlowLayoutPanel _repBar = null!;
    private Label _repArrow = null!;
    /// The correction the two fields are changing, or null while they add a new one.
    private Replacement? _editing;
    private ComboBox _hotkey = null!;
    private ComboBox _learn = null!;
    private MacButton _saveKey = null!;
    private MacButton _recordKey = null!;
    private HotkeyCapture? _capture;

    /// Every dictation on this PC, newest first, as the last reload read it. The list shows the
    /// first 300; the totals count all of them.
    private List<HistoryEntry> _allHistory = new();
    private MacNote _syncNote = null!;
    /// Reads the other computers' totals again while the window is open, so a dictation made on
    /// the Mac shows up here without closing and reopening it. Five minutes keeps a window left
    /// open all day to about a hundred small reads.
    private readonly System.Windows.Forms.Timer _pullTimer = new() { Interval = 5 * 60 * 1000 };

    private readonly List<Control> _sections = new();

    /// The sections' places in the sidebar, for opening the window at one.
    internal const int DictionarySection = 2;

    public Dashboard()
    {
        Text = "Lin Flow";
        // Every size in this file is written for a 96-DPI screen and goes through Ui.S, which has
        // the whole story. AutoScaleMode is off deliberately: a second, framework-run scaling
        // pass over numbers that are already scaled would double them.
        AutoScaleMode = AutoScaleMode.None;
        Size = Ui.S(1000, 700);
        MinimumSize = Ui.S(720, 480);
        StartPosition = FormStartPosition.CenterScreen;
        ShowInTaskbar = true;      // the whole point: a real taskbar presence
        BackColor = Mac.Content;
        try { Icon = Program.WindowIcon(); } catch { /* drawn icon is optional */ }

        _sidebar = new MacSidebar(new[]
        {
            new MacSidebar.Item("Dictation", Mac.GlyphMic),
            new MacSidebar.Item("Notetaker", Mac.GlyphNote),
            new MacSidebar.Item("Dictionary", Mac.GlyphBook),
            new MacSidebar.Item("Settings", Mac.GlyphGear),
        });
        _sidebar.SelectionChanged += Show;

        _sections.Add(BuildDictation());
        _sections.Add(_notetaker);
        _sections.Add(BuildDictionary());
        _sections.Add(BuildSettings());
        foreach (var s in _sections)
        {
            s.Dock = DockStyle.Fill;
            s.Visible = false;
            _pages.Controls.Add(s);
        }

        _status.Dock = DockStyle.Bottom;
        _status.Height = Ui.S(26);
        _status.TextAlign = ContentAlignment.MiddleLeft;
        _status.Padding = new Padding(Ui.S(22), 0, 0, 0);
        _status.Font = Mac.Small;
        _status.ForeColor = Mac.Grey;
        _status.BackColor = Mac.Content;

        // Docking is applied from the last child to the first, so the Fill control has to be
        // added first or the sidebar lands on top of it.
        var content = new Panel { Dock = DockStyle.Fill, BackColor = Mac.Content };
        content.Controls.Add(_pages);
        content.Controls.Add(_status);

        var rail = new Panel { Dock = DockStyle.Left, Width = Ui.S(190), BackColor = Mac.SidebarBack };
        rail.Controls.Add(_sidebar);
        rail.Controls.Add(_title);

        Controls.Add(content);
        Controls.Add(rail);

        Show(0);

        Glossary.DidChange += OnGlossaryChanged;
        CorrectionLearning.DidChange += OnGlossaryChanged;
        History.DidChange += OnHistoryChanged;
        TotalsSync.Shared.Changed += OnTotalsChanged;
        _pullTimer.Tick += (_, _) =>
        {
            if (Visible && WindowState != FormWindowState.Minimized) TotalsSync.Shared.RequestPull();
        };
        _pullTimer.Start();
        // Populate whenever the window appears, however it was shown. Refresh() on the way in
        // from the tray is not enough on its own: anything that makes the window visible another
        // way would otherwise show empty lists, which reads as a broken window rather than an
        // unfilled one. The other computers' totals are read again at the same moment.
        VisibleChanged += (_, _) =>
        {
            if (!Visible) return;
            Reload();
            TotalsSync.Shared.RequestPull();
        };
        FormClosing += (_, e) =>
        {
            // Never actually close: the tray icon is the app's life, not this window.
            if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
        };
    }

    private void Show(int index)
    {
        for (var i = 0; i < _sections.Count; i++) _sections[i].Visible = i == index;
        _title.Section = _sidebar.SelectedName;
    }

    /// Switches to a section, the way clicking it in the sidebar does.
    public void ShowSection(int index) => _sidebar.SelectedIndex = index;

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            Glossary.DidChange -= OnGlossaryChanged;
            CorrectionLearning.DidChange -= OnGlossaryChanged;
            History.DidChange -= OnHistoryChanged;
            TotalsSync.Shared.Changed -= OnTotalsChanged;
            _pullTimer.Dispose();
        }
        base.Dispose(disposing);
    }

    /// A push or a pull finished, on a pool thread. Only an open window has anything to redraw.
    private void OnTotalsChanged()
    {
        if (!IsHandleCreated || IsDisposed) return;
        try
        {
            BeginInvoke(() =>
            {
                if (!Visible) return;
                ShowStats();
                ShowSyncStatus();
            });
        }
        catch (Exception e) { Log.Info($"window refresh failed: {e.Message}"); }
    }

    private void OnGlossaryChanged()
    {
        // Fired from whichever thread saved; the lists belong to the UI thread.
        if (!IsHandleCreated || IsDisposed) return;
        try { BeginInvoke(LoadDictionary); } catch (Exception e) { Log.Info($"window refresh failed: {e.Message}"); }
    }

    /// A dictation was just saved: put it in the list now, not the next time the window opens.
    /// Raised on the hotkey's worker thread once the row is on disk. A hidden window is filled
    /// when it is shown, by VisibleChanged, so only an open one reloads here.
    private void OnHistoryChanged()
    {
        if (!IsHandleCreated || IsDisposed) return;
        try { BeginInvoke(ReloadHistoryIfOpen); } catch (Exception e) { Log.Info($"window refresh failed: {e.Message}"); }
    }

    private void ReloadHistoryIfOpen()
    {
        if (!Visible) return;
        try { LoadHistory(); }
        catch (Exception e) { Log.Info($"could not refresh the dictation list: {e.Message}"); }
    }

    /// Called on the way in from the tray, so the status line can name the engine's state.
    public void Refresh(string state)
    {
        _status.Text = $"Lin Flow is {state}.   Data folder: {Paths.DataDir}";
        Reload();
    }

    private void Reload()
    {
        try
        {
            LoadHistory();
            LoadDictionary();
            _notetaker.Reload();
        }
        catch (Exception e)
        {
            Log.Info($"could not fill the window: {e.Message}");
        }
    }

    // ---------- shared bits ----------

    /// A button sized by its text, painted like the Mac's. Kept as a Button so everything already
    /// written against it - Click, Enabled, the notetaker's record button - is unaffected.
    ///
    /// A fixed Height cannot be right at two DPIs at once: the text is drawn in points, so it
    /// doubles on a 200% screen while a hard-coded 23-pixel button does not, and the label ends
    /// up sliced in half. MacButton measures its own text.
    internal static Button Action(string text) => new MacButton(text)
    {
        Margin = Ui.S(new Padding(0, 0, 8, 0)),
    };

    /// The strip those buttons sit in, which is as tall as they are and no taller.
    internal static FlowLayoutPanel Bar(params Control[] items)
    {
        var bar = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            FlowDirection = FlowDirection.LeftToRight,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            BackColor = Mac.Content,
            Padding = Ui.S(new Padding(0, 6, 0, 6)),
        };
        bar.Controls.AddRange(items);
        return bar;
    }

    /// Draws a string at a point in one color and font, and says how wide it was, so a row can
    /// lay several runs out left to right the way the corrections list does.
    private static float Run(Graphics g, string text, Font font, Color color, float x, Rectangle row)
    {
        using var brush = new SolidBrush(color);
        var size = g.MeasureString(text, font);
        g.DrawString(text, font, brush, x, row.Y + (row.Height - size.Height) / 2);
        return size.Width;
    }

    // ---------- Dictation ----------

    private Control BuildDictation()
    {
        var page = new MacPage();
        _stats.Dock = DockStyle.Top;
        _stats.Height = Ui.S(46);
        _stats.Font = Mac.Body;
        _stats.ForeColor = Mac.Grey;
        _stats.BackColor = Mac.Content;
        _stats.TextAlign = ContentAlignment.MiddleLeft;

        // Both fill, and exactly one is visible: LoadHistory picks. Hidden to start with so an
        // empty state never flashes over a list that is about to be filled.
        _empty.Visible = false;
        page.Body.Controls.Add(_history);
        page.Body.Controls.Add(_empty);
        page.Body.Controls.Add(_stats);
        page.Body.Controls.Add(new MacHeader("Dictation",
            "Everything you have dictated on this PC, newest first. Select part of one to copy it, or copy the whole thing with the button on the right."));
        return page;
    }

    // The rows the Dictation list is showing, so a reload after a dictation builds one new row
    // and keeps the rest, and with them whatever is selected in one of them.
    private Dictionary<string, Control> _historyRows = new();

    private void LoadHistory()
    {
        // All of it, not the 300 the list shows: until 2026-09-25 the totals line counted only
        // those 300, so "words" was the last 300 dictations and stopped growing once there were more.
        _allHistory = History.Load(limit: 0);
        var entries = _allHistory.Count > 300 ? _allHistory.GetRange(0, 300) : _allHistory;
        var rows = new List<Control>();
        var shown = new Dictionary<string, Control>();
        var day = "";

        ShowStats();
        ShowSyncStatus();

        foreach (var e in entries)
        {
            var when = DateTime.TryParse(e.Timestamp, null,
                System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal,
                out var utc) ? utc.ToLocalTime() : (DateTime?)null;

            // The Mac groups by day under a small grey heading; the group only changes when the
            // date does, and the list is already newest first.
            var label = when == null ? "Earlier"
                : when.Value.Date == DateTime.Today ? "Today"
                : when.Value.Date == DateTime.Today.AddDays(-1) ? "Yesterday"
                : when.Value.ToString("dddd, MMMM d");
            if (label != day)
            {
                day = label;
                var heading = label;
                rows.Add(Reuse(shown, "day " + heading, () => new MacRow(28, (g, r) =>
                {
                    using var grey = new SolidBrush(Mac.Grey);
                    g.DrawString(heading, Mac.Small, grey, new Rectangle(Ui.S(2), r.Y, r.Width, r.Height),
                        new StringFormat { LineAlignment = StringAlignment.Far });
                })));
            }

            var time = when?.ToString("h:mm tt") ?? "";
            var text = e.Text;
            var speed = e.InferenceSeconds > 0 ? $"{e.AudioSeconds / e.InferenceSeconds:F0}x" : "";
            // Keyed by what the row shows. The id would do for rows written here, but a row
            // copied from an old Mac file has none and is given a new one on every read.
            var key = $"{e.Timestamp} {text}";
            while (shown.ContainsKey(key)) key += " again";
            rows.Add(Reuse(shown, key, () => new DictationRow(time, text, speed)));
        }
        _historyRows = shown;

        // The Mac shows a centered glyph, a bold line and a grey sentence rather than an empty
        // list, so an app with nothing in it yet still looks finished.
        _empty.Visible = rows.Count == 0;
        _history.Visible = rows.Count > 0;
        _history.SetRows(rows);
    }

    /// The line over the Dictation list. With shared totals on and another computer in them, the
    /// words are every computer's and this PC's own numbers follow; otherwise it is this PC alone.
    private void ShowStats()
    {
        var all = _allHistory;
        var words = 0;
        var audio = 0.0;
        foreach (var e in all)
        {
            words += DailyTotals.WordCount(e.Text);
            audio += e.AudioSeconds;
        }
        var wpm = audio > 1 ? words / (audio / 60) : 0;
        var here = all.Count == 0
            ? "nothing yet"
            : $"{words:N0} words, {all.Count:N0} dictations, {wpm:F0} words per minute";

        var combined = TotalsSync.Shared.Combined(all);
        if (combined is { } c && (c.Computers > 1 || (c.Computers == 1 && c.This is null)))
        {
            _stats.Text = $"{c.Words:N0} words on {c.Computers} computer{(c.Computers == 1 ? "" : "s")}      this PC: {here}";
            return;
        }
        _stats.Text = all.Count == 0
            ? ""
            : $"{words:N0} words      {wpm:F0} words per minute      {all.Count:N0} dictations";
    }

    /// The paragraph under Shared totals in Settings.
    private void ShowSyncStatus()
    {
        if (_syncNote is null) return;
        var s = TotalsSync.Shared.Status;
        const string what = "Only counts leave this PC: a date, and the words, dictations and seconds of audio on it. What you said never does.";
        if (!s.On)
        {
            _syncNote.Text = "Off. Turned on, the total over the Dictation list adds up every computer you dictate on. " + what
                           + " To turn it on, put a sync.env file in %APPDATA%\\Lin Flow\\. The README shows what goes in it.";
            return;
        }
        if (s.Error is { } error)
        {
            _syncNote.Text = $"On, as {s.Device}, but the last try failed: {error}. The Dictation total counts this PC only until it works again.";
            return;
        }
        if (s.LastSyncUtc is not { } last)
        {
            _syncNote.Text = $"On, as {s.Device}. Waiting for the first sync. " + what;
            return;
        }
        var breakdown = TotalsSync.Shared.Combined(_allHistory)?.Breakdown();
        _syncNote.Text = $"On, as {s.Device}. Last synced at {last.ToLocalTime():h:mm tt}."
                       + (string.IsNullOrEmpty(breakdown) ? " " : $" {breakdown}. ") + what;
    }

    /// The row already showing under `key`, or a new one.
    private Control Reuse(Dictionary<string, Control> shown, string key, Func<Control> build)
    {
        if (!_historyRows.TryGetValue(key, out var row) || row.IsDisposed) row = build();
        shown[key] = row;
        return row;
    }

    // ---------- Dictionary ----------

    private Control BuildDictionary()
    {
        var page = new MacPage();

        // Two equal columns, Words and Corrections, the way the Mac lays them out. A
        // TableLayoutPanel rather than a SplitContainer: the Mac's two halves are fixed, and a
        // splitter would be a Windows affordance the original does not have.
        var columns = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            RowCount = 1,
            BackColor = Mac.Content,
        };
        columns.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        columns.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));

        // --- Words
        var left = new Panel { Dock = DockStyle.Fill, BackColor = Mac.Content, Padding = new Padding(0, 0, Ui.S(24), 0) };
        _newWord = new MacField("Add a word or name", 240);
        var addWord = new MacButton("Add");
        addWord.Click += (_, _) => AddWord();
        _newWord.Box.KeyDown += (_, k) => { if (k.KeyCode == Keys.Enter) { k.SuppressKeyPress = true; AddWord(); } };
        var wordBar = Row(_newWord, addWord);

        left.Controls.Add(_words);
        left.Controls.Add(wordBar);
        left.Controls.Add(new MacHeader("Words",
            "Names, products, jargon. The engine is primed with these and the cleanup pass snaps near-misses to this exact spelling."));

        // --- Corrections
        var right = new Panel { Dock = DockStyle.Fill, BackColor = Mac.Content };
        _heard = new MacField("Heard as", 130);
        _meant = new MacField("Should be", 130);
        _addRep = new MacButton("Add");
        _addRep.Click += (_, _) => SaveCorrection();
        _cancelRep = new MacButton("Cancel") { Visible = false };
        _cancelRep.Click += (_, _) => EndEdit();
        // Enter adds from either field, as it does on the Mac, or saves a correction being
        // changed. Esc leaves that correction as it was.
        foreach (var field in new[] { _heard, _meant })
            field.Box.KeyDown += (_, k) =>
            {
                if (k.KeyCode == Keys.Enter) { k.SuppressKeyPress = true; SaveCorrection(); }
                else if (k.KeyCode == Keys.Escape && _editing is not null) { k.SuppressKeyPress = true; EndEdit(); }
            };
        _repArrow = new Label
        {
            Text = "→", Font = Mac.Body, ForeColor = Mac.Grey, BackColor = Mac.Content,
            AutoSize = false, Size = Ui.S(22, 28), TextAlign = ContentAlignment.MiddleCenter,
        };
        _repBar = Row(_heard, _repArrow, _meant, _addRep, _cancelRep);
        // The fields share what the arrow and the buttons leave, as the Mac's do, so Cancel has
        // room beside Save. In a window too narrow for that, the buttons wrap to a second line
        // rather than being cut off at the edge.
        _repBar.WrapContents = true;
        _repBar.Resize += (_, _) => FitCorrectionFields();

        right.Controls.Add(_corrections);
        right.Controls.Add(_suggested);
        right.Controls.Add(_repBar);
        right.Controls.Add(new MacHeader("Corrections",
            "When Lin Flow hears the left, it writes the right. Whole words, any capitalization. Click one to change it."));

        columns.Controls.Add(left, 0, 0);
        columns.Controls.Add(right, 1, 0);
        page.Body.Controls.Add(columns);
        return page;
    }

    /// A left-to-right strip of controls that is exactly as tall as they are.
    private static FlowLayoutPanel Row(params Control[] items)
    {
        var bar = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            FlowDirection = FlowDirection.LeftToRight,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            BackColor = Mac.Content,
            Padding = Ui.S(new Padding(0, 0, 0, 12)),
            WrapContents = false,
        };
        foreach (var c in items) c.Margin = Ui.S(new Padding(0, 0, 8, 0));
        bar.Controls.AddRange(items);
        return bar;
    }

    private void AddWord()
    {
        var v = _newWord.Box.Text.Trim();
        if (v.Length == 0) return;
        var list = Glossary.Load();
        if (!list.Contains(v, StringComparer.OrdinalIgnoreCase)) list.Add(v);
        Glossary.SaveTerms(list);
        _newWord.Box.Clear();
        LoadDictionary();
    }

    /// Add, or Save while a correction is being changed. A change is written over the rule where
    /// it stands, so it keeps its line in replacements.txt and its place in the list. Deleting it
    /// and adding it again, the only way before 2026-09-25, moved it to the bottom.
    private void SaveCorrection()
    {
        var from = _heard.Box.Text.Trim();
        var to = _meant.Box.Text.Trim();
        if (from.Length == 0 || to.Length == 0) return;
        // Not marked learned, even when the rule was: what John types is his.
        var saved = new Replacement(from, to);
        // Read fresh: the learner may have written the file since these rows were drawn.
        var list = Glossary.LoadReplacements();
        var status = "";
        if (_editing is { } old)
        {
            // Nothing changed, so nothing is written, and a learned rule stays learned.
            if (from == old.From && to == old.To) { EndEdit(); return; }
            // A second rule for the same words would fight this one, so the change replaces it,
            // the same as adding one does.
            list.RemoveAll(r => r.Id == saved.Id && r.Id != old.Id);
            var at = list.FindIndex(r => r.Id == old.Id);
            // Gone from the file since the row was drawn, edited by hand say: keep the change anyway.
            if (at >= 0) list[at] = saved; else list.Add(saved);
            Log.Info($"changed a correction in the Dictionary: {old.From} => {old.To} is now {from} => {to}");
            status = $"Changed to “{from}” → “{to}”.";
        }
        else
        {
            list.RemoveAll(r => r.Id == saved.Id);
            list.Add(saved);
        }
        Glossary.SaveReplacements(list);
        EndEdit();
        _status.Text = status;
        LoadDictionary();
    }

    /// Puts a correction in the two fields to be changed. Its row stays marked, Add becomes
    /// Save, and Cancel or Esc leaves it as it was.
    private void BeginEdit(Replacement rep)
    {
        _editing = rep;
        _heard.Box.Text = rep.From;
        _meant.Box.Text = rep.To;
        _addRep.Text = "Save";
        FitToLabel(_addRep);
        _cancelRep.Visible = true;
        FitCorrectionFields();
        MarkEditing();
        _meant.Box.Focus();
        _meant.Box.Select(_meant.Box.TextLength, 0);
        _status.Text = $"Changing “{rep.From}” → “{rep.To}”. Enter saves it, Esc leaves it as it was.";
    }

    /// Back to adding: empty fields, Add, and no row marked.
    private void EndEdit()
    {
        _editing = null;
        _heard.Box.Clear();
        _meant.Box.Clear();
        _addRep.Text = "Add";
        FitToLabel(_addRep);
        _cancelRep.Visible = false;
        FitCorrectionFields();
        _status.Text = "";
        MarkEditing();
    }

    /// Gives the two fields equal halves of the width the arrow and the buttons leave. Whether
    /// Cancel is showing is read from the edit, not from Cancel.Visible, which is false whenever
    /// another section is on screen.
    private void FitCorrectionFields()
    {
        static int Take(Control c) => c.Width + c.Margin.Horizontal;
        var used = _repBar.Padding.Horizontal + Take(_repArrow) + Take(_addRep)
                 + (_editing is not null ? Take(_cancelRep) : 0)
                 + _heard.Margin.Horizontal + _meant.Margin.Horizontal;
        var each = Math.Max(Ui.S(90), (_repBar.ClientSize.Width - used) / 2);
        if (_heard.Width != each) _heard.Width = each;
        if (_meant.Width != each) _meant.Width = each;
    }

    /// Marks the row being changed. LoadDictionary builds the rows unmarked, so it calls this too.
    private void MarkEditing()
    {
        foreach (var row in _corrections.Controls.OfType<MacRow>())
            row.Selected = _editing is not null && row.Tag is Replacement r && r.Id == _editing.Id;
    }

    /// A button as wide as its label, the width MacButton's constructor gives it.
    private static void FitToLabel(MacButton button) =>
        button.Width = TextRenderer.MeasureText(button.Text, Mac.Body).Width + Ui.S(22);

    private void LoadDictionary()
    {
        LoadSuggested();
        _words.SetRows(Glossary.Load().Select(term => (Control)new MacRow(25, (g, r) =>
        {
            using var ink = new SolidBrush(Mac.Ink);
            g.DrawString(term, Mac.Body, ink, new Rectangle(Ui.S(2), r.Y, r.Width, r.Height),
                new StringFormat { LineAlignment = StringAlignment.Center, Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap });
        }, () => RemoveWord(term))));

        // DisplayOrder is what puts the newest learned rule at the top and the ones John wrote
        // himself below, in his order. Same call the Mac's Dictionary makes.
        _corrections.SetRows(Glossary.DisplayOrder(Glossary.LoadReplacements()).Select(rep =>
        {
            var row = new MacRow(27, (g, r) =>
            {
                var x = (float)Ui.S(2);
                x += Run(g, rep.From, Mac.Body, Mac.Grey, x, r) + Ui.S(8);
                x += Run(g, "→", Mac.Body, Mac.Grey, x, r) + Ui.S(8);
                x += Run(g, rep.To, Mac.Body, Mac.Ink, x, r) + Ui.S(8);
                if (!rep.Learned) return;
                // The "learned" pill: a rounded grey chip, the same one the Mac draws.
                var size = g.MeasureString("learned", Mac.Small);
                var pill = new Rectangle((int)x, r.Y + (r.Height - Ui.S(16)) / 2, (int)size.Width + Ui.S(12), Ui.S(16));
                Mac.Fill(g, pill, Ui.S(8), Mac.Badge);
                using var ink = new SolidBrush(Mac.Ink);
                g.DrawString("learned", Mac.Small, ink, pill,
                    new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center });
            }, () => RemoveCorrection(rep.From)) { Tag = rep, Cursor = Cursors.Hand };
            // A click anywhere but the trash opens the correction to be changed.
            row.Activated += () => BeginEdit(rep);
            return (Control)row;
        }));
        MarkEditing();
    }

    /// The rules waiting for a click, above the corrections themselves, as on the Mac: ones the
    /// learner was not sure enough to write, and ones a toast offered that John did not answer.
    /// The toast lasts seconds and he is mid-sentence by definition, so this is where they wait.
    private void LoadSuggested()
    {
        var pending = CorrectionLearning.Pending();
        _suggested.SuspendLayout();
        try
        {
            foreach (var c in _suggested.Controls.Cast<Control>().ToList()) c.Dispose();
            if (pending.Count == 0)
            {
                _suggested.Visible = false;
                return;
            }
            // Top-docked, so the last one added ends up highest: the gap under the rows first,
            // then the rows from the bottom up, then the heading.
            var controls = new List<Control> { new Panel { Dock = DockStyle.Top, Height = Ui.S(14), BackColor = Mac.Content } };
            for (var i = pending.Count - 1; i >= 0; i--)
            {
                var rule = pending[i];
                controls.Add(new SuggestionRow(rule,
                    // Deferred, because each of these ends in a reload that disposes this very row.
                    accept: () => BeginInvoke(() =>
                    {
                        CorrectionLearning.Accept(rule);
                        Log.Info($"added from the Dictionary's suggestions: {rule.From} => {rule.To}");
                        _status.Text = $"Added “{rule.From}” → “{rule.To}”.";
                    }),
                    dismiss: () => BeginInvoke(() =>
                    {
                        CorrectionLearning.Dismiss(rule);
                        Log.Info($"dismissed a suggestion: {rule.From} => {rule.To}");
                    })));
            }
            controls.Add(new Label
            {
                Text = "Suggested",
                Dock = DockStyle.Top,
                Font = Mac.BodySemibold,
                ForeColor = Mac.Ink,
                BackColor = Mac.Content,
                AutoSize = false,
                Height = Ui.S(24),
                TextAlign = ContentAlignment.MiddleLeft,
            });
            _suggested.Controls.AddRange(controls.ToArray());
            _suggested.Height = controls.Sum(c => c.Height);
            _suggested.Visible = true;
        }
        finally
        {
            _suggested.ResumeLayout(true);
        }
    }

    /// One rule waiting in pending-corrections.json: what Lin Flow heard, what John typed, and
    /// the Mac's two buttons.
    private sealed class SuggestionRow : Panel
    {
        private readonly Replacement _rule;
        private readonly MacButton _add = new("Add");
        private readonly MacButton _no = new("No");

        public SuggestionRow(Replacement rule, Action accept, Action dismiss)
        {
            _rule = rule;
            Dock = DockStyle.Top;
            Height = Ui.S(34);
            BackColor = Mac.Content;
            Mac.DoubleBuffer(this);
            _add.Click += (_, _) => accept();
            _no.Click += (_, _) => dismiss();
            Controls.Add(_add);
            Controls.Add(_no);
            Resize += (_, _) => Lay();
            Lay();
        }

        private void Lay()
        {
            _no.Location = new Point(Width - _no.Width - Ui.S(8), (Height - _no.Height) / 2);
            _add.Location = new Point(_no.Left - _add.Width - Ui.S(6), (Height - _add.Height) / 2);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            var g = e.Graphics;
            Mac.Smooth(g);
            var row = new Rectangle(0, 0, Width, Height);
            g.SetClip(new Rectangle(0, 0, Math.Max(0, _add.Left - Ui.S(8)), Height));
            var x = (float)Ui.S(2);
            x += Run(g, _rule.From, Mac.Body, Mac.Grey, x, row) + Ui.S(8);
            x += Run(g, "→", Mac.Body, Mac.Grey, x, row) + Ui.S(8);
            Run(g, _rule.To, Mac.Body, Mac.Ink, x, row);
            g.ResetClip();
            Mac.Rule(g, 0, Width - Ui.S(8), Height - Ui.S(1), Mac.Hairline);
        }
    }

    private void RemoveWord(string term)
    {
        var list = Glossary.Load();
        list.RemoveAll(t => string.Equals(t, term, StringComparison.OrdinalIgnoreCase));
        Glossary.SaveTerms(list);
        LoadDictionary();
    }

    private void RemoveCorrection(string from)
    {
        // The trash on the row being changed ends the change along with the rule.
        if (_editing?.From == from) EndEdit();
        var list = Glossary.LoadReplacements();
        list.RemoveAll(r => r.From == from);
        Glossary.SaveReplacements(list);
        LoadDictionary();
    }

    // ---------- Settings ----------

    /// The Mac's grouped inset list: a bold group title, a rounded card of rows with the label on
    /// the left and its control on the right, and a grey paragraph under the group explaining it.
    private Control BuildSettings()
    {
        var page = new MacPage();
        var stack = new Panel { Dock = DockStyle.Fill, BackColor = Mac.Content, AutoScroll = true };

        _hotkey = new ComboBox
        {
            DropDownStyle = ComboBoxStyle.DropDown,
            FlatStyle = FlatStyle.Flat,
            Font = Mac.Body,
            Width = Ui.S(190),
        };
        _hotkey.Items.AddRange(new object[]
        {
            "RightAlt", "LeftAlt", "RightCtrl", "LeftCtrl", "RightShift", "LeftShift",
            "CapsLock", "Menu", "LeftCtrl+LeftAlt", "LeftCtrl+LeftShift", "MiddleMouse",
        });
        _hotkey.Text = HotkeySettings.NameOf(HotkeySettings.Load());

        _saveKey = new MacButton("Save");
        _saveKey.Click += (_, _) => SaveHotkey(_hotkey.Text);
        _recordKey = new MacButton("Record");
        _recordKey.Click += (_, _) => RecordHotkey();

        var dictation = new MacCard();
        dictation.Controls.Add(new MacCardRow("Save the talk key", _saveKey, rule: false));
        dictation.Controls.Add(new MacCardRow("Record the talk key", _recordKey));
        dictation.Controls.Add(new MacCardRow("Hold to talk", _hotkey));

        var openData = new MacButton("Open");
        openData.Click += (_, _) => System.Diagnostics.Process.Start("explorer.exe", Paths.DataDir);
        var openLog = new MacButton("Open");
        openLog.Click += (_, _) =>
        {
            if (File.Exists(Paths.LogFile))
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Paths.LogFile) { UseShellExecute = true });
        };
        var app = new MacCard();
        app.Controls.Add(new MacCardRow("Log", openLog, rule: false));
        app.Controls.Add(new MacCardRow("Data folder", openData));

        // The Mac's picker and its three labels. Saved as soon as it changes, and read at every
        // paste, so the next dictation already follows it.
        _learn = new ComboBox
        {
            DropDownStyle = ComboBoxStyle.DropDownList,
            FlatStyle = FlatStyle.Flat,
            Font = Mac.Body,
            Width = Ui.S(190),
        };
        foreach (var mode in LearnSettings.All) _learn.Items.Add(LearnSettings.Label(mode));
        _learn.SelectedIndex = Math.Max(0, LearnSettings.All.ToList().IndexOf(LearnSettings.Load()));
        _learn.SelectedIndexChanged += (_, _) => SaveLearnMode();
        var learning = new MacCard();
        learning.Controls.Add(new MacCardRow("When you fix pasted text", _learn, rule: false));

        // Shared totals: a status paragraph and a button that sends and reads now, rather than at
        // the next dictation or the next time the window opens.
        var syncNow = new MacButton("Sync now");
        syncNow.Click += (_, _) =>
        {
            _syncNote.Text = "Syncing...";
            TotalsSync.Shared.RequestPush();
            TotalsSync.Shared.RequestPull();
        };
        var shared = new MacCard();
        shared.Controls.Add(new MacCardRow("Send and read the totals now", syncNow, rule: false));
        _syncNote = new MacNote("");

        // Added top-docked, so the last one added ends up highest.
        stack.Controls.Add(new MacNote("Transcripts, audio, the dictionary and the log live in the data folder and never leave this PC."));
        stack.Controls.Add(app);
        stack.Controls.Add(Group("App"));
        stack.Controls.Add(_syncNote);
        stack.Controls.Add(shared);
        stack.Controls.Add(Group("Shared totals"));
        stack.Controls.Add(new MacNote(
            "For 15 seconds after a paste, Lin Flow reads back the field it pasted into and turns a word you fix there "
          + "into a correction. A note at the bottom of the screen says what it learned, and anything it was not sure "
          + "of waits under Suggested in the Dictionary."));
        stack.Controls.Add(learning);
        stack.Controls.Add(new MacNote(
            "Record takes whatever you press together next, any keys or a mouse button, and Save makes it the talk key. "
          + "You can also type one, joining keys with +, for example LeftCtrl+LeftAlt. Keys still reach the app you are in, "
          + "so pick ones you do not type with: Left Alt alone opens the menu bar, and Left Ctrl alone starts a recording "
          + "on every Ctrl+C. A mouse button is kept from the app, but a quick click still clicks. Fn can never be used, "
          + "on any layout: it is handled inside the keyboard and never reaches Windows."));
        stack.Controls.Add(dictation);
        stack.Controls.Add(Group("Dictation"));

        page.Body.Controls.Add(stack);
        return page;
    }

    /// The bold line above a settings card.
    private static Label Group(string text) => new()
    {
        Text = text,
        Dock = DockStyle.Top,
        Font = Mac.BodySemibold,
        ForeColor = Mac.Ink,
        BackColor = Mac.Content,
        AutoSize = false,
        Height = Ui.S(28),
        TextAlign = ContentAlignment.BottomLeft,
        Padding = new Padding(Ui.S(2), 0, 0, Ui.S(4)),
    };

    private void SaveLearnMode()
    {
        var mode = LearnSettings.All[Math.Max(0, _learn.SelectedIndex)];
        try
        {
            LearnSettings.Save(mode);
            Log.Info($"settings: {LearnSettings.Key} is now {LearnSettings.Name(mode)}");
            _status.Text = $"When you fix pasted text: {LearnSettings.Label(mode)}.";
        }
        catch (Exception e)
        {
            Log.Info($"could not save the learning setting: {e.Message}");
            MessageBox.Show($"Could not save the setting: {e.Message}", "Lin Flow");
        }
    }

    /// Writes only the hotkey key, leaving the notetaker's keys in settings.json alone.
    private void SaveHotkey(string value)
    {
        var parsed = HotkeySettings.Parse(value);
        var readable = HotkeySettings.NameOf(parsed);
        try
        {
            var node = File.Exists(Paths.SettingsFile)
                ? System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(Paths.SettingsFile)) as System.Text.Json.Nodes.JsonObject
                : new System.Text.Json.Nodes.JsonObject();
            node ??= new System.Text.Json.Nodes.JsonObject();
            node["hotkey"] = value.Trim();
            Paths.WriteAtomic(Paths.SettingsFile, node.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
            Program.RebindHotkey();
            _status.Text = $"Hold to talk is now {readable}.";
            _hotkey.Text = readable;
        }
        catch (Exception e)
        {
            Log.Info($"could not save the hotkey: {e.Message}");
            MessageBox.Show($"Could not save the hotkey: {e.Message}", "Lin Flow");
        }
    }

    /// Records the next keys or mouse button pressed together into the box, for Save to keep. The
    /// talk key is off while it records, so pressing it to be recorded does not start a dictation,
    /// and it comes back as it was unless Save is pressed. Pressed again, Record cancels.
    private void RecordHotkey()
    {
        if (_capture is not null)
        {
            EndRecording(null);
            return;
        }
        Program.PauseHotkey();
        try
        {
            _capture = new HotkeyCapture(chord =>
            {
                // On a pool thread; the window, and the rebind, belong to the UI thread.
                try { BeginInvoke(new Action(() => EndRecording(chord))); }
                catch (Exception e) { Log.Info($"could not show the recorded key: {e.Message}"); }
            });
        }
        catch (Exception e)
        {
            Log.Info($"could not record a key: {e.Message}");
            Program.RebindHotkey();
            _status.Text = "Could not record a key.";
            return;
        }
        _recordKey.Text = "Cancel";
        _saveKey.Enabled = false;
        _status.Text = "Press the keys or mouse button you want, together, then let go. Esc cancels.";
    }

    private void EndRecording(int[]? chord)
    {
        _capture?.Dispose();
        _capture = null;
        _recordKey.Text = "Record";
        _saveKey.Enabled = true;
        Program.RebindHotkey();
        if (chord is null)
        {
            _status.Text = "Nothing recorded. The talk key is unchanged.";
            return;
        }
        _hotkey.Text = HotkeySettings.NameOf(chord);
        _status.Text = $"Recorded {_hotkey.Text}. Press Save to make it the talk key.";
    }
}
