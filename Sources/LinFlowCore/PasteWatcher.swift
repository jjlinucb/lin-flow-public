import AppKit
import ApplicationServices

/// Reads back the field Lin Flow just pasted into, so a fix you type by hand can become a
/// dictionary correction the way Wispr Flow does it. Uses the Accessibility grant the hotkey
/// already needs, and reads only the one focused element, never the screen.
///
/// Coverage is what it is: native apps report their focused text element, and Chromium apps
/// (Chrome, Electron) expose nothing until asked, so we ask the way a screen reader does (see
/// `primeAccessibility`). When an app reports nothing, nothing is learned and no harm done.
///
/// Everything here runs on its own queue. It used to run on the main thread, where one read of
/// a busy app could block for the Accessibility API's default six seconds, and every key press
/// passed through the main thread on its way to the recorder.
public final class PasteWatcher {
    public static let shared = PasteWatcher()
    private init() {}
    private let queue = DispatchQueue(label: "linflow.readback", qos: .utility)

    /// How long to keep watching after a paste, and how often to look. The window is long
    /// because noticing a wrong word takes far longer than fixing one; the interval is short
    /// because the fix should reach the dictionary while you are still looking at the field.
    public var watchWindow: TimeInterval = 15
    public var pollInterval: TimeInterval = 0.8
    /// Every moment after the anchor attempts, one poll apart, plus two past the window so
    /// an edit made at the very end still gets the two looks it needs to settle.
    public var checkDelays: [TimeInterval] {
        guard pollInterval > 0 else { return [] }
        let start = (anchorDelays.last ?? 0) + pollInterval
        // Counted rather than accumulated: adding 0.8 repeatedly drifts and drops the last look.
        let steps = max(0, Int(((watchWindow - start) / pollInterval).rounded()) + 2)
        return (0...steps).map { start + Double($0) * pollInterval }
    }
    /// Early looks that only try to find the field, before any edit could have happened.
    /// Chromium needs several of these: its tree is not there the instant it is asked for.
    var anchorDelays: [TimeInterval] = [0.6, 1.5, 3]
    /// Every field still being watched, oldest first. More than one at a time on purpose:
    /// two dictations into the same box inside the window is John's normal rhythm, and
    /// canceling the first on the second keypress threw away its chance to be corrected.
    private var live: [Anchor] = []
    /// Past this many at once the oldest is retired, so a burst cannot pile timers up.
    private let maxLive = 3
    /// One phrase Lin Flow pasted, and the order it went out in.
    public struct Paste: Equatable {
        public let seq: Int
        public let text: String
        public init(seq: Int, text: String) { self.seq = seq; self.text = text }
    }
    /// The recent ones, newest last. An older watch reads this to tell John editing its
    /// field from Lin Flow pasting into that same field again.
    private var pastes: [Paste] = []
    private var pasteSeq = 0

    /// Remember the focused field of the app `pid` pasted into and check back later.
    /// `onEdit(wrote, now)` fires on the main thread with the phrase as pasted and as it stands
    /// afterwards, and returns whether it made something of it. Returning false leaves the field
    /// under watch for the rest of the window, so a later, better edit still gets its turn.
    public func watch(pasted: String, in pid: pid_t, onEdit: @escaping (String, String) -> Bool) {
        let wrote = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrote.isEmpty else { return }
        queue.async { self.begin(wrote, pid, onEdit) }
    }

