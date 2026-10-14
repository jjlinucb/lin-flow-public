using System.Collections.Concurrent;
using LinFlow.Core;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wave;

namespace LinFlow.Engine;

/// One meeting: the microphone (you) and what the machine plays (everyone else on the call)
/// captured side by side through WASAPI, each streamed through its own LiveSegmenter for live
/// lines, the audio kept as WAV. Ported from ../../Sources/LinFlowCore/MeetingRecorder.swift,
/// where the Core Audio process tap is replaced by WasapiLoopbackCapture on the default output.
///
/// The recording is the product and the live transcript is a view of it, so:
/// - audio goes to disk as it arrives through a WavWriter whose header stays valid, so a crash
///   costs at most the last second instead of the whole meeting;
/// - each track is kept on the note's clock: a slow start, a stall or a device switch is filled
///   with silence, so "You" and "Others" line up in any editor and in the transcript;
/// - a source that stops delivering is restarted (either when nothing has arrived for 3 s, the
///   mic when the default input changes, the loopback when the default output changes), and one
///   failing source never takes the other down with it;
/// - a second session on the same note appends to its audio instead of overwriting it.
/// Every gap, restart and failure is also written to the note's events.log.
///
/// Like the rest of the Windows audio layer this was written on a Mac and has never executed on
/// Windows; `linflow meeting` is where it first will. The WASAPI-independent parts (the clock,
/// the segmenter, the writer, the regions) run in the tests on any machine.
public sealed class MeetingRecorder : IDisposable
{
    public enum Source { Mic, System }

    public MeetingNote Note { get; private set; }
    public bool IsRecording { get; private set; }
    /// Zero of the note's clock: this session's start, minus whatever was recorded before.
    public DateTime? StartedAt { get; private set; }
    /// A source is stale when nothing has arrived for this long.
    public double StaleAfterSeconds { get; set; } = 3;
    /// WASAPI loopback only delivers buffers while something renders on the device. A silent
    /// stream of our own keeps it flowing, so a quiet stretch of a call is recorded as silence
    /// with the right timing rather than as a hole, and the watchdog can trust the cadence.
    public bool KeepLoopbackAlive { get; set; } = true;

    /// A live line, from the inference thread.
    public event Action<TranscriptSegment>? SegmentAdded;
    /// RMS of each chunk, from the audio thread.
    public event Action<Source, float>? Level;
    /// Something the user should see: a source that failed, a disk that is full.
    public event Action<string>? Failed;

    private sealed class Track
    {
        public readonly Source Source;
        public readonly string Speaker;
        public readonly LiveSegmenter Segmenter = new();
        public WavWriter? Writer;
        public StreamingResampler? Resampler;
        public WasapiCapture? Capture;
        public WasapiOut? KeepAlive;
        public string Device = "";
        public bool Wanted, SawFirstChunk, Failing, WriteFailing, WarnedFormat;
        public DateTime? LastChunkAt, RestartAt, LastRestartAt;
        public string RestartReason = "";
        public double Backoff = 2;
        public long FedThisSession;
        public Track(Source source, string speaker) { Source = source; Speaker = speaker; }
    }

    private readonly NotesStore _store;
    private readonly Func<ParakeetEngine?> _engine;
    private readonly TextCleaner _cleaner;
    private readonly Dictionary<Source, Track> _tracks = new();
    /// All per-track state, file writes and restarts happen on this one thread, in order.
    private readonly BlockingCollection<Action> _work = new();
    private readonly BlockingCollection<(Track Track, int Start, float[] Samples)> _infer = new();
    private readonly Thread _worker;
    private readonly Thread _inferThread;
    private Timer? _watchdog;
    private DateTime _clockStart, _sessionStart;
    private double _previous;
    private MMDeviceEnumerator? _enumerator;
    private DeviceWatcher? _watcher;
    private bool _disposed;

