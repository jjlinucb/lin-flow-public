import AVFoundation
import Foundation

/// 16 kHz mono float32 is what whisper.cpp (and Parakeet) consume.
public enum AudioIO {
    public static let sampleRate: Double = 16_000

    public static var targetFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    /// Decode any file AVFoundation can read (wav, aiff, m4a, mp3, caf...)
    /// into 16 kHz mono samples.
    public static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "LinFlow.AudioIO", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not allocate buffer"])
        }
        try file.read(into: buf)
        let resampler = try Resampler(from: inFormat)
        return resampler.convert(buf, endOfStream: true)
    }

    /// Write 16 kHz mono samples as a 16-bit PCM WAV (for saving the last
    /// recording, or feeding whisper-cli by hand).
    public static func writeWAV(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buf)
    }

    /// Root-mean-square level, 0...1-ish. Used for the silence gate and the HUD meter.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var acc: Float = 0
        for s in samples { acc += s * s }
        return (acc / Float(samples.count)).squareRoot()
    }

    /// A rough signal-to-noise estimate for a take, with no reference to compare against.
    ///
    /// Frames the clip, sorts the frame levels, and reads the quiet end as the noise floor and
    /// the loud end as speech-on-top-of-that-floor. Percentiles rather than min and max, so one
    /// click or one long gap cannot decide it.
    ///
    /// Measured against the benchmark clips in NOISE.md, this tracks true SNR monotonically but
    /// reads high, because the loud frames contain the noise as well and the quiet frames are
    /// not pure noise: true 10 dB comes out near 14, true 0 dB near 7.5.
    ///
    /// **It cannot tell loud babble from someone talking without pausing.** A clip with its
    /// gaps removed reads about 16.6 against babble-at-10-dB's 13.8 - adjacent, not separated.
    /// So this is for logging and for a human to read, and a threshold that switches engines on
    /// it must be set from real recordings in real rooms, not from this estimate's behavior on
    /// synthetic mixtures. `noiseFloor` is returned alongside for exactly that reason: the two
    /// together separate the cases better than the ratio does alone.
    public static func snrEstimate(_ samples: [Float], frameMilliseconds: Int = 20)
        -> (snrDB: Double, noiseFloor: Double) {
        let n = max(1, Int(sampleRate) * frameMilliseconds / 1000)
        guard samples.count >= n * 8 else { return (99, 0) }     // too short to say anything
        var levels: [Double] = []
        levels.reserveCapacity(samples.count / n)
        var i = 0
        while i + n <= samples.count {
            var sum = 0.0
            for j in i..<(i + n) { sum += Double(samples[j]) * Double(samples[j]) }
            levels.append((sum / Double(n)).squareRoot())
            i += n
        }
        levels.sort()
        func percentile(_ p: Double) -> Double {
            levels[min(levels.count - 1, max(0, Int(p * Double(levels.count))))]
        }
        let floor = percentile(0.10), speech = percentile(0.90)
        guard floor > 1e-6, speech > floor else { return (99, floor) }
        return (20 * log10(speech / floor), floor)
    }

    /// Peak absolute sample.
    public static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    /// Mixes a HAL buffer list of Float32 audio down to one channel, reading the layout
    /// off the list itself: one buffer with N channels is interleaved, N buffers of one
    /// channel each is planar. It never consults the format a device advertised for the
    /// stream, because on 2026-09-17 the system audio tap advertised one layout and
    /// delivered the other, and trusting the format cost every meeting half its audio.
    public static func monoMix(_ list: UnsafePointer<AudioBufferList>) -> [Float] {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard abl.count > 0 else { return [] }
        if abl.count == 1 {
            let b = abl[0]
            let channels = max(1, Int(b.mNumberChannels))
            let frames = Int(b.mDataByteSize) / (4 * channels)
            guard frames > 0, let p = b.mData?.assumingMemoryBound(to: Float.self) else { return [] }
            if channels == 1 { return Array(UnsafeBufferPointer(start: p, count: frames)) }
            var out = [Float](repeating: 0, count: frames)
            let scale = 1 / Float(channels)
            for i in 0..<frames {
                var acc: Float = 0
                for c in 0..<channels { acc += p[i * channels + c] }
                out[i] = acc * scale
            }
            return out
        }
        let frames = abl.reduce(Int.max) { min($0, Int($1.mDataByteSize) / 4) }
        guard frames > 0, frames != Int.max else { return [] }
        var out = [Float](repeating: 0, count: frames)
        var mixed = 0
        for b in abl {
            guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<frames { out[i] += p[i] }
            mixed += 1
        }
        guard mixed > 0 else { return [] }
        let scale = 1 / Float(mixed)
        for i in 0..<frames { out[i] *= scale }
        return out
    }

    /// "2 buffers x 1 ch (planar), 512 frames" for the log, so the layout the HAL actually
    /// delivers is on record the next time it matters.
    public static func describeLayout(_ list: UnsafePointer<AudioBufferList>) -> String {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = abl.first else { return "empty buffer list" }
        let channels = max(1, Int(first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / (4 * (abl.count == 1 ? channels : 1))
        let layout = abl.count > 1 ? "planar" : (channels > 1 ? "interleaved" : "mono")
        return "\(abl.count) buffer\(abl.count == 1 ? "" : "s") x \(channels) ch (\(layout)), \(frames) frames"
    }

    /// Wraps mono samples at `sampleRate` in a buffer the Resampler can take.
    public static func monoBuffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
        return buf
    }
}

