using LinFlow.Core;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace LinFlow.Engine;

/// Microphone capture through WASAPI, resampled to the 16 kHz mono float the engines want.
/// The Mac's Recorder.swift does the same job with AVAudioEngine.
///
/// Three rules here, the first two from the first real run on Windows:
///
///   1. Never hold `_gate` while stopping the device. NAudio's WasapiCapture.Dispose() joins the
///      capture thread, and that thread raises DataAvailable synchronously, so if OnData is
///      waiting on `_gate` at that moment the two wait on each other forever. The symptom is a
///      release that never transcribes: the dot stays red, the rest of the app keeps working,
///      and nothing is written to the log. Stop() takes the lock only to swap state, and stops
///      the device outside it.
///
///   2. Resample once, at Stop(), over the whole clip. Resampling each buffer on its own restarts
///      the interpolation at phase zero and truncates the output length at every buffer boundary,
///      which is a faint periodic artifact in every dictation whenever frames * ratio is not a
///      whole number - so, on any 44.1 kHz device. Capture keeps mono at the device rate and the
///      conversion happens in one pass at the end.
///
///   3. Stop() does not wait for the device to close. Closing it took 0.29-0.35 s on every take
///      on the laptop (measured 2026-09-23), a third of the whole wait for the text, and the
///      transcription needs none of it. Stop() waits only for one last read, then closes the
///      device on another thread.
public sealed class Recorder : IDisposable
{
    private WasapiCapture? _capture;
    private WaveFormat? _format;
    private readonly List<float> _mono = new();      // mono, still at the device rate
    private readonly object _gate = new();
    private int _sourceRate, _channels;
    private long _since;

    // Set by Stop(): the capture thread's next read, which picks up whatever the device captured
    // up to the key coming up, is the last one wanted. `_drained` says it has happened.
    private volatile bool _stopping;
    private readonly ManualResetEventSlim _drained = new(false);

    /// How long the last device close took, once it has finished on its thread. For `mic-test`,
    /// which is where the 0.3 s was measured; a dictation no longer waits for it.
    public double? CloseSeconds { get; private set; }

    /// The close running on its own thread, so `mic-test` can wait for it and report it.
    public Task Closed { get; private set; } = Task.CompletedTask;

    private static double Seconds(long from, long to) =>
        (to - from) / (double)System.Diagnostics.Stopwatch.Frequency;

    /// Fires roughly every buffer with the current level, for the HUD meter.
    public event Action<float>? Level;

    public bool IsRecording { get; private set; }

    /// How one take started: which microphone, and where the time before the first sample went.
    /// The Mac's `Recorder.Start` (5884622) with the same three numbers.
    public sealed class Take
    {
        /// The input device by name, e.g. "Microphone Array on SoundWire Device".
        public string? Device { get; init; }
        /// How long `WasapiCapture.StartRecording()` blocked - Lin Flow's own share of the wait.
        public double OpenSeconds { get; set; }
        /// From the moment passed to `Start` - the key going down - to the first audio.
        /// Null until a buffer has arrived, and for a take too short to get one.
        public double? FirstAudioSeconds { get; set; }

        /// One line for the log. `after` names what the clock started from, so `mic-test` can
        /// say "asking" where a dictation says "the key", as the Mac's does.
        public string Describe(string after = "the key") =>
            $"microphone: {Device ?? "unknown device"}, " +
            (FirstAudioSeconds is { } f ? $"first audio {f:F2}s after {after}" : "no audio arrived") +
            $" (device open {OpenSeconds:F2}s)";
    }

    private Take? _take;

    /// The take in progress, or the last one once it has stopped.
    public Take? LastTake { get { lock (_gate) return _take; } }

    /// `since` is when the take was asked for, as a `Stopwatch.GetTimestamp()` value, so the
    /// delay to the first audio covers everything after the key: the hop to this thread, opening
    /// the device, the hardware waking up. Pass nothing to time from here instead.
    ///
    /// One honest difference from the Mac: AVAudioEngine hands its tap the host time the audio
    /// was *captured*, and NAudio's DataAvailable carries no timestamp at all, so this measures
    /// when the buffer was *delivered*. That includes the buffer's own duration, which makes the
    /// Windows number slightly pessimistic against the Mac's. It is the right number for "how
    /// long until Lin Flow had something to work with" either way.
    public void Start(long since = 0)
    {
        if (since == 0) since = System.Diagnostics.Stopwatch.GetTimestamp();
        lock (_gate)
        {
            if (IsRecording) return;
            _mono.Clear();
            _since = since;
            _stopping = false;
            _drained.Reset();

            using var enumerator = new MMDeviceEnumerator();
            var device = DefaultInput(enumerator);
            _take = new Take { Device = device.FriendlyName };
            var capture = new WasapiCapture(device);
            try
            {
                _format = capture.WaveFormat;
                _sourceRate = _format.SampleRate;
                _channels = _format.Channels;
                capture.DataAvailable += OnData;
                // A capture thread that dies - the device unplugged mid-take - reads nothing
                // more, and Stop() must not wait for a read that will never come.
                capture.RecordingStopped += (_, _) => _drained.Set();
                var opening = System.Diagnostics.Stopwatch.GetTimestamp();
                capture.StartRecording();
                _take.OpenSeconds = Seconds(opening, System.Diagnostics.Stopwatch.GetTimestamp());
            }
            catch
            {
                // Otherwise a device that fails to start leaks its AudioClient and the endpoint
                // stays open, which the next attempt then cannot claim.
                capture.Dispose();
                throw;
            }
            _capture = capture;
            IsRecording = true;
            Log.Info($"recording from {device.FriendlyName} at {_sourceRate} Hz, {_channels}ch");
        }
    }

