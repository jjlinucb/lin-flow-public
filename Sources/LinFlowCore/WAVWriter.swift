import Foundation

/// A 16 kHz mono 16-bit WAV that stays readable if the process dies.
///
/// AVAudioFile writes the RIFF and data sizes only when the file is closed
/// (kAudioFilePropertyDeferSizeUpdates is on by default), so a recording cut short by a
/// crash, a force quit or a dead battery reads as 0 seconds in every player, with all of
/// its audio still in the file. Verified 2026-09-17: 100 KB written the way MeetingRecorder
/// did, `_exit` without a close, and afinfo said "estimated duration: 0.000000 sec". This
/// writer brings the header up to date about once a second, so a crash costs at most the
/// last second, and `repairHeader` fixes any WAV, AVAudioFile's included, from the file size.
public final class WAVWriter {
    public let url: URL
    /// Frames in the data chunk, including anything already in the file when appending.
    public private(set) var frames = 0
    public let sampleRate: Int
    /// How often the header is rewritten, in frames. One second by default.
    public var headerInterval = 16_000

    private let handle: FileHandle
    private let dataOffset: Int
    private var framesAtLastHeader = 0

    public enum WAVError: Error, LocalizedError {
        case cannotCreate(String)
        case notPCM16Mono(String)
        case malformed(String)
        public var errorDescription: String? {
            switch self {
            case .cannotCreate(let n): return "could not create \(n)"
            case .notPCM16Mono(let n): return "\(n) is not a 16 kHz mono 16-bit WAV"
            case .malformed(let n): return "\(n) is not a WAV file"
            }
        }
    }

