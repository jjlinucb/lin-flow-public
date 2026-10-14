namespace LinFlow.Core;

/// Telling a dead microphone apart from a quiet room.
///
/// Ported from the Mac's `DictationController.isDeadMicrophone` (5884622). It lives in Core
/// rather than beside `AudioIO` in Engine for one reason: Engine targets net8.0-windows and the
/// test project targets net8.0, so nothing in Engine can be pinned by a test. This is a pure
/// function over samples and it is exactly the kind of thing that should have a test.
public static class Microphone
{
    /// Half a second or more with nothing above -80 dB.
    ///
    /// No working microphone is that quiet, even in a silent room: John's quiet-home noise floor
    /// measures about 0.0009, which is -60 dB, twenty decibels above this. A run of exact zeros
    /// means the device handed over nothing at all.
    ///
    /// On the Mac this was found the expensive way - on 2026-09-15 the input sent pure zeros for
    /// eight takes in a row, through a restart of the app, and every one was dropped as "too
    /// quiet" without a word to say the microphone was not working. The failure is invisible
    /// precisely because it looks like not talking.
    ///
    /// Half a second is the floor because a shorter clip is a stray tap of the key, and a tap
    /// genuinely can contain nothing.
    public static bool IsDead(ReadOnlySpan<float> samples, int sampleRate = 16_000)
    {
        if (samples.Length < sampleRate / 2) return false;
        foreach (var s in samples) if (s > 0.0001f || s < -0.0001f) return false;
        return true;
    }
}
