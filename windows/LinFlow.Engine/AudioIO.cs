namespace LinFlow.Engine;

/// Audio helpers shared by the recorder and the engines. Ported from
/// ../../Sources/LinFlowCore/AudioIO.swift. Everything downstream expects 16 kHz mono float32,
/// which is what both whisper.cpp and libparakeet want.
public static class AudioIO
{
    public const int SampleRate = 16_000;

    /// Root-mean-square level, 0..1-ish. Used for the silence gate and the HUD meter.
    public static float Rms(ReadOnlySpan<float> samples)
    {
        if (samples.Length == 0) return 0;
        double acc = 0;
        foreach (var s in samples) acc += (double)s * s;
        return (float)Math.Sqrt(acc / samples.Length);
    }

    /// Peak absolute sample.
    public static float Peak(ReadOnlySpan<float> samples)
    {
        float p = 0;
        foreach (var s in samples) p = Math.Max(p, Math.Abs(s));
        return p;
    }

    /// Cuts audio longer than `limitSeconds` into pieces, each ending at the quietest 200 ms
    /// found between `searchFromSeconds` and the limit, so no piece splits a word if it can be
    /// helped. Both engines decode long clips this way: whisper.cpp drops speech that straddles
    /// its 30 s window and libparakeet drops sentences after a pause past about 60 s.
    public static List<float[]> SplitLong(float[] samples, double limitSeconds, double searchFromSeconds)
    {
        var limit = (int)(limitSeconds * SampleRate);
        if (samples.Length <= limit) return new List<float[]> { samples };

        var pieces = new List<float[]>();
        var offset = 0;
        while (samples.Length - offset > limit)
        {
            var cut = QuietestCut(samples, offset + (int)(searchFromSeconds * SampleRate), offset + limit);
            pieces.Add(samples[offset..cut]);
            offset = cut;
        }
        if (offset < samples.Length) pieces.Add(samples[offset..]);
        return pieces;
    }

    /// Middle of the quietest 200 ms between the two sample offsets.
    public static int QuietestCut(float[] samples, int lo, int hi)
    {
        var win = (int)(0.2 * SampleRate);
        hi = Math.Min(hi, samples.Length);
        lo = Math.Max(0, lo);
        var best = hi;
        var bestEnergy = float.MaxValue;
        var i = lo;
        while (i + win <= hi)
        {
            float e = 0;
            for (var k = i; k < i + win; k++) e += samples[k] * samples[k];
            if (e < bestEnergy) { bestEnergy = e; best = i + win / 2; }
            i += win / 2;
        }
        return best;
    }

    /// Average of the channels, still at the device rate. The mix-down half of ToMono16k; the
    /// recorder holds audio in this form during capture and resamples once at the end.
    public static float[] ToMono(ReadOnlySpan<float> interleaved, int channels)
    {
        if (channels <= 0) channels = 1;
        var frames = interleaved.Length / channels;
        if (frames == 0) return Array.Empty<float>();
        if (channels == 1) return interleaved.ToArray();

        var mono = new float[frames];
        for (var f = 0; f < frames; f++)
        {
            float sum = 0;
            for (var c = 0; c < channels; c++) sum += interleaved[f * channels + c];
            mono[f] = sum / channels;
        }
        return mono;
    }

    /// Straight-line resample of mono audio to 16 kHz. The Mac hands this to AVAudioConverter.
    /// Linear interpolation is enough here: speech models are not sensitive to the last fraction
    /// of a dB, and the alternative pulls in a resampler dependency for no measurable transcript
    /// difference.
    ///
    /// Run it over a whole clip, never buffer by buffer. Each call starts at phase zero and
    /// truncates the output length, so per-buffer use inserts a discontinuity at every boundary
    /// whenever frames * ratio is not a whole number, which on a 44.1 kHz device is almost every
    /// buffer.
    public static float[] Resample(float[] mono, int sourceRate)
    {
        var frames = mono.Length;
        if (frames == 0 || sourceRate == SampleRate || sourceRate <= 0) return mono;

        var ratio = (double)SampleRate / sourceRate;
        var outLen = Math.Max(1, (int)(frames * ratio));
        var outBuf = new float[outLen];
        for (var i = 0; i < outLen; i++)
        {
            var src = i / ratio;
            var i0 = (int)src;
            var i1 = Math.Min(i0 + 1, frames - 1);
            var t = (float)(src - i0);
            outBuf[i] = mono[i0] * (1 - t) + mono[i1] * t;
        }
        return outBuf;
    }

    /// Interleaved device-rate float in, 16 kHz mono out. What ReadWav uses; the recorder calls
    /// the two halves separately so the resample happens once.
    public static float[] ToMono16k(ReadOnlySpan<float> interleaved, int channels, int sourceRate)
        => Resample(ToMono(interleaved, channels), sourceRate);

    /// 16-bit PCM WAV at 16 kHz mono - what `linflow transcribe` reads and what the recorder
    /// writes for the "last recording" file, so a clip can be replayed on either machine.
    public static float[] ReadWav(string path)
    {
        using var reader = new NAudio.Wave.AudioFileReader(path);
        var channels = reader.WaveFormat.Channels;
        var rate = reader.WaveFormat.SampleRate;
        var buffer = new List<float>();
        var chunk = new float[16384];
        int read;
        while ((read = reader.Read(chunk, 0, chunk.Length)) > 0)
            buffer.AddRange(chunk.AsSpan(0, read).ToArray());
        return ToMono16k(System.Runtime.InteropServices.CollectionsMarshal.AsSpan(buffer), channels, rate);
    }

    public static void WriteWav(string path, float[] samples)
    {
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var format = new NAudio.Wave.WaveFormat(SampleRate, 16, 1);
        using var writer = new NAudio.Wave.WaveFileWriter(path, format);
        var pcm = new byte[samples.Length * 2];
        for (var i = 0; i < samples.Length; i++)
        {
            var v = (short)(Math.Clamp(samples[i], -1f, 1f) * short.MaxValue);
            pcm[i * 2] = (byte)(v & 0xFF);
            pcm[i * 2 + 1] = (byte)((v >> 8) & 0xFF);
        }
        writer.Write(pcm, 0, pcm.Length);
    }
}
