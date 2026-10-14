import Foundation
import LinFlowCore

extension SelfTest {
    /// The talk key: what it stores, what fires, what is swallowed, and what Record captures.
    /// All on made-up events: nothing is posted, so nothing reaches John's apps.
    static func hotkey() {
        // Storage. The four single keys saved before 2026-09-25 read back as they were.
        for raw in ["fn", "rightOption", "rightCommand", "rightControl"] {
            expect(Hotkey(rawValue: raw)?.rawValue == raw, "hotkey: \(raw) still reads back")
        }
        expect(Hotkey(rawValue: "fn") == .fn, "hotkey: fn is the Fn preset")
        expect(Hotkey(rawValue: "leftControl+leftOption")?.label ?? "", "Left Control + Left Option", "hotkey: chord label")
        expect(Hotkey(rawValue: "middleMouse")?.label ?? "", "Middle Mouse Button", "hotkey: middle button label")
        expect(Hotkey(rawValue: "leftCommand+key49")?.label ?? "", "Left Command + Space", "hotkey: key label")
        expect(Hotkey(rawValue: "fn")?.label ?? "", "Fn (Globe)", "hotkey: Fn label unchanged")
        expect(Hotkey(rawValue: "mouse0") == nil && Hotkey(rawValue: "mouse1") == nil, "hotkey: left and right buttons refused")
        expect(Hotkey(rawValue: "") == nil && Hotkey(rawValue: "banana") == nil, "hotkey: junk is refused, so Settings falls back to Fn")
        expect(Hotkey(rawValue: "fn+fn")?.parts.count == 1, "hotkey: a part named twice counts once")

        let fnMask: UInt64 = 0x80_0000
        let lctl: UInt64 = 0x0001 | 0x4_0000   // device bit + .maskControl
        let rctl: UInt64 = 0x2000 | 0x4_0000
        let lopt: UInt64 = 0x0020 | 0x8_0000

        // Fn alone: press, release, and its own event is swallowed; Shift while Fn is held is not.
        var m = HotkeyMatcher(hotkey: .fn)
        expect(m.handle(.flags(fnMask, keyCode: 63), at: 0) == .init(signal: .press, swallow: true), "hotkey: Fn down presses and is swallowed")
        expect(m.handle(.flags(fnMask | 0x0002, keyCode: 56), at: 0.1).swallow == false, "hotkey: Shift while Fn is held passes")
        expect(m.handle(.flags(0, keyCode: 63), at: 1) == .init(signal: .release, swallow: true), "hotkey: Fn up releases")

        // A sided modifier: the other side does not fire it, and it is never swallowed.
        m = HotkeyMatcher(hotkey: Hotkey(rawValue: "leftControl")!)
        expect(m.handle(.flags(rctl, keyCode: 62), at: 0).signal == .none, "hotkey: Right Control does not fire Left Control")
        expect(m.handle(.flags(rctl | lctl, keyCode: 59), at: 0.1) == .init(signal: .press), "hotkey: Left Control presses, not swallowed")
        expect(m.handle(.flags(rctl, keyCode: 59), at: 1).signal == .release, "hotkey: Left Control up releases")

        // A chord fires on its last key and ends when either comes up.
        m = HotkeyMatcher(hotkey: Hotkey(rawValue: "leftControl+leftOption")!)
        expect(m.handle(.flags(lctl, keyCode: 59), at: 0).signal == .none, "hotkey: half a chord does nothing")
        expect(m.handle(.flags(lctl | lopt, keyCode: 58), at: 0.1).signal == .press, "hotkey: the whole chord presses")
        expect(m.handle(.flags(lopt, keyCode: 59), at: 1).signal == .release, "hotkey: letting go of one releases")

        // The middle button: swallowed while it talks; a quick click is replayed, a hold is not.
        m = HotkeyMatcher(hotkey: .middleMouse)
        expect(m.handle(.mouse(2, down: true), at: 0) == .init(signal: .press, swallow: true), "hotkey: middle down presses, swallowed")
        expect(m.handle(.mouse(2, down: false), at: 0.2) == .init(signal: .release, swallow: true, replayClick: true), "hotkey: a quick middle click is replayed")
        _ = m.handle(.mouse(2, down: true), at: 5)
        expect(m.handle(.mouse(2, down: false), at: 7) == .init(signal: .release, swallow: true, replayClick: false), "hotkey: a held middle button is not replayed")
        expect(m.handle(.mouse(3, down: true), at: 8) == .init(), "hotkey: another button passes untouched")

        // A key in a chord: typed normally until the chord is held, swallowed while it is.
        m = HotkeyMatcher(hotkey: Hotkey(rawValue: "leftControl+key49")!)
        expect(m.handle(.key(49, down: true, isRepeat: false), at: 0) == .init(), "hotkey: Space alone types")
        _ = m.handle(.key(49, down: false, isRepeat: false), at: 0.1)
        _ = m.handle(.flags(lctl, keyCode: 59), at: 1)
        expect(m.handle(.key(49, down: true, isRepeat: false), at: 1.1) == .init(signal: .press, swallow: true), "hotkey: Control + Space presses, Space swallowed")
        expect(m.handle(.key(49, down: true, isRepeat: true), at: 1.5).swallow, "hotkey: Space's auto-repeat is swallowed while held")
        expect(m.handle(.key(49, down: false, isRepeat: false), at: 2) == .init(signal: .release, swallow: true), "hotkey: Space up releases, swallowed")

        // Record.
        var r = HotkeyRecorder()
        expect(r.handle(.flags(fnMask, keyCode: 63)) == .pending, "record: still listening while held")
        expect(r.handle(.flags(0, keyCode: 63)) == .done(.fn), "record: Fn")
        r = HotkeyRecorder()
        _ = r.handle(.flags(lctl, keyCode: 59)); _ = r.handle(.flags(lctl | lopt, keyCode: 58)); _ = r.handle(.flags(lctl, keyCode: 58))
        expect(r.handle(.flags(0, keyCode: 59)) == .done(Hotkey(rawValue: "leftControl+leftOption")!), "record: a chord, in the order pressed")
        r = HotkeyRecorder()
        _ = r.handle(.mouse(2, down: true))
        expect(r.handle(.mouse(2, down: false)) == .done(.middleMouse), "record: the middle button")
        r = HotkeyRecorder()
        _ = r.handle(.key(53, down: true, isRepeat: false))
        expect(r.handle(.key(53, down: false, isRepeat: false)) == .cancelled, "record: Escape alone cancels")
    }
}
