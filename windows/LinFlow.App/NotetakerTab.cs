using LinFlow.Core;
using LinFlow.Engine;

namespace LinFlow.App;

/// The meeting notetaker: record a call, watch the transcript arrive, keep the audio.
///
/// It was built on 2026-09-17 as `linflow meeting`, a console command, and John asked for it in
/// the window on 2026-09-18 - twice in four minutes, which is what a missing feature sounds like.
/// The recording, the live transcript, the running notes and the summary are exactly the CLI's
/// flow; only the front is new, so a note started here and a note started in a console are the
/// same folder with the same file names the Mac writes.
///
/// Everything that can take a while - stopping, re-transcribing the saved audio, the summary -
/// runs off the UI thread, and the recorder raises its events on its own threads, so every line
/// that touches a control goes through On().
internal sealed class NotetakerTab : Panel
{
    private readonly NotesStore _store = new();
    private readonly MacList _notes = new();
    private readonly List<MacRow> _noteRows = new();
    private readonly TextBox _title = new();
    private readonly Button _record = Dashboard.Action("Start recording");
    private readonly Label _state = new();
    private readonly ListView _transcript = new();
    private readonly TextBox _written = new();
    private readonly Label _writtenLabel = new();
    private readonly System.Windows.Forms.Timer _clock = new() { Interval = 1000 };

    private MeetingRecorder? _recorder;
    private RunningNotesTaker? _taker;
    private OllamaClient? _writer;
    private MeetingNote? _recording;
    private string? _viewing;
    private bool _busy;

