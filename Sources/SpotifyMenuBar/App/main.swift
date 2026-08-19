import AppKit

// Menu-bar-only app: no Dock icon (also enforced by LSUIElement in Info.plist).
// Top-level main.swift runs on the main thread; assert main-actor isolation so we
// can construct the main-actor-isolated AppDelegate/AppModel.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    BuildInfo.logStartupBanner()

    // Settle who owns the menu bar before building anything. It has to happen here rather than
    // in `applicationDidFinishLaunching`, because `AppDelegate` constructs `AppModel` — which
    // opens the Keychain, reads the shared JSON state, and starts polling Spotify — in its own
    // initializer. A copy that is about to stand down must do none of that; four copies polling
    // in lockstep is what exhausted the API quota.
    if case .standDown = InstanceGuard.enforce() {
        DebugLog.flush()   // the log write is async; don't exit out from under it
        exit(0)
    }

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
