import CoreGraphics
import Foundation
// Usage: hotkeypost <hold-seconds>
// Posts a synthetic Right Option press (keycode 61) as a flagsChanged event, holds, then
// releases. It could post Fn too and no longer can: Wispr Flow also binds Fn, so a synthetic
// Fn records and pastes into whatever John has focused, and John's own Lin Flow listens on Fn.
// Right Option only reaches a Lin Flow whose hotkey was set to it, which the live one's is not.
let hold = Double(CommandLine.arguments.dropFirst().first ?? "3") ?? 3
let src = CGEventSource(stateID: .combinedSessionState)
func post(down: Bool) {
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: 61, keyDown: down) else { return }
    e.type = .flagsChanged
    e.flags = down ? [.maskAlternate] : []
    e.post(tap: .cghidEventTap)
}
post(down: true)
print("right option DOWN")
Thread.sleep(forTimeInterval: hold)
post(down: false)
print("right option UP")
