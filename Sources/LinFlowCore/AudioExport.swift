import AVFoundation
import Foundation

/// A meeting's recording as one file to keep or send: both sides leveled, mixed and encoded.
///
/// The two WAVs share one clock (MeetingRecorder pads whatever a track falls short), so sample n
/// of each is the same moment and the mix is a sum. Each side is first brought to one speech
/// level. In five of John's notes, measured 2026-10-07 as the 95th percentile of 20 ms frame
/// levels, his own side sat 4 to 7 dB under the call's, quiet enough to strain at in a plain mix.
/// A soft limiter then keeps the sum under full scale where both talk at once.
///
/// MP3 needs LAME: AudioToolbox decodes MP3 but has no encoder (`afconvert -d .mp3` fails with
/// 'fmt?'). Homebrew's lame, which its ffmpeg also needs, is opened at run time rather than
/// linked, so a Mac without it still launches, and saves AAC (.m4a) instead.
public enum AudioExport {
    public enum Format: String { case mp3, m4a }

    /// MP3 when LAME is installed, else AAC.
    public static var preferredFormat: Format { LAME.shared != nil ? .mp3 : .m4a }

    /// The speech level each side is brought to, as the 95th percentile of its frame levels, and
    /// how far a side may move. The call measured -12 to -18 dB, John's side -19 to -24.
    static let targetLevel: Float = -16
    static let gainRange: ClosedRange<Float> = -6...12
    /// Quieter frames are silence or the recorder's padding, and don't count toward a level.
    static let liveFloor: Float = -70
    static let frameLength = 320  // 20 ms
    static let chunk = 160_000    // 10 s, a whole number of frames
    static let mp3Bitrate: Int32 = 64
    static let aacBitrate = 48_000

    public struct Result {
        public let seconds: Double
        /// The gain applied to each side, in dB, keyed "mic" and "system". A side left out has none.
        public let gains: [String: Float]
        public let coupling: Coupling
        /// How far the call trails the mic, in seconds, when they match. Negative: the mic trails.
        public let delay: Double
    }

    /// How a note's two tracks relate.
    public enum Coupling: String {
        /// Headphones: each track holds its own side.
        case separate
        /// The mic hears the call from the speakers, a moment after it plays.
        case speakers
        /// The people are in the room. The mic hears them first and the call carries them back later.
        case room
    }

    /// Exports a saved note. Throws if it has no audio.
    @discardableResult
    public static func export(noteID: String, title: String, to url: URL, format: Format,
                              progress: ((Double) -> Void)? = nil) throws -> Result {
        var tracks: [String: URL] = [:]
        for source in ["mic", "system"] {
            let u = NotesStore.audioURL(noteID, source: source)
            guard FileManager.default.fileExists(atPath: u.path) else { continue }
            _ = try? WAVWriter.repairHeader(at: u)
            tracks[source] = u
        }
        guard !tracks.isEmpty else { throw failure("This meeting has no saved audio.") }
        return try export(tracks: tracks, title: title, to: url, format: format, progress: progress)
    }