    /// Thrown when the machine has no microphone at all, so the tray app can say that rather
    /// than showing the raw HRESULT.
    public sealed class NoInputDeviceException : Exception
    {
        public NoInputDeviceException() : base("no microphone found") { }
    }

    /// Windows keeps three separate "default" input devices and a machine can have any of them
    /// unset. Asking only for Communications threw `Element not found (0x80070490)` on a desktop
    /// with no microphone, which tells the user nothing, and would also have failed on a machine
    /// where only the Console default is assigned. Try each role, then any active device, and if
    /// there is genuinely nothing, say so in words.
    internal static MMDevice DefaultInput(MMDeviceEnumerator enumerator)
    {
        foreach (var role in new[] { Role.Communications, Role.Console, Role.Multimedia })
        {
            try { return enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, role); }
            catch (Exception) { /* role not assigned; try the next one */ }
        }

        var active = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active);
        if (active.Count > 0)
        {
            Log.Info($"no default input device is set; falling back to {active[0].FriendlyName}");
            return active[0];
        }
        throw new NoInputDeviceException();
    }

    /// The input device Start() would open, or null when there is none. For `doctor`.
    public static string? DescribeDefaultInput()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = DefaultInput(enumerator);
            return device.FriendlyName;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private bool _warnedFormat;

    private void OnData(object? sender, WaveInEventArgs e)
    {
        // Stop() has taken its copy. What the device sends while it closes is after the key.
        if (_drained.IsSet) return;
        try { Add(e); }
        finally
        {
            // NAudio raises this once per poll, with zero bytes when nothing was waiting, so an
            // empty poll after the stop means the same as a full one: everything up to the key
            // is in. Signalled after Add, so Stop() never copies before the tail is added.
            if (_stopping) _drained.Set();
        }
    }

    private void Add(WaveInEventArgs e)
    {
        // Read the format from the field, not from _capture: Stop() clears _capture before the
        // device is disposed, and the buffers that arrive in that window are the tail of the
        // dictation rather than something to throw away.
        var fmt = _format;
        if (fmt is null || e.BytesRecorded == 0) return;

        // The format handling lives in WaveBlocks now, shared with the meeting recorder.
        var block = WaveBlocks.ToFloat(e.Buffer, e.BytesRecorded, fmt);
        if (block is null)
        {
            // Silence with no explanation is the worst failure this file can produce.
            if (!_warnedFormat)
            {
                _warnedFormat = true;
                Log.Info($"recorder: cannot read {fmt.BitsPerSample}-bit {fmt.Encoding} audio; no samples will be captured");
            }
            return;
        }

        var arrived = System.Diagnostics.Stopwatch.GetTimestamp();
        var mono = AudioIO.ToMono(block, _channels);
        lock (_gate)
        {
            // First buffer only. A device that never delivers leaves this null, which is what
            // makes "no audio arrived" in the log mean exactly that.
            if (_take is { FirstAudioSeconds: null }) _take.FirstAudioSeconds = Seconds(_since, arrived);
            _mono.AddRange(mono);
        }
        if (mono.Length > 0) Level?.Invoke(AudioIO.Rms(mono));
    }

    /// Stops and hands back everything captured, as 16 kHz mono float.
    public float[] Stop()
    {
        WasapiCapture? capture;
        lock (_gate)
        {
            if (!IsRecording) return Array.Empty<float>();
            IsRecording = false;
            capture = _capture;
            _capture = null;
            _stopping = true;
        }

        // One more read rather than none. NAudio polls every half buffer, about 50 ms, and
        // StopRecording() ends the loop before its next read, so stopping outright dropped
        // whatever the device had captured since the last poll: the end of the last word.
        // Waiting for that read costs the same 0-50 ms. The timeout is for a device that has
        // gone quiet without the capture thread noticing; RecordingStopped covers one that died.
        // Outside the lock; see rule 1 on the class.
        if (capture is not null && !_drained.Wait(TimeSpan.FromMilliseconds(250)))
            Log.Info("recorder: no final read within 250 ms; using what had arrived");

        float[] mono;
        lock (_gate)
        {
            _drained.Set();              // and anything that arrives from here on is ignored
            mono = _mono.ToArray();
        }

        // Rule 3 on the class: the text does not wait for the device to close. Nothing left
        // needs the lock, so rule 1 holds on that thread too.
        if (capture is not null)
        {
            Closed = Task.Run(() =>
            {
                var closing = System.Diagnostics.Stopwatch.GetTimestamp();
                try
                {
                    capture.StopRecording();
                    capture.Dispose();
                }
                catch (Exception e)
                {
                    Log.Info($"stopping the recorder threw: {e.Message}");
                }
                CloseSeconds = Seconds(closing, System.Diagnostics.Stopwatch.GetTimestamp());
            });
        }
        return AudioIO.Resample(mono, _sourceRate);
    }

    public void Dispose() => Stop();
}
