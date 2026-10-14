import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

public enum SystemAudioTapError: Error, LocalizedError {
    case osStatus(String, OSStatus)
    case noFormat

    public var errorDescription: String? {
        switch self {
        case .osStatus(let what, let code): return "\(what) failed (\(code)). If macOS asked about System Audio Recording, allow it and try again."
        case .noFormat: return "Could not read the system audio format."
        }
    }
}

/// Captures what every app is playing (the other people on a call) with a
/// Core Audio process tap, macOS 14.2+. The tap is wrapped in a private
/// aggregate device whose I/O proc hands us the mix; AVAudioEngine can't read
/// taps, so this goes through the low-level HAL API. Output is 16 kHz mono
/// float like every other audio source in the app. macOS prompts once for
/// "System Audio Recording" (NSAudioCaptureUsageDescription in Info.plist).
public final class SystemAudioTap {
    public var onChunk: (([Float]) -> Void)?
    public var onLevel: ((Float) -> Void)?
    public private(set) var isRunning = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var resampler: Resampler?
    private var isFloat32 = false
    private var loggedLayout = false
    private var rateWatch = RateWatch(rate: 48000)
    private let queue = DispatchQueue(label: "linflow.systemtap", qos: .userInitiated)

    public init() {}
    deinit { stop() }

    public func start() throws {
        guard !isRunning else { return }

        // Everything except nothing: a stereo mixdown of all processes' output,
        // left audible (unmuted) so the user still hears the call.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tap)
        guard err == noErr, tap != kAudioObjectUnknown else { throw SystemAudioTapError.osStatus("Creating the system audio tap", err) }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        do { try Self.read(tap, kAudioTapPropertyFormat, into: &asbd) } catch { stop(); throw error }
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { stop(); throw SystemAudioTapError.noFormat }
        format = fmt
        // Float32 is what the tap produces on every macOS so far. If that ever changes, the
        // old AVAudioPCMBuffer path below is the fallback, layout risk and all.
        isFloat32 = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: 1, interleaved: false)!
        do { resampler = try Resampler(from: isFloat32 ? monoFormat : fmt) } catch { stop(); throw error }
        rateWatch = RateWatch(rate: asbd.mSampleRate)

        var outputDevice = AudioDeviceID(kAudioObjectUnknown)
        do { try Self.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, into: &outputDevice) } catch { stop(); throw error }
        let outputUID: String
        do { outputUID = try Self.readString(outputDevice, kAudioDevicePropertyDeviceUID) } catch { stop(); throw error }
        let outputName = (try? Self.readString(outputDevice, kAudioObjectPropertyName)) ?? outputUID

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lin Flow System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard err == noErr else { stop(); throw SystemAudioTapError.osStatus("Creating the capture device", err) }
        aggregateID = agg

        err = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, queue) { [weak self] _, inputData, _, _, _ in
            guard let self, let fmt = self.format, var rs = self.resampler else { return }
            let buffer: AVAudioPCMBuffer?
            if self.isFloat32 {
                // The layout is read off the buffer list itself, never off `fmt`. On 2026-09-17
                // the format said one channel layout and the HAL delivered another, and
                // AVAudioPCMBuffer(bufferListNoCopy:) believed the format: it paired adjacent
                // samples of one channel as left and right and averaged them, so every meeting
                // came out at double speed with half its length. Parakeet is robust enough to
                // 2x speech that the transcript still read as words, which is what hid it.
                if !self.loggedLayout {
                    self.loggedLayout = true
                    Log.info("system audio buffers: \(AudioIO.describeLayout(inputData)) at \(Int(fmt.sampleRate)) Hz")
                }
                let mono = AudioIO.monoMix(inputData)
                let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
                let was = self.rateWatch.rate
                if let real = self.rateWatch.add(frames: mono.count, at: now),
                   let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: real, channels: 1, interleaved: false),
                   let fresh = try? Resampler(from: format) {
                    Log.info("system audio now arrives at \(Int(real)) Hz, where it was \(Int(was)) Hz: resampling from \(Int(real)). The tap reports \(Int(fmt.sampleRate)) Hz")
                    self.resampler = fresh
                    rs = fresh
                }
                buffer = mono.isEmpty ? nil : AudioIO.monoBuffer(mono, sampleRate: self.rateWatch.rate)
            } else {
                buffer = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inputData, deallocator: nil)
            }
            guard let buffer, buffer.frameLength > 0 else { return }
            let chunk = rs.convert(buffer)
            guard !chunk.isEmpty else { return }
            self.onLevel?(AudioIO.rms(chunk))
            self.onChunk?(chunk)
        }
        guard err == noErr else { stop(); throw SystemAudioTapError.osStatus("Attaching to the capture device", err) }
        err = AudioDeviceStart(agg, procID)
        guard err == noErr else { stop(); throw SystemAudioTapError.osStatus("Starting system audio capture", err) }
        isRunning = true
        Log.info("system audio tap running (\(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch, output: \(outputName))")
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
                self.procID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        format = nil
        resampler = nil
        isFloat32 = false
        loggedLayout = false
        if isRunning { Log.info("system audio tap stopped") }
        isRunning = false
    }

    // MARK: property helpers

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard err == noErr else { throw SystemAudioTapError.osStatus("Reading audio property \(selector)", err) }
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>? = nil
        let err = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard err == noErr, let cf = value?.takeRetainedValue() else { throw SystemAudioTapError.osStatus("Reading audio property \(selector)", err) }
        return cf as String
    }
}
