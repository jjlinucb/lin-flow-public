import AVFoundation
import CryptoKit
import Foundation

/// John's voice, learned from his own dictations, and the pass that uses it to say who spoke each
/// line of a meeting.
///
/// A note labels lines by track: the mic is "You" and the call is "Others". With headphones that is
/// right by construction. Through the speakers the mic also hears the call, and in a shared room
/// (10-08: three people at one table, the call carrying their voices back 0.52 s later) both tracks
/// hold every voice. There the track says nothing about who spoke, and the voice decides.
///
/// Measured 2026-10-08 against a voiceprint from 200 of John's dictations: his held-out takes scored
/// a median 0.78, and 95% of them above 0.49. In two headphone meetings the call's lines never
/// passed 0.44. In the room meeting the lines fell into two clusters, about 0.1 to 0.25 and 0.65 to
/// 0.85. Short replies ("Okay.", "Yeah, thank you") score anywhere, so only lines of `minWords`
/// words and `SpeakerModel.minSeconds` are judged.
public enum VoiceID {
    /// At or above: John. Below `notJohn`: someone else. Between: the track's label stands.
    public static let isJohn: Float = 0.55
    public static let notJohn: Float = 0.35
    public static let minWords = 4
    /// How many of the newest dictations make the voiceprint, the fewest that will do, and how old
    /// it may get before it is made again from newer ones.
    static let enrollTakes = 200, enrollMinimum = 20
    static let enrollMaxAge: TimeInterval = 30 * 86_400

    public static var voiceprintURL: URL { ModelCatalog.appSupportDir.appendingPathComponent("voiceprint.json") }

    public struct Voiceprint: Codable {
        public var vector: [Float]
        public var takes: Int
        public var madeAt: Date
        public var model: String
    }

    // MARK: getting ready

    /// Fetches the model if it is missing and makes the voiceprint if it is missing or old. Slow:
    /// call it off the main queue. Returns why voices cannot be told apart yet, or nil once they can.
    @discardableResult
    public static func prepare() -> String? {
        if FileManager.default.fileExists(atPath: SpeakerModel.fileURL.path), !fileMatches() {
            Log.error("voices: the speaker model on disk is not the expected file, fetching it again")
            try? FileManager.default.removeItem(at: SpeakerModel.fileURL)
        }
        if !FileManager.default.fileExists(atPath: SpeakerModel.fileURL.path) {
            let done = DispatchSemaphore(value: 0)
            var failure: Error?
            ModelCatalog.download(SpeakerModel.info, progress: { _ in }) { result in
                if case .failure(let e) = result { failure = e }
                done.signal()
            }
            done.wait()
            if let failure { return "the speaker model did not download: \(failure.localizedDescription)" }
            guard fileMatches() else {
                try? FileManager.default.removeItem(at: SpeakerModel.fileURL)
                Log.error("voices: the downloaded speaker model did not match its checksum, removed it")
                return "the speaker model download was not the expected file"
            }
        }
        if let v = loadVoiceprint(), Date().timeIntervalSince(v.madeAt) < enrollMaxAge, v.model == SpeakerModel.info.id { return nil }
        guard let model = shared else { return "the speaker model did not load" }
        let t0 = Date()
        guard let v = enroll(model: model) else { return "too few saved dictations to learn John's voice from" }
        save(v)
        Log.info(String(format: "voices: voiceprint made from %d dictations in %.1f s", v.takes, Date().timeIntervalSince(t0)))
        return nil
    }

    static func fileMatches() -> Bool {
        guard let data = try? Data(contentsOf: SpeakerModel.fileURL, options: .mappedIfSafe) else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == SpeakerModel.sha256
    }

    /// Loaded on first use once the file is there, then kept. Asked again until it is.
    public static var shared: SpeakerModel? {
        lock.lock(); defer { lock.unlock() }
        if let loaded { return loaded }
        guard FileManager.default.fileExists(atPath: SpeakerModel.fileURL.path) else { return nil }
        do { loaded = try SpeakerModel() } catch { Log.error("voices: \(error.localizedDescription)") }
        return loaded
    }
    private static var loaded: SpeakerModel?
    private static let lock = NSLock()

    /// The mean direction of John's newest dictations of three seconds or more.
    public static func enroll(model: SpeakerModel, entries: [HistoryEntry] = History.all()) -> Voiceprint? {
        let takes = entries.filter { $0.audioSeconds >= 3 && $0.audioFile != nil }.suffix(enrollTakes)
        var sum = [Float](repeating: 0, count: 256), used = 0
        for t in takes {
            guard let file = t.audioFile, let samples = try? AudioIO.loadSamples(from: History.recordingsDir.appendingPathComponent(file)),
                  let e = model.embed(samples[...]), e.count == sum.count else { continue }
            for i in sum.indices { sum[i] += e[i] }
            used += 1
        }
        guard used >= enrollMinimum, let v = SpeakerModel.unit(sum) else { return nil }
        return Voiceprint(vector: v, takes: used, madeAt: Date(), model: SpeakerModel.info.id)
    }

