import AppKit
import LinFlowCore

/// Settings' Record button: the next key, combination or mouse button pressed in the window
/// becomes the talk key.
///
/// The talk key is off while it listens, because the tap swallows Fn before the window can see
/// it, and a press of the old key would start a dictation. So the listening always ends: on a
/// finished combination, on Escape alone, on Cancel, or after 10 seconds, whichever comes first.
/// A window that lost focus mid-recording would otherwise leave John with no way to dictate.
extension DashboardModel {
    func recordHotkey() {
        guard !recordingHotkey else { return }
        controller.suspendHotkey()
        hotkeyRecorder = HotkeyRecorder()
        recordingHotkey = true
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp, .otherMouseDown, .otherMouseUp]) { [weak self] event in
            guard let self, let cg = event.cgEvent, let e = HotkeyEvent(cg) else { return event }
            switch self.hotkeyRecorder.handle(e) {
            case .pending: break
            case .cancelled: self.finishRecordingHotkey(nil)
            case .done(let key): self.finishRecordingHotkey(key)
            }
            return nil
        }
        let timeout = DispatchWorkItem { [weak self] in self?.finishRecordingHotkey(nil) }
        hotkeyTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    /// `key` nil keeps the old talk key.
    func finishRecordingHotkey(_ key: Hotkey?) {
        guard recordingHotkey else { return }
        if let m = hotkeyMonitor { NSEvent.removeMonitor(m) }
        hotkeyMonitor = nil
        hotkeyTimeout?.cancel()
        hotkeyTimeout = nil
        recordingHotkey = false
        if let key { controller.setHotkey(key) } else { controller.resumeHotkey() }
        settingChanged()
    }
}
