import Foundation
import UserNotifications

/// Posts the "New From Followed added N tracks" notification and routes a click on it back to
/// the app.
///
/// Kept out of `NewReleaseScanner` so the scanner stays free of UserNotifications and can keep
/// reporting through a plain closure. Permission is only ever requested when the user turns the
/// toggle on — never on launch — so the system prompt appears at the moment they asked for it.
///
/// `UNUserNotificationCenter.current()` requires a real app bundle; this file is deliberately
/// not in the test target.
@MainActor
final class ReleaseNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// Called with the playlist id carried by the notification the user clicked.
    var onOpenPlaylist: ((String) -> Void)?

    /// One identifier, so a new sweep's notification replaces the previous one rather than
    /// stacking up a week of them.
    private static let identifier = "newReleases.added"

    /// Set the delegate. Must run in `applicationWillFinishLaunching`, so a click that launches
    /// the app is delivered to us.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Read the current status without prompting.
    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor in self?.authorization = status }
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted: Bool
        do { granted = try await center.requestAuthorization(options: [.alert, .sound]) }
        catch {
            DebugLog.log("notifications: authorization request failed: \(error.localizedDescription)")
            granted = false
        }
        refreshAuthorizationStatus()
        return granted
    }

    func notify(title: String, body: String, playlistId: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["playlistId": playlistId]
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                DebugLog.log("notifications: couldn't post: \(error.localizedDescription)")
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show it even while the app is frontmost — a menu bar app has no "frontmost" to speak of.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let playlistId = response.notification.request.content.userInfo["playlistId"] as? String
        Task { @MainActor in
            if let playlistId { self.onOpenPlaylist?(playlistId) }
            completionHandler()
        }
    }
}
