import AVFoundation
import Foundation
import LinFlowCore

extension SelfTest {
    /// Audio: levels, the system-audio mixdown, WAV files that survive a crash, the rescue engine.
    static func audio() {
        // The tap's real rate, 10-06: AirPods on a Teams call delivered half the rate reported.
        func feed(_ w: inout RateWatch, rate: Double, seconds: Double, from t0: Double = 0, pauseAt: Double? = nil) -> [Double] {
            var got: [Double] = []
            var t = t0
            while t < t0 + seconds {
                t += 0.01
                if let p = pauseAt, t > p, t < p + 1 { continue }
                if let r = w.add(frames: Int(rate / 100), at: t) { got.append(r) }
            }
            return got
        }
        var half = RateWatch(rate: 48000)
        expect(feed(&half, rate: 24000, seconds: 10) == [24000] && half.rate == 24000, "tap rate: half the reported rate is found and used")
        var steady = RateWatch(rate: 48000)
        expect(feed(&steady, rate: 48000, seconds: 20).isEmpty, "tap rate: the reported rate stays")
        var stall = RateWatch(rate: 48000)
        expect(feed(&stall, rate: 48000, seconds: 20, pauseAt: 5).isEmpty, "tap rate: a stall is not a slow rate")
        var back = RateWatch(rate: 48000)
        _ = feed(&back, rate: 24000, seconds: 10)
        expect(feed(&back, rate: 48000, seconds: 10, from: 10) == [48000], "tap rate: back to the full rate when the call ends")
        var drift = RateWatch(rate: 48000)
        expect(feed(&drift, rate: 47000, seconds: 20).isEmpty, "tap rate: clock drift is not a new rate")
        // A dead input sends digital zeros. A quiet room never does, and a short tap is not a take.
        let second = Int(AudioIO.sampleRate)
        expect(DictationController.isDeadMicrophone([Float](repeating: 0, count: second * 3)), "dead mic: three seconds of zeros")
        expect(!DictationController.isDeadMicrophone([Float](repeating: 0, count: second / 4)), "dead mic: a quarter second is only a tap")
        expect(!DictationController.isDeadMicrophone((0..<second).map { $0 % 2 == 0 ? 0.0009 : -0.0009 }),
               "dead mic: a silent room's noise is not a dead microphone")

        // A wedged audio daemon (AudioRepair): its error code, and two dead takes in a row.
        expect(AudioRepair.isStuck(NSError(domain: "com.apple.coreaudio.avfaudio", code: 1_937_010_544)), "stuck audio: the 'stop' error")
        expect(!AudioRepair.isStuck(NSError(domain: "com.apple.coreaudio.avfaudio", code: -10868)), "stuck audio: another error is not it")
        do {
            let mac = "MacBook Pro Microphone", t0 = Date()
            var room = LoudRoom()
            expect(!room.record(floor: 0.04, device: mac, at: t0), "loud room: one loud take is not a room")
            expect(room.record(floor: 0.04, device: mac, at: t0), "loud room: the second loud take on the Mac's mic says so")
            expect(!room.record(floor: 0.04, device: mac, at: t0 + 600), "loud room: quiet for two hours once said")
            expect(room.record(floor: 0.04, device: mac, at: t0 + 3 * 3600), "loud room: says it again after two hours of loud takes")
            var quiet = LoudRoom()
            for _ in 0..<5 { expect(!quiet.record(floor: 0.0036, device: mac), "loud room: a home's floor never warns") }
            var pods = LoudRoom()
            for _ in 0..<5 { expect(!pods.record(floor: 0.04, device: "John’s AirPods Pro"), "loud room: AirPods are never the problem") }
            var broken = LoudRoom()
            _ = broken.record(floor: 0.04, device: mac)
            _ = broken.record(floor: 0.002, device: mac)
            expect(!broken.record(floor: 0.04, device: mac), "loud room: the two loud takes must be in a row")
            expect(LoudRoom.isBuiltIn("Built-in Microphone") && !LoudRoom.isBuiltIn(nil), "loud room: older Macs' mic name")
        }
        var streak = AudioRepair.SilentStreak()
        expect(!streak.record(dead: true), "stuck audio: one dead take is only a warning")
        expect(streak.record(dead: true), "stuck audio: the second dead take in a row")
        expect(!streak.record(dead: true), "stuck audio: says so once, not on every take after")
        _ = streak.record(dead: false)
        expect(!streak.record(dead: true), "stuck audio: a take with sound starts the count again")
        if let folder = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                      appropriateFor: FileManager.default.temporaryDirectory, create: true),
           let url = try? AudioRepair.writeScript(in: folder) {
            let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
            expect(mode & 0o100 != 0 && url.pathExtension == "command", "stuck audio: the repair opens in Terminal")
            expect((try? String(contentsOf: url, encoding: .utf8))?.contains("sudo killall coreaudiod") == true, "stuck audio: the repair restarts coreaudiod")
            try? FileManager.default.removeItem(at: folder)
        } else {
            expect(false, "stuck audio: the repair script was written")
        }

