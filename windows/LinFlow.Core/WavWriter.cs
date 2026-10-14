using System.Buffers.Binary;
using System.Text;

namespace LinFlow.Core;

/// A 16 kHz mono 16-bit WAV that stays readable if the process dies. Ported from
/// ../../Sources/LinFlowCore/WAVWriter.swift.
///
/// Library writers (AVAudioFile on the Mac, NAudio's WaveFileWriter here unless it is flushed)
/// fill in the RIFF and data sizes when the file is closed, so a recording cut short by a
/// crash, a force quit or a dead battery reads as 0 seconds in every player with all of its
/// audio still in the file. This writer brings the header up to date about once a second, so a
/// crash costs at most the last second, and `RepairHeader` fixes any WAV from its size.
public sealed class WavWriter : IDisposable
{
    public string FilePath { get; }
    /// Frames in the data chunk, including anything already in the file when appending.
    public long Frames { get; private set; }
    public int SampleRate { get; }
    /// How often the header is rewritten, in frames. One second by default.
    public int HeaderInterval { get; set; } = 16_000;

    // Every FileStream in this file shares ReadWrite. RepairHeader opens the file for writing
    // while this writer still holds it, and Windows denies that unless both handles allow a
    // writer. Unix does not enforce share modes, so a narrower one passes on the Mac and throws
    // IOException here.
    private readonly FileStream _stream;
    private readonly int _dataOffset;
    private long _framesAtLastHeader;
    private bool _closed;

    /// Creates the file, or with `append` continues one that already exists (repairing its
    /// header first if the last writer died). A file at the path that is not our format is
    /// moved aside rather than overwritten: nothing recorded is ever destroyed here.
    public WavWriter(string path, int sampleRate = 16_000, bool append = false)
    {
        FilePath = path;
        SampleRate = sampleRate;
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        if (File.Exists(path))
        {
            WavInfo? info = null;
            if (append)
            {
                try { RepairHeader(path); } catch (Exception) { /* not a WAV: moved aside below */ }
                info = Info(path);
                if (info is not null && (info.SampleRate != sampleRate || info.Channels != 1 || info.Bits != 16)) info = null;
            }
            if (info is not null)
            {
                _stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);
                _dataOffset = info.DataOffset;
                Frames = info.DataBytes / 2;
                _framesAtLastHeader = Frames;
                _stream.Seek(info.DataOffset + info.DataBytes, SeekOrigin.Begin);
                return;
            }
            var aside = Path.ChangeExtension(path, null) + $".previous-{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}.wav";
            File.Move(path, aside);
            Log.Info($"moved {Path.GetFileName(path)} aside as {Path.GetFileName(aside)} instead of overwriting it");
        }

