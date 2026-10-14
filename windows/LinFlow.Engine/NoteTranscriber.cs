using LinFlow.Core;

namespace LinFlow.Engine;

/// Transcribes a note's saved audio end to end, after the meeting, and rewrites the transcript
/// from it. Ported from ../../Sources/LinFlowCore/NoteTranscriber.swift; the region finding is
/// SpeechRegions in LinFlow.Core, where the tests reach it.
///
/// The live transcript has to show something now, so it cuts wherever the speaker pauses or at
/// 10 s, whichever comes first. This pass has the whole recording: it finds the real pauses
/// with hindsight, hands the model up to 28 s of context at a time, cuts a long stretch at its
/// quietest moment instead of mid-word, and never drops the words on either side of a forced
/// split. It can be run again whenever a better model is installed, which is the reason the
/// audio is kept at all.
public static class NoteTranscriber
{
    /// One saved track. Our own files (16 kHz mono 16-bit) are read from disk in pieces; anything
    /// else is decoded whole through NAudio first.
    public static List<TranscriptSegment> TranscribeFile(string path, string speaker, ParakeetEngine engine, TextCleaner cleaner,
                                                         Action<string>? progress = null)
    {
        try { WavWriter.RepairHeader(path); } catch (InvalidDataException) { /* not a WAV we wrote; NAudio decides below */ }
        var info = WavWriter.Info(path);
        Func<long, int, float[]> read;
        long total;
        if (info is { SampleRate: 16_000, Channels: 1, Bits: 16 })
        {
            total = info.DataBytes / 2;
            read = (start, count) => WavWriter.ReadFrames(path, info, start, count);
        }
        else
        {
            var whole = AudioIO.ReadWav(path);
            total = whole.Length;
            read = (start, count) =>
            {
                var n = (int)Math.Max(0, Math.Min(count, whole.Length - start));
                var piece = new float[n];
                Array.Copy(whole, start, piece, 0, n);
                return piece;
            };
        }

        var levels = SpeechRegions.Levels(read, total);
        var regions = SpeechRegions.Find(levels, (int)Math.Min(int.MaxValue, total));
        var segments = new List<TranscriptSegment>();
        for (var i = 0; i < regions.Count; i++)
        {
            progress?.Invoke($"{speaker} {i + 1}/{regions.Count}");
            var r = regions[i];
            var samples = read(r.Start, r.End - r.Start);
            if (AudioIO.Peak(samples) <= 0.01f) continue;
            var result = engine.Transcribe(samples);
            var text = cleaner.Clean(result.Text);
            if (string.IsNullOrWhiteSpace(text)) continue;
            segments.Add(new TranscriptSegment
            {
                Start = r.Start / (double)AudioIO.SampleRate,
                End = r.End / (double)AudioIO.SampleRate,
                Speaker = speaker,
                Text = text,
            });
        }
        return segments;
    }

    /// Every saved track of a note, merged in time order. Throws if the note has no audio.
    public static List<TranscriptSegment> TranscribeNote(NotesStore store, string id, ParakeetEngine engine, TextCleaner cleaner,
                                                         Action<string>? progress = null)
    {
        var all = new List<TranscriptSegment>();
        var found = false;
        foreach (var (file, speaker) in NotesStore.Sources)
        {
            var path = store.AudioPath(id, file);
            if (!File.Exists(path)) continue;
            found = true;
            all.AddRange(TranscribeFile(path, speaker, engine, cleaner, progress));
        }
        if (!found) throw new FileNotFoundException("This meeting has no saved audio to transcribe.");
        return all.OrderBy(s => s.Start).ToList();
    }

    /// "Parakeet · parakeet-tdt-0.6b-v3-q8_0", the way the Mac names the model in note.json.
    public static string DisplayName(ParakeetEngine engine)
    {
        var id = Path.GetFileNameWithoutExtension(engine.ModelPath);
        if (id.StartsWith("ggml-", StringComparison.Ordinal)) id = id[5..];
        return "Parakeet · " + id;
    }
}
