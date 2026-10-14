import AVFoundation
import Foundation

/// Transcribes a note's saved audio end to end, after the meeting, and rewrites the
/// transcript from it.
///
/// The live transcript has to show something now, so it cuts wherever the speaker pauses
/// or at 10 s, whichever comes first, and the model never sees more than that. This pass
/// has the whole recording: it finds the real pauses with hindsight, hands the model up to
/// 28 s of context at a time, cuts a long stretch at its quietest moment instead of
/// mid-word, and never drops the words on either side of a forced split. It is the
/// transcript Summarize should read, and it can be run again whenever a better model is
/// installed, which is the reason the audio is kept at all.
public enum NoteTranscriber {
    /// A stretch of speech, in samples at 16 kHz, `end` exclusive.
    public struct Region: Equatable {
        public var start: Int
        public var end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
    }

    /// Tunables, in seconds.
    public static var frameSeconds = 0.1
    /// Both engines decode long clips in pieces past this (whisper.cpp at 28 s), so a region
    /// never exceeds it and the engine sees each region whole.
    public static var maxRegionSeconds = 28.0
    /// Two stretches of speech this close together are transcribed as one, for context.
    public static var mergeGapSeconds = 2.0
    /// Quiet inside a stretch that does not end it.
    public static var closeGapSeconds = 0.8
    public static var padSeconds = 0.3
    /// Anything with less speech than this is a click or a cough, not a segment.
    public static var minSpeechSeconds = 0.4
    /// Absolute floor for the speech threshold (RMS); same as the live path.
    public static var minimumThreshold: Float = 0.006

    public static var sources: [(file: String, speaker: String)] { [("mic", "You"), ("system", "Others")] }

    /// Speech regions from per-frame RMS levels of one track. The noise floor is the 10th
    /// percentile of all frames (so an hour of hold music or fan noise lifts it, and digital
    /// silence does not drag it to zero), speech is anything above max(0.006, 3x floor).
    public static func regions(levels: [Float], totalSamples: Int, frameSeconds: Double = frameSeconds) -> [Region] {
        guard !levels.isEmpty, totalSamples > 0 else { return [] }
        let frameSamples = max(1, Int(frameSeconds * AudioIO.sampleRate))
        let sorted = levels.sorted()
        let floor = min(max(sorted[sorted.count / 10], 0.0005), 0.05)
        let threshold = max(minimumThreshold, floor * 3)
        // Rounded, not truncated: 0.3 / 0.1 is 2.9999999999999996 in floating point.
        func frames(_ seconds: Double) -> Int { Int((seconds / frameSeconds).rounded()) }
        let closeGap = max(1, frames(closeGapSeconds))
        let mergeGap = max(1, frames(mergeGapSeconds))
        let maxLen = max(2, frames(maxRegionSeconds))
        let pad = frames(padSeconds)
        let minSpeech = max(1, frames(minSpeechSeconds))
        let totalFrames = levels.count

        // Runs of speech frames, a run tolerating up to closeGap quiet frames inside it.
        var runs: [(start: Int, end: Int, speech: Int)] = []
        var open: (start: Int, last: Int, speech: Int)?
        for (i, level) in levels.enumerated() {
            let speaking = level > threshold
            if var o = open {
                if speaking { o.last = i; o.speech += 1; open = o }
                else if i - o.last > closeGap { runs.append((o.start, o.last + 1, o.speech)); open = nil }
                else { open = o }
            } else if speaking {
                open = (i, i, 1)
            }
        }
        if let o = open { runs.append((o.start, o.last + 1, o.speech)) }
        runs.removeAll { $0.speech < minSpeech }

        // Neighbours close together become one region, for context, while it stays short.
        var merged: [(start: Int, end: Int)] = []
        for r in runs {
            if let last = merged.last, r.start - last.end <= mergeGap, r.end - last.start <= maxLen {
                merged[merged.count - 1].end = r.end
            } else {
                merged.append((r.start, r.end))
            }
        }

        // Pad both sides without overlapping the neighbour, then split anything long at its
        // quietest frame in the second half.
        var out: [Region] = []
        for (i, m) in merged.enumerated() {
            var start = max(0, m.start - pad)
            let end = min(totalFrames, m.end + pad)
            if let prev = merged[safe: i - 1] { start = max(start, prev.end) }
            var pieces: [(Int, Int)] = []
            var s = start
            while end - s > maxLen {
                var cut = s + maxLen, quietest = Float.greatestFiniteMagnitude
                for f in (s + maxLen / 2)..<(s + maxLen) where levels[f] < quietest { quietest = levels[f]; cut = f }
                pieces.append((s, cut)); s = cut
            }
            pieces.append((s, end))
            for p in pieces where p.1 > p.0 {
                out.append(Region(start: p.0 * frameSamples, end: min(totalSamples, p.1 * frameSamples)))
            }
        }
        return out.filter { $0.end > $0.start }
    }

    /// RMS per frame over a whole track, read in 30 s blocks so an hour of audio never sits
    /// in memory at once.
    public static func levels(read: (Int, Int) -> [Float], totalSamples: Int, frameSeconds: Double = frameSeconds) -> [Float] {
        let frameSamples = max(1, Int(frameSeconds * AudioIO.sampleRate))
        let block = frameSamples * 300
        var levels: [Float] = []
        levels.reserveCapacity(totalSamples / frameSamples + 1)
        var pos = 0
        while pos < totalSamples {
            let n = min(block, totalSamples - pos)
            let samples = read(pos, n)
            var i = 0
            while i + frameSamples <= samples.count {
                levels.append(AudioIO.rms(Array(samples[i..<i + frameSamples])))
                i += frameSamples
            }
            if i < samples.count, samples.count - i >= frameSamples / 2 { levels.append(AudioIO.rms(Array(samples[i...]))) }
            pos += n
        }
        return levels
    }

