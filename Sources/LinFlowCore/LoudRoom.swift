import Foundation

/// Tells John when the room is too loud for the Mac's own microphone. Moving the mic closer
/// beats every software fix for cafe babble (NOISE.md), and his AirPods already do it, so the
/// one useful response to a loud room is a nudge to put them in.
///
/// The floor is judged only for the built-in mic. AirPods suppress noise before Lin Flow hears
/// it and read a floor near 0 in any room, so their floor says nothing about the room. Measured
/// on 913 built-in takes to 2026-10-14: median 0.0022, 90% under 0.0036, and the cafe on 10-14
/// read 0.031 to 0.046. 0.01 or more held for 26 of them, on six days. Re-measure before moving it.
public struct LoudRoom {
    public static let floorThreshold = 0.01
    /// Two loud takes in a row, so one cough or passing espresso machine is not a room.
    public static let streakLength = 2
    /// Once said, quiet for this long: in a cafe every take is loud and he has heard it.
    public static let quietPeriod: TimeInterval = 2 * 60 * 60

    public private(set) var streak = 0
    public private(set) var lastWarned: Date?
    public init() {}

    /// The Mac's own mic: "MacBook Pro Microphone", "MacBook Air Microphone", and
    /// "Built-in Microphone" on older Macs and some locales.
    public static func isBuiltIn(_ device: String?) -> Bool {
        guard let d = device?.lowercased() else { return false }
        return d.contains("macbook") || d.contains("built-in")
    }

    /// Returns true on the take that should show the nudge.
    public mutating func record(floor: Double, device: String?, at now: Date = Date()) -> Bool {
        guard Self.isBuiltIn(device), floor >= Self.floorThreshold else { streak = 0; return false }
        streak += 1
        guard streak >= Self.streakLength else { return false }
        if let last = lastWarned, now.timeIntervalSince(last) < Self.quietPeriod { return false }
        lastWarned = now
        return true
    }
}