        // audio helpers
        expect(AudioIO.rms([0, 0, 0]) == 0, "rms silence")
        expect(abs(AudioIO.rms([0.5, -0.5]) - 0.5) < 1e-6, "rms")
        expect(AudioIO.peak([0.1, -0.7, 0.3]) == 0.7, "peak")

        // System audio mixdown. The layout has to come from the buffer list, not from the
        // format the tap advertised: on 2026-09-17 the two disagreed and every meeting was
        // recorded at double speed. Same four frames in both layouts, same answer expected.
        do {
            var left: [Float] = [0.2, 0.4, 0.6, 0.8]
            var right: [Float] = [0.0, 0.0, 0.2, 0.0]
            var interleaved: [Float] = [0.2, 0.0, 0.4, 0.0, 0.6, 0.2, 0.8, 0.0]
            let planar = AudioBufferList.allocate(maximumBuffers: 2)
            defer { free(planar.unsafeMutablePointer) }
            left.withUnsafeMutableBytes { l in right.withUnsafeMutableBytes { r in
                planar[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(l.count), mData: l.baseAddress)
                planar[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(r.count), mData: r.baseAddress)
                let mix = AudioIO.monoMix(planar.unsafePointer)
                expect(mix.count == 4, "monoMix planar keeps every frame")
                expect(mix.count == 4 && abs(mix[2] - 0.4) < 1e-6, "monoMix planar averages the channels")
                expect(AudioIO.describeLayout(planar.unsafePointer), "2 buffers x 1 ch (planar), 4 frames", "describeLayout planar")
            } }
            let inter = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(inter.unsafeMutablePointer) }
            interleaved.withUnsafeMutableBytes { b in
                inter[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(b.count), mData: b.baseAddress)
                let mix = AudioIO.monoMix(inter.unsafePointer)
                expect(mix.count == 4, "monoMix interleaved keeps every frame, not half")
                expect(mix.count == 4 && abs(mix[2] - 0.4) < 1e-6, "monoMix interleaved averages the pairs")
                expect(AudioIO.describeLayout(inter.unsafePointer), "1 buffer x 2 ch (interleaved), 4 frames", "describeLayout interleaved")
            }
        }

        // Meeting audio on disk. AVAudioFile wrote the WAV sizes only on close, so a crash left
        // a whole meeting reading as 0 seconds; WAVWriter keeps the header current and
        // repairHeader fixes any WAV from its size. See WAVWriter.swift.
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linflow-selftest-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("a.wav")
            let ramp = (0..<24_000).map { Float($0 % 1600) / 1600 - 0.5 }   // 1.5 s
            do {
                let w = try WAVWriter(url: url)
                var i = 0
                while i < ramp.count { try w.append(Array(ramp[i..<min(i + 160, ramp.count)])); i += 160 }
                try w.close()
                expect(abs((WAVWriter.duration(at: url) ?? 0) - 1.5) < 1e-6, "WAVWriter: closed file reports 1.5 s")
                let back = try AudioIO.loadSamples(from: url)
                expect(back.count == 24_000, "WAVWriter: 24000 frames read back")
                expect(back.count == 24_000 && abs(back[1000] - ramp[1000]) < 1.0 / 32000, "WAVWriter: samples round-trip through 16-bit")
            } catch { expect(false, "WAVWriter round trip threw: \(error)") }
            do {
                // A crash mid-meeting: the header trails the data by under a second, and never reads as empty.
                let crashed = dir.appendingPathComponent("crash.wav")
                let w = try WAVWriter(url: crashed)
                try w.append([Float](repeating: 0.1, count: 16_000))   // header refreshed here (1.0 s)
                try w.append([Float](repeating: 0.1, count: 8_000))    // not yet here
                withExtendedLifetime(w) {
                    expect(abs((WAVWriter.duration(at: crashed) ?? 0) - 1.0) < 1e-6, "WAVWriter: header trails an unclosed file by under a second")
                    expect((try? WAVWriter.repairHeader(at: crashed)) == true, "WAVWriter: repairHeader closes the gap")
                    expect(abs((WAVWriter.duration(at: crashed) ?? 0) - 1.5) < 1e-6, "WAVWriter: repaired header holds 1.5 s")
                    expect((try? WAVWriter.repairHeader(at: crashed)) == false, "WAVWriter: a consistent header is left alone")
                }
            } catch { expect(false, "WAVWriter crash case threw: \(error)") }
            do {
                // What AVAudioFile leaves behind: sizes of zero, and a JUNK chunk before "fmt ".
                func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)] }
                func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
                var b: [UInt8] = Array("RIFF".utf8) + le32(4088) + Array("WAVE".utf8)
                b += Array("JUNK".utf8) + le32(28) + [UInt8](repeating: 0, count: 28)
                b += Array("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(16_000) + le32(32_000) + le16(2) + le16(16)
                b += Array("data".utf8) + le32(0) + [UInt8](repeating: 0x40, count: 3200)   // 0.1 s
                let junk = dir.appendingPathComponent("junk.wav")
                try Data(b).write(to: junk)
                expect(WAVWriter.info(at: junk)?.dataOffset == 80, "WAVWriter: data chunk found behind a JUNK chunk")
                expect((WAVWriter.duration(at: junk) ?? -1) == 0, "WAVWriter: AVAudioFile's crashed header reads as 0 s")
                expect((try? WAVWriter.repairHeader(at: junk)) == true, "WAVWriter: repairs an AVAudioFile header")
                expect(abs((WAVWriter.duration(at: junk) ?? 0) - 0.1) < 1e-6, "WAVWriter: repaired AVAudioFile header holds 0.1 s")
                expect((try? AudioIO.loadSamples(from: junk))?.count == 1600, "WAVWriter: repaired file decodes")
            } catch { expect(false, "WAVWriter JUNK case threw: \(error)") }
            do {
                // A second session on the same note appends; a foreign file is moved aside, never overwritten.
                let w = try WAVWriter(url: url, append: true)
                expect(w.frames == 24_000, "WAVWriter: append resumes at the existing 24000 frames")
                try w.append([Float](repeating: 0, count: 8_000))
                try w.close()
                expect(abs((WAVWriter.duration(at: url) ?? 0) - 2.0) < 1e-6, "WAVWriter: appended file holds 2.0 s")
                let odd = dir.appendingPathComponent("odd.wav")
                var b: [UInt8] = Array("RIFF".utf8) + [36, 0, 0, 0] + Array("WAVE".utf8) + Array("fmt ".utf8) + [16, 0, 0, 0]
                b += [1, 0, 1, 0] + [0x40, 0x1f, 0, 0] + [0x80, 0x3e, 0, 0] + [2, 0, 16, 0] + Array("data".utf8) + [0, 0, 0, 0]   // 8 kHz
                try Data(b).write(to: odd)
                let w2 = try WAVWriter(url: odd, append: true)
                try w2.close()
                let aside = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasPrefix("odd.previous-") } ?? []
                expect(aside.count == 1, "WAVWriter: a file in another format is moved aside")
                expect(WAVWriter.info(at: odd)?.sampleRate == 16_000, "WAVWriter: and a fresh 16 kHz file takes its place")
            } catch { expect(false, "WAVWriter append case threw: \(error)") }
        }

        // Save Audio: both sides leveled to one speech level, summed, limited, encoded.
        expect(AudioExport.limit(0.5) == 0.5 && AudioExport.limit(-0.7) == -0.7, "export: the limiter leaves ordinary levels alone")
        expect(AudioExport.limit(4) <= 0.95 && AudioExport.limit(-4) >= -0.95 && AudioExport.limit(0.9) < AudioExport.limit(1.2),
               "export: the limiter never passes 0.95 and keeps louder louder")
        expect(AudioExport.gain(forLevel: -19) == 3 && AudioExport.gain(forLevel: nil) == 0, "export: a quiet side is raised to the call's level")
        expect(AudioExport.gain(forLevel: -60) == 12 && AudioExport.gain(forLevel: -2) == -6, "export: the gain is capped both ways")
        expect(NotesStore.fileName("Meeting Oct 7, 2:09 PM", ext: "mp3"), "Meeting Oct 7, 2.09 PM.mp3")
        // Turns of talk, 20 ms frames: loud for a random stretch, then quiet.
        var seed: UInt32 = 7
        func turns(_ n: Int) -> [Float] {
            var out: [Float] = [], loud = false
            while out.count < n { seed = seed &* 1_664_525 &+ 1_013_904_223; loud.toggle(); out += Array(repeating: loud ? -20 + Float(seed % 7) : -80, count: 20 + Int(seed % 120)) }
            return Array(out.prefix(n))
        }
        let call = turns(6_000), other = turns(6_000)
        func shifted(_ x: [Float], by d: Int) -> [Float] { d >= 0 ? Array(repeating: -80, count: d) + x.dropLast(d) : Array(x.dropFirst(-d)) + Array(repeating: -80, count: -d) }
        expect(AudioExport.coupling(mic: shifted(call, by: 6).map { $0 - 15 }, call: call).coupling == .speakers, "coupling: a mic 0.12 s behind the call hears the speakers")
        let room = AudioExport.coupling(mic: call, call: shifted(call, by: 26))
        expect(room.coupling == .room && abs(room.delay - 0.52) < 0.03, "coupling: a call 0.52 s behind the mic carries the room")
        expect(AudioExport.coupling(mic: other, call: call).coupling == .separate, "coupling: headphones keep the sides apart")
        expect(AudioExport.speechLevel([-90, -80, -30, -20]) == -30 && AudioExport.speechLevel([-90]) == nil, "export: speech level ignores silence")
        expect(NotesStore.fileName("Plan a/b ", ext: "md") == "Plan a-b.md" && NotesStore.fileName("", ext: "mp3") == "Meeting.mp3",
               "export: a title's slash and an empty title make file names")
        do {
            let id = "selftest-export-\(UUID().uuidString)"
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("linflow-export-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: NotesStore.folder(for: id)); try? FileManager.default.removeItem(at: out) }
            try FileManager.default.createDirectory(at: NotesStore.folder(for: id), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            // John, quietly, for the first half second. The call, louder, from then to 1.5 s.
            func tone(_ hz: Float, _ amp: Float, _ n: Int) -> [Float] { (0..<n).map { amp * sin(2 * .pi * hz * Float($0) / 16_000) } }
            let hush = [Float](repeating: 0, count: 8_000)
            for (source, samples) in [("mic", tone(300, 0.05, 8_000) + hush), ("system", hush + tone(500, 0.2, 16_000))] {
                let w = try WAVWriter(url: NotesStore.audioURL(id, source: source))
                try w.append(samples)
                try w.close()
            }
            var formats: [AudioExport.Format] = [.m4a]
            if AudioExport.preferredFormat == .mp3 { formats.append(.mp3) } else { print("selftest: no LAME, MP3 export not checked") }
            for f in formats {
                let file = out.appendingPathComponent("m." + f.rawValue)
                let r = try AudioExport.export(noteID: id, title: "Selftest é", to: file, format: f)
                let back = try AudioIO.loadSamples(from: file)
                expect(abs(r.seconds - 1.5) < 0.001 && abs(Double(back.count) / 16_000 - 1.5) < 0.15, "export \(f): the longer side sets the length")
                expect(r.coupling == .separate && r.gains["mic"] == 12 && abs((r.gains["system"] ?? 0) - 1) < 0.1, "export \(f): each side's gain from its own level")
                let tail = AudioIO.rms(Array(back[18_400..<22_400])), want = 0.2 / sqrt(2) * pow(10, (r.gains["system"] ?? 0) / 20)
                expect(abs(tail - want) / want < 0.1, "export \(f): the call alone plays at its leveled volume")
            }
            let left = (try? FileManager.default.contentsOfDirectory(atPath: out.path))?.sorted() ?? []
            expect(left == formats.map { "m." + $0.rawValue }.sorted(), "export: only the finished files are left")
            expect((try? AudioExport.export(noteID: "selftest-no-such-note", title: "x", to: out.appendingPathComponent("x.m4a"), format: .m4a)) == nil,
                   "export: a note with no audio is refused")
        } catch { expect(false, "export threw: \(error)") }
        do {
            // A renamed note takes its saved audio along, unless John named the file himself.
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("linflow-follow-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: dir) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            func file(_ name: String) -> String { let u = dir.appendingPathComponent(name); fm.createFile(atPath: u.path, contents: Data([1])); return u.path }
            let saved = AudioExportRecord(path: file("Meeting Oct 8, 11.22 AM.mp3"), title: "Meeting Oct 8, 11:22 AM")
            let mine = AudioExportRecord(path: file("for Mike.mp3"), title: "Meeting Oct 8, 11:22 AM")
            let gone = AudioExportRecord(path: dir.appendingPathComponent("gone.m4a").path, title: "gone")
            let after = NotesStore.followTitle([saved, mine, gone], to: "Pass file viewer: demo")
            expect(after == [AudioExportRecord(path: dir.appendingPathComponent("Pass file viewer. demo.mp3").path, title: "Pass file viewer: demo")]
                   && fm.fileExists(atPath: dir.appendingPathComponent("Pass file viewer. demo.mp3").path) && fm.fileExists(atPath: mine.path),
                   "rename: the saved MP3 follows, a file John named stays his, a gone file is forgotten")
            _ = file("Taken.mp3")
            expect(NotesStore.followTitle(after, to: "Taken") == after, "rename: a taken name leaves the file to wait")
            let cased = NotesStore.followTitle(after, to: "pass file viewer: demo")
            expect(cased.first?.title == "pass file viewer: demo"
                   && (try? fm.contentsOfDirectory(atPath: dir.path))?.contains("pass file viewer. demo.mp3") == true,
                   "rename: a change of case alone renames the file")
        } catch { expect(false, "rename follow threw: \(error)") }

        // The speaker model's front end: Kaldi's filterbank, and enough protobuf to read the ONNX file.
        let tone: [Float] = (0..<16_000).map { (i: Int) -> Float in
            let wave = Float(0.1 * sin(2 * Double.pi * 440 * Double(i) / 16_000))
            return wave + Float((i * 7919) % 13) * 1e-4
        }
        let bank = Fbank.compute(tone[...])
        expect(bank?.count == 98 * Fbank.bins && bank?.allSatisfy { $0.isFinite } == true, "fbank: 98 frames of 80 bands from a second")
        expect(Fbank.compute(tone[0..<300]) == nil, "fbank: less than one frame is nothing")
        // a node {input "x", output "y", op_type "Relu"} and a weight {dims [2], data_type 1, name "w", raw_data 1.5, -2}
        let node: [UInt8] = [0x0a, 1, 0x78, 0x12, 1, 0x79, 0x22, 4] + Array("Relu".utf8)
        let weight: [UInt8] = [0x08, 2, 0x10, 1, 0x42, 1, 0x77, 0x4a, 8] + [0, 0, 0xc0, 0x3f, 0, 0, 0, 0xc0]
        let graph: [UInt8] = [0x0a, UInt8(node.count)] + node + [0x2a, UInt8(weight.count)] + weight
        let model = FileManager.default.temporaryDirectory.appendingPathComponent("linflow-onnx-\(UUID().uuidString).onnx")
        try? Data([0x08, 7, 0x3a, UInt8(graph.count)] + graph).write(to: model)
        let parsed = try? ONNXProbe.read(model)
        try? FileManager.default.removeItem(at: model)
        expect(parsed?.ops == ["Relu"] && parsed?.weights["w"] == [1.5, -2], "onnx: a node and a float weight read back")

        // The recording clock. Normal jitter never pads; a real stall or a slow start does.
        expect(MeetingRecorder.shortfall(expected: 16_000, have: 15_000, first: false) == 0, "shortfall: 60 ms of jitter is not a gap")
        expect(MeetingRecorder.shortfall(expected: 32_000, have: 15_000, first: false) == 17_000, "shortfall: a 1 s stall is filled exactly")
        expect(MeetingRecorder.shortfall(expected: 3_000, have: 1_000, first: true) == 2_000, "shortfall: a slow first chunk aligns the track")
        expect(MeetingRecorder.shortfall(expected: 1_500, have: 1_000, first: true) == 0, "shortfall: 30 ms of start-up latency is left alone")

        // Rescuing a take the engine heard nothing in. NOISE.md has the measurement behind
        // this: at 0 dB babble Parakeet returns an empty transcript rather than a degraded
        // one, so the retry has to land on a different engine kind.
        do {
            func urls(_ names: [String]) -> [URL] {
                names.map { URL(fileURLWithPath: "/models/ggml-\($0).bin") }
            }
            let all = urls(["parakeet-tdt-0.6b-v3-q8_0", "large-v3-turbo-q5_0", "small.en-q8_0"])

            let fromParakeet = ModelCatalog.rescueModelURL(after: .parakeet, installed: all)
            expect(fromParakeet?.lastPathComponent ?? "nil", "ggml-large-v3-turbo-q5_0.bin")

            // A second Parakeet is not a rescue: it fails on the same audio the same way.
            let onlyParakeets = urls(["parakeet-tdt-0.6b-v3-q8_0", "parakeet-tdt-0.6b-v3-q4_k"])
            expect(ModelCatalog.rescueModelURL(after: .parakeet, installed: onlyParakeets) == nil,
                   "rescue: another Parakeet is not a rescue from Parakeet")

            // Coming from Whisper the only other kind is Parakeet.
            expect(ModelCatalog.rescueModelURL(after: .whisper, installed: all)?.lastPathComponent ?? "nil",
                   "ggml-parakeet-tdt-0.6b-v3-q8_0.bin")

            // The most capable Whisper wins, whatever order they are installed in.
            let jumbled = urls(["small.en-q8_0", "parakeet-tdt-0.6b-v3-q8_0", "base.en", "medium-q5_0", "large-v3-turbo-q5_0"])
            expect(ModelCatalog.rescueModelURL(after: .parakeet, installed: jumbled)?.lastPathComponent ?? "nil",
                   "ggml-large-v3-turbo-q5_0.bin")

            expect(ModelCatalog.rescueModelURL(after: .parakeet, installed: []) == nil,
                   "rescue: nothing installed, nothing to rescue with")

            // An engine that hears no words returns a space or a newline, not "".
            expect(DictationController.isBlank(""), "blank: empty")
            expect(DictationController.isBlank("  \n "), "blank: whitespace only")
            expect(!DictationController.isBlank("ok"), "blank: a word is not blank")
        }

        // The no-reference noise estimate. Nothing switches on it yet - see the comment on
        // snrEstimate and NOISE.md - but it is logged on every dictation, so it has to be
        // monotonic in noise and it must not blow up on a short or silent clip.
        do {
            let rate = Int(AudioIO.sampleRate)
            /// A second of "speech": a tone burst, then quiet, repeated. Deterministic.
            func take(noise level: Float) -> [Float] {
                var out = [Float](); out.reserveCapacity(rate * 2)
                var seed: UInt64 = 12345
                func rnd() -> Float {                      // xorshift, so this never varies
                    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                    return Float(Int64(bitPattern: seed % 2000)) / 1000.0 - 1.0
                }
                for i in 0..<(rate * 2) {
                    let loud = (i / (rate / 5)) % 2 == 0    // 200 ms on, 200 ms off
                    let tone = loud ? 0.30 * sinf(2 * .pi * 220 * Float(i) / Float(rate)) : 0
                    out.append(tone + level * rnd())
                }
                return out
            }

            let quiet = AudioIO.snrEstimate(take(noise: 0.0005))
            let middling = AudioIO.snrEstimate(take(noise: 0.02))
            let loud = AudioIO.snrEstimate(take(noise: 0.12))
            expect(quiet.snrDB > middling.snrDB, "snr: a quiet room reads higher than a middling one")
            expect(middling.snrDB > loud.snrDB, "snr: a middling room reads higher than a loud one")
            expect(quiet.noiseFloor < loud.noiseFloor, "snr: the floor rises with the noise")

            // Degenerate inputs must not produce a number anything could act on.
            expect(AudioIO.snrEstimate([Float](repeating: 0, count: 100)).snrDB == 99,
                   "snr: too short to judge")
            expect(AudioIO.snrEstimate([Float](repeating: 0, count: rate)).snrDB == 99,
                   "snr: pure silence is not a ratio")
        }
    }
}