    public MeetingRecorder(NotesStore store, MeetingNote note, Func<ParakeetEngine?> engine, TextCleaner cleaner)
    {
        _store = store;
        Note = note;
        _engine = engine;
        _cleaner = cleaner;
        foreach (var (source, speaker) in new[] { (Source.Mic, "You"), (Source.System, "Others") })
        {
            var t = new Track(source, speaker);
            t.Segmenter.Segment += (start, samples) => { if (!_infer.IsAddingCompleted) _infer.Add((t, start, samples)); };
            _tracks[source] = t;
        }
        _worker = new Thread(() =>
        {
            foreach (var action in _work.GetConsumingEnumerable())
            {
                try { action(); } catch (Exception e) { Log.Info($"meeting: worker: {e.Message}"); }
            }
        }) { IsBackground = true, Name = "linflow-meeting-io" };
        _inferThread = new Thread(InferLoop) { IsBackground = true, Name = "linflow-meeting-infer" };
        _worker.Start();
        _inferThread.Start();
    }

    public static string Name(Source s) => s == Source.Mic ? "mic" : "system";

    public double Elapsed => StartedAt is { } s ? (DateTime.UtcNow - s).TotalSeconds : Note.DurationSeconds;

    /// Starts every source asked for. Throws only if none of them could start; a source that
    /// fails while the other works is reported through `Failed` and retried by the watchdog.
    public void Start(bool useMicrophone, bool useSystemAudio, bool keepAudio)
    {
        if (IsRecording || !(useMicrophone || useSystemAudio)) return;
        // Re-read the note first: it may have been renamed, and its duration is where the
        // clock resumes if it was recorded before.
        Note = _store.Load(Note.Id) ?? Note;
        _previous = Math.Max(0, Note.DurationSeconds);
        _sessionStart = DateTime.UtcNow;
        _clockStart = _sessionStart.AddSeconds(-_previous);
        StartedAt = _clockStart;
        if (keepAudio)
        {
            Directory.CreateDirectory(_store.Folder(Note.Id));
            CheckFreeSpace();
        }
        IsRecording = true;   // before the sources start, or their first chunks are dropped
        var started = new List<Source>();
        var failed = new List<(Source Source, Exception Error)>();
        RunSync(() =>
        {
            foreach (var source in new[] { Source.System, Source.Mic })
            {
                if (source == Source.System ? !useSystemAudio : !useMicrophone) continue;
                var t = _tracks[source];
                t.Wanted = true;
                if (keepAudio)
                {
                    try { t.Writer = new WavWriter(_store.AudioPath(Note.Id, Name(source)), append: true); }
                    catch (Exception e) { Log.Info($"meeting: could not open {Name(source)} audio file: {e.Message}"); failed.Add((source, e)); }
                }
                try { StartSource(t); started.Add(source); }
                catch (Exception e)
                {
                    failed.Add((source, e));
                    t.RestartAt = DateTime.UtcNow.AddSeconds(t.Backoff);
                    t.RestartReason = "retrying after: " + e.Message;
                }
            }
        });
        if (started.Count == 0)
        {
            IsRecording = false;
            RunSync(() => { StopSources(); CloseWriters(); });
            throw failed.Count > 0 ? failed[0].Error : new InvalidOperationException("nothing to record");
        }
        Note.UsedMicrophone = useMicrophone;
        Note.UsedSystemAudio = useSystemAudio;
        _store.Save(Note);
        _store.AppendEvent(_previous > 0
            ? $"recording resumed at {(int)_previous} s (mic={useMicrophone}, system={useSystemAudio})"
            : $"recording started (mic={useMicrophone}, system={useSystemAudio}, audio kept={keepAudio})", Note.Id);
        foreach (var f in failed) Report(_tracks[f.Source], $"{(f.Source == Source.Mic ? "The microphone" : "System audio")} did not start ({f.Error.Message}). Lin Flow keeps trying every few seconds.");
        StartDeviceWatcher();
        _watchdog = new Timer(_ => _work.Add(Tick), null, 1000, 1000);
        Log.Info($"meeting note {Note.Id} recording (mic={useMicrophone}, system={useSystemAudio}, resumed at {(int)_previous} s)");
    }