    /// Creates the file, or with `append` continues one that already exists (repairing its
    /// header first if the last writer died). A file at the path that is not our format is
    /// moved aside rather than overwritten: nothing recorded is ever destroyed here.
    public init(url: URL, sampleRate: Int = Int(AudioIO.sampleRate), append: Bool = false) throws {
        self.url = url
        self.sampleRate = sampleRate
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            var reuse = false
            if append {
                _ = try? Self.repairHeader(at: url)
                if let info = Self.info(at: url), info.sampleRate == sampleRate, info.channels == 1, info.bits == 16 { reuse = true }
            }
            if reuse {
                let info = Self.info(at: url)!
                handle = try FileHandle(forWritingTo: url)
                dataOffset = info.dataOffset
                frames = info.dataBytes / 2
                framesAtLastHeader = frames
                try handle.seek(toOffset: UInt64(info.dataOffset + info.dataBytes))
                return
            }
            let aside = url.deletingPathExtension().appendingPathExtension("previous-\(Int(Date().timeIntervalSince1970)).wav")
            try fm.moveItem(at: url, to: aside)
            Log.info("moved \(url.lastPathComponent) aside as \(aside.lastPathComponent) instead of overwriting it")
        }
        guard fm.createFile(atPath: url.path, contents: nil) else { throw WAVError.cannotCreate(url.lastPathComponent) }
        handle = try FileHandle(forWritingTo: url)
        dataOffset = 44
        try handle.write(contentsOf: Self.header(dataBytes: 0, sampleRate: sampleRate))
    }

    /// Appends samples (clipped to ±1) as 16-bit little-endian PCM and refreshes the header
    /// once `headerInterval` frames have gone by since it was last written.
    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            let v = max(-1, min(1, s)) * 32767
            pcm[i] = Int16(v.rounded())
        }
        try pcm.withUnsafeBufferPointer { try handle.write(contentsOf: Data(buffer: $0)) }
        frames += samples.count
        if frames - framesAtLastHeader >= headerInterval { try updateHeader() }
    }

    /// Writes the final header and closes the file. Safe to call twice.
    public func close() throws {
        guard !closed else { return }
        closed = true
        try updateHeader()
        try handle.close()
    }
    private var closed = false

    deinit { try? close() }

    private func updateHeader() throws {
        let dataBytes = frames * 2
        let end = try handle.offset()
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.le32(UInt32(clamping: dataOffset - 8 + dataBytes)))
        try handle.seek(toOffset: UInt64(dataOffset - 4))
        try handle.write(contentsOf: Self.le32(UInt32(clamping: dataBytes)))
        try handle.seek(toOffset: end)
        framesAtLastHeader = frames
    }

    // MARK: header

    static func header(dataBytes: Int, sampleRate: Int) -> Data {
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8)); d.append(le32(UInt32(clamping: 36 + dataBytes)))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); d.append(le32(16))
        d.append(le16(1)); d.append(le16(1))                      // PCM, mono
        d.append(le32(UInt32(sampleRate))); d.append(le32(UInt32(sampleRate * 2)))
        d.append(le16(2)); d.append(le16(16))                     // block align, bits
        d.append(contentsOf: Array("data".utf8)); d.append(le32(UInt32(clamping: dataBytes)))
        return d
    }

    static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    public struct Info {
        public var sampleRate: Int
        public var channels: Int
        public var bits: Int
        /// Where the samples start.
        public var dataOffset: Int
        /// What the header claims. May be wrong after a crash; see `repairHeader`.
        public var dataBytes: Int
        public var fileSize: Int
        public var seconds: Double { channels > 0 && bits > 0 && sampleRate > 0 ? Double(dataBytes) / Double(channels * bits / 8 * sampleRate) : 0 }
    }

    /// Walks the RIFF chunks (AVAudioFile puts a JUNK chunk before "fmt ") to find the format
    /// and the data chunk. Nil if the file is not a WAV.
    public static func info(at url: URL) -> Info? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 4096), head.count >= 12,
              let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else { return nil }
        let b = [UInt8](head)
        func tag(_ o: Int) -> String { o + 4 <= b.count ? String(decoding: b[o..<o + 4], as: UTF8.self) : "" }
        func u32(_ o: Int) -> Int { o + 4 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 : 0 }
        func u16(_ o: Int) -> Int { o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
        guard tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }
        var o = 12
        var rate = 0, channels = 0, bits = 0
        while o + 8 <= b.count {
            let id = tag(o), len = u32(o + 4)
            if id == "fmt " {
                channels = u16(o + 10); rate = u32(o + 12); bits = u16(o + 22)
            } else if id == "data" {
                return Info(sampleRate: rate, channels: channels, bits: bits, dataOffset: o + 8, dataBytes: len, fileSize: size)
            }
            o += 8 + len + (len & 1)
        }
        return nil
    }

    /// Seconds of audio in the file according to its header, nil if it is not a WAV.
    public static func duration(at url: URL) -> Double? { info(at: url)?.seconds }

    /// Makes the header agree with the file's size when a writer died before closing it:
    /// the data chunk says 0 bytes (AVAudioFile) or ends short of the file (this writer,
    /// up to a second). Returns true if it changed anything. A data chunk that is followed
    /// by another well-formed chunk is somebody else's valid file and is left alone.
    @discardableResult
    public static func repairHeader(at url: URL) throws -> Bool {
        guard let info = info(at: url) else { throw WAVError.malformed(url.lastPathComponent) }
        let actual = info.fileSize - info.dataOffset
        guard actual >= 0, info.dataBytes != actual else { return false }
        if info.dataBytes > 0, info.dataBytes < actual {
            // Something after the data chunk: a real trailing chunk means the header is right.
            if let fh = try? FileHandle(forReadingFrom: url) {
                defer { try? fh.close() }
                try? fh.seek(toOffset: UInt64(info.dataOffset + info.dataBytes + (info.dataBytes & 1)))
                if let tail = try? fh.read(upToCount: 8), tail.count == 8 {
                    let id = String(decoding: tail[tail.startIndex..<tail.startIndex + 4], as: UTF8.self)
                    if id.allSatisfy({ $0.isLetter || $0 == " " || $0.isNumber }) { return false }
                }
            }
        }
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: 4)
        try fh.write(contentsOf: le32(UInt32(clamping: info.fileSize - 8)))
        try fh.seek(toOffset: UInt64(info.dataOffset - 4))
        try fh.write(contentsOf: le32(UInt32(clamping: actual)))
        return true
    }
}