    /// Mixes 16 kHz mono tracks into one file at `url`. The file appears only once it is whole.
    @discardableResult
    public static func export(tracks: [String: URL], title: String, to url: URL, format: Format,
                              progress: ((Double) -> Void)? = nil) throws -> Result {
        var levels: [String: [Float]] = [:]
        for key in tracks.keys { levels[key] = try frameLevels(open(tracks[key]!)) }
        var link = (coupling: Coupling.separate, delay: 0.0)
        if let mic = levels["mic"], let call = levels["system"] { link = coupling(mic: mic, call: call) }
        let keys = tracks.keys.sorted()
        let files = try keys.map { try open(tracks[$0]!) }
        var gains: [String: Float] = [:]
        for key in keys { gains[key] = gain(forLevel: speechLevel(levels[key]!)) }
        if link.coupling == .speakers { gains["mic"] = min(gains["mic"]!, 0) }   // raising it would raise the call's echo
        let linear = keys.map { pow(10, gains[$0]! / 20) }
        // In a shared room the call holds the room's voices again, late. Played as recorded each voice
        // would come twice, so the call starts that much earlier, its copies under the mic's, and
        // whoever is only on the call still comes through.
        let skip = keys.map { $0 == "system" && link.coupling == .room ? AVAudioFramePosition(link.delay * AudioIO.sampleRate) : 0 }
        let total = zip(files, skip).map { max(0, $0.length - $1) }.max() ?? 0

        let fm = FileManager.default
        let dir = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)) ?? fm.temporaryDirectory
        let partial = dir.appendingPathComponent("export-\(UUID().uuidString).\(format.rawValue)")
        defer { try? fm.removeItem(at: partial); if dir != fm.temporaryDirectory { try? fm.removeItem(at: dir) } }

        let sink: Sink = format == .mp3 ? try MP3Sink(url: partial, title: title) : try AACSink(url: partial)
        for (f, k) in zip(files, skip) { f.framePosition = min(k, f.length) }
        let buffers = try files.map { try buffer($0) }
        var mix = [Float](repeating: 0, count: chunk)
        var done: AVAudioFramePosition = 0
        while done < total {
            let n = Int(min(AVAudioFramePosition(chunk), total - done))
            for i in 0..<n { mix[i] = 0 }
            for (j, f) in files.enumerated() where f.framePosition < f.length {
                let b = buffers[j]
                try f.read(into: b, frameCount: AVAudioFrameCount(n))
                let s = b.floatChannelData![0], g = linear[j]
                for i in 0..<Int(b.frameLength) { mix[i] += s[i] * g }
            }
            for i in 0..<n { mix[i] = limit(mix[i]) }
            try sink.write(mix[0..<n])
            done += AVAudioFramePosition(n)
            progress?(Double(done) / Double(total))
        }
        try sink.finish()
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: partial)   // the old file stays until the new one is in place
        } else {
            try fm.moveItem(at: partial, to: url)
        }
        return Result(seconds: Double(total) / AudioIO.sampleRate, gains: gains, coupling: link.coupling, delay: link.delay)
    }

    /// The level a side's speech reaches: the 95th percentile of its live frames, in dB. Nil for
    /// a side with nothing above the floor.
    public static func speechLevel(_ frames: [Float]) -> Float? {
        let live = frames.filter { $0 > liveFloor }.sorted()
        return live.isEmpty ? nil : live[Int(Float(live.count - 1) * 0.95)]
    }

    /// Matches the mic's loudness against the call's, ten seconds at a time wherever the call talks,
    /// at every delay up to 1.2 s either way. Measured 2026-10-08 on six notes, as the share of
    /// stretches that matched (r > 0.4): 0 to 2% in headphones. 88% through the speakers, the mic
    /// 0.12 s behind the call (10-02). 100% in a shared room, the call 0.52 s behind the mic (10-08).
    public static func coupling(mic: [Float], call: [Float]) -> (coupling: Coupling, delay: Double) {
        let n = min(mic.count, call.count), w = 500, reach = 60   // 20 ms frames
        var windows = 0, lags: [Int] = []
        var start = reach
        while start + w + reach <= n {
            defer { start += w }
            let loud = call[start..<start + w].sorted()
            guard loud[w * 9 / 10] > -45 else { continue }
            windows += 1
            let a = Array(mic[start..<start + w])
            let ma = a.reduce(0, +) / Float(w)
            let va = a.reduce(0) { $0 + ($1 - ma) * ($1 - ma) }
            guard va > 0 else { continue }
            var best: (r: Float, lag: Int) = (-1, 0)
            for lag in -reach...reach {
                let b = call[(start + lag)..<(start + lag + w)]
                let mb = b.reduce(0, +) / Float(w)
                var cov: Float = 0, vb: Float = 0
                for (x, y) in zip(a, b) { cov += (x - ma) * (y - mb); vb += (y - mb) * (y - mb) }
                guard vb > 0 else { continue }
                let r = cov / (va * vb).squareRoot()
                if r > best.r { best = (r, lag) }
            }
            if best.r > 0.4 { lags.append(best.lag) }
        }
        guard windows > 0, lags.count * 2 > windows else { return (.separate, 0) }
        let delay = Double(lags.sorted()[lags.count / 2]) * 0.02
        return (delay >= 0.1 ? .room : .speakers, delay)
    }

    /// The coupling of a note's two saved tracks.
    public static func coupling(mic: URL, call: URL) throws -> (coupling: Coupling, delay: Double) {
        coupling(mic: try frameLevels(open(mic)), call: try frameLevels(open(call)))
    }

    /// Every whole 20 ms frame's level, in dB.
    static func frameLevels(_ file: AVAudioFile) throws -> [Float] {
        file.framePosition = 0
        let b = try buffer(file)
        var levels: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: b)
            let s = b.floatChannelData![0]
            var at = 0
            while at + frameLength <= Int(b.frameLength) {
                var sum: Float = 0
                for i in at..<(at + frameLength) { sum += s[i] * s[i] }
                levels.append(10 * log10(sum / Float(frameLength) + 1e-18))
                at += frameLength
            }
        }
        return levels
    }

    /// The gain, in dB, that brings a side's speech level to the target. A silent side stays as it is.
    public static func gain(forLevel level: Float?) -> Float {
        guard let level else { return 0 }
        return min(max(targetLevel - level, gainRange.lowerBound), gainRange.upperBound)
    }

    /// Untouched below 0.75, then bent smoothly toward 0.95 and never past it. The half decibel
    /// under full scale is room for the encoder, whose decoded output overshoots its input.
    public static func limit(_ x: Float) -> Float {
        let knee: Float = 0.75, ceiling: Float = 0.95
        let m = abs(x)
        guard m > knee else { return x }
        let y = knee + (ceiling - knee) * tanh((m - knee) / (ceiling - knee))
        return x < 0 ? -y : y
    }

    private static func open(_ url: URL) throws -> AVAudioFile {
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        guard fmt.sampleRate == AudioIO.sampleRate, fmt.channelCount == 1 else {
            throw failure("\(url.lastPathComponent) is \(Int(fmt.sampleRate)) Hz with \(fmt.channelCount) channels, where a note's audio is 16 kHz mono.")
        }
        return f
    }

    private static func buffer(_ f: AVAudioFile) throws -> AVAudioPCMBuffer {
        guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(chunk)) else {
            throw failure("Could not allocate an audio buffer.")
        }
        return b
    }

    static func failure(_ text: String) -> NSError {
        NSError(domain: "LinFlow.AudioExport", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

private protocol Sink {
    func write(_ samples: ArraySlice<Float>) throws
    func finish() throws
}

/// Constant 64 kbit/s, which is plenty for 16 kHz speech: about 29 MB an hour. Constant, so the
/// file needs no VBR header for players to know its length.
private final class MP3Sink: Sink {
    private let lame: LAME
    private var gfp: OpaquePointer?
    private let out: FileHandle
    private var pcm: [Int16] = []
    private var mp3: [UInt8] = []

    init(url: URL, title: String) throws {
        guard let lame = LAME.shared else { throw AudioExport.failure("MP3 needs LAME. Install it with: brew install lame") }
        self.lame = lame
        guard let gfp = lame.initialize() else { throw AudioExport.failure("LAME did not start.") }
        self.gfp = gfp
        _ = lame.setChannels(gfp, 1)
        _ = lame.setInRate(gfp, Int32(AudioIO.sampleRate))
        _ = lame.setMode(gfp, 3)  // MONO
        _ = lame.setBitrate(gfp, AudioExport.mp3Bitrate)
        _ = lame.setQuality(gfp, 2)
        _ = lame.setVbrTag(gfp, 0)
        if let tags = lame.tags {
            tags.initialize(gfp)
            tags.utf8Only(gfp)
            tags.title(gfp, title)
            tags.artist(gfp, "Lin Flow")
        }
        guard lame.initParams(gfp) >= 0 else { lame.close(gfp); self.gfp = nil; throw AudioExport.failure("LAME refused the settings.") }
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let out = try? FileHandle(forWritingTo: url) else {
            lame.close(gfp); self.gfp = nil
            throw AudioExport.failure("Could not write \(url.lastPathComponent).")
        }
        self.out = out
    }

    deinit {
        if let gfp { lame.close(gfp) }
        try? out.close()
    }

    func write(_ samples: ArraySlice<Float>) throws {
        guard let gfp else { return }
        pcm.removeAll(keepingCapacity: true)
        for s in samples { pcm.append(Int16(max(-1, min(1, s)) * 32767)) }
        let room = pcm.count * 5 / 4 + 7200
        if mp3.count < room { mp3 = [UInt8](repeating: 0, count: room) }
        let n = pcm.withUnsafeBufferPointer { p in
            mp3.withUnsafeMutableBufferPointer { m in
                lame.encode(gfp, p.baseAddress, p.baseAddress, Int32(p.count), m.baseAddress, Int32(m.count))
            }
        }
        guard n >= 0 else { throw AudioExport.failure("LAME failed to encode (\(n)).") }
        try out.write(contentsOf: mp3[0..<Int(n)])
    }

    func finish() throws {
        guard let gfp else { return }
        if mp3.count < 7200 { mp3 = [UInt8](repeating: 0, count: 7200) }
        let n = mp3.withUnsafeMutableBufferPointer { lame.flush(gfp, $0.baseAddress, Int32($0.count)) }
        if n > 0 { try out.write(contentsOf: mp3[0..<Int(n)]) }
        lame.close(gfp)
        self.gfp = nil
        try out.close()
    }
}

private final class AACSink: Sink {
    private var file: AVAudioFile?

    init(url: URL) throws {
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioIO.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: AudioExport.aacBitrate,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ samples: ArraySlice<Float>) throws {
        guard let file, let b = AudioIO.monoBuffer(Array(samples), sampleRate: AudioIO.sampleRate) else { return }
        try file.write(from: b)
    }

    func finish() throws {
        file?.close()
        file = nil
    }
}

/// Homebrew's libmp3lame, opened by path. Nil when it isn't installed.
final class LAME {
    static let shared = LAME()
    static let paths = ["/opt/homebrew/opt/lame/lib/libmp3lame.0.dylib", "/usr/local/opt/lame/lib/libmp3lame.0.dylib"]

    typealias New = @convention(c) () -> OpaquePointer?
    typealias SetInt = @convention(c) (OpaquePointer?, Int32) -> Int32
    typealias Call = @convention(c) (OpaquePointer?) -> Int32
    typealias Encode = @convention(c) (OpaquePointer?, UnsafePointer<Int16>?, UnsafePointer<Int16>?, Int32,
                                       UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    typealias Flush = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32

    let initialize: New
    let setChannels: SetInt, setInRate: SetInt, setMode: SetInt, setBitrate: SetInt, setQuality: SetInt, setVbrTag: SetInt
    let initParams: Call
    let encode: Encode
    let flush: Flush
    private let closeFn: Call
    /// ID3 tags, written only by a LAME that can write them in UTF-8 (4.0 on). Nil otherwise.
    let tags: Tags?

    struct Tags {
        typealias Void1 = @convention(c) (OpaquePointer?) -> Void
        typealias Text = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
        let initialize: Void1, utf8Only: Void1
        private let setTitle: Text, setArtist: Text
        init?(_ sym: (String) -> UnsafeMutableRawPointer?) {
            guard let a = sym("id3tag_init"), let b = sym("id3tag_v2_4_UTF8_only"),
                  let c = sym("id3tag_set_title"), let d = sym("id3tag_set_artist") else { return nil }
            initialize = unsafeBitCast(a, to: Void1.self)
            utf8Only = unsafeBitCast(b, to: Void1.self)
            setTitle = unsafeBitCast(c, to: Text.self)
            setArtist = unsafeBitCast(d, to: Text.self)
        }
        func title(_ g: OpaquePointer, _ s: String) { s.withCString { setTitle(g, $0) } }
        func artist(_ g: OpaquePointer, _ s: String) { s.withCString { setArtist(g, $0) } }
    }

    func close(_ g: OpaquePointer) { _ = closeFn(g) }

    private init?() {
        guard let handle = Self.paths.lazy.compactMap({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }).first else { return nil }
        func sym(_ name: String) -> UnsafeMutableRawPointer? { dlsym(handle, name) }
        guard let a = sym("lame_init"), let b = sym("lame_set_num_channels"), let c = sym("lame_set_in_samplerate"),
              let d = sym("lame_set_mode"), let e = sym("lame_set_brate"), let f = sym("lame_set_quality"),
              let g = sym("lame_set_bWriteVbrTag"), let h = sym("lame_init_params"), let i = sym("lame_encode_buffer"),
              let j = sym("lame_encode_flush"), let k = sym("lame_close") else { return nil }
        initialize = unsafeBitCast(a, to: New.self)
        setChannels = unsafeBitCast(b, to: SetInt.self)
        setInRate = unsafeBitCast(c, to: SetInt.self)
        setMode = unsafeBitCast(d, to: SetInt.self)
        setBitrate = unsafeBitCast(e, to: SetInt.self)
        setQuality = unsafeBitCast(f, to: SetInt.self)
        setVbrTag = unsafeBitCast(g, to: SetInt.self)
        initParams = unsafeBitCast(h, to: Call.self)
        encode = unsafeBitCast(i, to: Encode.self)
        flush = unsafeBitCast(j, to: Flush.self)
        closeFn = unsafeBitCast(k, to: Call.self)
        tags = Tags(sym)
    }
}