    /// Stops capture, flushes the last segments, finalizes files and metadata. Blocks until the
    /// last live line has been transcribed (at most a minute).
    public void Stop()
    {
        if (!IsRecording) return;
        IsRecording = false;
        _watchdog?.Dispose(); _watchdog = null;
        StopDeviceWatcher();
        RunSync(StopSources);   // every chunk already queued is written before this returns
        var current = _store.Load(Note.Id) ?? Note;   // keep a title typed during the meeting
        current.EndedAt = NotesStore.Now();
        current.DurationSeconds = (DateTime.UtcNow - _clockStart).TotalSeconds;
        Note = current;
        _store.Save(Note);
        _store.AppendEvent($"recording stopped at {(int)Note.DurationSeconds} s", Note.Id);
        RunSync(() => { foreach (var t in _tracks.Values) t.Segmenter.Finish(); });
        _infer.CompleteAdding();
        if (!_inferThread.Join(TimeSpan.FromSeconds(60))) Log.Info("meeting: the last live line did not finish in a minute; moving on");
        RunSync(CloseWriters);
        Log.Info($"meeting note stopped after {(int)Note.DurationSeconds}s");
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Stop();
        _work.CompleteAdding();
        _worker.Join(TimeSpan.FromSeconds(5));
        _enumerator?.Dispose();
    }

    // MARK: sources (worker thread)

    private void StartSource(Track t)
    {
        StopCapture(t);
        _enumerator ??= new MMDeviceEnumerator();
        if (t.Source == Source.Mic)
        {
            var device = Recorder.DefaultInput(_enumerator);
            Wire(t, new WasapiCapture(device), device.FriendlyName);
        }
        else
        {
            var device = DefaultRender(_enumerator);
            var capture = new WasapiLoopbackCapture(device);
            Wire(t, capture, device.FriendlyName);
            if (KeepLoopbackAlive)
            {
                try
                {
                    var keep = new WasapiOut(device, AudioClientShareMode.Shared, true, 200);
                    keep.Init(new SilenceProvider(capture.WaveFormat));
                    keep.Play();
                    t.KeepAlive = keep;
                }
                catch (Exception e) { Log.Info($"meeting: could not start the loopback keep-alive: {e.Message}"); }
            }
        }
    }

    private void Wire(Track t, WasapiCapture capture, string deviceName)
    {
        var fmt = capture.WaveFormat;
        var resampler = new StreamingResampler(fmt.SampleRate);
        var channels = fmt.Channels;
        try
        {
            capture.DataAvailable += (_, e) => OnData(t, resampler, fmt, channels, e);
            capture.StartRecording();
        }
        catch
        {
            // Otherwise a device that fails to start leaks its AudioClient and the endpoint
            // stays open, which the next attempt then cannot claim.
            capture.Dispose();
            throw;
        }
        t.Resampler = resampler;
        t.Capture = capture;
        t.Device = deviceName;
        Log.Info($"meeting: {Name(t.Source)} capture from {deviceName} at {fmt.SampleRate} Hz, {fmt.Channels}ch, {fmt.BitsPerSample}-bit {fmt.Encoding}");
    }

    private void StopCapture(Track t)
    {
        var capture = t.Capture;
        var keep = t.KeepAlive;
        t.Capture = null;
        t.KeepAlive = null;
        // Dispose() joins the capture thread, which raises DataAvailable synchronously; OnData
        // only ever posts to the worker queue, so nothing here can wait on it.
        try { capture?.StopRecording(); capture?.Dispose(); } catch (Exception e) { Log.Info($"meeting: stopping {Name(t.Source)} capture threw: {e.Message}"); }
        try { keep?.Stop(); keep?.Dispose(); } catch (Exception e) { Log.Info($"meeting: stopping the keep-alive threw: {e.Message}"); }
    }

