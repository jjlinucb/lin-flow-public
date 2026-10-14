import AppKit
import LinFlowCore
import SwiftUI

/// The main window. Closing it hides it; Lin Flow keeps running in the Dock
/// and menu bar, and the Dock icon or the menu brings it back.
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    private let model: DashboardModel

    init(model: DashboardModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Lin Flow"
        window.minSize = NSSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DashboardView(model: model))
        if !window.setFrameUsingName("LinFlowDashboard") { window.center() }
        window.setFrameAutosaveName("LinFlowDashboard")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Reads the other computers' totals again while the window is open, so a dictation made on
    /// another computer shows up here without closing and reopening it. Five minutes keeps a
    /// window left open all day to about a hundred small reads.
    private var pullTimer: Timer?

    func show(section: DashboardModel.Section? = nil) {
        if let section { model.section = section }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        TotalsSync.shared.requestPull()
        if pullTimer == nil {
            pullTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                guard let window = self?.window, window.isVisible, !window.isMiniaturized else { return }
                TotalsSync.shared.requestPull()
            }
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