    public NotetakerTab()
    {
        Text = "Notetaker";

        var split = new SplitContainer { Dock = DockStyle.Fill, Orientation = Orientation.Vertical };
        var placed = false;
        var placing = false;
        split.Layout += (_, _) =>
        {
            if (placed || placing) return;
            placing = true;
            try { placed = Ui.Place(split, Ui.S(280), Ui.S(200), Ui.S(360)); }
            finally { placing = false; }
        };

        split.Panel1.Controls.Add(BuildList());
        split.Panel2.Controls.Add(BuildDetail());
        Controls.Add(split);

        // Only while something is being recorded. ShowState reads the viewed note's JSON off
        // disk, so ticking it when nothing is happening meant a file open, read and parse every
        // second for as long as the app was up - on the UI thread - to redraw a line that cannot
        // have changed. Everything that does change the line calls ShowState itself.
        _clock.Tick += (_, _) => { if (_recorder is { IsRecording: true }) ShowState(); };
        _clock.Start();

        // A meeting that a crash, a force quit or a dead battery left open is repaired and closed
        // here, the same as the Mac does at launch and the CLI does before recording. Off the UI
        // thread: it re-reads every unfinished WAV.
        Task.Run(() =>
        {
            try
            {
                foreach (var n in _store.RecoverUnfinished())
                    Log.Info($"notetaker: closed a meeting an earlier run never stopped: \"{n.Title}\" ({(int)n.DurationSeconds}s)");
                On(Reload);
            }
            catch (Exception e) { Log.Info($"notetaker: recovery failed: {e.Message}"); }
        });
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _clock.Dispose();
            // A recorder left running would hold the microphone after the window went away.
            try { _recorder?.Dispose(); } catch (Exception e) { Log.Info($"notetaker: {e.Message}"); }
            try { _taker?.Dispose(); } catch (Exception e) { Log.Info($"notetaker: {e.Message}"); }
        }
        base.Dispose(disposing);
    }

    // ---------- the list of meetings ----------

    private Control BuildList()
    {
        var host = new Panel { Dock = DockStyle.Fill, BackColor = Mac.Content, Padding = Ui.S(new Padding(18, 20, 10, 8)) };

        // The Mac puts "Meetings" and a "+ New" button on one line above the list. New here means
        // clearing the title box for a fresh recording rather than creating an empty folder: a
        // note exists once it has audio.
        var heading = new Panel { Dock = DockStyle.Top, Height = Ui.S(38), BackColor = Mac.Content };
        var title = new Label
        {
            Text = "Meetings", Font = Mac.Header, ForeColor = Mac.Ink, BackColor = Mac.Content,
            AutoSize = false, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft,
        };
        var fresh = new MacButton("+ New") { Dock = DockStyle.Right };
        fresh.Click += (_, _) =>
        {
            _viewing = null;
            foreach (var r in _noteRows) r.Selected = false;
            _title.Clear();
            _transcript.Items.Clear();
            _written.Text = "";
            _title.Focus();
            ShowState();
        };
        heading.Controls.Add(title);
        heading.Controls.Add(fresh);

        host.Controls.Add(_notes);
        host.Controls.Add(heading);
        return host;
    }

    /// The recording is the product, so deleting one asks first and defaults to No.
    private void Delete(string? id = null)
    {
        id ??= _viewing;
        if (id is null || id == _recording?.Id) return;
        var note = _store.Load(id);
        var answer = MessageBox.Show(
            $"Delete \"{note?.Title ?? id}\" and its recording? This cannot be undone.",
            "Lin Flow", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
        if (answer != DialogResult.Yes) return;
        try
        {
            Directory.Delete(_store.Folder(id), recursive: true);
            _viewing = null;
            _transcript.Items.Clear();
            _written.Text = "";
            Reload();
        }
        catch (Exception e)
        {
            Log.Info($"notetaker: could not delete {id}: {e.Message}");
            MessageBox.Show($"Could not delete it: {e.Message}", "Lin Flow");
        }
    }

    // ---------- the meeting itself ----------

    private Control BuildDetail()
    {
        var host = new Panel { Dock = DockStyle.Fill, BackColor = Mac.Content, Padding = Ui.S(new Padding(20, 20, 20, 8)) };

        var top = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            FlowDirection = FlowDirection.LeftToRight,
            BackColor = Mac.Content,
            WrapContents = false,
        };
        _title.PlaceholderText = "What is this meeting?";
        var titleFrame = new MacFrame(_title, 300, 28) { Margin = Ui.S(new Padding(0, 0, 10, 10)) };
        _record.Margin = Ui.S(new Padding(0, 1, 0, 10));
        _record.Click += (_, _) => Toggle();
        top.Controls.Add(titleFrame);
        top.Controls.Add(_record);

        _state.Dock = DockStyle.Top;
        _state.Height = Ui.S(30);
        _state.Font = Mac.Small;
        _state.ForeColor = Mac.Grey;
        _state.BackColor = Mac.Content;
        _state.Padding = Ui.S(new Padding(2, 6, 0, 0));

        var lower = new SplitContainer { Dock = DockStyle.Fill, Orientation = Orientation.Horizontal, BackColor = Mac.Content };
        var placed = false;
        var placing = false;
        lower.Layout += (_, _) =>
        {
            if (placed || placing) return;
            placing = true;
            try { placed = Ui.Place(lower, (int)(lower.Height * 0.62), Ui.S(120), Ui.S(90)); }
            finally { placing = false; }
        };

        _transcript.Dock = DockStyle.Fill;
        _transcript.View = View.Details;
        _transcript.FullRowSelect = true;
        // The Mac's transcript has no column headers and no border; a time, a name and a
        // sentence do not need labelling. ListView draws its own header and frame through the
        // OS theme, and turning them off is as close as it goes.
        _transcript.HeaderStyle = ColumnHeaderStyle.None;
        _transcript.BorderStyle = BorderStyle.None;
        _transcript.BackColor = Mac.Content;
        _transcript.ForeColor = Mac.Ink;
        _transcript.Font = Mac.Body;
        _transcript.Columns.Add("At", Ui.S(60));
        _transcript.Columns.Add("Who", Ui.S(60));
        _transcript.Columns.Add("Said", Ui.S(420));
        _transcript.Resize += (_, _) => FitSaidColumn();
        lower.Panel1.Controls.Add(_transcript);

        _writtenLabel.Dock = DockStyle.Top;
        _writtenLabel.Height = Ui.S(26);
        _writtenLabel.Text = "Notes";
        _writtenLabel.Font = Mac.BodySemibold;
        _writtenLabel.ForeColor = Mac.Ink;
        _writtenLabel.BackColor = Mac.Content;
        _writtenLabel.Padding = Ui.S(new Padding(2, 5, 0, 0));
        _written.Dock = DockStyle.Fill;
        _written.Multiline = true;
        _written.ReadOnly = true;
        _written.ScrollBars = ScrollBars.Vertical;
        _written.BorderStyle = BorderStyle.None;
        _written.BackColor = Mac.Content;
        _written.ForeColor = Mac.Ink;
        _written.Font = Mac.Body;
        lower.Panel2.Controls.Add(_written);
        lower.Panel2.Controls.Add(_writtenLabel);

        host.Controls.Add(lower);
        host.Controls.Add(_state);
        host.Controls.Add(top);
        return host;
    }

    private void FitSaidColumn()
    {
        if (_transcript.Columns.Count < 3) return;
        var room = _transcript.ClientSize.Width - _transcript.Columns[0].Width
                 - _transcript.Columns[1].Width - Ui.S(24);
        if (room > Ui.S(160)) _transcript.Columns[2].Width = room;
    }

    // ---------- start and stop ----------

    private void Toggle()
    {
        if (_busy) return;
        if (_recorder is { IsRecording: true }) Stop();
        else Start();
    }

    private void Start()
    {
        if (Program.SharedEngine() is null)
        {
            MessageBox.Show("The model is still loading. Give it a moment and press it again.", "Lin Flow");
            return;
        }

        var title = _title.Text.Trim();
        if (title.Length == 0) title = $"Meeting {DateTime.Now:MMM d, h:mm tt}";

        try
        {
            Glossary.SeedIfMissing();
            var cleaner = new TextCleaner(Glossary.Load(), Glossary.LoadReplacements()) { SpokenCommands = false };
            var note = _store.Create(title);
            var recorder = new MeetingRecorder(_store, note, Program.SharedEngine, cleaner);
            recorder.SegmentAdded += s => On(() => AddSegment(s));
            recorder.Failed += m => On(() => { Log.Info($"notetaker: {m}"); _state.Text = m; });

            // Both sides of the call: the microphone, and through WASAPI loopback whatever the PC
            // is playing.
            recorder.Start(useMicrophone: true, useSystemAudio: true, keepAudio: true);

            _recorder = recorder;
            _recording = note;
            _viewing = note.Id;
            _transcript.Items.Clear();
            _written.Text = "";
            _writtenLabel.Text = "Running notes";
            _title.Enabled = false;
            _record.Text = "Stop recording";
            Log.Info($"notetaker: recording \"{title}\" -> {_store.Folder(note.Id)}");
            Reload();
            StartRunningNotes(note, title);
        }
        catch (Exception e)
        {
            Log.Info($"notetaker: could not start: {e}");
            MessageBox.Show($"Could not start recording: {e.Message}", "Lin Flow");
        }
        ShowState();
    }

    /// Running notes need a local model behind Ollama, which Windows does not come with. Its
    /// absence must never stop a meeting being recorded: the recording is the product.
    private void StartRunningNotes(MeetingNote note, string title)
    {
        Task.Run(async () =>
        {
            try
            {
                var (host, model) = NoteWriterSettings.Load();
                var candidate = new OllamaClient(host, model);
                var problem = await candidate.CheckAsync();
                if (problem is not null)
                {
                    Log.Info($"notetaker: running notes are off this meeting: {problem}");
                    On(() => _writtenLabel.Text = $"Running notes - off ({problem})");
                    return;
                }
                var taker = new RunningNotesTaker(_store, note.Id, candidate, title);
                taker.NotesAdded += block => On(() => Append(block));
                taker.Failed += m => Log.Info($"notetaker: notes: {m}");
                taker.Start();
                _writer = candidate;
                _taker = taker;
                On(() => _writtenLabel.Text = $"Running notes - {candidate.Name}");
            }
            catch (Exception e)
            {
                Log.Info($"notetaker: running notes unavailable: {e.Message}");
            }
        });
    }

    private void Stop()
    {
        var recorder = _recorder;
        var note = _recording;
        if (recorder is null || note is null) return;

        _busy = true;
        _record.Enabled = false;
        _state.Text = "Stopping...";

        Task.Run(() =>
        {
            try
            {
                recorder.Stop();
                var saved = _store.Load(note.Id) ?? note;
                Log.Info($"notetaker: saved {(int)saved.DurationSeconds}s to {_store.Folder(note.Id)}");

                var taker = _taker;
                if (taker is not null)
                {
                    taker.StopAsync().GetAwaiter().GetResult();   // the last stretch gets its bullets
                    taker.Dispose();
                }

                // The live transcript was cut wherever the stream paused. This reads the saved
                // audio whole, which is better text and the reason the audio is kept at all.
                var engine = Program.SharedEngine();
                if (engine is not null)
                {
                    On(() => _state.Text = "Transcribing the recording...");
                    var cleaner = new TextCleaner(Glossary.Load(), Glossary.LoadReplacements()) { SpokenCommands = false };
                    var segments = NoteTranscriber.TranscribeNote(
                        _store, note.Id, engine, cleaner,
                        p => On(() => _state.Text = $"Transcribing the recording... {p}"));
                    _store.ReplaceTranscript(segments, note.Id, NoteTranscriber.DisplayName(engine));
                }

                var writer = _writer;
                if (writer is not null)
                {
                    On(() => _state.Text = "Writing the summary...");
                    var all = _store.Transcript(note.Id);
                    var last = all.Where(s => s.End >= (all.Count > 0 ? all[^1].End : 0) - 180).ToList();
                    var summary = writer
                        .SummaryAsync(_store.RunningNotes(note.Id), NotesStore.TranscriptText(last), saved.Title)
                        .GetAwaiter().GetResult();
                    if (summary.Length > 0)
                    {
                        _store.SaveSummary(summary, note.Id);
                        saved.SummaryModel = writer.Name;
                        _store.Save(saved);
                    }
                }

                File.WriteAllText(Path.Combine(_store.Folder(note.Id), "note.md"), _store.Markdown(saved));
            }
            catch (Exception e)
            {
                Log.Info($"notetaker: stopping failed: {e}");
                On(() => _state.Text = $"Something went wrong stopping: {e.Message}");
            }
            finally
            {
                On(() =>
                {
                    recorder.Dispose();
                    _recorder = null;
                    _recording = null;
                    _taker = null;
                    _writer = null;
                    _busy = false;
                    _record.Enabled = true;
                    _record.Text = "Start recording";
                    _title.Enabled = true;
                    _title.Text = "";
                    var id = note.Id;
                    _viewing = null;
                    Reload();
                    ShowNote(id);
                });
            }
        });
    }

    // ---------- filling the panes ----------

    public void Reload()
    {
        try
        {
            _noteRows.Clear();
            foreach (var n in _store.List())
            {
                var when = NotesStore.Parse(n.CreatedAt).ToLocalTime().ToString("MMM d, h:mm tt");
                var minutes = n.DurationSeconds >= 60 ? $"{n.DurationSeconds / 60:F0} min" : $"{n.DurationSeconds:F0} s";
                var detail = n.Id == _recording?.Id ? $"{when} · recording" : $"{when} · {minutes}";
                var id = n.Id;
                var name = n.Title;
                // Title on top, the when and how long under it in grey - the Mac's meeting row.
                var row = new MacRow(46, (g, r) =>
                {
                    using var ink = new SolidBrush(Mac.Ink);
                    using var grey = new SolidBrush(Mac.Grey);
                    g.DrawString(name, Mac.Body, ink, new Rectangle(Ui.S(10), r.Y + Ui.S(6), r.Width - Ui.S(12), Ui.S(18)),
                        new StringFormat { Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap });
                    g.DrawString(detail, Mac.Small, grey, new Rectangle(Ui.S(10), r.Y + Ui.S(24), r.Width - Ui.S(12), Ui.S(16)),
                        new StringFormat { Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap });
                }, () => Delete(id));
                row.Activated += () =>
                {
                    foreach (var other in _noteRows) other.Selected = false;
                    row.Selected = true;
                    ShowNote(id);
                };
                row.Selected = id == _viewing;
                _noteRows.Add(row);
            }

            if (_noteRows.Count == 0)
                _notes.SetRows(new Control[] { new MacRow(56, (g, r) =>
                {
                    using var grey = new SolidBrush(Mac.Grey);
                    g.DrawString("No meetings yet.", Mac.Body, grey, new Rectangle(Ui.S(10), r.Y, r.Width, r.Height),
                        new StringFormat { LineAlignment = StringAlignment.Center });
                }) });
            else
                _notes.SetRows(_noteRows);
        }
        catch (Exception e)
        {
            Log.Info($"notetaker: could not list the meetings: {e.Message}");
        }
        ShowState();
    }

    /// Shows a note that is not the one being recorded: its transcript, and its summary if it has
    /// one, otherwise the running notes.
    private void ShowNote(string? id)
    {
        if (id is null || id == _recording?.Id) return;
        _viewing = id;
        try
        {
            _transcript.BeginUpdate();
            _transcript.Items.Clear();
            foreach (var s in _store.Transcript(id))
                _transcript.Items.Add(new ListViewItem(new[] { s.TimestampLabel, s.Speaker, s.Text }));
            _transcript.EndUpdate();
            FitSaidColumn();

            var summary = _store.Summary(id);
            var running = _store.RunningNotes(id);
            _writtenLabel.Text = summary is not null ? "Summary" : "Running notes";
            _written.Text = (summary ?? running).Replace("\n", Environment.NewLine);
        }
        catch (Exception e)
        {
            Log.Info($"notetaker: could not open {id}: {e.Message}");
        }
        ShowState();
    }

    private void AddSegment(TranscriptSegment s)
    {
        var row = new ListViewItem(new[] { s.TimestampLabel, s.Speaker, s.Text });
        _transcript.Items.Add(row);
        row.EnsureVisible();
        FitSaidColumn();
    }

    private void Append(string block)
    {
        var text = block.TrimEnd().Replace("\n", Environment.NewLine);
        _written.AppendText(_written.TextLength == 0 ? text : Environment.NewLine + text);
    }

    private void ShowState()
    {
        if (_busy) return;
        if (_recorder is { IsRecording: true } r)
        {
            var t = TimeSpan.FromSeconds(r.Elapsed);
            _state.Text = $"Recording  {t:hh\\:mm\\:ss}   you and what the PC plays";
            _state.ForeColor = Color.FromArgb(190, 40, 40);
            return;
        }
        _state.ForeColor = SystemColors.ControlText;
        if (_viewing is null) { _state.Text = "Pick a meeting, or start a new one."; return; }
        var note = _store.Load(_viewing);
        if (note is null) { _state.Text = ""; return; }
        var length = TimeSpan.FromSeconds(note.DurationSeconds);
        var model = note.TranscriptModel is null ? "" : $"   transcribed with {note.TranscriptModel}";
        _state.Text = $"{note.Title}   {length:hh\\:mm\\:ss}{model}";
    }

    /// The recorder, the notes taker and the stop task all run on their own threads; a control may
    /// only be touched on the thread that made it.
    private void On(Action work)
    {
        if (IsDisposed || !IsHandleCreated) return;
        try { BeginInvoke(work); }
        catch (Exception e) { Log.Info($"notetaker: {e.Message}"); }
    }
}