    private func begin(_ wrote: String, _ pid: pid_t, _ onEdit: @escaping (String, String) -> Bool) {
        guard AXIsProcessTrusted() else { Log.info("readback: not trusted for Accessibility"); return }
        // Chromium and Electron build their accessibility tree only once something asks for
        // it, and they build it *asynchronously*. Asking and then reading in the same breath
        // always came back empty, so every paste into Chrome taught nothing -- and taught it
        // silently. Ask first, then look again on each checkpoint until the tree shows up.
        Self.primeAccessibility(pid)
        pasteSeq += 1
        let mine = pasteSeq
        pastes.append(Paste(seq: mine, text: wrote))
        while pastes.count > 8 { pastes.removeFirst() }
        let anchor = Anchor()
        anchor.timeoutsAtStart = Self.timeouts
        live.append(anchor)
        while live.count > maxLive { live.removeFirst().done = true }
        let delays = anchorDelays + checkDelays
        // The only thing this ever hands back to the main thread, synchronously because the
        // answer decides whether the watch goes on.
        let report: (String, String) -> Bool = { wrote, now in DispatchQueue.main.sync { onEdit(wrote, now) } }
        for delay in delays {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let last = delay == delays.last
                defer {
                    if last {
                        self.retire(anchor)
                        let slow = Self.timeouts - anchor.timeoutsAtStart
                        if slow > 0 { Log.info("readback: \(slow) Accessibility read(s) got no answer within \(Self.messagingTimeout)s") }
                    }
                }
                guard !anchor.done else { return }
                guard let element = anchor.element ?? Self.focusedTextElement(pid) else {
                    if last { Log.info("readback: no focused element in this app; nothing can be learned from an edit here") }
                    return
                }
                guard let now = Self.value(of: element) else { return }
                // Lin Flow pasted into this field again. From here an older watch cannot tell
                // John's typing from the new dictation's text, and reading one ASR output as
                // an edit of another learns rules from nothing he did: re-dictating over a
                // selection turned "Let's meet Thursday." into "Let's meet Tuesday." and that
                // is one word apart, so it would have auto-written Thursday => Tuesday -- the
                // exact destructive rule this whole file exists to prevent. Stand down.
                if Self.superseded(by: self.pastes, mine: mine, fieldNow: now) {
                    if anchor.element != nil { Log.info("readback: a newer dictation landed in this field; standing down") }
                    self.retire(anchor)
                    return
                }
                // Only ever compare against the field that actually received the paste.
                if anchor.element == nil {
                    if now.contains(wrote) { anchor.element = element; Log.info("readback: watching the field (\(Int(delay * 1000))ms)") }
                    else if last { Log.info("readback: never found the pasted text in a field; nothing can be learned from this one") }
                    return
                }
                guard !now.contains(wrote), let edited = Self.editedVersion(of: wrote, in: now) else {
                    // The field stopped looking like the dictation while an edit was still
                    // waiting to settle. That is exactly what hitting send looks like: on
                    // 2026-09-14 John fixed "Siena" to "Verona" and pressed Enter inside the
                    // 1.6s the settle gate needs, the composer emptied, and the correction was
                    // dropped. Two polls protect against a half-typed word; they must not cost
                    // the fix of anyone who types quickly. Take the candidate rather than lose it.
                    if !now.contains(wrote), let candidate = anchor.pending,
                       !anchor.reported.contains(candidate) {
                        anchor.pending = nil; anchor.stable = 0
                        anchor.reported.insert(candidate)
                        Log.info("readback: the field was cleared mid-edit; taking \"\(wrote)\" as \"\(candidate)\"")
                        if report(wrote, candidate) { self.retire(anchor) }
                        return
                    }
                    anchor.pending = nil; anchor.stable = 0   // back to the phrase as pasted
                    // Say why nothing came of this, once, at the end of the window. Until this
                    // line existed the log recorded only successes, so a readback that watched
                    // the field and then quietly decided nothing looked exactly like a readback
                    // that never ran -- 15 of 16 in the two days after the toast shipped.
                    if last {
                        Log.info(now.contains(wrote)
                            ? "readback: field unchanged after \(Int(self.watchWindow))s, nothing to learn"
                            : "readback: field changed but it is not recognizably an edit of the dictation")
                    }
                    return
                }
                // Handed over once already; wait for John to type something different.
                guard !anchor.reported.contains(edited) else { return }
                // A fix takes several keystrokes and a pause mid-word is ordinary. One look
                // 0.8s apart was not enough: on 2026-09-14 it caught "earl" on the way to
                // "early", offered that, and -- worse -- stopped watching. Two in a row now.
                if anchor.pending != edited { anchor.pending = edited; anchor.stable = 1; return }
                anchor.stable += 1
                guard anchor.stable >= 2 else { return }
                anchor.reported.insert(edited)
                Log.info("readback: edit seen, \"\(wrote)\" is now \"\(edited)\"")
                // Only an edit that taught something ends the watch. Before this, the first
                // edit of any kind did: three of seven readbacks on 2026-09-14 spent their
                // window on a half-typed word or a sentence John was still adding to, and the
                // correction that followed a second later was never looked at.
                if report(wrote, edited) { self.retire(anchor) }
            }
        }
    }

    /// Whether a dictation later than `mine` is now sitting in this field. Pure so `selftest`
    /// can check it: the live one reads an Accessibility tree and a timer.
    public static func superseded(by pastes: [Paste], mine: Int, fieldNow: String) -> Bool {
        pastes.contains { $0.seq > mine && fieldNow.contains($0.text) }
    }

    /// Stop watching one field. Idempotent: the end of the window and a successful edit both
    /// call it, and either may come first.
    private func retire(_ anchor: Anchor) {
        anchor.done = true
        live.removeAll { $0 === anchor }
    }

    /// Switches a Chromium or Electron app's accessibility tree on the way a screen reader does.
    ///
    /// AXManualAccessibility is Electron's documented switch, and every other app ignores it.
    /// AXEnhancedUserInterface, which this used to set on every app pasted into and never
    /// cleared, is the flag VoiceOver sets: AppKit changes how the app's windows behave while
    /// it is on, which is known to make window moves and animations misbehave. Chrome is the
    /// one app that still gets it. Checked 2026-09-22 against a fresh Chrome: it refuses
    /// AXManualAccessibility (kAXErrorAttributeUnsupported), and its NSApplication subclass
    /// (chrome_browser_application_mac.mm) handles only AXEnhancedUserInterface.
    public static func primeAccessibility(_ pid: pid_t) {
        _ = timeoutSet
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if isChromiumBrowser(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// Chrome and the browsers built on it, which take their accessibility switch from Chrome.
    public static func isChromiumBrowser(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return ["com.google.chrome", "org.chromium.chromium", "com.microsoft.edgemac", "com.brave.browser",
                "company.thebrowser.browser", "com.vivaldi.vivaldi", "com.operasoftware.opera"]
            .contains { id == $0 || id.hasPrefix($0 + ".") }
    }

    /// How long one Accessibility read may take before it gives up. The default is six seconds,
    /// and a busy app can use all of it. Set for the whole process: it covers every element.
    public static let messagingTimeout: Float = 0.5
    private static let timeoutSet: Void = { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout) }()
    /// Reads that hit `messagingTimeout`, for the log. Touched only on the watcher's queue.
    private static var timeouts = 0

    /// A box so every checkpoint shares the one field we decided to watch.
    private final class Anchor {
        var element: AXUIElement?
        var pending: String?        // an edit seen, waiting to prove it has settled
        var stable = 0              // how many looks in a row have read it the same
        var reported = Set<String>()// edits already handed over, so none is offered twice
        var done = false
        var timeoutsAtStart = 0
    }

    // MARK: reading the field

    /// The focused element, system-wide first and then inside `pid`, the app pasted into.
    public static func focusedTextElement(_ pid: pid_t) -> AXUIElement? {
        _ = timeoutSet
        let system = AXUIElementCreateSystemWide()
        if let e = copy(system, kAXFocusedUIElementAttribute) { return usable(e) }
        // Chromium and Electron keep their tree switched off until something asks for it.
        primeAccessibility(pid)
        let app = AXUIElementCreateApplication(pid)
        return (copy(app, kAXFocusedUIElementAttribute) ?? copy(system, kAXFocusedUIElementAttribute)).flatMap(usable)
    }

    /// Anything but a password field. A secure field is never read back, whatever is in it.
    static func usable(_ element: AXUIElement) -> AXUIElement? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &v)
        if let subrole = v as? String, subrole == "AXSecureTextField" { return nil }
        return element
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &v)
        if err == .cannotComplete { timeouts += 1 }
        guard err == .success else { return nil }
        guard let result = v, CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    /// The field's text, if it has any and it is a sane size to work with.
    public static func value(of element: AXUIElement) -> String? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &v)
        if err == .cannotComplete { timeouts += 1 }
        guard err == .success, let s = v as? String, s.count <= 200_000 else { return nil }
        return s
    }

    // MARK: finding the phrase again

    /// The pasted phrase as it now reads, or nil when it is gone or untouched.
    public static func editedVersion(of wrote: String, in now: String) -> String? {
        let current = now.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, !current.contains(wrote) else { return nil }
        let wroteWords = wrote.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard !wroteWords.isEmpty else { return nil }
        // A field holding little more than the dictation: compare the whole thing -- but only
        // while it still reads like that dictation. Sending a message empties the field and the
        // app drops its own placeholder in ("Type / for commands"), and a wholesale retype is
        // not a correction either. Same budget the long-document path below uses.
        if current.count <= max(200, wrote.count * 3) {
            let currentWords = current.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
            if wordDistance(wroteWords, currentWords) <= max(1, wroteWords.count / 2) { return current }
            // A short dictation has almost no word budget: "Merissa Wong." is two words, so the
            // budget is one, and fixing a first and last name at once blows it. That is the
            // whole point of dictating a name to test it, and on 2026-09-14 it was refused here.
            // Characters still separate a fix from a placeholder where words cannot -- "marissa
            // wong." to "marisa vuong" is 4 edits over 12 characters, while "you can merge it in
            // now." to "type / for commands" is 18 over 19.
            guard wrote.count <= 2_000, current.count <= 2_000 else { return nil }
            let charDistance = GlossaryMatcher.levenshtein(wrote.lowercased(), current.lowercased())
            // Three quarters, measured rather than guessed. Across John's real cases the fixes
            // sit at 0.04 to 0.62 of the shorter string and everything that must be refused --
            // composer placeholders, an unrelated field, a wholesale retype -- sits at 1.00 to
            // 1.93. Half was the first guess and it cut through the middle of the fixes.
            return charDistance * 4 <= min(wrote.count, current.count) * 3 ? current : nil
        }
        // A longer document: find the phrase by its own words, then take a window around it.
        let words = current.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard words.count <= 20_000 else { return nil }
        let width = wroteWords.count
        var best: (score: Int, range: Range<Int>)? = nil
        for anchor in anchors(wroteWords) {
            guard let offset = wroteWords.firstIndex(of: anchor) else { continue }
            for (i, w) in words.enumerated() where w == anchor {
                let start = max(0, i - offset)
                for slack in [0, -2, -1, 1, 2] {
                    let end = min(words.count, start + max(1, width + slack))
                    guard start < end else { continue }
                    let score = wordDistance(wroteWords, Array(words[start..<end]))
                    if best == nil || score < best!.score { best = (score, start..<end) }
                }
            }
        }
        // Too different to be the same phrase edited.
        guard let found = best, found.score <= max(1, width / 2) else { return nil }
        return words[found.range].joined(separator: " ")
    }

    /// The most distinctive words of the phrase, longest first: those are the ones most
    /// likely to survive an edit and least likely to appear elsewhere in the document.
    static func anchors(_ words: [String]) -> [String] {
        Array(Set(words)).sorted { ($0.count, $0) > ($1.count, $1) }.prefix(3).map { $0 }
    }

    /// Levenshtein over words rather than characters.
    public static func wordDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
