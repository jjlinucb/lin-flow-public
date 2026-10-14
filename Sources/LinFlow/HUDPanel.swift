import AppKit
import LinFlowCore

/// Floating always-on-top status pill (same idea as Wispr Flow's on-screen
/// HUD): a colored dot + state label, a click-and-hold mic button as a mouse
/// alternative to the hotkey, and an X to hide it. While recording the dot
/// becomes a small level meter. Drag it anywhere; the spot is remembered.
final class HUDPanel: NSPanel {
    private let pill: PillView
    private let mic: MicButtonView
    private let close: CloseButtonView

    private static let height: CGFloat = 34
    private static let gap: CGFloat = 7
    private static let micSize: CGFloat = 29
    private static let closeSize: CGFloat = 22
    private static let bottomMargin: CGFloat = 110

    init(pressBegan: @escaping () -> Void, pressEnded: @escaping () -> Void, hide: @escaping () -> Void, menu: @escaping () -> NSMenu) {
        pill = PillView(frame: .zero, menuProvider: menu)
        mic = MicButtonView(frame: .zero, pressBegan: pressBegan, pressEnded: pressEnded)
        close = CloseButtonView(frame: .zero, action: hide)

        let pillWidth = PillView.width(for: DictationState.transcribing.label)
        let contentWidth = pillWidth + Self.gap + Self.micSize + Self.gap + Self.closeSize
        let rect = NSRect(origin: .zero, size: NSSize(width: contentWidth, height: Self.height))
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let container = NSView(frame: rect)
        container.addSubview(pill)
        container.addSubview(mic)
        container.addSubview(close)
        contentView = container
        layout(pillWidth: pillWidth)
        setFrameOrigin(Self.initialOrigin(for: rect.size))
    }

    private func layout(pillWidth: CGFloat) {
        let h = Self.height
        pill.frame = NSRect(x: 0, y: 0, width: pillWidth, height: h)
        mic.frame = NSRect(x: pillWidth + Self.gap, y: (h - Self.micSize) / 2, width: Self.micSize, height: Self.micSize)
        close.frame = NSRect(x: mic.frame.maxX + Self.gap, y: (h - Self.closeSize) / 2, width: Self.closeSize, height: Self.closeSize)
        let width = close.frame.maxX
        var f = frame
        f.size.width = width
        setFrame(f, display: true)
        contentView?.frame = NSRect(x: 0, y: 0, width: width, height: h)
    }

    /// Saved spot if it's still on some screen, otherwise bottom-center of the main screen.
    private static func initialOrigin(for size: NSSize) -> NSPoint {
        if let saved = Settings.shared.hudOrigin,
           NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -size.width, dy: 0).contains(saved) }) {
            return saved
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: screen.midX - size.width / 2, y: screen.minY + bottomMargin)
    }

    func show() { orderFrontRegardless() }

    func apply(state: DictationState) {
        pill.apply(state: state)
        mic.isActive = state == .recording
        layout(pillWidth: PillView.width(for: state.label))
    }

    func apply(level: Float) { pill.apply(level: level) }

    func rememberPosition() { Settings.shared.hudOrigin = frame.origin }
}

// MARK: - pill

final class PillView: NSView {
    private static let font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
    private static let paddingX: CGFloat = 12
    private static let dotSize: CGFloat = 9
    private static let meterWidth: CGFloat = 22
    private static let textGap: CGFloat = 8

