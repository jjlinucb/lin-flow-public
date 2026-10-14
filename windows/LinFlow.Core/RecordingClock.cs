namespace LinFlow.Core;

/// The note's clock, shared by every track of a meeting. Ported from MeetingRecorder.shortfall
/// in ../../Sources/LinFlowCore/MeetingRecorder.swift.
public static class RecordingClock
{
    public const int SampleRate = 16_000;

    /// Zeros to insert before a chunk so the track catches up with the clock. Normal delivery
    /// jitter is tens of milliseconds and must never pad; the first chunk of a session is pure
    /// start-up latency, so it aligns more tightly. A slow start, a stall or a device switch is
    /// filled with silence, so the microphone and the system tracks line up in any editor.
    public static int Shortfall(long expected, long have, bool first)
    {
        var threshold = (long)((first ? 0.1 : 0.5) * SampleRate);
        var deficit = expected - have;
        return deficit > threshold ? (int)Math.Min(int.MaxValue, deficit) : 0;
    }
}
