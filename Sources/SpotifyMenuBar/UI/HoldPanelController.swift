import AppKit
import SwiftUI

/// A borderless, NON-ACTIVATING floating panel that drops down under the status item
/// to present the discovery "judge" UI without stealing keyboard focus from the user's
/// current app. (The regular NSPopover is still used for deliberate icon clicks.)
@MainActor
final class HoldPanelController {
    private let model: AppModel
    private var panel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(model: AppModel) { self.model = model }

    var isVisible: Bool { panel?.isVisible ?? false }

    func present(below statusItem: NSStatusItem) {
        let panel = ensurePanel()
        position(panel, below: statusItem)
        panel.orderFrontRegardless()        // show WITHOUT activating the app
        installOutsideClickMonitor()
    }

    func dismiss() {
        panel?.orderOut(nil)
        removeOutsideClickMonitor()
    }

    // MARK: Panel construction

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 360),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.worksWhenModal = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hasShadow = true
        p.isMovableByWindowBackground = false
        p.backgroundColor = .clear
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.animationBehavior = .utilityWindow

        let host = NSHostingView(rootView: NowPlayingView(mode: .hold).environmentObject(model))
        p.contentView = host
        panel = p
        return p
    }

    private func position(_ panel: NSPanel, below statusItem: NSStatusItem) {
        if let host = panel.contentView {
            host.layoutSubtreeIfNeeded()
            let fitting = host.fittingSize
            if fitting.width > 0, fitting.height > 0 { panel.setContentSize(fitting) }
        }
        guard let button = statusItem.button, let itemWindow = button.window else { return }
        let buttonInWindow = button.convert(button.bounds, to: nil)
        let onScreen = itemWindow.convertToScreen(buttonInWindow)
        let size = panel.frame.size
        let gap: CGFloat = 4
        var x = onScreen.midX - size.width / 2
        let y = onScreen.minY - gap - size.height
        if let visible = (itemWindow.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Outside-click dismissal (the panel won't auto-close like a .transient popover)

    /// While a track is held for review and the user opted to keep it open, outside
    /// clicks don't dismiss — only the in-panel Add/Remove/Next buttons resolve it.
    /// (The menu-bar icon still toggles the panel, as a manual escape hatch.)
    private func shouldStayOpen() -> Bool {
        if case .held = model.reviewState { return model.settings.keepHeldPanelOpen }
        return false
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let panel = self.panel, event.window != panel, !self.shouldStayOpen() { self.dismiss() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.shouldStayOpen() else { return }
            self.dismiss()
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }
}
