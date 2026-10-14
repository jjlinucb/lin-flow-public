using LinFlow.Core;
using Xunit;

namespace LinFlow.Tests;

/// The meeting audio has to survive the process dying. A library writer fills in the WAV sizes
/// on close, so a crash left a whole meeting reading as 0 seconds with every byte still in the
/// file (verified on the Mac 2026-09-17). WavWriter keeps the header current and RepairHeader
/// fixes any WAV from its size. Everything here writes to a temp folder and deletes it.
public class WavWriterTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "linflow-tests-" + Guid.NewGuid().ToString("N"));
    public WavWriterTests() => Directory.CreateDirectory(_dir);
    public void Dispose() { try { Directory.Delete(_dir, true); } catch (IOException) { } }

    private static float[] Ramp(int n) => Enumerable.Range(0, n).Select(i => i % 1600 / 1600f - 0.5f).ToArray();

    [Fact]
    public void Closed_file_round_trips()
    {
        var path = Path.Combine(_dir, "a.wav");
        var ramp = Ramp(24_000);   // 1.5 s
        using (var w = new WavWriter(path))
        {
            for (var i = 0; i < ramp.Length; i += 160) w.Append(ramp.AsSpan(i, Math.Min(160, ramp.Length - i)));
            w.Close();
        }
        Assert.Equal(1.5, WavWriter.Duration(path)!.Value, 6);
        var info = WavWriter.Info(path)!;
        var back = WavWriter.ReadFrames(path, info, 0, 24_000);
        Assert.Equal(24_000, back.Length);
        Assert.InRange(Math.Abs(back[1000] - ramp[1000]), 0, 1f / 32000);
    }

    [Fact]
    public void Unclosed_file_trails_by_under_a_second_and_repairs()
    {
        var path = Path.Combine(_dir, "crash.wav");
        var w = new WavWriter(path);
        w.Append(new float[16_000].Select(_ => 0.1f).ToArray());   // header refreshed here (1.0 s)
        w.Append(new float[8_000].Select(_ => 0.1f).ToArray());    // not yet here
        Assert.Equal(1.0, WavWriter.Duration(path)!.Value, 6);
        Assert.True(WavWriter.RepairHeader(path));
        Assert.Equal(1.5, WavWriter.Duration(path)!.Value, 6);
        Assert.False(WavWriter.RepairHeader(path));
        w.Close();
    }

    private static byte[] Le32(int v) => BitConverter.GetBytes(v);
    private static byte[] Le16(int v) => BitConverter.GetBytes((short)v);

    [Fact]
    public void A_library_writers_crashed_header_with_a_junk_chunk_repairs()
    {
        var b = new List<byte>();
        b.AddRange("RIFF"u8.ToArray()); b.AddRange(Le32(4088)); b.AddRange("WAVE"u8.ToArray());
        b.AddRange("JUNK"u8.ToArray()); b.AddRange(Le32(28)); b.AddRange(new byte[28]);
        b.AddRange("fmt "u8.ToArray()); b.AddRange(Le32(16)); b.AddRange(Le16(1)); b.AddRange(Le16(1));
        b.AddRange(Le32(16_000)); b.AddRange(Le32(32_000)); b.AddRange(Le16(2)); b.AddRange(Le16(16));
        b.AddRange("data"u8.ToArray()); b.AddRange(Le32(0)); b.AddRange(Enumerable.Repeat((byte)0x40, 3200));   // 0.1 s
        var path = Path.Combine(_dir, "junk.wav");
        File.WriteAllBytes(path, b.ToArray());
        Assert.Equal(80, WavWriter.Info(path)!.DataOffset);
        Assert.Equal(0, WavWriter.Duration(path)!.Value);
        Assert.True(WavWriter.RepairHeader(path));
        Assert.Equal(0.1, WavWriter.Duration(path)!.Value, 6);
        Assert.Equal(1600, WavWriter.ReadFrames(path, WavWriter.Info(path)!, 0, 100_000).Length);
    }

    [Fact]
    public void Append_resumes_and_a_foreign_file_is_moved_aside()
    {
        var path = Path.Combine(_dir, "b.wav");
        using (var w = new WavWriter(path)) { w.Append(Ramp(24_000)); w.Close(); }
        using (var w = new WavWriter(path, append: true))
        {
            Assert.Equal(24_000, w.Frames);
            w.Append(new float[8_000]);
            w.Close();
        }
        Assert.Equal(2.0, WavWriter.Duration(path)!.Value, 6);

        var odd = Path.Combine(_dir, "odd.wav");
        var b = new List<byte>();
        b.AddRange("RIFF"u8.ToArray()); b.AddRange(Le32(36)); b.AddRange("WAVE"u8.ToArray());
        b.AddRange("fmt "u8.ToArray()); b.AddRange(Le32(16)); b.AddRange(Le16(1)); b.AddRange(Le16(1));
        b.AddRange(Le32(8_000)); b.AddRange(Le32(16_000)); b.AddRange(Le16(2)); b.AddRange(Le16(16));
        b.AddRange("data"u8.ToArray()); b.AddRange(Le32(0));
        File.WriteAllBytes(odd, b.ToArray());
        using (var w = new WavWriter(odd, append: true)) w.Close();
        Assert.Single(Directory.GetFiles(_dir, "odd.previous-*.wav"));
        Assert.Equal(16_000, WavWriter.Info(odd)!.SampleRate);
    }
}
