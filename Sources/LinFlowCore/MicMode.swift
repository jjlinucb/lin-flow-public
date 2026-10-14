import AVFoundation
import Foundation

/// macOS's Mic Mode for this app, chosen in Control Center while the mic is on: Standard, Wide
/// Spectrum or Voice Isolation. On 2026-10-06 John's Teams note kept 55 of his words. The MacBook
/// mic gave Lin Flow exact silence between words while another process, recording the same mic at
/// the same moment, got the room's normal floor (0.0014). Voice Isolation keeps only a voice close
/// to the mic, and with AirPods in, John's voice across the desk did not count. Every dictation
/// since the relaunch at 17:07 on 10-02 had the same digital-silence floor.
///
/// An app can read the mode and open the switcher, never set it, so Lin Flow logs it and, when a
/// meeting starts under Voice Isolation, offers the switcher.
public enum MicMode {
    /// Posted on the main thread when a meeting starts its mic under Voice Isolation.
    public static let isolatingMeeting = Notification.Name("LinFlow.MicMode.isolatingMeeting")

    public static func name(_ mode: AVCaptureDevice.MicrophoneMode) -> String {
        switch mode {
        case .standard: return "Standard"
        case .wideSpectrum: return "Wide Spectrum"
        case .voiceIsolation: return "Voice Isolation"
        @unknown default: return "mode \(mode.rawValue)"
        }
    }

    public static var summary: String {
        "mic mode: \(name(AVCaptureDevice.preferredMicrophoneMode)) chosen, \(name(AVCaptureDevice.activeMicrophoneMode)) active"
    }

    public static var isolating: Bool {
        AVCaptureDevice.preferredMicrophoneMode == .voiceIsolation || AVCaptureDevice.activeMicrophoneMode == .voiceIsolation
    }

    /// Control Center's Mic Mode switcher for this app.
    public static func showSwitcher() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }
}
