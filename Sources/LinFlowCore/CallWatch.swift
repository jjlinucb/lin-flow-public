import CoreAudio
import Foundation

/// Knowing when a call is over, so a note does not record for an hour after it. John, 10-07: "I
/// often forget and then the recording goes on for like 1 hr." Every call app holds the
/// microphone for the whole call, muted or not, and lets go when it ends. On 10-07 Chrome
/// released its call at 10:26:58 and the note was still recording at 10:34. So the list of apps
/// using the microphone is the signal, the same rule as Lin Flow Next's `meeting::detect`.
/// A meeting with no call app, one in a room, is caught by both sides going quiet instead.
///
/// No clock and no OS calls here: the window feeds what it sees every few seconds.
public struct CallWatch {
    public enum Event: Equatable {
        /// Every call app seen during this recording has been off the microphone `endedAfter`.
        case callEnded(name: String)
        /// A call app took the microphone again after `callEnded`.
        case callBack
        /// Nobody on either side has spoken for `longSilence`.
        case longSilence(minutes: Int)
        /// Someone spoke again after `longSilence`.
        case speechBack
    }

    /// Call apps by bundle id, with the name John sees. A helper process counts as its app:
    /// Chrome's audio runs in `com.google.Chrome.helper`.
    static let callApps: [(String, String)] = [
        ("us.zoom.xos", "Zoom"), ("com.microsoft.teams2", "Teams"), ("com.microsoft.teams", "Teams"),
        ("com.cisco.webexmeetingsapp", "Webex"), ("com.apple.facetime", "FaceTime"), ("com.apple.avconferenced", "FaceTime"),
        ("com.tinyspeck.slackmacgap", "Slack"), ("com.hnc.discord", "Discord"), ("com.google.chrome", "Chrome"),
        ("com.microsoft.edgemac", "Edge"), ("com.apple.safari", "Safari"), ("com.apple.webkit.gpu", "Safari"),
        ("org.mozilla.firefox", "Firefox"), ("company.thebrowser.browser", "Arc"), ("com.brave.browser", "Brave"),
    ]

    public static func callAppName(_ id: String) -> String? {
        let id = id.lowercased()
        return callApps.first { id == $0.0 || id.hasPrefix($0.0 + ".") }?.1
    }

    public let endedAfter: Double
    public let longSilence: Double
    /// When each call app seen during this recording was last on the microphone.
    private var seen: [String: Double] = [:]
    private var endedSent = false
    private var silenceSent = false

    public init(endedAfter: Double = 6, longSilence: Double = 300) {
        self.endedAfter = endedAfter
        self.longSilence = longSilence
    }

    /// `quietFor`: seconds since either side last had a line in the transcript.
    public mutating func observe(at t: Double, micUsers: [String], quietFor: Double) -> [Event] {
        var events: [Event] = []
        var onMic = false
        for user in micUsers {
            guard let name = Self.callAppName(user) else { continue }
            seen[name] = t
            onMic = true
        }
        if onMic {
            if endedSent { endedSent = false; events.append(.callBack) }
        } else if !endedSent, let (name, last) = seen.max(by: { $0.value < $1.value }), t - last >= endedAfter {
            endedSent = true
            events.append(.callEnded(name: name))
        }
        // While a call app holds the mic, silence is a waiting room or a pause, never the end.
        if quietFor >= longSilence, !onMic {
            if !silenceSent { silenceSent = true; events.append(.longSilence(minutes: Int(quietFor / 60))) }
        } else if silenceSent {
            silenceSent = false
            events.append(.speechBack)
        }
        return events
    }
}

/// Knowing when a call starts, so John is offered a note before it gets going. John, 10-02: the
/// first Zoom note worked, but nothing offered to record when the call began. The signal is the
/// one `CallWatch` reads for the end: a call app holding the microphone `offerAfter` is a call,
/// not a sound check. One offer per run of an app on the mic, never a nag, and none for a call
/// that is being recorded. The same rule as Lin Flow Next's `meeting::detect`.
///
/// No clock and no OS calls here: the model feeds what it sees every few seconds.
public struct CallOffer {
    public let offerAfter: Double
    /// An app off the mic this long has ended its run. A shorter gap is a device switch, such
    /// as AirPods connecting, and the same call is not offered twice.
    public let goneAfter: Double
    /// When each call app's current run on the mic began, and when it was last seen there.
    private var since: [String: Double] = [:]
    private var lastSeen: [String: Double] = [:]
    private var offered: Set<String> = []

    public init(offerAfter: Double = 8, goneAfter: Double = 15) {
        self.offerAfter = offerAfter
        self.goneAfter = goneAfter
    }

    /// The name of the call app to offer a note for, if one is due now.
    public mutating func observe(at t: Double, micUsers: [String], recording: Bool) -> String? {
        let names = Set(micUsers.compactMap(CallWatch.callAppName))
        for name in names {
            lastSeen[name] = t
            if since[name] == nil { since[name] = t }
        }
        for (name, last) in lastSeen where t - last >= goneAfter {
            lastSeen[name] = nil; since[name] = nil; offered.remove(name)
        }
        // A call recorded now is not offered again once the note stops.
        if recording { offered.formUnion(since.keys); return nil }
        // Each app is offered once per run, the longest-running first, so a browser tab does
        // not win over Zoom. A browser that joins a call John let go by gets its own offer:
        // a needless toast costs less than a call nobody offered to record.
        let due = since.filter { !offered.contains($0.key) && names.contains($0.key) && t - $0.value >= offerAfter }
        guard let name = due.min(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key else { return nil }
        offered.insert(name)
        return name
    }
}

extension CallWatch {
    /// Bundle ids of the processes using a microphone now, this one left out: Core Audio's
    /// process objects, macOS 14.2 and later. Calls into the HAL, so never from the main thread.
    public static func micUsers() -> [String] {
        func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        let me = getpid()
        return ids.compactMap { process in
            var running: UInt32 = 0
            guard get(process, kAudioProcessPropertyIsRunningInput, &running), running != 0 else { return nil }
            var pid: pid_t = 0
            if get(process, kAudioProcessPropertyPID, &pid), pid == me { return nil }
            var bundle: Unmanaged<CFString>?
            guard get(process, kAudioProcessPropertyBundleID, &bundle), let id = bundle?.takeRetainedValue() as String?, !id.isEmpty else { return "pid:\(pid)" }
            return id
        }
    }
}
