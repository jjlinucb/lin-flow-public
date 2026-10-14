using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// Ported from the Mac's SelfTest+Audio cases in 5884622.
public class MicrophoneTests
{
    private const int Second = 16_000;

    [Fact]
    public void Three_seconds_of_zeros_is_a_dead_microphone()
    {
        Assert.True(Microphone.IsDead(new float[Second * 3]));
    }

    [Fact]
    public void A_quarter_second_is_only_a_tap()
    {
        // Short enough to be a stray press, and a stray press really can hold nothing.
        Assert.False(Microphone.IsDead(new float[Second / 4]));
    }

    [Fact]
    public void A_silent_rooms_noise_is_not_a_dead_microphone()
    {
        // 0.0009 is John's measured quiet-home floor, about -60 dB - twenty decibels above
        // the -80 dB this looks for. The gap is the whole point of the threshold.
        var room = new float[Second];
        for (var i = 0; i < room.Length; i++) room[i] = i % 2 == 0 ? 0.0009f : -0.0009f;
        Assert.False(Microphone.IsDead(room));
    }

    [Fact]
    public void One_sample_of_real_audio_is_enough_to_clear_it()
    {
        // A device that works for a moment and then stops is not a dead microphone; it is a
        // recording with a problem, and it still has audio worth transcribing.
        var mostlyDead = new float[Second * 2];
        mostlyDead[^1] = 0.02f;
        Assert.False(Microphone.IsDead(mostlyDead));
    }
}
