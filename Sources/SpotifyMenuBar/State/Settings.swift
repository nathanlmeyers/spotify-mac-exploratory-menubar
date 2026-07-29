import Foundation
import ServiceManagement

/// User preferences, persisted in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    private let d = UserDefaults.standard

    // MARK: Curation
    @Published var targetPlaylistId: String? { didSet { d.set(targetPlaylistId, forKey: K.targetId) } }
    @Published var targetPlaylistName: String? { didSet { d.set(targetPlaylistName, forKey: K.targetName) } }
    @Published var removeFromSourceOnAdd: Bool { didSet { d.set(removeFromSourceOnAdd, forKey: K.moveOnAdd) } }
    @Published var skipToNextAfterRemove: Bool { didSet { d.set(skipToNextAfterRemove, forKey: K.skipAfterRemove) } }
    @Published var skipToNextAfterAdd: Bool { didSet { d.set(skipToNextAfterAdd, forKey: K.skipAfterAdd) } }

    // MARK: Menu bar
    @Published var menuBarTitleMode: MenuBarTitleMode {
        didSet { d.set(menuBarTitleMode.rawValue, forKey: K.titleMode) }
    }
    /// Max width of the menu bar text, in points. See `MenuBarTitle` for why not characters.
    @Published var menuBarTitleMaxWidth: Double {
        didSet { d.set(menuBarTitleMaxWidth, forKey: K.titleMaxWidth) }
    }

    // MARK: Discovery
    @Published var discoveryEnabled: Bool { didSet { d.set(discoveryEnabled, forKey: K.discovery) } }
    @Published var alertAutoOpenPanel: Bool { didSet { d.set(alertAutoOpenPanel, forKey: K.alertPanel) } }
    @Published var alertBadgeIcon: Bool { didSet { d.set(alertBadgeIcon, forKey: K.alertBadge) } }
    @Published var alertSound: Bool { didSet { d.set(alertSound, forKey: K.alertSound) } }
    @Published var skipIfInTarget: Bool { didSet { d.set(skipIfInTarget, forKey: K.skipInTarget) } }
    @Published var skipAlreadyReviewed: Bool { didSet { d.set(skipAlreadyReviewed, forKey: K.skipReviewed) } }
    @Published var keepHeldPanelOpen: Bool { didSet { d.set(keepHeldPanelOpen, forKey: K.keepHeldOpen) } }

    // MARK: System
    @Published var launchAtLogin: Bool {
        didSet { d.set(launchAtLogin, forKey: K.launchAtLogin); applyLaunchAtLogin() }
    }

    init() {
        // Local reader so every toggle's default is visible in one column below.
        let defaults = d
        func bool(_ key: String, default def: Bool) -> Bool {
            (defaults.object(forKey: key) as? Bool) ?? def
        }

        targetPlaylistId = defaults.string(forKey: K.targetId)
        targetPlaylistName = defaults.string(forKey: K.targetName)
        removeFromSourceOnAdd = bool(K.moveOnAdd, default: false)
        skipToNextAfterRemove = bool(K.skipAfterRemove, default: true)
        skipToNextAfterAdd = bool(K.skipAfterAdd, default: false)
        // Menu bar text. `showTrackTitleInMenuBar` (a plain on/off) is migrated to the
        // three-way mode: "on" becomes `.whenHeld` rather than `.always`, because an
        // always-on title is what grew wide enough for macOS to hide the status item —
        // the held moment is the only one where the text has to be readable at a glance.
        if let stored = defaults.string(forKey: K.titleMode),
           let mode = MenuBarTitleMode(rawValue: stored) {
            menuBarTitleMode = mode
        } else {
            let migrated: MenuBarTitleMode = bool(K.retiredShowTitle, default: false) ? .whenHeld : .never
            menuBarTitleMode = migrated
            // `didSet` doesn't fire during init, so persist the migrated value by hand —
            // otherwise the retired key is cleared below and the choice is lost next launch.
            defaults.set(migrated.rawValue, forKey: K.titleMode)
        }
        let storedWidth = defaults.double(forKey: K.titleMaxWidth)
        menuBarTitleMaxWidth = storedWidth > 0 ? storedWidth : MenuBarTitle.defaultWidth

        discoveryEnabled = bool(K.discovery, default: false)
        alertAutoOpenPanel = bool(K.alertPanel, default: true)
        alertBadgeIcon = bool(K.alertBadge, default: true)
        alertSound = bool(K.alertSound, default: false)
        skipIfInTarget = bool(K.skipInTarget, default: false)
        skipAlreadyReviewed = bool(K.skipReviewed, default: false)
        keepHeldPanelOpen = bool(K.keepHeldOpen, default: true)

        launchAtLogin = bool(K.launchAtLogin, default: true)

        // Retired: auto-skip used to delete from the source playlist under this flag.
        // Clear the stored value so an older build sharing this domain can't read a
        // leftover `true` and resume deleting songs nobody asked it to delete.
        d.removeObject(forKey: K.retiredSkipInTargetRemove)
        // Migrated above into `menuBarTitleMode`; drop it so the migration runs once.
        d.removeObject(forKey: K.retiredShowTitle)
    }

    /// Call once at startup to sync the login item to the stored intent.
    func bootstrap() { applyLaunchAtLogin() }

    private func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        let bundlePath = BuildInfo.bundlePath

        do {
            guard launchAtLogin else {
                if service.status == .enabled { try service.unregister() }
                d.removeObject(forKey: K.registeredBundlePath)
                return
            }

            // A DerivedData bundle must never become a login item. macOS records the login
            // item by absolute path, so registering one pins that exact throwaway build —
            // which is how a June 2 debug build kept relaunching for two months, long after
            // every fix had shipped, and deleted 15 songs using logic nobody was running.
            // Install to /Applications for launch-at-login.
            if BuildInfo.isTransientBuild {
                // Unregister unconditionally rather than gating on `status`: status describes
                // THIS bundle path, so a login item pinned to a *different, older* bundle of
                // the same app reads as not-registered while still being armed to relaunch
                // that stale build at every login. Unregistering by bundle identifier clears
                // it. Throws when nothing is registered, which is the expected common case.
                do { try service.unregister() } catch { /* nothing was registered */ }
                d.removeObject(forKey: K.registeredBundlePath)
                DebugLog.log("launch-at-login: refusing to register a DerivedData build (\(bundlePath)); cleared any stale login item. Move the app to /Applications to launch at login.")
                return
            }

            // Re-register when the bundle moved. `status == .enabled` only says *something*
            // is registered, not that it's us, so a plain status check silently leaves an
            // older bundle path in place forever.
            let registered = d.string(forKey: K.registeredBundlePath)
            if service.status == .enabled, registered == bundlePath { return }
            if service.status == .enabled {
                DebugLog.log("launch-at-login: re-pointing from \(registered ?? "unknown") to \(bundlePath)")
                try service.unregister()
            }
            try service.register()
            d.set(bundlePath, forKey: K.registeredBundlePath)
            DebugLog.log("launch-at-login: registered \(bundlePath)")
        } catch {
            DebugLog.log("launch-at-login sync failed: \(error.localizedDescription)")
        }
    }

    private enum K {
        static let targetId = "targetPlaylistId"
        static let targetName = "targetPlaylistName"
        static let moveOnAdd = "removeFromSourceOnAdd"
        static let skipAfterRemove = "skipToNextAfterRemove"
        static let skipAfterAdd = "skipToNextAfterAdd"
        static let titleMode = "menuBarTitleMode"
        static let titleMaxWidth = "menuBarTitleMaxWidth"
        /// Retired on/off title flag, migrated into `titleMode`. Never read after init.
        static let retiredShowTitle = "showTrackTitleInMenuBar"
        static let discovery = "discoveryEnabled"
        static let alertPanel = "alertAutoOpenPanel"
        static let alertBadge = "alertBadgeIcon"
        static let alertSound = "alertSound"
        static let skipInTarget = "skipIfInTarget"
        static let skipReviewed = "skipAlreadyReviewed"
        /// Retired auto-delete flag; kept only so init() can clear it. Never read.
        static let retiredSkipInTargetRemove = "skipInTargetAlsoRemove"
        static let keepHeldOpen = "keepHeldPanelOpen"
        static let launchAtLogin = "launchAtLogin"
        /// Bundle path of the login item we registered, so we can spot a moved build.
        static let registeredBundlePath = "registeredLoginItemBundlePath"
    }
}
