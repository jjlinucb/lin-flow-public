import AppKit
import Foundation

/// Audible state cues (the menu bar icon alone is easy to miss).
public enum Sound: String {
    case ready = "Glass"
    case recordStart = "Tink"
    case recordStop = "Pop"
    case error = "Basso"

    public func play() {
        guard Settings.shared.sounds else { return }
        let path = "/System/Library/Sounds/\(rawValue).aiff"
        DispatchQueue.main.async {
            NSSound(contentsOfFile: path, byReference: true)?.play()
        }
    }
}
