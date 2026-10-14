import CoreGraphics
import Foundation

/// What you hold to talk: one key, a combination, or a mouse button, alone or with keys.
///
/// John, 2026-09-25: "the key to do the recording on Lin Flow needs to be settable even though
/// I'll probably leave it as FN for myself right now." Windows got the same on 09-25 (PR #17), for
/// the middle button of a plain three-button mouse. Fn stays the default.
///
/// Stored as its parts' names joined by "+": "fn", "rightOption", "leftControl+leftOption",
/// "middleMouse", "leftCommand+key49". The four single keys the Mac offered before read back
/// unchanged, so a saved setting survives the upgrade.
public struct Hotkey: Hashable {
    public enum Part: Hashable {
        /// Fn (Globe). One key, no side.
        case fn
        case modifier(Modifier)
        /// Any other key, by virtual key code.
        case key(Int64)
        /// An extra mouse button, by CGEvent button number: 2 middle, 3 back, 4 forward. The
        /// left and right buttons (0 and 1) are never a talk key.
        case mouse(Int64)
    }

    /// Shift, Control, Option and Command, each side on its own.
    public enum Modifier: String, CaseIterable {
        case leftShift, rightShift, leftControl, rightControl, leftOption, rightOption, leftCommand, rightCommand

        public var keyCode: Int64 {
            switch self {
            case .leftShift: return 56
            case .rightShift: return 60
            case .leftControl: return 59
            case .rightControl: return 62
            case .leftOption: return 58
            case .rightOption: return 61
            case .leftCommand: return 55
            case .rightCommand: return 54
            }
        }

        /// The device-dependent bit in a CGEvent's flags. The side-less flags (.maskControl and
        /// so on) cannot tell which Control is down, so a chord of Left Control would fire on
        /// the right one too.
        var deviceMask: UInt64 {
            switch self {
            case .leftControl: return 0x0001
            case .leftShift: return 0x0002
            case .rightShift: return 0x0004
            case .leftCommand: return 0x0008
            case .rightCommand: return 0x0010
            case .leftOption: return 0x0020
            case .rightOption: return 0x0040
            case .rightControl: return 0x2000
            }
        }

        public var label: String {
            switch self {
            case .leftShift: return "Left Shift"
            case .rightShift: return "Right Shift"
            case .leftControl: return "Left Control"
            case .rightControl: return "Right Control"
            case .leftOption: return "Left Option"
            case .rightOption: return "Right Option"
            case .leftCommand: return "Left Command"
            case .rightCommand: return "Right Command"
            }
        }

        init?(keyCode: Int64) {
            guard let m = Modifier.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
            self = m
        }
    }

    public static let fnKeyCode: Int64 = 63
    static let fnMask = CGEventFlags.maskSecondaryFn.rawValue
    public static let escapeKeyCode: Int64 = 53

    /// In the order they were pressed, without repeats.
    public let parts: [Part]

    public init?(parts: [Part]) {
        var seen: [Part] = []
        for p in parts where !seen.contains(p) {
            if case .mouse(let b) = p, b < 2 { return nil }
            seen.append(p)
        }
        guard !seen.isEmpty else { return nil }
        self.parts = seen
    }

    public static let fn = Hotkey(parts: [.fn])!
    public static let middleMouse = Hotkey(parts: [.mouse(2)])!

    /// What the menu and Settings offer without recording: the four keys the Mac always had, and
    /// the middle button.
    public static let presets: [Hotkey] = [
        .fn,
        Hotkey(parts: [.modifier(.rightOption)])!,
        Hotkey(parts: [.modifier(.rightCommand)])!,
        Hotkey(parts: [.modifier(.rightControl)])!,
        .middleMouse,
    ]

    // MARK: storage

    public var rawValue: String { parts.map(Self.name).joined(separator: "+") }