/// Streaming converter from any AVAudioFormat to 16 kHz mono float32.
/// Feed it buffers as they arrive; it keeps resampler state between calls.
public final class Resampler {
    private let converter: AVAudioConverter
    private let outFormat = AudioIO.targetFormat
    private let inFormat: AVAudioFormat

    public init(from inFormat: AVAudioFormat) throws {
        guard let c = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "LinFlow.AudioIO", code: 2, userInfo: [NSLocalizedDescriptionKey: "no converter from \(inFormat)"])
        }
        self.converter = c
        self.inFormat = inFormat
    }

    public func convert(_ buffer: AVAudioPCMBuffer, endOfStream: Bool = false) -> [Float] {
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return [] }
        var handedOver = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if handedOver {
                outStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            handedOver = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            Log.error("audio convert failed: \(error?.localizedDescription ?? "?")")
            return []
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}

extension AudioIO {
    /// Cuts audio longer than `limitSeconds` into pieces, each ending at the quietest 200 ms
    /// found between `searchFromSeconds` and the limit, so no piece splits a word if it can
    /// be helped. Both engines decode long clips this way: whisper.cpp drops speech that
    /// straddles its 30 s window and libparakeet drops sentences after a pause past 60 s.
    public static func splitLong(_ samples: [Float], limitSeconds: Double, searchFromSeconds: Double) -> [[Float]] {
        let limit = Int(limitSeconds * sampleRate)
        guard samples.count > limit else { return [samples] }
        var pieces: [[Float]] = []
        var rest = samples
        while rest.count > limit {
            let cut = quietestCut(in: rest, from: Int(searchFromSeconds * sampleRate), to: limit)
            pieces.append(Array(rest[..<cut]))
            rest = Array(rest[cut...])
        }
        if !rest.isEmpty { pieces.append(rest) }
        return pieces
    }

    /// Middle of the quietest 200 ms between the two sample offsets.
    public static func quietestCut(in samples: [Float], from lo: Int, to hi: Int) -> Int {
        let win = Int(0.2 * sampleRate)
        var best = hi, bestEnergy = Float.greatestFiniteMagnitude
        var i = lo
        while i + win <= hi {
            var e: Float = 0
            for s in samples[i..<(i + win)] { e += s * s }
            if e < bestEnergy { bestEnergy = e; best = i + win / 2 }
            i += win / 2
        }
        return best
    }
}
