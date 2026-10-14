using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// The pure parts of the meeting recorder and of the pass over the saved audio, mirrored from
/// the Mac's selftest cases so the two ports agree on every boundary.
public class RecordingClockTests
{
    [Fact] public void Jitter_is_not_a_gap() => Assert.Equal(0, RecordingClock.Shortfall(16_000, 15_000, first: false));
    [Fact] public void A_stall_is_filled_exactly() => Assert.Equal(17_000, RecordingClock.Shortfall(32_000, 15_000, first: false));
    [Fact] public void A_slow_first_chunk_aligns_the_track() => Assert.Equal(2_000, RecordingClock.Shortfall(3_000, 1_000, first: true));
    [Fact] public void Small_startup_latency_is_left_alone() => Assert.Equal(0, RecordingClock.Shortfall(1_500, 1_000, first: true));
}

public class SpeechRegionsTests
{
    private const int Fs = 1600;   // samples per 100 ms frame

    private static float[] Levels(int n, float @base, params (Range Frames, float Level)[] bursts)
    {
        var l = Enumerable.Repeat(@base, n).ToArray();
        foreach (var (range, v) in bursts)
        {
            var (off, len) = range.GetOffsetAndLength(n);
            for (var i = off; i < off + len; i++) l[i] = v;
        }
        return l;
    }

    [Fact]
    public void Two_stretches_far_apart_are_two_regions_padded_300_ms()
    {
        var r = SpeechRegions.Find(Levels(600, 0, (50..80, 0.05f), (200..230, 0.05f)), 600 * Fs);
        Assert.Equal(2, r.Count);
        Assert.Equal(new SpeechRegions.Region(47 * Fs, 83 * Fs), r[0]);
    }

    [Fact]
    public void A_one_second_gap_merges_the_neighbours()
    {
        var r = SpeechRegions.Find(Levels(600, 0, (50..80, 0.05f), (90..120, 0.05f)), 600 * Fs);
        Assert.Single(r);
        Assert.Equal(123 * Fs, r[0].End);
    }

    [Fact]
    public void Fifty_seconds_of_talk_splits_at_the_quietest_frame_under_28_s()
    {
        var levels = Levels(600, 0, (0..500, 0.05f));
        levels[200] = 0.02f;
        var r = SpeechRegions.Find(levels, 600 * Fs);
        Assert.Equal(3, r.Count);
        Assert.Equal(200 * Fs, r[0].End);
        Assert.Equal(200 * Fs, r[1].Start);
        Assert.All(r, x => Assert.True(x.End - x.Start <= 280 * Fs));
    }

    [Fact]
    public void A_click_is_not_a_segment() =>
        Assert.Empty(SpeechRegions.Find(Levels(600, 0, (300..303, 0.05f)), 600 * Fs));

    [Fact]
    public void A_constant_hum_raises_the_floor_instead_of_becoming_speech()
    {
        var r = SpeechRegions.Find(Levels(600, 0.01f, (100..150, 0.05f)), 600 * Fs);
        Assert.Single(r);
        Assert.Equal(97 * Fs, r[0].Start);
    }

    [Fact]
    public void Levels_are_rms_per_100_ms_frame_with_a_half_frame_tail()
    {
        var samples = new float[32_800];   // 2.05 s
        for (var i = 16_000; i < samples.Length; i++) samples[i] = 0.5f;
        var lv = SpeechRegions.Levels((start, count) => samples.Skip((int)start).Take(count).ToArray(), samples.Length);
        Assert.Equal(21, lv.Count);
        Assert.Equal(0.5f, lv[15], 5);
        Assert.Equal(0f, lv[3]);
    }
}

public class StreamingResamplerTests
{
    private static float[] Sine(int rate, double seconds, double hz)
    {
        var n = (int)(rate * seconds);
        var s = new float[n];
        for (var i = 0; i < n; i++) s[i] = (float)(0.5 * Math.Sin(2 * Math.PI * hz * i / rate));
        return s;
    }

    [Theory]
    [InlineData(48_000, 480)]
    [InlineData(44_100, 441)]
    [InlineData(44_100, 1000)]
    public void Chunked_equals_whole(int rate, int chunk)
    {
        var input = Sine(rate, 1.0, 440);
        var whole = new StreamingResampler(rate).Feed(input);
        var piecewise = new StreamingResampler(rate);
        var chunked = new List<float>();
        for (var i = 0; i < input.Length; i += chunk) chunked.AddRange(piecewise.Feed(input.AsSpan(i, Math.Min(chunk, input.Length - i))));
        Assert.Equal(whole.Length, chunked.Count);
        for (var i = 0; i < whole.Length; i++) Assert.Equal(whole[i], chunked[i], 5);
        Assert.InRange(whole.Length, 15_990, 16_000);
    }

    [Fact]
    public void Same_rate_passes_through()
    {
        var input = Sine(16_000, 0.1, 440);
        Assert.Equal(input, new StreamingResampler(16_000).Feed(input));
    }
}

public class LiveSegmenterTests
{
    /// Speech-like noise: loud, with a quiet 100 ms every half second the way speech dips
    /// between words. Noise with no dips at all reads as a fan, and the floor rises to meet it.
    private static float[] Noise(int n, int seed)
    {
        var rng = new Random(seed);
        var s = new float[n];
        for (var i = 0; i < n; i++)
        {
            var dip = i / 1600 % 5 == 4 ? 0.05f : 1f;
            s[i] = (float)(rng.NextDouble() * 0.2 - 0.1) * dip;
        }
        return s;
    }

    private static List<(int Start, float[] Samples)> Run(float[] stream)
    {
        var seg = new LiveSegmenter();
        var got = new List<(int, float[])>();
        seg.Segment += (start, samples) => got.Add((start, samples));
        for (var i = 0; i < stream.Length; i += 1600) seg.Feed(stream.AsSpan(i, Math.Min(1600, stream.Length - i)));
        seg.Finish();
        return got;
    }

    [Fact]
    public void Speech_between_silences_is_one_segment_with_pre_padding()
    {
        var stream = new float[16_000 * 7];
        Noise(32_000, 1).CopyTo(stream, 48_000);   // 3 s in, 2 s long
        var got = Run(stream);
        Assert.Single(got);
        Assert.InRange(got[0].Start, 48_000 - 4800 - 1600, 48_000);
        Assert.InRange(got[0].Samples.Length / 16_000.0, 2.0, 2.8);
    }

    [Fact]
    public void Someone_who_never_pauses_is_cut_by_ten_seconds()
    {
        var got = Run(Noise(16_000 * 15, 2));
        Assert.True(got.Count >= 2, $"expected a forced split, got {got.Count} segment(s)");
        Assert.True(got[0].Samples.Length <= 16_000 * 10 + 1600);
        Assert.Equal(got[0].Start + got[0].Samples.Length, got[1].Start);   // no overlap, no hole
    }

    [Fact]
    public void Silence_alone_produces_nothing() => Assert.Empty(Run(new float[16_000 * 5]));
}