    public init?(rawValue: String) {
        var parts: [Part] = []
        for token in rawValue.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard let p = Self.part(named: token) else { return nil }
            parts.append(p)
        }
        self.init(parts: parts)
    }

    static func name(_ p: Part) -> String {
        switch p {
        case .fn: return "fn"
        case .modifier(let m): return m.rawValue
        case .key(let c): return "key\(c)"
        case .mouse(2): return "middleMouse"
        case .mouse(3): return "mouseBack"
        case .mouse(4): return "mouseForward"
        case .mouse(let b): return "mouse\(b)"
        }
    }

    static func part(named s: String) -> Part? {
        if s == "fn" { return .fn }
        if let m = Modifier(rawValue: s) { return .modifier(m) }
        switch s {
        case "middleMouse": return .mouse(2)
        case "mouseBack": return .mouse(3)
        case "mouseForward": return .mouse(4)
        default: break
        }
        if s.hasPrefix("mouse"), let b = Int64(s.dropFirst(5)), b >= 2 { return .mouse(b) }
        if s.hasPrefix("key"), let c = Int64(s.dropFirst(3)), c >= 0, c < 128 { return .key(c) }
        return nil
    }

    // MARK: display

    public var label: String {
        if self == .fn { return "Fn (Globe)" }
        return parts.map(Self.label).joined(separator: " + ")
    }

    static func label(_ p: Part) -> String {
        switch p {
        case .fn: return "Fn"
        case .modifier(let m): return m.label
        case .key(let c): return keyNames[c] ?? "Key \(c)"
        case .mouse(2): return "Middle Mouse Button"
        case .mouse(3): return "Mouse Back Button"
        case .mouse(4): return "Mouse Forward Button"
        case .mouse(let b): return "Mouse Button \(b + 1)"
        }
    }

    /// US-layout names for the key codes. A code missing here still works; it reads "Key 50".
    static let keyNames: [Int64: String] = {
        var n: [Int64: String] = [:]
        let letters: [(Int64, String)] = [(0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"),
                                          (34, "I"), (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"),
                                          (12, "Q"), (15, "R"), (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"),
                                          (16, "Y"), (6, "Z")]
        let digits: [(Int64, String)] = [(29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9")]
        let fkeys: [(Int64, String)] = [(122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"), (98, "F7"), (100, "F8"),
                                        (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"), (105, "F13"), (107, "F14"), (113, "F15"),
                                        (106, "F16"), (64, "F17"), (79, "F18"), (80, "F19"), (90, "F20")]
        let others: [(Int64, String)] = [(49, "Space"), (36, "Return"), (48, "Tab"), (53, "Escape"), (51, "Delete"), (117, "Forward Delete"),
                                         (123, "Left Arrow"), (124, "Right Arrow"), (125, "Down Arrow"), (126, "Up Arrow"),
                                         (115, "Home"), (119, "End"), (116, "Page Up"), (121, "Page Down"), (57, "Caps Lock"),
                                         (50, "`"), (27, "-"), (24, "="), (33, "["), (30, "]"), (42, "\\"), (41, ";"), (39, "'"),
                                         (43, ","), (47, "."), (44, "/"), (76, "Enter"), (71, "Clear")]
        for (c, s) in letters + digits + fkeys + others { n[c] = s }
        return n
    }()

    // MARK: what the tap needs to see

    var usesKeys: Bool { parts.contains { if case .key = $0 { return true }; return false } }
    var usesMouse: Bool { parts.contains { if case .mouse = $0 { return true }; return false } }

    /// Fn and the eight sided modifiers that `flags` says are down.
    static func modifiersDown(in flags: UInt64) -> Set<Part> {
        var down: Set<Part> = []
        if flags & fnMask != 0 { down.insert(.fn) }
        for m in Modifier.allCases where flags & m.deviceMask != 0 { down.insert(.modifier(m)) }
        return down
    }
}

/// One event the talk key cares about, taken out of a CGEvent so the logic can be tested
/// without posting anything.
public enum HotkeyEvent: Equatable {
    /// A modifier went down or up: the flags after the change, and the key that changed.
    case flags(UInt64, keyCode: Int64)
    case key(Int64, down: Bool, isRepeat: Bool)
    case mouse(Int64, down: Bool)

    public init?(_ e: CGEvent) {
        switch e.type {
        case .flagsChanged:
            self = .flags(e.flags.rawValue, keyCode: e.getIntegerValueField(.keyboardEventKeycode))
        case .keyDown, .keyUp:
            self = .key(e.getIntegerValueField(.keyboardEventKeycode), down: e.type == .keyDown,
                        isRepeat: e.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .otherMouseDown, .otherMouseUp:
            self = .mouse(e.getIntegerValueField(.mouseEventButtonNumber), down: e.type == .otherMouseDown)
        default:
            return nil
        }
    }
}

/// Turns events into press and release for one hotkey, and says which events to swallow.
///
/// What is swallowed, and why:
/// - Fn's own flagsChanged, whenever Fn is part of the hotkey, so the Globe action (John's opens
///   the emoji picker) does not fire on every dictation.
/// - Never Shift, Control, Option or Command: apps rely on seeing their state.
/// - A key or mouse button of the hotkey, when it is the part that completes the combination or
///   arrives while it is held, and then its matching release. A middle button held to talk
///   should not also open a link, and a letter in a chord should not type.
/// - A mouse button released within `replayWindow` asks for its click to be replayed, so a quick
///   middle click still opens a link in a new tab. 0.35 s is the controller's
///   `minimumClipSeconds`, below which the take is dropped anyway. Windows does the same at its
///   own 0.3 s.
public struct HotkeyMatcher {
    public let hotkey: Hotkey
    public static let replayWindow: TimeInterval = 0.35

    public enum Signal: Equatable { case none, press, release }
    public struct Outcome: Equatable {
        public var signal: Signal = .none
        public var swallow = false
        public var replayClick = false
        public init(signal: Signal = .none, swallow: Bool = false, replayClick: Bool = false) {
            self.signal = signal; self.swallow = swallow; self.replayClick = replayClick
        }
    }

    private let required: Set<Hotkey.Part>
    private var held: Set<Hotkey.Part> = []
    private var swallowedAt: [Hotkey.Part: TimeInterval] = [:]
    public private(set) var active = false

    public init(hotkey: Hotkey) {
        self.hotkey = hotkey
        required = Set(hotkey.parts)
    }

    public mutating func handle(_ event: HotkeyEvent, at time: TimeInterval) -> Outcome {
        switch event {
        case .flags(let flags, let keyCode):
            // Every modifier in the hotkey is read back from the flags, not tracked from the one
            // key that changed, so a release the tap missed cannot leave one stuck down.
            let down = Hotkey.modifiersDown(in: flags)
            for p in required {
                switch p {
                case .fn, .modifier: if down.contains(p) { held.insert(p) } else { held.remove(p) }
                default: break
                }
            }
            var out = Outcome(signal: evaluate())
            out.swallow = keyCode == Hotkey.fnKeyCode && required.contains(.fn)
            return out
        case .key(let code, let down, let isRepeat):
            return button(.key(code), down: down, isRepeat: isRepeat, at: time)
        case .mouse(let b, let down):
            return button(.mouse(b), down: down, isRepeat: false, at: time)
        }
    }

    private mutating func button(_ p: Hotkey.Part, down: Bool, isRepeat: Bool, at time: TimeInterval) -> Outcome {
        guard required.contains(p) else { return Outcome() }
        var out = Outcome()
        if down {
            if isRepeat { out.swallow = active; return out }
            held.insert(p)
            out.signal = evaluate()
            if active { out.swallow = true; swallowedAt[p] = time }
        } else {
            held.remove(p)
            out.signal = evaluate()
            if let at = swallowedAt.removeValue(forKey: p) {
                out.swallow = true
                if case .mouse = p { out.replayClick = time - at < Self.replayWindow }
            }
        }
        return out
    }

    private mutating func evaluate() -> Signal {
        let now = required.isSubset(of: held)
        defer { active = now }
        if now && !active { return .press }
        if !now && active { return .release }
        return .none
    }
}

/// Settings' Record button: everything pressed, in order, until everything is released again.
/// Escape on its own cancels. A left or right click never reaches it.
public struct HotkeyRecorder {
    public enum Result: Equatable { case pending, done(Hotkey), cancelled }

    private var down: Set<Hotkey.Part> = []
    private var seen: [Hotkey.Part] = []

    public init() {}

    public mutating func handle(_ event: HotkeyEvent) -> Result {
        switch event {
        case .flags(let flags, _):
            let now = Hotkey.modifiersDown(in: flags)
            for p in now.subtracting(down.filter(Self.isModifier)) { press(p) }
            for p in down.filter(Self.isModifier).subtracting(now) { down.remove(p) }
        case .key(let c, let isDown, let isRepeat):
            if isRepeat { return .pending }
            if isDown { press(.key(c)) } else { down.remove(.key(c)) }
        case .mouse(let b, let isDown):
            guard b >= 2 else { return .pending }
            if isDown { press(.mouse(b)) } else { down.remove(.mouse(b)) }
        }
        guard down.isEmpty, !seen.isEmpty else { return .pending }
        if seen == [.key(Hotkey.escapeKeyCode)] { return .cancelled }
        return Hotkey(parts: seen).map(Result.done) ?? .cancelled
    }

    private mutating func press(_ p: Hotkey.Part) {
        down.insert(p)
        if !seen.contains(p) { seen.append(p) }
    }

    private static func isModifier(_ p: Hotkey.Part) -> Bool {
        switch p {
        case .fn, .modifier: return true
        default: return false
        }
    }
}
