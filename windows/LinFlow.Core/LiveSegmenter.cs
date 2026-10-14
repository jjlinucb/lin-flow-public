namespace LinFlow.Core;

/// Turns a continuous 16 kHz stream into speech segments as people speak: the pure half of
/// ../../Sources/LinFlowCore/LiveTranscriber.swift. Energy based: a segment opens when the level
/// rises above an adaptive noise floor and closes after ~0.8 s of quiet, or at 10 s cut at the
/// quietest recent moment. The caller hands each segment to the engine; this class never sees
/// a model, so it runs in the tests on any machine. Not thread-safe: feed it from one thread.
public sealed class LiveSegmenter
{
    public const int SampleRate = 16_000;

    /// Tunables, in seconds unless noted.
    public double SilenceToClose = 0.8;
    public double MinimumSegment = 0.8;
    /// Someone on a call who does not pause is the normal case, and this is how long their
    /// words wait before anything appears.
    public double MaximumSegment = 10;
    public double PrePadding = 0.3;
    public double NoiseWindow = 5;
    /// Absolute floor for the speech threshold (RMS). Quiet rooms sit around 0.002.
    public float MinimumThreshold = 0.006f;

    /// A closed segment: where it starts, in samples from the first sample fed, and its audio.
    public event Action<int, float[]>? Segment;

    private readonly List<float> _buffer = new();
    private readonly List<float> _preBuffer = new();
    private int _bufferStartSample;
    private int _samplesSeen;
    private bool _inSpeech;
    private int _silentSamples;
    private float _noiseFloor = 0.004f;
    private readonly List<(int Sample, float Level)> _recentLevels = new();
    private (int Offset, float Level)? _quietCut;
    private bool _afterForcedSplit;

    public void Feed(ReadOnlySpan<float> chunk)
    {
        if (chunk.Length == 0) return;
        var level = SpeechRegions.Rms(chunk);
        _samplesSeen += chunk.Length;
        UpdateNoiseFloor(level);
        var threshold = Math.Max(MinimumThreshold, _noiseFloor * 3);
        var speaking = level > threshold;

        if (!_inSpeech)
        {
            _preBuffer.AddRange(chunk.ToArray());
            var keep = (int)(PrePadding * SampleRate);
            if (_preBuffer.Count > keep) _preBuffer.RemoveRange(0, _preBuffer.Count - keep);
            if (speaking)
            {
                _inSpeech = true;
                _buffer.Clear();
                _buffer.AddRange(_preBuffer);
                _bufferStartSample = _samplesSeen - _buffer.Count;
                _silentSamples = 0;
                _quietCut = null;
                _afterForcedSplit = false;
                _preBuffer.Clear();
            }
            return;
        }

        _buffer.AddRange(chunk.ToArray());
        _silentSamples = speaking ? 0 : _silentSamples + chunk.Length;
        var duration = _buffer.Count / (double)SampleRate;
        // Once a segment runs long, remember its quietest recent chunk so a forced split lands
        // between words instead of through one.
        if (duration >= MaximumSegment - 4)
        {
            var offset = _buffer.Count - chunk.Length;
            if (_quietCut is null || level < _quietCut.Value.Level) _quietCut = (offset, level);
        }
        var spoken = duration - _silentSamples / (double)SampleRate;
        if (_silentSamples / (double)SampleRate >= SilenceToClose)
        {
            if (spoken >= MinimumSegment || _afterForcedSplit)
            {
                var keepSilence = (int)(0.25 * SampleRate);
                var drop = Math.Max(0, _silentSamples - keepSilence);
                var count = drop < _buffer.Count ? _buffer.Count - drop : _buffer.Count;
                Emit(_buffer.GetRange(0, count).ToArray(), _bufferStartSample);
            }
            _inSpeech = false;
            _buffer.Clear();
            _quietCut = null;
            _afterForcedSplit = false;
        }
        else if (duration >= MaximumSegment)
        {
            // Still talking: cut at the quiet point, no overlap, so no word is transcribed twice.
            var cut = _quietCut?.Offset ?? _buffer.Count;
            var head = _buffer.GetRange(0, cut).ToArray();
            var tail = _buffer.GetRange(cut, _buffer.Count - cut);
            Emit(head, _bufferStartSample);
            _bufferStartSample += cut;
            _buffer.Clear();
            _buffer.AddRange(tail);
            _silentSamples = Math.Min(_silentSamples, tail.Count);
            _quietCut = null;
            _afterForcedSplit = true;
        }
    }

    /// Close whatever is open. Call when the recording stops.
    public void Finish()
    {
        if (_inSpeech) Emit(_buffer.ToArray(), _bufferStartSample);
        _inSpeech = false;
        _buffer.Clear();
    }

    /// The floor is the quietest chunk of the last few seconds: it drops at once and rises
    /// slowly, so a fan or hold music that starts mid-meeting lifts the threshold within seconds,
    /// while continuous speech (which always has dips) cannot drag it up.
    private void UpdateNoiseFloor(float level)
    {
        _recentLevels.Add((_samplesSeen, level));
        var horizon = _samplesSeen - (int)(NoiseWindow * SampleRate);
        while (_recentLevels.Count > 0 && _recentLevels[0].Sample < horizon) _recentLevels.RemoveAt(0);
        var target = _recentLevels.Count > 0 ? _recentLevels.Min(r => r.Level) : level;
        if (target < _noiseFloor) _noiseFloor = Math.Max(_noiseFloor * 0.7f + target * 0.3f, 0.0005f);
        else _noiseFloor = Math.Min(Math.Min(target, Math.Max(_noiseFloor * 1.04f, _noiseFloor + 0.0005f)), 0.05f);
    }

    private void Emit(float[] samples, int startSample)
    {
        if (samples.Length == 0 || SpeechRegions.Peak(samples) <= 0.01f) return;
        Segment?.Invoke(startSample, samples);
    }
}
