import Accelerate
import Foundation

/// A voice as 256 numbers: WeSpeaker's ResNet34 trained on VoxCeleb (CC BY 4.0), read from its
/// ONNX file and run with Accelerate, so it needs no runtime beyond macOS. Two takes of one voice
/// land close together and two voices far apart, which is how a note tells John from the others
/// when both tracks hold every voice (a shared room, or a call on the speakers).
///
/// The network is the file's own: its convolutions (batch norm already folded in), ReLUs and
/// residual adds run in the file's order, then the mean and spread of each channel over time, one
/// linear layer, and the file's mean vector taken off. Checked 2026-10-08 against ONNX Runtime on
/// John's audio: the embeddings agree to a cosine of 0.9999 and better.
public final class SpeakerModel {
    public static let info = ModelInfo(
        id: "wespeaker-resnet34-lm", fileName: "voxceleb_resnet34_LM.onnx",
        downloadURL: URL(string: "https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM/resolve/main/voxceleb_resnet34_LM.onnx")!,
        sizeMB: 27, multilingual: true, note: "Speaker recognition, WeSpeaker ResNet34 (CC BY 4.0)")
    public static let sha256 = "7bb2f06e9df17cdf1ef14ee8a15ab08ed28e8d0ef5054ee135741560df2ec068"
    public static var fileURL: URL { ModelCatalog.modelsDir.appendingPathComponent(info.fileName) }

    /// Shortest and longest audio one embedding is made from. Longer audio is cut into pieces of
    /// at most `maxSeconds` and their embeddings averaged, which bounds the memory a piece takes.
    public static let minSeconds = 1.5
    public static let maxSeconds = 6.0

    struct Conv { let input: String, output: String, weight: [Float], bias: [Float], out: Int, inC: Int, k: Int, stride: Int, pad: Int }
    enum Step { case conv(Conv), relu(String, String), add(String, String, String) }

    private let steps: [Step]
    /// For each step, the tensors it reads for the last time, dropped once it has run.
    private let done: [[String]]
    private let feats: String      // the name the first convolution reads
    private let pooled: String     // the name the pooling reads
    private let seg: (weight: [Float], bias: [Float], inputs: Int, outputs: Int)
    private let meanVec: [Float]

    public init(url: URL = SpeakerModel.fileURL) throws {
        let g = try ONNX.read(url)
        var steps: [Step] = [], start: String?, pooled: String?
        for n in g.nodes {
            switch n.op {
            case "Conv":
                guard let w = g.weights[n.inputs[1]], let b = g.weights[n.inputs[2]], w.dims.count == 4 else { throw Self.bad("a convolution without weights") }
                let pads = n.ints["pads"] ?? [0, 0, 0, 0], strides = n.ints["strides"] ?? [1, 1]
                guard w.dims[2] == w.dims[3], Set(pads).count == 1, strides[0] == strides[1], (n.ints["group"]?.first ?? 1) == 1 else { throw Self.bad("a convolution of an unexpected shape") }
                if start == nil { start = n.inputs[0] }
                steps.append(.conv(Conv(input: n.inputs[0], output: n.outputs[0], weight: w.data, bias: b.data, out: w.dims[0], inC: w.dims[1],
                                        k: w.dims[2], stride: strides[0], pad: pads[0])))
            case "Relu": steps.append(.relu(n.inputs[0], n.outputs[0]))
            case "Add" where pooled == nil: steps.append(.add(n.inputs[0], n.inputs[1], n.outputs[0]))
            case "ReduceMean" where pooled == nil: pooled = n.inputs[0]
            default: continue
            }
        }
        guard let start, let pooled, let w = g.weights["model.seg_1.weight"], let b = g.weights["model.seg_1.bias"], let mean = g.weights["mean_vec"] else {
            throw Self.bad("not the WeSpeaker ResNet this was written for")
        }
        self.steps = steps; feats = start; self.pooled = pooled
        var last: [String: Int] = [:]
        for (i, s) in steps.enumerated() {
            switch s {
            case .conv(let c): last[c.input] = i
            case .relu(let a, _): last[a] = i
            case .add(let a, let b, _): last[a] = i; last[b] = i
            }
        }
        last[pooled] = steps.count
        done = steps.indices.map { i in last.filter { $0.value == i }.map(\.key) }
        seg = (w.data, b.data, w.dims[1], w.dims[0]); meanVec = mean.data
    }

