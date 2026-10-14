namespace LinFlow.Core;

/// Where the speech is in a saved track, found with hindsight over the whole recording. The
/// pure half of NoteTranscriber in ../../Sources/LinFlowCore/NoteTranscriber.swift: the engine
/// call lives in LinFlow.Engine, this part runs in the tests on any machine.
public static class SpeechRegions
{
    /// A stretch of speech in samples at 16 kHz, `End` exclusive.
    public readonly record struct Region(int Start, int End);

    public const int SampleRate = 16_000;
    /// Tunables, in seconds.
    public static double FrameSeconds = 0.1;
    /// Both engines decode long clips in pieces past this (whisper.cpp at 28 s), so a region
    /// never exceeds it and the engine sees each region whole.
    public static double MaxRegionSeconds = 28;
    /// Two stretches of speech this close together are transcribed as one, for context.
    public static double MergeGapSeconds = 2;
    /// Quiet inside a stretch that does not end it.
    public static double CloseGapSeconds = 0.8;
    public static double PadSeconds = 0.3;
    /// Anything with less speech than this is a click or a cough, not a segment.
    public static double MinSpeechSeconds = 0.4;
    /// Absolute floor for the speech threshold (RMS); the same as the live path.
    public static float MinimumThreshold = 0.006f;

    /// Speech regions from per-frame RMS levels of one track. The noise floor is the 10th
    /// percentile of all frames (an hour of hold music or fan noise lifts it, digital silence does
    /// not drag it to zero), speech is anything above max(0.006, 3x floor).
    public static List<Region> Find(IReadOnlyList<float> levels, int totalSamples, double? frameSeconds = null)
    {
        var result = new List<Region>();
        if (levels.Count == 0 || totalSamples <= 0) return result;
        var fsec = frameSeconds ?? FrameSeconds;
        var frameSamples = Math.Max(1, (int)Math.Round(fsec * SampleRate));
        // Rounded, not truncated: 0.3 / 0.1 is 2.9999999999999996 in floating point.
        int Frames(double seconds) => (int)Math.Round(seconds / fsec);
        var sorted = levels.OrderBy(l => l).ToArray();
        var floor = Math.Min(Math.Max(sorted[sorted.Length / 10], 0.0005f), 0.05f);
        var threshold = Math.Max(MinimumThreshold, floor * 3);
        var closeGap = Math.Max(1, Frames(CloseGapSeconds));
        var mergeGap = Math.Max(1, Frames(MergeGapSeconds));
        var maxLen = Math.Max(2, Frames(MaxRegionSeconds));
        var pad = Frames(PadSeconds);
        var minSpeech = Math.Max(1, Frames(MinSpeechSeconds));
        var totalFrames = levels.Count;

        // Runs of speech frames, a run tolerating up to closeGap quiet frames inside it.
        var runs = new List<(int Start, int End, int Speech)>();
        (int Start, int Last, int Speech)? open = null;
        for (var i = 0; i < levels.Count; i++)
        {
            var speaking = levels[i] > threshold;
            if (open is { } o)
            {
                if (speaking) open = (o.Start, i, o.Speech + 1);
                else if (i - o.Last > closeGap) { runs.Add((o.Start, o.Last + 1, o.Speech)); open = null; }
            }
            else if (speaking) open = (i, i, 1);
        }
        if (open is { } last) runs.Add((last.Start, last.Last + 1, last.Speech));
        runs.RemoveAll(r => r.Speech < minSpeech);

        // Neighbours close together become one region, for context, while it stays short.
        var merged = new List<(int Start, int End)>();
        foreach (var r in runs)
        {
            if (merged.Count > 0 && r.Start - merged[^1].End <= mergeGap && r.End - merged[^1].Start <= maxLen)
                merged[^1] = (merged[^1].Start, r.End);
            else
                merged.Add((r.Start, r.End));
        }

        // Pad both sides without overlapping the neighbour, then split anything long at its
        // quietest frame in the second half.
        for (var i = 0; i < merged.Count; i++)
        {
            var start = Math.Max(0, merged[i].Start - pad);
            var end = Math.Min(totalFrames, merged[i].End + pad);
            if (i > 0) start = Math.Max(start, merged[i - 1].End);
            var s = start;
            while (end - s > maxLen)
            {
                var cut = s + maxLen;
                var quietest = float.MaxValue;
                for (var f = s + maxLen / 2; f < s + maxLen; f++)
                    if (levels[f] < quietest) { quietest = levels[f]; cut = f; }
                if (cut > s) result.Add(new Region(s * frameSamples, Math.Min(totalSamples, cut * frameSamples)));
                s = cut;
            }
            if (end > s) result.Add(new Region(s * frameSamples, Math.Min(totalSamples, end * frameSamples)));
        }
        result.RemoveAll(r => r.End <= r.Start);
        return result;
    }

    /// RMS per frame over a whole track, read in 30 s blocks so an hour of audio never sits in
    /// memory at once. `read(start, count)` hands back up to `count` samples from `start`.
    public static List<float> Levels(Func<long, int, float[]> read, long totalSamples, double? frameSeconds = null)
    {
        var fsec = frameSeconds ?? FrameSeconds;
        var frameSamples = Math.Max(1, (int)Math.Round(fsec * SampleRate));
        var block = frameSamples * 300;
        var levels = new List<float>((int)(totalSamples / frameSamples) + 1);
        long pos = 0;
        while (pos < totalSamples)
        {
            var n = (int)Math.Min(block, totalSamples - pos);
            var samples = read(pos, n);
            var i = 0;
            while (i + frameSamples <= samples.Length)
            {
                levels.Add(Rms(samples.AsSpan(i, frameSamples)));
                i += frameSamples;
            }
            if (i < samples.Length && samples.Length - i >= frameSamples / 2) levels.Add(Rms(samples.AsSpan(i)));
            pos += n;
        }
        return levels;
    }

    public static float Rms(ReadOnlySpan<float> samples)
    {
        if (samples.Length == 0) return 0;
        double acc = 0;
        foreach (var s in samples) acc += (double)s * s;
        return (float)Math.Sqrt(acc / samples.Length);
    }

    public static float Peak(ReadOnlySpan<float> samples)
    {
        float p = 0;
        foreach (var s in samples) p = Math.Max(p, Math.Abs(s));
        return p;
    }
}