    /// One saved track. Our own files are 16 kHz mono and are read straight from disk in
    /// pieces; anything else is decoded whole through AVFoundation first.
    public static func transcribe(file url: URL, speaker: String, engine: SpeechEngine, options: TranscriptionOptions,
                                  glossary: [String], progress: ((String) -> Void)? = nil) throws -> [TranscriptSegment] {
        var cleaner = TextCleaner(glossary: glossary)
        cleaner.spokenCommands = false   // "question mark" in a meeting is a phrase, not a command
        let file = try AVAudioFile(forReading: url)
        let native = file.processingFormat.sampleRate == AudioIO.sampleRate && file.processingFormat.channelCount == 1
        var whole: [Float] = []
        let total: Int
        if native {
            total = Int(file.length)
        } else {
            whole = try AudioIO.loadSamples(from: url)
            total = whole.count
        }
        let read: (Int, Int) -> [Float] = { start, count in
            if !native { return Array(whole[start..<min(whole.count, start + count)]) }
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { return [] }
            file.framePosition = AVAudioFramePosition(start)
            guard (try? file.read(into: buf, frameCount: AVAudioFrameCount(count))) != nil, let p = buf.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: p, count: Int(buf.frameLength)))
        }
        let regions = self.regions(levels: levels(read: read, totalSamples: total), totalSamples: total)
        var segments: [TranscriptSegment] = []
        for (i, r) in regions.enumerated() {
            progress?("\(speaker) \(i + 1)/\(regions.count)")
            let samples = read(r.start, r.end - r.start)
            guard AudioIO.peak(samples) > 0.01 else { continue }
            let result = try engine.transcribe(samples, options: options)
            let text = cleaner.clean(result.text)
            guard !text.isEmpty else { continue }
            segments.append(TranscriptSegment(start: Double(r.start) / AudioIO.sampleRate, end: Double(r.end) / AudioIO.sampleRate,
                                              speaker: speaker, text: text))
        }
        return segments
    }

    /// Every saved track of a note, merged in time order. Throws if the note has no audio.
    public static func transcribe(noteID: String, engine: SpeechEngine, options: TranscriptionOptions, glossary: [String],
                                  progress: ((String) -> Void)? = nil,
                                  voices: ((String) -> Void)? = nil) throws -> [TranscriptSegment] {
        var all: [TranscriptSegment] = []
        var found = false
        for s in sources {
            let url = NotesStore.audioURL(noteID, source: s.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            found = true
            _ = try? WAVWriter.repairHeader(at: url)
            all += try transcribe(file: url, speaker: s.speaker, engine: engine, options: options, glossary: glossary, progress: progress)
        }
        guard found else {
            throw NSError(domain: "LinFlow.Notes", code: 3, userInfo: [NSLocalizedDescriptionKey: "This meeting has no saved audio to transcribe."])
        }
        let merged = all.sorted { $0.start < $1.start }
        // The voice first, where the tracks share voices: it keeps the right copy of each line and
        // says who spoke it. The echo filter then takes what the voice could not judge.
        progress?("Telling voices apart…")
        let voiced = VoiceID.label(merged, noteID: noteID)
        if voiced.judged > 0 {
            let line = "voices (\(voiced.coupling.rawValue)): \(voiced.judged) lines judged, \(voiced.moved) moved to the other speaker, \(voiced.dropped) copies dropped"
            Log.info("notes: \(noteID) \(line)")
            voices?(line)
        }
        let kept = dropEcho(voiced.segments, keep: voiced.john)
        if kept.count < voiced.segments.count { Log.info("notes: dropped \(voiced.segments.count - kept.count) microphone segment(s) that echoed the other side") }
        return kept
    }

    /// Without headphones the microphone hears the speakers, so every sentence the other side
    /// says comes back a second time as "You". On 2026-10-02, a 29-minute Zoom training, 80 of
    /// 87 "You" segments were the presenter. A "You" segment goes when most of its word pairs
    /// are in "Others" segments overlapping it in time; the system track is the clean copy.
    /// Pairs, not single words, so "I think that is right" said over someone's long sentence
    /// stays. Segments under three words stay too, since "yeah" and "okay" are too common to judge.
    public static func dropEcho(_ segments: [TranscriptSegment], slack: Double = 1.0, share: Double = 0.5,
                                keep: Set<String> = []) -> [TranscriptSegment] {
        let others = segments.filter { $0.speaker == "Others" }
        guard !others.isEmpty else { return segments }
        return segments.filter { s in
            guard s.speaker == "You", !keep.contains(s.id) else { return true }
            guard words(s.text).count >= 3 else { return true }
            let mine = pairs(s.text)
            var theirs = Set<String>()
            for o in others where o.start < s.end + slack && o.end > s.start - slack { theirs.formUnion(pairs(o.text)) }
            let shared = mine.filter { theirs.contains($0) }.count
            return Double(shared) / Double(mine.count) <= share
        }
    }

    static func pairs(_ text: String) -> [String] {
        let w = words(text)
        return w.count < 2 ? w : (1..<w.count).map { w[$0 - 1] + " " + w[$0] }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
