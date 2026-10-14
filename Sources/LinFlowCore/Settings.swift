import CoreGraphics
import Foundation

public enum CleanupLevel: String, CaseIterable {
    case none, light, medium

    public var label: String {
        switch self {
        case .none: return "None"
        case .light: return "Light"
        case .medium: return "Medium"
        }
    }
}

/// What happens when you fix text Lin Flow pasted, or edit a dictation in the window.
public enum LearnMode: String, CaseIterable {
    case auto, ask, off

    public var label: String {
        switch self {
        case .auto: return "Add it automatically"
        case .ask: return "Suggest it first"
        case .off: return "Do nothing"
        }
    }
}

/// UserDefaults-backed settings, one computed property per knob so call
/// sites read like plain properties. The suite name is fixed so the CLI and
/// the .app share values, unless LINFLOW_DEFAULTS_SUITE says otherwise.
public final class Settings {
    public static let shared = Settings()
    /// Posted (on main) by whoever changes a setting from a place the app
    /// delegate can't see directly, e.g. the Settings tab in the window.
    public static let didChange = Notification.Name("LinFlow.Settings.didChange")
    private let d: UserDefaults

    /// Inside the .app the standard defaults already live in com.johnlin.linflow;
    /// the bare CLI binary has no bundle id, so it opens that same domain by name.
    /// Either way both read and write one plist.
    public init(defaults: UserDefaults? = nil) {
        if let defaults { d = defaults }
        else if let suite = Settings.testSuite, let other = UserDefaults(suiteName: suite) { d = other }
        else if Bundle.main.bundleIdentifier == Settings.domain { d = .standard }
        else { d = UserDefaults(suiteName: Settings.domain) ?? .standard }
    }
    public static let domain = "com.johnlin.linflow"

    /// LINFLOW_DEFAULTS_SUITE sends every setting to another defaults domain, so a test copy of
    /// the app or the CLI cannot write to the live one. On 2026-09-09 a test hotkey written to
    /// com.johnlin.linflow took over John's dictation. The live domain's own name is ignored.
    public static var testSuite: String? {
        guard let suite = ProcessInfo.processInfo.environment["LINFLOW_DEFAULTS_SUITE"], !suite.isEmpty, suite != domain else { return nil }
        return suite
    }

