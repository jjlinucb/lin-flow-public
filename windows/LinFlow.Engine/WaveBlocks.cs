using NAudio.Wave;

namespace LinFlow.Engine;

/// Turns a WASAPI buffer into float samples whatever the mix format. Shared by the dictation
/// recorder and the meeting captures, so the lesson below is learned once.
///
/// WASAPI shared mode hands back IEEE float most of the time, 16-bit PCM occasionally, and
/// 24-in-32 integer PCM whenever the user has picked a "Studio Quality" default format in the
/// Sound control panel. Ask the subformat, not the sample width: a WAVEFORMATEXTENSIBLE mix
/// format, which is what Windows reports for anything outside plain 16-bit PCM and 32-bit
/// float, makes NAudio's `Encoding` read `Extensible`, never `IeeeFloat`. Testing
/// `BitsPerSample == 32` alone reinterpreted 32-bit integer PCM as IEEE-754 and fed the model
/// full-scale noise, with no error anywhere.
internal static class WaveBlocks
{
    /// KSDATAFORMAT_SUBTYPE_IEEE_FLOAT. Spelled out rather than taken from a library constant
    /// so it cannot drift with an NAudio upgrade.
    private static readonly Guid SubtypeIeeeFloat = new("00000003-0000-0010-8000-00aa00389b71");

    public static bool IsFloat(WaveFormat fmt) =>
        fmt.Encoding == WaveFormatEncoding.IeeeFloat
        || (fmt is WaveFormatExtensible ext && ext.SubFormat == SubtypeIeeeFloat);

    /// Interleaved float samples, or null when the format cannot be read.
    public static float[]? ToFloat(byte[] buffer, int bytes, WaveFormat fmt)
    {
        float[] block;
        if (IsFloat(fmt) && fmt.BitsPerSample == 32)
        {
            block = new float[bytes / 4];
            Buffer.BlockCopy(buffer, 0, block, 0, bytes);
        }
        else if (fmt.BitsPerSample == 16)
        {
            block = new float[bytes / 2];
            for (var i = 0; i < block.Length; i++) block[i] = BitConverter.ToInt16(buffer, i * 2) / 32768f;
        }
        else if (fmt.BitsPerSample == 32)
        {
            block = new float[bytes / 4];
            for (var i = 0; i < block.Length; i++) block[i] = BitConverter.ToInt32(buffer, i * 4) / 2147483648f;
        }
        else if (fmt.BitsPerSample == 24)
        {
            block = new float[bytes / 3];
            for (var i = 0; i < block.Length; i++)
            {
                var o = i * 3;
                var v = (buffer[o] << 8) | (buffer[o + 1] << 16) | (buffer[o + 2] << 24);
                block[i] = (v >> 8) / 8388608f;
            }
        }
        else
        {
            return null;
        }
        return block;
    }
}
