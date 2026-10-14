import Foundation

/// Turns a continuous 16 kHz stream into transcript segments as people speak.
/// Energy-based: a segment opens when the level rises above an adaptive noise
/// floor, and closes after ~0.8 s of quiet (or at 10 s, cut at the quietest
/// recent moment if need be). Each closed segment goes through the speech engine and the
/// cleanup pass, then comes back on the main thread with its time span.
public final class LiveTranscriber {
    public let speaker: String
    public var onSegment: ((TranscriptSegment) -> Void)?

    /// Tunables, in seconds unless noted.
    public var silenceToClose = 0.8
    public var minimumSegment = 0.8
    /// Someone on a call who does not pause is the normal case, not the edge case, and this
    /// is how long their words wait before anything appears. 20 s read as "nothing is being
    /// added" during a real Teams meeting on 2026-09-17; 10 s is still inside Parakeet's
    /// sweet spot and costs about 0.3 s of inference per cut.
    public var maximumSegment = 10.0
    public var prePadding = 0.3
    /// Added to every emitted timestamp: what the note had recorded before this session.
    public var timeOffset = 0.0
    /// Absolute floor for the speech threshold (RMS). Quiet rooms sit around 0.002.
    public var minimumThreshold: Float = 0.006

    private let engine: () -> SpeechEngine?
    private let options: () -> TranscriptionOptions
    private let cleaner: TextCleaner
    private let queue: DispatchQueue
    private let inferQueue: DispatchQueue

    private var buffer: [Float] = []
    private var preBuffer: [Float] = []
    private var bufferStartSample = 0
    private var samplesSeen = 0
    private var inSpeech = false
    private var silentSamples = 0
    private var noiseFloor: Float = 0.004
    /// Seconds of recent chunk levels the noise floor is estimated from.
    public var noiseWindow = 5.0
    private var recentLevels: [(sample: Int, level: Float)] = []
    /// Where to split a segment that runs long: the quietest chunk of its last seconds.
    private var quietCut: (offset: Int, level: Float)?
    /// The open segment is what was left after a forced split: emit it however short.
    private var afterForcedSplit = false

    public init(speaker: String, engine: @escaping () -> SpeechEngine?, options: @escaping () -> TranscriptionOptions, glossary: [String]) {
        self.speaker = speaker
        self.engine = engine
        self.options = options
        var c = TextCleaner(glossary: glossary)
        c.spokenCommands = false   // "question mark" in a meeting is a phrase, not a command
        self.cleaner = c
        self.queue = DispatchQueue(label: "linflow.live.\(speaker.lowercased())", qos: .userInitiated)
        self.inferQueue = DispatchQueue(label: "linflow.live.infer.\(speaker.lowercased())", qos: .userInitiated)
    }

    /// Feed audio from any thread; chunks are processed in order.
    public func feed(_ chunk: [Float]) {
        queue.async { self.process(chunk) }
    }

    /// Close whatever is open. Call when the recording stops.
    public func finish(completion: (() -> Void)? = nil) {
        queue.async {
            if self.inSpeech { self.emit(self.buffer, startSample: self.bufferStartSample) }
            self.inSpeech = false
            self.buffer.removeAll()
            self.inferQueue.async { completion?() }
        }
    }

    private var sampleRate: Double { AudioIO.sampleRate }

    private func process(_ chunk: [Float]) {
        let level = AudioIO.rms(chunk)
        samplesSeen += chunk.count
        updateNoiseFloor(level)
        let threshold = max(minimumThreshold, noiseFloor * 3)
        let speaking = level > threshold

        if !inSpeech {
            preBuffer.append(contentsOf: chunk)
            let keep = Int(prePadding * sampleRate)
            if preBuffer.count > keep { preBuffer.removeFirst(preBuffer.count - keep) }
            if speaking {
                inSpeech = true
                buffer = preBuffer
                bufferStartSample = samplesSeen - buffer.count
                silentSamples = 0
                quietCut = nil
                afterForcedSplit = false
                preBuffer.removeAll(keepingCapacity: true)
            }
            return
        }

        buffer.append(contentsOf: chunk)
        silentSamples = speaking ? 0 : silentSamples + chunk.count
        let duration = Double(buffer.count) / sampleRate
        // Once a segment runs long, remember its quietest recent chunk so a forced split
        // lands between words instead of through one.
        if duration >= maximumSegment - 4 {
            let offset = buffer.count - chunk.count
            if quietCut == nil || level < quietCut!.level { quietCut = (offset, level) }
        }
        let spoken = duration - Double(silentSamples) / sampleRate
        if Double(silentSamples) / sampleRate >= silenceToClose {
            if spoken >= minimumSegment || afterForcedSplit {
                var samples = buffer
                let keepSilence = Int(0.25 * sampleRate)
                let drop = max(0, silentSamples - keepSilence)
                if drop < samples.count { samples.removeLast(drop) }
                emit(samples, startSample: bufferStartSample)
            }
            inSpeech = false
            buffer.removeAll(keepingCapacity: true)
            quietCut = nil
            afterForcedSplit = false
        } else if duration >= maximumSegment {
            // Still talking: cut at the quiet point, no overlap, so no word is transcribed twice.
            let cut = quietCut?.offset ?? buffer.count
            let head = Array(buffer[..<cut])
            let tail = Array(buffer[cut...])
            emit(head, startSample: bufferStartSample)
            bufferStartSample += cut
            buffer = tail
            silentSamples = min(silentSamples, tail.count)
            quietCut = nil
            afterForcedSplit = true
        }
    }

    /// The floor is the quietest chunk of the last few seconds: it drops at once and rises
    /// slowly, so a fan or hold music that starts mid-meeting lifts the threshold within
    /// seconds, while continuous speech (which always has dips) cannot drag it up.
    private func updateNoiseFloor(_ level: Float) {
        recentLevels.append((samplesSeen, level))
        let horizon = samplesSeen - Int(noiseWindow * sampleRate)
        while let first = recentLevels.first, first.sample < horizon { recentLevels.removeFirst() }
        let target = recentLevels.map { $0.level }.min() ?? level
        // Clamped from below and raised additively as well, so digital silence (an idle system
        // audio tap) does not drive the floor to zero where a multiplicative rise never recovers.
        if target < noiseFloor { noiseFloor = max(noiseFloor * 0.7 + target * 0.3, 0.0005) }
        else { noiseFloor = min(target, max(noiseFloor * 1.04, noiseFloor + 0.0005), 0.05) }
    }

    private func emit(_ samples: [Float], startSample: Int) {
        guard !samples.isEmpty, AudioIO.peak(samples) > 0.01 else { return }
        let start = timeOffset + Double(startSample) / sampleRate
        let end = start + Double(samples.count) / sampleRate
        let speaker = self.speaker
        let opts = options()
        inferQueue.async { [cleaner, engine, onSegment] in
            guard let engine = engine() else { return }
            do {
                let result = try engine.transcribe(samples, options: opts)
                let text = cleaner.clean(result.text)
                guard !text.isEmpty else { return }
                let segment = TranscriptSegment(start: start, end: end, speaker: speaker, text: text)
                DispatchQueue.main.async { onSegment?(segment) }
            } catch {
                Log.error("live transcribe (\(speaker)): \(error.localizedDescription)")
            }
        }
    }
}