    private void StopSources()
    {
        foreach (var t in _tracks.Values) { StopCapture(t); t.Wanted = false; }
    }

    private void CloseWriters()
    {
        foreach (var t in _tracks.Values)
        {
            if (t.Writer is null) continue;
            try { t.Writer.Close(); } catch (Exception e) { Log.Info($"meeting: closing {Name(t.Source)} audio: {e.Message}"); }
            t.Writer = null;
        }
    }

    /// Audio thread. Decodes the buffer, mixes to mono, resamples to 16 kHz with the resampler
    /// this capture was wired with (a restart makes a new one, and a stale callback from the old
    /// capture must not feed it), then hands the chunk to the worker with its arrival time.
    private void OnData(Track t, StreamingResampler resampler, WaveFormat fmt, int channels, WaveInEventArgs e)
    {
        if (e.BytesRecorded == 0 || !ReferenceEquals(t.Resampler, resampler)) return;
        var block = WaveBlocks.ToFloat(e.Buffer, e.BytesRecorded, fmt);
        if (block is null)
        {
            if (!t.WarnedFormat)
            {
                t.WarnedFormat = true;
                Log.Info($"meeting: cannot read {fmt.BitsPerSample}-bit {fmt.Encoding} audio from {t.Device}; nothing will be captured from it");
            }
            return;
        }
        var mono = AudioIO.ToMono(block, channels);
        float[] chunk;
        lock (resampler) chunk = resampler.Feed(mono);
        if (chunk.Length == 0) return;
        Level?.Invoke(t.Source, AudioIO.Rms(chunk));
        var now = DateTime.UtcNow;
        if (!_work.IsAddingCompleted) _work.Add(() => Handle(t, chunk, now));
    }

    private void Handle(Track t, float[] chunk, DateTime now)
    {
        if (!IsRecording || !t.Wanted) return;
        var name = Name(t.Source);
        if (t.LastRestartAt is { } r && (now - r).TotalSeconds > 30) t.Backoff = 2;
        if (t.Failing)
        {
            t.Failing = false;
            Log.Info($"meeting: {name} audio is back");
            _store.AppendEvent($"{name} audio is back", Note.Id);
        }
        var first = !t.SawFirstChunk;
        t.SawFirstChunk = true;
        t.LastChunkAt = now;
        t.RestartAt = null;

        // The segmenter runs on this session's clock (the note's earlier duration is added to
        // every timestamp when a line is written).
        var expectedSession = (long)((now - _sessionStart).TotalSeconds * RecordingClock.SampleRate);
        var padT = RecordingClock.Shortfall(expectedSession, t.FedThisSession + chunk.Length, first);
        if (padT > 0) FeedSilence(t, padT);
        t.Segmenter.Feed(chunk);
        t.FedThisSession += chunk.Length;

        // The file runs on the note's clock, so a resumed session lands after the earlier audio.
        var padF = 0;
        if (t.Writer is { } w)
        {
            var expectedTotal = (long)((now - _clockStart).TotalSeconds * RecordingClock.SampleRate);
            padF = RecordingClock.Shortfall(expectedTotal, w.Frames + chunk.Length, first);
            try
            {
                var left = padF;
                while (left > 0) { var n = Math.Min(left, RecordingClock.SampleRate); w.Append(new float[n]); left -= n; }
                w.Append(chunk);
                if (t.WriteFailing) { t.WriteFailing = false; Log.Info($"meeting: writing {name} audio again"); }
            }
            catch (Exception e)
            {
                if (!t.WriteFailing)
                {
                    t.WriteFailing = true;
                    Log.Info($"meeting: writing {name} audio failed: {e.Message}");
                    _store.AppendEvent($"could not write {name} audio: {e.Message}", Note.Id);
                    Report(t, $"Could not write the meeting audio ({e.Message}). Check the free space on this disk; the transcript keeps going.");
                }
            }
        }
        var gap = Math.Max(padT, padF) / (double)RecordingClock.SampleRate;
        if (first)
        {
            if (gap > 0) Log.Info($"meeting: {name} delivered its first audio {gap:F2} s after start; aligned with silence");
        }
        else if (gap >= 0.5)
        {
            Log.Info($"meeting: filled a {gap:F1} s gap in {name} with silence");
            _store.AppendEvent($"[{Stamp(now)}] {gap:F1} s gap in {name} filled with silence", Note.Id);
        }
    }

