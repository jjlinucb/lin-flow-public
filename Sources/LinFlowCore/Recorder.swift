import AVFoundation
import CoreAudio
import Foundation

public enum RecorderError: Error, LocalizedError {
    case noInputDevice
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone is available."
        case .permissionDenied: return "Microphone access was denied. Allow Lin Flow under System Settings → Privacy & Security → Microphone."
        }
    }
}

/// Push-to-talk microphone capture. A fresh AVAudioEngine per take keeps
/// device switches (AirPods on/off) from wedging a long-lived engine, and
/// costs only a few milliseconds. Samples come out as 16 kHz mono float.
public final class Recorder {
    /// RMS level of each incoming chunk (0...~1), delivered on the audio thread.
    public var onLevel: ((Float) -> Void)?
    /// Each resampled chunk as it arrives (audio thread). For live transcription.
    public var onChunk: (([Float]) -> Void)?
    /// Off for long live sessions so an hour of audio isn't held in memory.
    public var keepsSamples = true
    /// The input device changed under the engine (AirPods on or off, a headset unplugged).
    /// AVAudioEngine stops on its own when that happens and delivers nothing more until it
    /// is started again, so a long recording has to restart the take from here.
    public var onConfigurationChange: (() -> Void)?
    private var configObserver: NSObjectProtocol?

    private var engine: AVAudioEngine?
    private var resampler: Resampler?
    private var samples: [Float] = []
    private let lock = NSLock()
    public private(set) var isRecording = false

    /// How one take started, for the log and the history row.
    public struct Start: Equatable {
        /// The input device by name, e.g. "MacBook Pro Microphone" or "AirPods Pro".
        public var device: String?
        /// How long `AVAudioEngine.start()` blocked.
        public var engineSeconds = 0.0
        /// From the moment passed to `start(since:)` -- the key going down -- to the first sample
        /// of audio. Nil until a buffer has arrived, and for a take too short to get one.
        public var firstAudioSeconds: Double?
    }
    /// The take in progress, or the last one once it has stopped.
    public var lastStart: Start? { lock.lock(); defer { lock.unlock() }; return takeStart }
    private var takeStart: Start?

    public init() {}

    public static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Prompts on first use; completion runs on an arbitrary queue.
    public static func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        default: completion(false)
        }
    }

    /// `requested` is when the take was asked for, as a host time (`mach_absolute_time`), so
    /// the delay to the first audio covers everything after the key: the hop to the audio
    /// queue, building the engine, the device waking up. Nothing measured that before 09-22.
    public func start(since requested: UInt64 = mach_absolute_time()) throws {
        guard !isRecording else { return }
        guard Recorder.microphoneAuthorized else { throw RecorderError.permissionDenied }
        let device = Self.defaultInputName()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }
        let resampler = try Resampler(from: format)

        lock.lock(); samples.removeAll(keepingCapacity: true); takeStart = Start(device: device); lock.unlock()
        var first = true
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self else { return }
            if first {
                first = false
                let captured = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
                let delay = captured > requested ? AVAudioTime.seconds(forHostTime: captured - requested) : 0
                self.lock.lock(); self.takeStart?.firstAudioSeconds = delay; self.lock.unlock()
            }
            let chunk = resampler.convert(buffer)
            if self.keepsSamples { self.lock.lock(); self.samples.append(contentsOf: chunk); self.lock.unlock() }
            self.onLevel?(AudioIO.rms(chunk))
            self.onChunk?(chunk)
        }
        engine.prepare()
        let beforeStart = mach_absolute_time()
        try engine.start()
        let engineSeconds = AVAudioTime.seconds(forHostTime: mach_absolute_time() - beforeStart)
        lock.lock(); takeStart?.engineSeconds = engineSeconds; lock.unlock()
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Log.info("microphone: engine configuration changed")
            self?.onConfigurationChange?()
        }
        self.engine = engine
        self.resampler = resampler
        self.isRecording = true
    }

    /// The system's default input device by name, which is what AVAudioEngine records from.
    public static func defaultInputName() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard err == noErr, let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }

    /// Stops and returns everything captured since start().
    @discardableResult
    public func stop() -> [Float] {
        guard isRecording, let engine = engine else { return [] }
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        self.resampler = nil
        isRecording = false
        lock.lock(); let out = samples; samples = []; lock.unlock()
        return out
    }
}