    /// The unit-length embedding of 16 kHz mono samples, or nil when there are too few.
    public func embed(_ samples: ArraySlice<Float>) -> [Float]? {
        let rate = Int(AudioIO.sampleRate), n = samples.count
        guard n >= Int(Self.minSeconds * Double(rate)) else { return nil }
        let pieces = max(1, Int((Double(n) / (Self.maxSeconds * Double(rate))).rounded(.up)))
        var sum = [Float](repeating: 0, count: seg.outputs)
        for p in 0..<pieces {
            let a = samples.startIndex + n * p / pieces, b = samples.startIndex + n * (p + 1) / pieces
            guard let e = embedPiece(samples[a..<b]).flatMap(Self.unit) else { continue }
            vDSP.add(sum, e, result: &sum)
        }
        return Self.unit(sum)
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float { vDSP.dot(a, b) / max(1e-12, (vDSP.sumOfSquares(a) * vDSP.sumOfSquares(b)).squareRoot()) }

    static func unit(_ v: [Float]) -> [Float]? {
        let norm = vDSP.sumOfSquares(v).squareRoot()
        return norm > 0 ? vDSP.divide(v, norm) : nil
    }

    private struct Tensor { var c: Int, h: Int, w: Int, data: [Float] }

    private func embedPiece(_ samples: ArraySlice<Float>) -> [Float]? {
        guard let f = Fbank.compute(samples) else { return nil }   // frames x 80
        let frames = f.count / Fbank.bins
        // [frames][80] -> one channel of 80 rows (frequency) by `frames` columns (time)
        var x = [Float](repeating: 0, count: f.count)
        vDSP_mtrans(f, 1, &x, 1, vDSP_Length(Fbank.bins), vDSP_Length(frames))
        var t: [String: Tensor] = [feats: Tensor(c: 1, h: Fbank.bins, w: frames, data: x)]
        for (i, step) in steps.enumerated() {
            defer { for name in done[i] { t[name] = nil } }
            switch step {
            case .conv(let c):
                guard let input = t[c.input] else { return nil }
                t[c.output] = conv(input, c)
            case .relu(let a, let out):
                guard var v = t[a] else { return nil }
                v.data = vDSP.threshold(v.data, to: 0, with: .clampToThreshold)
                t[out] = v
            case .add(let a, let b, let out):
                guard var v = t[a], let u = t[b], v.data.count == u.data.count else { return nil }
                v.data = vDSP.add(v.data, u.data)
                t[out] = v
            }
        }
        guard let y = t[pooled], y.w >= 2, y.c * y.h * 2 == seg.inputs else { return nil }
        // The mean and the spread (unbiased, plus 1e-8 under the root) of each channel and row over time.
        var stats = [Float](repeating: 0, count: seg.inputs)
        let rows = y.c * y.h
        y.data.withUnsafeBufferPointer { p in
            for r in 0..<rows {
                let row = UnsafeBufferPointer(rebasing: p[(r * y.w)..<((r + 1) * y.w)])
                let mean = vDSP.mean(row)
                let ss = row.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) }
                stats[r] = mean
                stats[rows + r] = (ss / Float(y.w - 1) + 1e-8).squareRoot()
            }
        }
        var out = seg.bias
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(seg.outputs), Int32(seg.inputs), 1, seg.weight, Int32(seg.inputs), stats, 1, 1, &out, 1)
        return vDSP.subtract(out, meanVec)
    }

    /// im2col, then one matrix product.
    private func conv(_ x: Tensor, _ c: Conv) -> Tensor {
        let ho = (x.h + 2 * c.pad - c.k) / c.stride + 1, wo = (x.w + 2 * c.pad - c.k) / c.stride + 1
        let cols = c.inC * c.k * c.k, hw = ho * wo
        var col = [Float](repeating: 0, count: cols * hw)
        x.data.withUnsafeBufferPointer { src in
            col.withUnsafeMutableBufferPointer { dst in
                for ch in 0..<c.inC {
                    for ky in 0..<c.k {
                        for kx in 0..<c.k {
                            let rowBase = ((ch * c.k + ky) * c.k + kx) * hw
                            // the output columns whose input column falls inside the image
                            let ox0 = max(0, (c.pad - kx + c.stride - 1) / c.stride), ox1 = min(wo, (x.w - 1 + c.pad - kx) / c.stride + 1)
                            guard ox0 < ox1 else { continue }
                            for oy in 0..<ho {
                                let iy = oy * c.stride + ky - c.pad
                                guard iy >= 0, iy < x.h else { continue }
                                let srcRow = (ch * x.h + iy) * x.w + kx - c.pad, dstRow = rowBase + oy * wo
                                if c.stride == 1 {
                                    (dst.baseAddress! + dstRow + ox0).update(from: src.baseAddress! + srcRow + ox0, count: ox1 - ox0)
                                } else {
                                    for ox in ox0..<ox1 { dst[dstRow + ox] = src[srcRow + ox * c.stride] }
                                }
                            }
                        }
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: c.out * hw)
        for o in 0..<c.out { for i in 0..<hw { out[o * hw + i] = c.bias[o] } }
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(c.out), Int32(hw), Int32(cols), 1,
                    c.weight, Int32(cols), col, Int32(hw), 1, &out, Int32(hw))
        return Tensor(c: c.out, h: ho, w: wo, data: out)
    }

    static func bad(_ what: String) -> NSError {
        NSError(domain: "LinFlow.SpeakerModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "The speaker model file is \(what)."])
    }
}

/// Kaldi's filterbank as WeSpeaker computes it: samples at 16-bit scale, 25 ms frames every 10 ms
/// with the edges snipped, the DC taken out, pre-emphasis 0.97, a Povey window, 80 mel bands from
/// 20 Hz to 8 kHz on a 512-point FFT, the log of each, then each band's mean taken off.
public enum Fbank {
    public static let bins = 80
    static let frame = 400, shift = 160, fftSize = 512

    static let window: [Float] = (0..<frame).map { Float(pow(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(frame - 1)), 0.85)) }
    /// For each band, its first FFT bin and weights.
    static let banks: [(first: Int, weights: [Float])] = {
        func mel(_ f: Double) -> Double { 1127 * log(1 + f / 700) }
        let lo = mel(20), hi = mel(8000), step = (hi - lo) / Double(bins + 1)
        return (0..<bins).map { m in
            let l = lo + Double(m) * step, c = l + step, r = c + step
            var first = -1, w: [Float] = []
            for k in 0..<(fftSize / 2) {
                let f = mel(Double(k) * 16_000 / Double(fftSize))
                let v = max(0, min((f - l) / (c - l), (r - f) / (r - c)))
                if v > 0 { if first < 0 { first = k }; w.append(Float(v)) } else if first >= 0 { break }
            }
            return (max(first, 0), w)
        }
    }()
    static let fft = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!

    /// frames x 80, row by row. Nil for audio shorter than one frame.
    public static func compute(_ samples: ArraySlice<Float>) -> [Float]? {
        let n = samples.count
        guard n >= frame else { return nil }
        let frames = 1 + (n - frame) / shift
        let x = vDSP.multiply(Float(32_768), Array(samples))
        var out = [Float](repeating: 0, count: frames * bins)
        var buf = [Float](repeating: 0, count: fftSize)
        var re = [Float](repeating: 0, count: fftSize / 2), im = [Float](repeating: 0, count: fftSize / 2)
        var power = [Float](repeating: 0, count: fftSize / 2)
        for t in 0..<frames {
            let s = x[(t * shift)..<(t * shift + frame)]
            let mean = vDSP.mean(s)
            for i in 0..<frame { buf[i] = s[s.startIndex + i] - mean }
            for i in stride(from: frame - 1, to: 0, by: -1) { buf[i] -= 0.97 * buf[i - 1] }
            buf[0] -= 0.97 * buf[0]
            for i in 0..<frame { buf[i] *= window[i] }
            for i in frame..<fftSize { buf[i] = 0 }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    buf.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                    vDSP_fft_zrip(fft, &split, 1, 9, FFTDirection(FFT_FORWARD))
                }
            }
            // vDSP's real FFT comes out doubled, with the Nyquist term in im[0]; Kaldi drops that bin.
            power[0] = re[0] * re[0] / 4
            for k in 1..<(fftSize / 2) { power[k] = (re[k] * re[k] + im[k] * im[k]) / 4 }
            for (m, bank) in banks.enumerated() {
                var e: Float = 0
                for (j, w) in bank.weights.enumerated() { e += w * power[bank.first + j] }
                out[t * bins + m] = log(max(e, Float.ulpOfOne))
            }
        }
        for m in 0..<bins {
            var mean: Float = 0
            for t in 0..<frames { mean += out[t * bins + m] }
            mean /= Float(frames)
            for t in 0..<frames { out[t * bins + m] -= mean }
        }
        return out
    }
}

