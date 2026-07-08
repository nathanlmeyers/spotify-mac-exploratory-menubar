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
    @Published var showTrackTitleInMenuBar: Bool { didSet { d.set(showTrackTitleInMenuBar, forKey: K.showTitle) } }

    // MARK: Discovery
    @Published var discoveryEnabled: Bool { didSet { d.set(discoveryEnabled, forKey: K.discovery) } }
    @Published var alertAutoOpenPanel: Bool { didSet { d.set(alertAutoOpenPanel, forKey: K.alertPanel) } }
    @Published var alertBadgeIcon: Bool { didSet { d.set(alertBadgeIcon, forKey: K.alertBadge) } }
    @Published var alertSound: Bool { didSet { d.set(alertSound, forKey: K.alertSound) } }
    @Published var skipIfInTarget: Bool { didSet { d.set(skipIfInTarget, forKey: K.skipInTarget) } }
    @Published var skipInTargetAlsoRemove: Bool { didSet { d.set(skipInTargetAlsoRemove, forKey: K.skipInTargetRemove) } }
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
        showTrackTitleInMenuBar = bool(K.showTitle, default: false)

        discoveryEnabled = bool(K.discovery, default: false)
        alertAutoOpenPanel = bool(K.alertPanel, default: true)
        alertBadgeIcon = bool(K.alertBadge, default: true)
        alertSound = bool(K.alertSound, default: false)
        skipIfInTarget = bool(K.skipInTarget, default: false)
        skipInTargetAlsoRemove = bool(K.skipInTargetRemove, default: false)
        skipAlreadyReviewed = bool(K.skipReviewed, default: false)
        keepHeldPanelOpen = bool(K.keepHeldOpen, default: true)

        launchAtLogin = bool(K.launchAtLogin, default: true)
    }

    /// Call once at startup to sync the login item to the stored intent.
    func bootstrap() { applyLaunchAtLogin() }

    private func applyLaunchAtLogin() {
        // Best-effort: registration can fail when running from a transient build
        // directory; it succeeds once the app lives in /Applications.
        do {
            let service = SMAppService.mainApp
            if launchAtLogin {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            NSLog("[SpotifyMenuBar] launch-at-login sync failed: \(error.localizedDescription)")
        }
    }

    private enum K {
        static let targetId = "targetPlaylistId"
        static let targetName = "targetPlaylistName"
        static let moveOnAdd = "removeFromSourceOnAdd"
        static let skipAfterRemove = "skipToNextAfterRemove"
        static let skipAfterAdd = "skipToNextAfterAdd"
        static let showTitle = "showTrackTitleInMenuBar"
        static let discovery = "discoveryEnabled"
        static let alertPanel = "alertAutoOpenPanel"
        static let alertBadge = "alertBadgeIcon"
        static let alertSound = "alertSound"
        static let skipInTarget = "skipIfInTarget"
        static let skipInTargetRemove = "skipInTargetAlsoRemove"
        static let skipReviewed = "skipAlreadyReviewed"
        static let keepHeldOpen = "keepHeldPanelOpen"
        static let launchAtLogin = "launchAtLogin"
    }
}
