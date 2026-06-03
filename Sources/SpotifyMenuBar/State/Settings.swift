import Foundation
import ServiceManagement

/// User preferences, persisted in UserDefaults. Discovery-mode fields are stored
/// now and consumed by the discovery engine (Phase 2).
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

    // MARK: Discovery (Phase 2)
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
        targetPlaylistId = d.string(forKey: K.targetId)
        targetPlaylistName = d.string(forKey: K.targetName)
        removeFromSourceOnAdd = d.bool(forKey: K.moveOnAdd)
        skipToNextAfterRemove = (d.object(forKey: K.skipAfterRemove) as? Bool) ?? true   // default ON
        skipToNextAfterAdd = d.bool(forKey: K.skipAfterAdd)                              // default OFF
        showTrackTitleInMenuBar = d.bool(forKey: K.showTitle)

        discoveryEnabled = d.bool(forKey: K.discovery)
        alertAutoOpenPanel = (d.object(forKey: K.alertPanel) as? Bool) ?? true   // default ON
        alertBadgeIcon = (d.object(forKey: K.alertBadge) as? Bool) ?? true       // default ON (shade icon)
        alertSound = d.bool(forKey: K.alertSound)
        skipIfInTarget = d.bool(forKey: K.skipInTarget)
        skipInTargetAlsoRemove = d.bool(forKey: K.skipInTargetRemove)
        skipAlreadyReviewed = d.bool(forKey: K.skipReviewed)
        keepHeldPanelOpen = (d.object(forKey: K.keepHeldOpen) as? Bool) ?? true          // default ON

        launchAtLogin = (d.object(forKey: K.launchAtLogin) as? Bool) ?? true      // default ON (intent)
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
