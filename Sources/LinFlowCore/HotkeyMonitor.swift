import ApplicationServices
import CoreGraphics
import Foundation

public enum HotkeyError: Error, LocalizedError {
    case tapCreationFailed
    public var errorDescription: String? {
        "Couldn't watch the keyboard. Grant Lin Flow access under System Settings → Privacy & Security → Accessibility (and Input Monitoring), then relaunch."
    }
}

/// Watches the talk key system-wide with a CGEventTap and reports press / release. Fn never
/// reaches the normal key event APIs, so a tap is the one way to see it; the same tap covers every
/// other key, combination and mouse button a `Hotkey` can name.
///
/// `HotkeyMatcher` decides what fires and what is swallowed, and its comment says why. In short:
/// Fn's own flagsChanged when Fn is in the hotkey, so the Globe action does not fire on every
/// dictation (John's opens the emoji picker, AppleFnUsageType = 2); never Shift, Control, Option or
/// Command; a key or mouse button of the hotkey while the combination is held. A quick click of a
/// talk-key mouse button is posted again, marked, so it still does what a click does.
///
/// The tap asks for key and mouse events only when the hotkey uses them, so with Fn it sees
/// modifier changes alone, as it always has.
///
/// Runs its own CFRunLoop on a background thread and calls `onPress` / `onRelease` right there,
/// so they must be quick and thread-safe (DictationController's hand the key to its audio
/// queue and return). They used to hop to the main thread first, where a busy window or a
/// slow Accessibility read could hold a key press back while the first words went unrecorded.
public final class HotkeyMonitor {
    public var hotkey: Hotkey
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    /// Read and changed on the tap's thread, and by stop() on main, so always under `lock`.
    private var matcher: HotkeyMatcher
    private let lock = NSLock()

    /// Marks the clicks this tap posts again, so it lets them through instead of catching them.
    static let replayMarker: Int64 = 0x4C_69_6E_46   // "LinF"

    public init(hotkey: Hotkey) {
        self.hotkey = hotkey
        matcher = HotkeyMatcher(hotkey: hotkey)
    }

    /// Whether this process is trusted for Accessibility. `prompt` pops the
    /// system dialog (and registers the app in the list) when it isn't.
    @discardableResult
    public static func checkAccessibility(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    public func start() throws {
        guard tap == nil else { return }
        lock.withLock { matcher = HotkeyMatcher(hotkey: hotkey) }
        var mask = 1 << CGEventType.flagsChanged.rawValue
        if hotkey.usesKeys { mask |= 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue }
        if hotkey.usesMouse { mask |= 1 << CGEventType.otherMouseDown.rawValue | 1 << CGEventType.otherMouseUp.rawValue }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                let swallow = monitor.handle(type: type, event: event)
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr) else {
            throw HotkeyError.tapCreationFailed
        }
        self.tap = tap
        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            let rl = CFRunLoopGetCurrent()
            self.runLoop = rl
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            Log.info("hotkey tap running (\(self.hotkey.label))")
            CFRunLoopRun()
        }
        thread.name = "linflow.hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    public func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        // A take in progress ends here rather than waiting for a release this tap will not see.
        let wasActive: Bool = lock.withLock {
            defer { matcher = HotkeyMatcher(hotkey: hotkey) }
            return matcher.active
        }
        if wasActive { onRelease?() }
        if let rl = runLoop { CFRunLoopStop(rl) }
        tap = nil; runLoop = nil; thread = nil
    }

    /// Returns true when the event should be swallowed.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // macOS disables a tap it thinks is unresponsive; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker { return false }
        guard let e = HotkeyEvent(event) else { return false }
        let out = lock.withLock { matcher.handle(e, at: Double(event.timestamp) / 1_000_000_000) }
        switch out.signal {
        case .press: onPress?()
        case .release: onRelease?()
        case .none: break
        }
        if out.replayClick, case .mouse(let button, _) = e { Self.replayClick(button: button, at: event.location) }
        return out.swallow
    }

    /// Posts the click the tap swallowed, down and up, marked so this tap passes it on.
    private static func replayClick(button: Int64, at point: CGPoint) {
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .center) else { continue }
            e.setIntegerValueField(.mouseEventButtonNumber, value: button)
            // A click count of 0 is not a click to a browser: it opens no link.
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.setIntegerValueField(.eventSourceUserData, value: replayMarker)
            e.post(tap: .cgSessionEventTap)
        }
    }
}