    private static void FeedSilence(Track t, int samples)
    {
        var left = samples;
        while (left > 0)
        {
            var n = Math.Min(left, RecordingClock.SampleRate);
            t.Segmenter.Feed(new float[n]);
            t.FedThisSession += n;
            left -= n;
        }
    }

    private void InferLoop()
    {
        foreach (var (t, start, samples) in _infer.GetConsumingEnumerable())
        {
            try
            {
                var engine = _engine();
                if (engine is null) continue;
                var r = engine.Transcribe(samples);
                var text = _cleaner.Clean(r.Text);
                if (string.IsNullOrWhiteSpace(text)) continue;
                var segment = new TranscriptSegment
                {
                    Start = _previous + start / (double)RecordingClock.SampleRate,
                    End = _previous + (start + samples.Length) / (double)RecordingClock.SampleRate,
                    Speaker = t.Speaker,
                    Text = text,
                };
                _store.AppendSegment(segment, Note.Id);
                SegmentAdded?.Invoke(segment);
            }
            catch (Exception e) { Log.Info($"meeting: live transcribe ({t.Speaker}): {e.Message}"); }
        }
    }

    // MARK: watchdog (worker thread)

    private void Tick()
    {
        if (!IsRecording) return;
        var now = DateTime.UtcNow;
        foreach (var t in _tracks.Values.Where(t => t.Wanted))
        {
            if (t.RestartAt is { } due && now >= due)
            {
                Restart(t, t.RestartReason);
                continue;
            }
            var last = t.LastChunkAt ?? t.LastRestartAt ?? _sessionStart;
            if ((now - last).TotalSeconds > StaleAfterSeconds && now >= (t.LastRestartAt ?? DateTime.MinValue).AddSeconds(t.Backoff))
            {
                Restart(t, $"no audio for {(now - last).TotalSeconds:F0} s");
                t.Backoff = Math.Min(t.Backoff * 2, 60);
            }
        }
    }

    private void ScheduleRestart(Source source, string reason, double afterSeconds)
    {
        if (_work.IsAddingCompleted) return;
        _work.Add(() =>
        {
            if (!IsRecording) return;
            var t = _tracks[source];
            if (!t.Wanted) return;
            var at = DateTime.UtcNow.AddSeconds(afterSeconds);
            t.RestartAt = t.RestartAt is { } existing && existing < at ? existing : at;
            t.RestartReason = reason;
        });
    }

    private void Restart(Track t, string reason)
    {
        if (!IsRecording) return;
        t.RestartAt = null;
        t.LastRestartAt = DateTime.UtcNow;
        Log.Info($"meeting: restarting {Name(t.Source)} ({reason})");
        _store.AppendEvent($"[{Stamp(DateTime.UtcNow)}] restarting {Name(t.Source)}: {reason}", Note.Id);
        try { StartSource(t); }
        catch (Exception e)
        {
            Log.Info($"meeting: {Name(t.Source)} restart failed: {e.Message}");
            if (!t.Failing)
            {
                t.Failing = true;
                var what = t.Source == Source.Mic ? "The microphone stopped" : "System audio stopped";
                var other = _tracks.Values.Any(o => o.Wanted && o.Source != t.Source) ? " The other track keeps recording." : "";
                Report(t, $"{what} ({e.Message}). Lin Flow keeps trying every few seconds.{other}");
            }
        }
    }

