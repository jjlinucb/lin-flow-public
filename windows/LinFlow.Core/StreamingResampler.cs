namespace LinFlow.Core;

/// Linear resampler that keeps its phase between calls, so a live stream can be converted
/// buffer by buffer. `AudioIO.Resample` in the engine warns against per-buffer use because each
/// call there restarts at phase zero and truncates the output, which puts a discontinuity at
/// every buffer boundary on a 44.1 kHz device; this one carries the fractional position and the
/// last input sample across calls, so feeding a stream in 480-frame pieces gives the same output
/// as feeding it whole.
public sealed class StreamingResampler
{
    public int SourceRate { get; }
    public int TargetRate { get; }
    private readonly double _step;   // input samples per output sample
    private double _pos;             // input index of the next output sample; 0 is the carried sample
    private float _last;
    private bool _hasLast;

    public StreamingResampler(int sourceRate, int targetRate = 16_000)
    {
        if (sourceRate <= 0 || targetRate <= 0) throw new ArgumentOutOfRangeException(nameof(sourceRate));
        SourceRate = sourceRate;
        TargetRate = targetRate;
        _step = (double)sourceRate / targetRate;
    }

    public float[] Feed(ReadOnlySpan<float> input)
    {
        if (input.Length == 0) return Array.Empty<float>();
        if (SourceRate == TargetRate) return input.ToArray();

        var total = (_hasLast ? 1 : 0) + input.Length;
        var expected = (int)(total / _step) + 2;
        var output = new List<float>(expected);
        while (true)
        {
            var i0 = (int)Math.Floor(_pos);
            var i1 = i0 + 1;
            if (i1 >= total) break;
            var t = (float)(_pos - i0);
            output.Add(Get(input, i0) * (1 - t) + Get(input, i1) * t);
            _pos += _step;
        }
        // Next call: index 0 is this input's last sample.
        _pos -= total - 1;
        _last = input[^1];
        _hasLast = true;
        return output.ToArray();
    }

    private float Get(ReadOnlySpan<float> input, int index)
    {
        if (_hasLast) return index == 0 ? _last : input[index - 1];
        return input[index];
    }
}