    private var label = DictationState.loading("model").label
    private var color = NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.58, alpha: 1)
    private var recording = false
    private var level: Float = 0
    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var didDrag = false
    private let menuProvider: () -> NSMenu

    init(frame: NSRect, menuProvider: @escaping () -> NSMenu) {
        self.menuProvider = menuProvider
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    static func width(for label: String) -> CGFloat {
        let w = (label as NSString).size(withAttributes: [.font: font]).width
        return paddingX + meterWidth + textGap + ceil(w) + paddingX
    }

    func apply(state: DictationState) {
        label = state.label
        recording = state == .recording
        switch state {
        case .loading, .downloading: color = NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.58, alpha: 1)
        case .idle: color = NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.42, alpha: 1)
        case .recording, .error: color = NSColor(calibratedRed: 0.95, green: 0.23, blue: 0.23, alpha: 1)
        case .transcribing, .rewriting: color = NSColor(calibratedRed: 0.98, green: 0.70, blue: 0.20, alpha: 1)
        }
        if !recording { level = 0 }
        needsDisplay = true
    }

    func apply(level newLevel: Float) {
        // Fast attack, slow decay so the meter reads as speech, not noise.
        level = max(newLevel, level * 0.75)
        if recording { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: b, xRadius: b.height / 2, yRadius: b.height / 2).fill()

        let meterRect = NSRect(x: Self.paddingX, y: 0, width: Self.meterWidth, height: b.height)
        color.setFill()
        if recording {
            // Five bars, center tallest, scaled by level.
            let bars = 5, barW: CGFloat = 3, gap: CGFloat = 1.75
            let total = CGFloat(bars) * barW + CGFloat(bars - 1) * gap
            var x = meterRect.midX - total / 2
            let amp = CGFloat(min(1, level * 6))
            for i in 0..<bars {
                let shape: CGFloat = [0.45, 0.75, 1.0, 0.75, 0.45][i]
                let h = max(3, (4 + 12 * amp) * shape)
                NSBezierPath(roundedRect: NSRect(x: x, y: b.midY - h / 2, width: barW, height: h), xRadius: 1.5, yRadius: 1.5).fill()
                x += barW + gap
            }
        } else {
            let d = Self.dotSize
            NSBezierPath(ovalIn: NSRect(x: meterRect.midX - d / 2, y: b.midY - d / 2, width: d, height: d)).fill()
        }

        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white]
        let size = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: meterRect.maxX + Self.textGap, y: (b.height - size.height) / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStartMouse.x, dy = now.y - dragStartMouse.y
        if abs(dx) > 3 || abs(dy) > 3 { didDrag = true }
        window?.setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag { (window as? HUDPanel)?.rememberPosition(); return }
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }
}

// MARK: - buttons

final class MicButtonView: NSView {
    var isActive = false { didSet { needsDisplay = true } }
    private let pressBegan: () -> Void
    private let pressEnded: () -> Void
    private var tracking = false

    init(frame: NSRect, pressBegan: @escaping () -> Void, pressEnded: @escaping () -> Void) {
        self.pressBegan = pressBegan; self.pressEnded = pressEnded
        super.init(frame: frame)
        toolTip = "Click and hold to dictate"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        (isActive || tracking ? NSColor(calibratedRed: 0.95, green: 0.23, blue: 0.23, alpha: 1) : NSColor(calibratedWhite: 0.30, alpha: 1)).setFill()
        NSBezierPath(ovalIn: b).fill()
        let cx = b.midX, cy = b.midY
        NSColor.white.setFill(); NSColor.white.setStroke()
        let bodyW: CGFloat = 7, bodyH: CGFloat = 12
        NSBezierPath(roundedRect: NSRect(x: cx - bodyW / 2, y: cy - bodyH / 2 + 2, width: bodyW, height: bodyH), xRadius: bodyW / 2, yRadius: bodyW / 2).fill()
        let stand = NSBezierPath()
        stand.lineWidth = 1.6
        stand.move(to: NSPoint(x: cx - 5, y: cy - 1))
        stand.curve(to: NSPoint(x: cx + 5, y: cy - 1), controlPoint1: NSPoint(x: cx - 5, y: cy - 6), controlPoint2: NSPoint(x: cx + 5, y: cy - 6))
        stand.move(to: NSPoint(x: cx, y: cy + bodyH / 2 - 4))
        stand.line(to: NSPoint(x: cx, y: cy - bodyH / 2 - 2))
        stand.stroke()
    }

    override func mouseDown(with event: NSEvent) { tracking = true; needsDisplay = true; pressBegan() }
    override func mouseUp(with event: NSEvent) { tracking = false; needsDisplay = true; pressEnded() }
}

final class CloseButtonView: NSView {
    private let action: () -> Void
    private var hover = false
    init(frame: NSRect, action: @escaping () -> Void) { self.action = action; super.init(frame: frame); toolTip = "Hide the pill" }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        NSColor(calibratedWhite: hover ? 0.38 : 0.24, alpha: 1).setFill()
        NSBezierPath(ovalIn: b).fill()
        let r = b.width * 0.24, cx = b.midX, cy = b.midY
        let x = NSBezierPath(); x.lineWidth = 1.6
        x.move(to: NSPoint(x: cx - r, y: cy - r)); x.line(to: NSPoint(x: cx + r, y: cy + r))
        x.move(to: NSPoint(x: cx - r, y: cy + r)); x.line(to: NSPoint(x: cx + r, y: cy - r))
        NSColor.white.setStroke(); x.stroke()
    }
    override func mouseDown(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) { hover = false; needsDisplay = true; action() }
}