/// Just enough of protobuf to read an ONNX model's nodes and float weights.
enum ONNX {
    struct Node { var op = "", inputs: [String] = [], outputs: [String] = [], ints: [String: [Int]] = [:] }
    struct Weight { var dims: [Int], data: [Float] }
    struct Graph { var nodes: [Node] = [], weights: [String: Weight] = [:] }

    static func read(_ url: URL) throws -> Graph {
        let bytes = [UInt8](try Data(contentsOf: url, options: .mappedIfSafe))
        guard let graph = try fields(bytes[...]).first(where: { $0.number == 7 })?.bytes else { throw SpeakerModel.bad("missing its graph") }
        var g = Graph()
        for f in try fields(graph) {
            if f.number == 1, let b = f.bytes { g.nodes.append(try node(b)) }
            if f.number == 5, let b = f.bytes, let (name, w) = try weight(b) { g.weights[name] = w }
        }
        return g
    }

    struct Field { var number: Int, value: UInt64, bytes: ArraySlice<UInt8>? }

    static func fields(_ b: ArraySlice<UInt8>) throws -> [Field] {
        var i = b.startIndex, out: [Field] = []
        func varint() throws -> UInt64 {
            var r: UInt64 = 0, s: UInt64 = 0
            while true {
                guard i < b.endIndex, s < 64 else { throw SpeakerModel.bad("not readable") }
                let c = b[i]; i += 1
                r |= UInt64(c & 0x7f) << s; s += 7
                if c < 0x80 { return r }
            }
        }
        while i < b.endIndex {
            let key = try varint()
            let number = Int(key >> 3)
            switch key & 7 {
            case 0: out.append(Field(number: number, value: try varint(), bytes: nil))
            case 1: guard i + 8 <= b.endIndex else { throw SpeakerModel.bad("cut short") }; out.append(Field(number: number, value: 0, bytes: b[i..<(i + 8)])); i += 8
            case 5: guard i + 4 <= b.endIndex else { throw SpeakerModel.bad("cut short") }; out.append(Field(number: number, value: 0, bytes: b[i..<(i + 4)])); i += 4
            case 2:
                let len = Int(try varint())
                guard len >= 0, i + len <= b.endIndex else { throw SpeakerModel.bad("cut short") }
                out.append(Field(number: number, value: 0, bytes: b[i..<(i + len)])); i += len
            default: throw SpeakerModel.bad("not readable")
            }
        }
        return out
    }

