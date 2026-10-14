import Foundation

/// How fast a capture really delivers audio, against the clock. On 2026-10-06 a Teams call on
/// AirPods came through the system tap at half the 48 kHz the tap reported, so every second of
/// the other side was half a second of double-speed audio and half a second of padding, and the
/// transcript was garbage. Whether the AirPods dropped to a call rate or the buffers held one
/// channel labeled as two, the cure is the same: resample from the rate that actually arrives.
///
/// Fed every buffer's frame count and its arrival time. Returns a new rate once two windows of
/// three seconds in a row agree on a standard rate more than 15% from the one in use. A window
/// with a pause longer than a quarter second is thrown away, so a stall never reads as a slow rate.
public struct RateWatch {
    public private(set) var rate: Double
    private var start: Double?
    private var last: Double = 0
    private var frames = 0
    private var candidate: Double?

    static let window = 3.0
    static let maxPause = 0.25
    static let rates: [Double] = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000]

    public init(rate: Double) { self.rate = rate }

    public mutating func add(frames n: Int, at t: Double) -> Double? {
        guard let s = start, t - last <= Self.maxPause, t >= last else {
            start = t; last = t; frames = 0
            return nil
        }
        last = t
        frames += n
        guard t - s >= Self.window else { return nil }
        // The frames counted arrived after `s`, the first buffer only opened the window.
        let measured = Double(frames) / (t - s)
        start = t; frames = 0
        guard let snapped = Self.rates.min(by: { abs($0 - measured) < abs($1 - measured) }),
              abs(snapped - measured) / snapped < 0.1 else { candidate = nil; return nil }
        guard abs(snapped - rate) / rate > 0.15 else { candidate = nil; return nil }
        if candidate == snapped {
            candidate = nil
            rate = snapped
            return snapped
        }
        candidate = snapped
        return nil
    }
}