        _stream = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.ReadWrite);
        _dataOffset = 44;
        var header = Header(0, sampleRate);
        _stream.Write(header, 0, header.Length);
        _stream.Flush();
    }

    /// Appends samples (clipped to ±1) as 16-bit little-endian PCM and refreshes the header once
    /// `HeaderInterval` frames have gone by since it was last written.
    public void Append(ReadOnlySpan<float> samples)
    {
        if (samples.Length == 0) return;
        var pcm = new byte[samples.Length * 2];
        for (var i = 0; i < samples.Length; i++)
        {
            var v = (short)Math.Round(Math.Clamp(samples[i], -1f, 1f) * 32767f);
            pcm[i * 2] = (byte)(v & 0xFF);
            pcm[i * 2 + 1] = (byte)((v >> 8) & 0xFF);
        }
        _stream.Write(pcm, 0, pcm.Length);
        Frames += samples.Length;
        if (Frames - _framesAtLastHeader >= HeaderInterval) UpdateHeader();
    }

    /// Writes the final header and closes the file. Safe to call twice.
    public void Close()
    {
        if (_closed) return;
        _closed = true;
        UpdateHeader();
        _stream.Flush(true);
        _stream.Dispose();
    }

    public void Dispose() => Close();

    private void UpdateHeader()
    {
        var dataBytes = Frames * 2;
        var end = _stream.Position;
        _stream.Seek(4, SeekOrigin.Begin);
        _stream.Write(Le32(Clamp(_dataOffset - 8 + dataBytes)));
        _stream.Seek(_dataOffset - 4, SeekOrigin.Begin);
        _stream.Write(Le32(Clamp(dataBytes)));
        _stream.Seek(end, SeekOrigin.Begin);
        _stream.Flush();
        _framesAtLastHeader = Frames;
    }

    private static uint Clamp(long v) => (uint)Math.Min(uint.MaxValue, Math.Max(0, v));

    internal static byte[] Header(long dataBytes, int sampleRate)
    {
        var d = new byte[44];
        Encoding.ASCII.GetBytes("RIFF").CopyTo(d, 0);
        BinaryPrimitives.WriteUInt32LittleEndian(d.AsSpan(4), Clamp(36 + dataBytes));
        Encoding.ASCII.GetBytes("WAVE").CopyTo(d, 8);
        Encoding.ASCII.GetBytes("fmt ").CopyTo(d, 12);
        BinaryPrimitives.WriteUInt32LittleEndian(d.AsSpan(16), 16);
        BinaryPrimitives.WriteUInt16LittleEndian(d.AsSpan(20), 1);      // PCM
        BinaryPrimitives.WriteUInt16LittleEndian(d.AsSpan(22), 1);      // mono
        BinaryPrimitives.WriteUInt32LittleEndian(d.AsSpan(24), (uint)sampleRate);
        BinaryPrimitives.WriteUInt32LittleEndian(d.AsSpan(28), (uint)(sampleRate * 2));
        BinaryPrimitives.WriteUInt16LittleEndian(d.AsSpan(32), 2);      // block align
        BinaryPrimitives.WriteUInt16LittleEndian(d.AsSpan(34), 16);     // bits
        Encoding.ASCII.GetBytes("data").CopyTo(d, 36);
        BinaryPrimitives.WriteUInt32LittleEndian(d.AsSpan(40), Clamp(dataBytes));
        return d;
    }

    private static byte[] Le32(uint v)
    {
        var b = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(b, v);
        return b;
    }

    public sealed record WavInfo(int SampleRate, int Channels, int Bits, int DataOffset, long DataBytes, long FileSize)
    {
        public double Seconds => Channels > 0 && Bits > 0 && SampleRate > 0
            ? DataBytes / (double)(Channels * (Bits / 8) * SampleRate) : 0;
    }

    /// Walks the RIFF chunks (some writers put a JUNK or LIST chunk before "fmt ") to find the
    /// format and the data chunk. Null if the file is not a WAV. Reads a file another process is
    /// still writing.
    public static WavInfo? Info(string path)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var head = new byte[4096];
            var n = fs.Read(head, 0, head.Length);
            if (n < 12) return null;
            string Tag(int o) => o + 4 <= n ? Encoding.ASCII.GetString(head, o, 4) : "";
            long U32(int o) => o + 4 <= n ? BinaryPrimitives.ReadUInt32LittleEndian(head.AsSpan(o)) : 0;
            int U16(int o) => o + 2 <= n ? BinaryPrimitives.ReadUInt16LittleEndian(head.AsSpan(o)) : 0;
            if (Tag(0) != "RIFF" || Tag(8) != "WAVE") return null;
            var o = 12;
            int rate = 0, channels = 0, bits = 0;
            while (o + 8 <= n)
            {
                var id = Tag(o);
                var len = U32(o + 4);
                if (id == "fmt ") { channels = U16(o + 10); rate = (int)U32(o + 12); bits = U16(o + 22); }
                else if (id == "data") return new WavInfo(rate, channels, bits, o + 8, len, fs.Length);
                o += (int)Math.Min(int.MaxValue, 8 + len + (len & 1));
            }
            return null;
        }
        catch (IOException) { return null; }
    }

    /// Seconds of audio in the file according to its header, null if it is not a WAV.
    public static double? Duration(string path) => Info(path)?.Seconds;

    /// Makes the header agree with the file's size when a writer died before closing it: the data
    /// chunk says 0 bytes (a library writer) or ends short of the file (this writer, by under a
    /// second). Returns true if it changed anything. A data chunk followed by another well-formed
    /// chunk is somebody else's valid file and is left alone.
    public static bool RepairHeader(string path)
    {
        var info = Info(path) ?? throw new InvalidDataException($"{Path.GetFileName(path)} is not a WAV file");
        var actual = info.FileSize - info.DataOffset;
        if (actual < 0 || info.DataBytes == actual) return false;
        if (info.DataBytes > 0 && info.DataBytes < actual)
        {
            using var r = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            r.Seek(info.DataOffset + info.DataBytes + (info.DataBytes & 1), SeekOrigin.Begin);
            var tail = new byte[8];
            if (r.Read(tail, 0, 8) == 8)
            {
                var id = Encoding.ASCII.GetString(tail, 0, 4);
                if (id.All(c => char.IsLetterOrDigit(c) || c == ' ')) return false;
            }
        }
        using var w = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);
        w.Seek(4, SeekOrigin.Begin);
        w.Write(Le32(Clamp(info.FileSize - 8)));
        w.Seek(info.DataOffset - 4, SeekOrigin.Begin);
        w.Write(Le32(Clamp(actual)));
        return true;
    }

    /// The samples of one of our own files as float, `count` frames from `start`, read straight
    /// from disk so a two-hour track never has to sit in memory. For NoteTranscriber.
    public static float[] ReadFrames(string path, WavInfo info, long start, int count)
    {
        if (info.Bits != 16 || info.Channels != 1) throw new InvalidDataException($"{Path.GetFileName(path)} is not 16-bit mono");
        var available = (int)Math.Max(0, Math.Min(count, info.DataBytes / 2 - start));
        if (available <= 0) return Array.Empty<float>();
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        fs.Seek(info.DataOffset + start * 2, SeekOrigin.Begin);
        var bytes = new byte[available * 2];
        var got = 0;
        while (got < bytes.Length)
        {
            var n = fs.Read(bytes, got, bytes.Length - got);
            if (n <= 0) break;
            got += n;
        }
        var out16 = new float[got / 2];
        for (var i = 0; i < out16.Length; i++) out16[i] = BinaryPrimitives.ReadInt16LittleEndian(bytes.AsSpan(i * 2)) / 32768f;
        return out16;
    }
}