    private void Report(Track t, string message) => Failed?.Invoke(message);

    private string Stamp(DateTime utc)
    {
        var s = (int)(utc - _clockStart).TotalSeconds;
        return s >= 3600 ? $"{s / 3600}:{s % 3600 / 60:D2}:{s % 60:D2}" : $"{s / 60}:{s % 60:D2}";
    }

    // MARK: devices

    /// Windows keeps three "default" output devices; try each role, then any active device.
    internal static MMDevice DefaultRender(MMDeviceEnumerator enumerator)
    {
        foreach (var role in new[] { Role.Multimedia, Role.Console, Role.Communications })
        {
            try { return enumerator.GetDefaultAudioEndpoint(DataFlow.Render, role); }
            catch (Exception) { /* role not assigned; try the next one */ }
        }
        var active = enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active);
        if (active.Count > 0) return active[0];
        throw new InvalidOperationException("no output device to capture system audio from");
    }

    /// The output device the loopback would open, or null when there is none. For `doctor`.
    public static string? DescribeDefaultOutput()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = DefaultRender(enumerator);
            return device.FriendlyName;
        }
        catch (Exception) { return null; }
    }

    private sealed class DeviceWatcher : IMMNotificationClient
    {
        private readonly Action<DataFlow, Role> _onDefaultChanged;
        public DeviceWatcher(Action<DataFlow, Role> onDefaultChanged) => _onDefaultChanged = onDefaultChanged;
        public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId) => _onDefaultChanged(flow, role);
        public void OnDeviceStateChanged(string deviceId, DeviceState newState) { }
        public void OnDeviceAdded(string pwstrDeviceId) { }
        public void OnDeviceRemoved(string deviceId) { }
        public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }
    }

    private void StartDeviceWatcher()
    {
        try
        {
            _enumerator ??= new MMDeviceEnumerator();
            _watcher = new DeviceWatcher((flow, role) =>
            {
                // Windows raises one change per role; the restart is debounced, so three arrive as one.
                if (role != Role.Multimedia && role != Role.Console) return;
                if (flow == DataFlow.Capture) ScheduleRestart(Source.Mic, "the default input device changed", 0.7);
                else ScheduleRestart(Source.System, "the default output device changed", 0.7);
            });
            _enumerator.RegisterEndpointNotificationCallback(_watcher);
        }
        catch (Exception e) { Log.Info($"meeting: could not watch for device changes; the watchdog still covers it: {e.Message}"); }
    }

    private void StopDeviceWatcher()
    {
        if (_watcher is null || _enumerator is null) return;
        try { _enumerator.UnregisterEndpointNotificationCallback(_watcher); } catch (Exception) { }
        _watcher = null;
    }

    /// 16 kHz mono 16-bit is about 230 MB an hour for two tracks. Under half a gigabyte the
    /// meeting is warned about before it starts, while there is still time to make room.
    private void CheckFreeSpace()
    {
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(_store.Root));
            if (string.IsNullOrEmpty(root)) return;
            var free = new DriveInfo(root).AvailableFreeSpace;
            if (free >= 500_000_000) return;
            var mb = free / 1_000_000;
            Log.Info($"meeting: only {mb} MB free for the recording");
            Failed?.Invoke($"Only {mb} MB free on this disk. A meeting needs about 230 MB an hour; make room or the recording will stop short.");
        }
        catch (Exception) { /* an unusual root; not worth failing the meeting over */ }
    }

    private void RunSync(Action action)
    {
        if (_work.IsAddingCompleted) { action(); return; }
        using var done = new ManualResetEventSlim();
        Exception? error = null;
        _work.Add(() =>
        {
            try { action(); } catch (Exception e) { error = e; } finally { done.Set(); }
        });
        done.Wait();
        if (error is not null) throw error;
    }
}