    /// Repeated integers, packed or one field each.
    static func ints(_ fs: [Field], _ number: Int) throws -> [Int] {
        var out: [Int] = []
        for f in fs where f.number == number {
            if let b = f.bytes { out += try fields(packed(b)).map { Int(truncatingIfNeeded: $0.value) } } else { out.append(Int(truncatingIfNeeded: f.value)) }
        }
        return out
    }

    /// A packed run of varints, re-framed as field 1 so `fields` can read it.
    private static func packed(_ b: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var out: [UInt8] = []
        var i = b.startIndex
        while i < b.endIndex {
            out.append(0x08)
            repeat { out.append(b[i]); i += 1 } while i < b.endIndex && b[i - 1] >= 0x80
        }
        return out[...]
    }

    static func string(_ f: Field) -> String { f.bytes.map { String(decoding: $0, as: UTF8.self) } ?? "" }

    static func node(_ b: ArraySlice<UInt8>) throws -> Node {
        var n = Node()
        for f in try fields(b) {
            switch f.number {
            case 1: n.inputs.append(string(f))
            case 2: n.outputs.append(string(f))
            case 4: n.op = string(f)
            case 5:
                guard let a = f.bytes else { continue }
                let fs = try fields(a)
                guard let name = fs.first(where: { $0.number == 1 }).map(string) else { continue }
                let list = try ints(fs, 8)
                n.ints[name] = list.isEmpty ? fs.filter { $0.number == 3 && $0.bytes == nil }.map { Int(truncatingIfNeeded: $0.value) } : list
            default: break
            }
        }
        return n
    }

    static func weight(_ b: ArraySlice<UInt8>) throws -> (String, Weight)? {
        let fs = try fields(b)
        guard let name = fs.first(where: { $0.number == 8 }).map(string),
              fs.first(where: { $0.number == 2 })?.value == 1 else { return nil }   // float32 only
        let dims = try ints(fs, 1)
        var data: [Float] = []
        if let raw = fs.first(where: { $0.number == 9 })?.bytes {
            var d = [Float](repeating: 0, count: raw.count / 4)
            d.withUnsafeMutableBytes { $0.copyBytes(from: raw.prefix(raw.count / 4 * 4)) }
            data = d
        } else if let packedFloats = fs.first(where: { $0.number == 4 })?.bytes {
            var d = [Float](repeating: 0, count: packedFloats.count / 4)
            d.withUnsafeMutableBytes { $0.copyBytes(from: packedFloats.prefix(packedFloats.count / 4 * 4)) }
            data = d
        }
        guard data.count == dims.reduce(1, *) else { return nil }
        return (name, Weight(dims: dims, data: data))
    }
}

/// The ONNX reader, for the selftest.
public enum ONNXProbe {
    public static func read(_ url: URL) throws -> (ops: [String], weights: [String: [Float]]) {
        let g = try ONNX.read(url)
        return (g.nodes.map(\.op), g.weights.mapValues(\.data))
    }
}
