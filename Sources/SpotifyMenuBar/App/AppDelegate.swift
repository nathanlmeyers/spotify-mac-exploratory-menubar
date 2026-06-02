import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    static let openSettings = Notification.Name("SpotifyMenuBar.openSettings")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Receive the spotifymenubar://callback URL (PKCE redirect).
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(Self.fourCharCode("GURL")),
            andEventID: AEEventID(Self.fourCharCode("GURL"))
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "Spotify Menu Bar")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: NowPlayingView().environmentObject(model)
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings), name: .openSettings, object: nil
        )

        // Keep the menu bar title in sync with playback + the user's preference.
        model.$nowPlaying.sink { [weak self] _ in self?.updateButtonTitle() }.store(in: &cancellables)
        model.settings.$showTrackTitleInMenuBar.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateButtonTitle() }
        }.store(in: &cancellables)

        model.start()
    }

    // MARK: Status item

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task {
                await model.refreshSource()
                if model.isAuthorized && model.editablePlaylists.isEmpty { await model.loadPlaylists() }
            }
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Spotify Menu Bar", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // restore left-click popover behavior
    }

    private func updateButtonTitle() {
        guard let button = statusItem?.button else { return }
        if model.settings.showTrackTitleInMenuBar, let np = model.nowPlaying, !np.name.isEmpty {
            let title = np.name.count > 28 ? String(np.name.prefix(27)) + "…" : np.name
            button.title = " \(title)"
        } else {
            button.title = ""
        }
    }

    // MARK: Settings

    @objc private func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(settings: model.settings).environmentObject(model))
            let window = NSWindow(contentViewController: host)
            window.title = "Spotify Menu Bar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: URL callback

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        let keyword = AEKeyword(Self.fourCharCode("----"))
        guard let string = event.paramDescriptor(forKeyword: keyword)?.stringValue,
              let url = URL(string: string) else { return }
        handleIncoming(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(handleIncoming)
    }

    private func handleIncoming(_ url: URL) {
        Task {
            await model.auth.handleCallback(url)
            if model.isAuthorized { await model.refreshAfterLogin() }
        }
    }

    private static func fourCharCode(_ string: String) -> FourCharCode {
        var result: FourCharCode = 0
        for unit in string.utf16 { result = (result << 8) + FourCharCode(unit) }
        return result
    }
}
