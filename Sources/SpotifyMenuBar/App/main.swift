import AppKit

// Menu-bar-only app: no Dock icon (also enforced by LSUIElement in Info.plist).
// Top-level main.swift runs on the main thread; assert main-actor isolation so we
// can construct the main-actor-isolated AppDelegate/AppModel.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
