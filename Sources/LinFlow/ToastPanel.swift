import AppKit
import LinFlowCore

/// The two lines a learning outcome turns into. Kept apart from the panel so `selftest`
/// can check the wording without a window server.
enum LearnToast {
    static func lines(for outcome: CorrectionLearning.Outcome) -> (title: String, detail: String)? {
        let added = !outcome.added.isEmpty
        let list = added ? outcome.added : outcome.suggested
        guard let first = list.first else { return nil }
        let total = outcome.added.count + outcome.suggested.count
        let more = total > 1 ? "  +\(total - 1) more" : ""
        return (
            "\(added ? "Learned" : "Suggested"): “\(first.from)” → “\(first.to)”\(more)",
            added ? "Used from now on. Click to change it in the Dictionary."
                  : "Not applied yet. Click to confirm it in the Dictionary."
        )
    }
}

extension LearnToast {
    /// An edit Lin Flow saw and refused. Saying nothing here is what made the dictionary feel
    /// broken: John fixes a word, the filters decide it is too far from a mishearing to bind
    /// globally, and nothing on screen distinguishes that from the readback never running.
    /// Offered rather than applied, because one click from him is a better signal than any
    /// edit-distance rule.
    static func declined(from: String, to: String) -> (title: String, detail: String) {
        ("Add “\(from)” → “\(to)”?",
         "Not sure enough to add it alone. Click to add.")
    }
}

/// A short-lived pill that says what Lin Flow just learned from an edit.
///
/// Dictation almost always lands in some other app with the Lin Flow window shut, so the
/// banner inside that window is feedback John never sees: before this, a rule learned from a
/// real dictation existed only as a line in the log, which is why the dictionary felt broken
/// while it was quietly working. This floats above everything for a few seconds, says what
/// changed, and goes away by itself. It never takes focus -- he is usually still typing.
final class ToastPanel: NSPanel {
    private let body = ToastView(frame: .zero)
    private var dismissal: DispatchWorkItem?

    /// What a click does, set per message: opening the Dictionary for a rule that was learned,
    /// or adding the rule for one that was not.
    private var action: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 48),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = body
        body.onClick = { [weak self] in
            guard let self else { return }
            let act = self.action
            self.hide()
            act?()
        }
    }

    /// Just above the floating pill, or near the bottom of the main screen when it is hidden.
    func show(title: String, detail: String, above anchor: NSRect?, for seconds: TimeInterval = 6,
              warning: Bool = false, onClick: (() -> Void)? = nil) {
        action = onClick
        body.set(title: title, detail: detail, warning: warning)
        let size = body.measure()
        setContentSize(size)
        body.frame = NSRect(origin: .zero, size: size)
        setFrameOrigin(Self.origin(for: size, above: anchor))
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.14; animator().alphaValue = 1 }
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.orderOut(nil) })
    }

    static func origin(for size: NSSize, above anchor: NSRect?) -> NSPoint {
        let screen = anchor.flatMap { a in NSScreen.screens.first(where: { $0.frame.intersects(a) }) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        return origin(for: size, above: anchor, in: screen)
    }

    /// The placement rule by itself, so `selftest` can check it with no window server.
    ///
    /// John keeps the pill at the very top of his screen -- hudY 952 against a 949pt visible
    /// frame -- and a toast 8pt above that landed past the top edge every single time. It was
    /// posted, it was logged, and he never saw one. For weeks that read as "the dictionary
    /// does not work", because from where he sat the two are identical. x was clamped to the
    /// screen from the start; y never was.
    ///
    /// Above the pill when there is room, below it when there is not, inside the screen either way.
    static func origin(for size: NSSize, above anchor: NSRect?, in screen: NSRect?) -> NSPoint {
        let gap: CGFloat = 8, edge: CGFloat = 8
        guard let a = anchor, a.width > 0 else {
            let s = screen ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return NSPoint(x: s.midX - size.width / 2, y: s.minY + 150)
        }
        var x = a.midX - size.width / 2
        var y = a.maxY + gap
        if let s = screen {
            x = min(max(s.minX + edge, x), max(s.minX + edge, s.maxX - size.width - edge))
            if y + size.height > s.maxY - edge { y = a.minY - gap - size.height }
            y = min(max(s.minY + edge, y), max(s.minY + edge, s.maxY - size.height - edge))
        }
        return NSPoint(x: x, y: y)
    }
}

/// Internal rather than private so `LinFlow toast-shot` can render the real thing offscreen.
/// Checking the toast used to mean asking John to look at his own screen, which is how a
/// clipped last word shipped once already.
final class ToastView: NSView {
    var onClick: (() -> Void)?
    private var title = "", detail = ""

    // Read at a glance, from the corner of the eye, while typing something else. 12.5pt
    // was small enough that John had to stop and look at it, which is the one thing a
    // toast must not ask for.
    private static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private static let detailFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private static let padX: CGFloat = 18, padY: CGFloat = 14
    private static let dot: CGFloat = 9, gap: CGFloat = 11, lineGap: CGFloat = 5
    // Wider than before so the larger type does not simply wrap onto more lines.
    private static let maxTextWidth: CGFloat = 420

    override var isFlipped: Bool { true }

    /// `warning` turns the dot red, for something that went wrong rather than something learned.
    func set(title: String, detail: String, warning: Bool = false) {
        self.title = title; self.detail = detail; self.warning = warning
        needsDisplay = true
    }
    private var warning = false

    private func size(of s: String, _ font: NSFont) -> NSSize {
        let r = (s as NSString).boundingRect(with: NSSize(width: Self.maxTextWidth, height: 400),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading],
                                             attributes: [.font: font])
        return NSSize(width: ceil(r.width) + 2, height: ceil(r.height))
    }

    func measure() -> NSSize {
        let t = size(of: title, Self.titleFont), d = size(of: detail, Self.detailFont)
        return NSSize(width: ceil(max(t.width, d.width) + Self.padX * 2 + Self.dot + Self.gap),
                      height: ceil(t.height + Self.lineGap + d.height + Self.padY * 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        NSColor(calibratedWhite: 0.08, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: b, xRadius: 16, yRadius: 16).fill()

        let t = size(of: title, Self.titleFont), d = size(of: detail, Self.detailFont)
        let x = Self.padX + Self.dot + Self.gap
        let w = max(10, b.width - x - Self.padX)

        (warning ? NSColor(calibratedRed: 0.95, green: 0.23, blue: 0.23, alpha: 1)
                 : NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.42, alpha: 1)).setFill()
        NSBezierPath(ovalIn: NSRect(x: Self.padX, y: Self.padY + (t.height - Self.dot) / 2, width: Self.dot, height: Self.dot)).fill()

        (title as NSString).draw(in: NSRect(x: x, y: Self.padY, width: w, height: t.height),
                                 withAttributes: [.font: Self.titleFont, .foregroundColor: NSColor.white])
        (detail as NSString).draw(in: NSRect(x: x, y: Self.padY + t.height + Self.lineGap, width: w, height: d.height),
                                  withAttributes: [.font: Self.detailFont,
                                                   .foregroundColor: NSColor(calibratedWhite: 0.80, alpha: 1)])
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
}