    public var modelID: String {
        get { d.string(forKey: "modelID") ?? ModelCatalog.defaultModelID }
        set { d.set(newValue, forKey: "modelID") }
    }
    public var hotkey: Hotkey {
        get { Hotkey(rawValue: d.string(forKey: "hotkey") ?? "") ?? .fn }
        set { d.set(newValue.rawValue, forKey: "hotkey") }
    }
    /// "en", "auto", or any whisper language code.
    public var language: String {
        get { d.string(forKey: "language") ?? "en" }
        set { d.set(newValue, forKey: "language") }
    }
    public var beamSize: Int {
        get { d.object(forKey: "beamSize") as? Int ?? 5 }
        set { d.set(newValue, forKey: "beamSize") }
    }
    public var temperatureFallback: Bool {
        get { d.object(forKey: "temperatureFallback") as? Bool ?? false }
        set { d.set(newValue, forKey: "temperatureFallback") }
    }
    public var useVAD: Bool {
        get { d.object(forKey: "useVAD") as? Bool ?? true }
        set { d.set(newValue, forKey: "useVAD") }
    }
    /// None: the engine's text as-is. Light: the rule-based pass (fillers, dictionary,
    /// punctuation). Medium: Light plus the on-device model's "Clarity" rewrite everywhere
    /// no per-app transform says otherwise.
    public var cleanupLevel: CleanupLevel {
        get {
            if let raw = d.string(forKey: "cleanupLevel"), let level = CleanupLevel(rawValue: raw) { return level }
            return (d.object(forKey: "cleanup") as? Bool ?? true) ? .light : .none
        }
        set {
            d.set(newValue.rawValue, forKey: "cleanupLevel")
            d.set(newValue != .none, forKey: "cleanup")
        }
    }
    /// Whether an edit you make to pasted text becomes a dictionary correction.
    public var learnCorrections: LearnMode {
        get { LearnMode(rawValue: d.string(forKey: "learnCorrections") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "learnCorrections") }
    }
    /// Bundle id -> transform id for dictations into that app, or `Transforms.none` to
    /// turn transforms off there even at the Medium level.
    public var appTransforms: [String: String] {
        get { d.dictionary(forKey: "appTransforms") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "appTransforms") }
    }
    /// The transform a dictation into `bundleID` gets, if any.
    public func transformID(forApp bundleID: String?) -> String? {
        Settings.resolveTransform(app: bundleID, table: appTransforms, level: cleanupLevel)
    }
    public static func resolveTransform(app: String?, table: [String: String], level: CleanupLevel) -> String? {
        if let app, let t = table[app] { return t == Transforms.none ? nil : t }
        return level == .medium ? Transforms.clarityID : nil
    }
    /// Write spoken numbers as digits: "twenty two" -> 22.
    public var numbersAsDigits: Bool {
        get { d.object(forKey: "numbersAsDigits") as? Bool ?? true }
        set { d.set(newValue, forKey: "numbersAsDigits") }
    }
    public var spokenCommands: Bool {
        get { d.object(forKey: "spokenCommands") as? Bool ?? true }
        set { d.set(newValue, forKey: "spokenCommands") }
    }
    public var sounds: Bool {
        get { d.object(forKey: "sounds") as? Bool ?? true }
        set { d.set(newValue, forKey: "sounds") }
    }
    public var showHUD: Bool {
        get { d.object(forKey: "showHUD") as? Bool ?? true }
        set { d.set(newValue, forKey: "showHUD") }
    }
    /// Regular app with a Dock icon (and the running dot), like Wispr Flow.
    /// Off turns it into a menu-bar-only accessory.
    public var showInDock: Bool {
        get { d.object(forKey: "showInDock") as? Bool ?? true }
        set { d.set(newValue, forKey: "showInDock") }
    }
    /// Append a space after each dictation so the next one doesn't run on.
    public var trailingSpace: Bool {
        get { d.object(forKey: "trailingSpace") as? Bool ?? true }
        set { d.set(newValue, forKey: "trailingSpace") }
    }
    /// Days to keep each dictation's audio for playback. 0 = don't keep audio.
    public var audioRetentionDays: Int {
        get { d.object(forKey: "audioRetentionDays") as? Int ?? 30 }
        set { d.set(newValue, forKey: "audioRetentionDays") }
    }
    public var keepMeetingAudio: Bool {
        get { d.object(forKey: "keepMeetingAudio") as? Bool ?? true }
        set { d.set(newValue, forKey: "keepMeetingAudio") }
    }
    /// A few bullets a minute while a meeting records, written by Apple Intelligence (see RunningNotes).
    public var runningNotes: Bool {
        get { d.object(forKey: "runningNotes") as? Bool ?? true }
        set { d.set(newValue, forKey: "runningNotes") }
    }
    /// After a meeting, transcribe the saved audio end to end and replace the live transcript.
    public var transcribeAfterMeeting: Bool {
        get { d.object(forKey: "transcribeAfterMeeting") as? Bool ?? true }
        set { d.set(newValue, forKey: "transcribeAfterMeeting") }
    }
    /// Offer a meeting note when a call app has held the microphone a few seconds (CallOffer).
    public var offerToRecordCalls: Bool {
        get { d.object(forKey: "offerToRecordCalls") as? Bool ?? true }
        set { d.set(newValue, forKey: "offerToRecordCalls") }
    }
    public var meetingUsesMicrophone: Bool {
        get { d.object(forKey: "meetingUsesMicrophone") as? Bool ?? true }
        set { d.set(newValue, forKey: "meetingUsesMicrophone") }
    }
    public var meetingUsesSystemAudio: Bool {
        get { d.object(forKey: "meetingUsesSystemAudio") as? Bool ?? true }
        set { d.set(newValue, forKey: "meetingUsesSystemAudio") }
    }
    /// Show the main window when the app is launched by hand.
    public var openWindowAtLaunch: Bool {
        get { d.object(forKey: "openWindowAtLaunch") as? Bool ?? true }
        set { d.set(newValue, forKey: "openWindowAtLaunch") }
    }
    public var hudOrigin: CGPoint? {
        get {
            guard let x = d.object(forKey: "hudX") as? Double, let y = d.object(forKey: "hudY") as? Double else { return nil }
            return CGPoint(x: x, y: y)
        }
        set {
            if let p = newValue { d.set(Double(p.x), forKey: "hudX"); d.set(Double(p.y), forKey: "hudY") }
            else { d.removeObject(forKey: "hudX"); d.removeObject(forKey: "hudY") }
        }
    }

    /// Decoder options assembled from the current settings.
    public func transcriptionOptions(glossary: [String]) -> TranscriptionOptions {
        var o = TranscriptionOptions()
        o.language = language
        o.beamSize = Int32(max(1, min(8, beamSize)))
        o.temperatureFallback = temperatureFallback
        o.vadModelPath = useVAD ? ModelCatalog.vadModelURL?.path : nil
        o.initialPrompt = Glossary.initialPrompt(glossary)
        return o
    }
}