    public static func loadVoiceprint() -> Voiceprint? {
        guard let data = try? Data(contentsOf: voiceprintURL) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(Voiceprint.self, from: data)
    }

    static func save(_ v: Voiceprint) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try? e.encode(v).write(to: voiceprintURL, options: .atomic)
    }

    // MARK: a note

    public struct Outcome {
        public var segments: [TranscriptSegment]
        public var judged = 0, moved = 0, dropped = 0
        /// Lines the voice says are John's and that stay "You", which the echo filter must leave alone.
        public var john: Set<String> = []
        public var coupling: AudioExport.Coupling = .separate
    }

    /// Says who spoke each line of a note by voice, when its tracks share voices and John's
    /// voiceprint and the model are on hand. Otherwise the lines come back as they went in.
    public static func label(_ segments: [TranscriptSegment], noteID: String) -> Outcome {
        var outcome = Outcome(segments: segments)
        let mic = NotesStore.audioURL(noteID, source: "mic"), call = NotesStore.audioURL(noteID, source: "system")
        guard let model = shared, let voice = loadVoiceprint(), voice.model == SpeakerModel.info.id,
              let link = try? AudioExport.coupling(mic: mic, call: call) else { return outcome }
        outcome.coupling = link.coupling
        guard link.coupling != .separate else { return outcome }   // headphones: the tracks already say who spoke
        // Every line is heard from the mic, the nearest to the room, where even the call's own copy of
        // John's voice is faint: 10-08, his lines scored 0.58 to 0.84 there and 0.25 to 0.6 on the call.
        // A line of the call's is found on the mic `delay` earlier. Through the speakers the call never
        // holds John's voice, so only the mic's lines are judged.
        guard let micFile = try? AVAudioFile(forReading: mic) else { return outcome }
        var scores: [String: Float] = [:]
        for s in segments where s.end - s.start >= SpeakerModel.minSeconds && NoteTranscriber.words(s.text).count >= minWords {
            guard s.speaker == "You" || link.coupling == .room else { continue }
            let shift = s.speaker == "You" ? 0 : link.delay
            guard let samples = AudioIO.read(micFile, from: s.start - shift, to: s.end - shift), let e = model.embed(samples[...]) else { continue }
            scores[s.id] = SpeakerModel.cosine(e, voice.vector)
        }
        outcome.judged = scores.count
        let r = relabel(segments, scores: scores, slack: abs(link.delay) + 1, callLag: link.coupling == .room ? link.delay : 0)
        outcome.segments = r.segments; outcome.moved = r.moved; outcome.dropped = r.dropped
        outcome.john = Set(r.segments.filter { $0.speaker == "You" && (scores[$0.id] ?? 0) >= isJohn }.map(\.id))
        return outcome
    }

    /// A line whose voice disagrees with its track moves to the other label, or, when the other
    /// track already has the same words at the same moment (the copy that came through the room or
    /// the speakers), it goes, and that copy stands. Pure, so the selftest can pin it.
    /// A call line moved to John comes back to when he said it, `callLag` earlier.
    public static func relabel(_ segments: [TranscriptSegment], scores: [String: Float], slack: Double, callLag: Double = 0)
        -> (segments: [TranscriptSegment], moved: Int, dropped: Int) {
        func voice(_ s: TranscriptSegment) -> String? {
            guard let score = scores[s.id] else { return nil }
            return score >= isJohn ? "You" : (score < notJohn ? "Others" : nil)
        }
        var out: [TranscriptSegment] = [], moved = 0, dropped = 0
        for s in segments {
            guard let v = voice(s), v != s.speaker else { out.append(s); continue }
            let mine = Set(NoteTranscriber.pairs(s.text))
            var theirs = Set<String>()
            for o in segments where o.speaker == v && o.start < s.end + slack && o.end > s.start - slack { theirs.formUnion(NoteTranscriber.pairs(o.text)) }
            if !mine.isEmpty, Double(mine.intersection(theirs).count) / Double(mine.count) >= 0.3 {
                dropped += 1
            } else {
                var t = s; t.speaker = v
                if v == "You" { t.start = max(0, t.start - callLag); t.end = max(t.start, t.end - callLag) }
                out.append(t); moved += 1
            }
        }
        return (out.sorted { $0.start < $1.start }, moved, dropped)
    }
}

extension AudioIO {
    /// A stretch of a 16 kHz mono file, by time. Nil when the file is in another format.
    public static func read(_ file: AVAudioFile, from start: Double, to end: Double) -> [Float]? {
        guard file.processingFormat.sampleRate == sampleRate, file.processingFormat.channelCount == 1 else { return nil }
        let a = max(0, AVAudioFramePosition(start * sampleRate)), b = min(file.length, AVAudioFramePosition(end * sampleRate))
        guard b > a, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(b - a)) else { return nil }
        file.framePosition = a
        guard (try? file.read(into: buf, frameCount: AVAudioFrameCount(b - a))) != nil, let p = buf.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: p, count: Int(buf.frameLength)))
    }
}
