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
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    // One borderless panel serves both the manual click and the discovery hold; it hugs
    // the menu bar (no arrow/gap like NSPopover) and renders standard vs held from reviewState.
    private lazy var holdPanel = HoldPanelController(model: model)
    // True only while the panel was opened by a discovery hold (not a manual click), so leaving
    // .held closes the auto-opened panel but never a panel the user opened themselves.
    private var presentedByHold = false

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
            button.image = Self.makeMenuBarIcon()
            button.imagePosition = .imageLeading
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings), name: .openSettings, object: nil
        )

        // Keep the menu bar title in sync with playback + the user's preference.
        model.$nowPlaying.sink { [weak self] _ in self?.updateButtonTitle() }.store(in: &cancellables)
        // Refresh when the full (featured) artist list arrives a beat after the track changes.
        model.$displayArtists.sink { [weak self] _ in self?.updateButtonTitle() }.store(in: &cancellables)
        model.settings.$showTrackTitleInMenuBar.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateButtonTitle() }
        }.store(in: &cancellables)

        // Discovery hold → fire the configured alerts (panel / badge / sound).
        model.$reviewState
            .map { state -> Bool in
                if case .held = state { return true }
                return false
            }
            .removeDuplicates()
            .sink { [weak self] isHeld in
                if isHeld { self?.presentHold() } else { self?.dismissHold() }
            }
            .store(in: &cancellables)

        model.start()
    }

    // MARK: Status item

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggleMainPanel()
        }
    }

    private func toggleMainPanel() {
        if holdPanel.isVisible {
            holdPanel.dismiss()
        } else {
            presentedByHold = false   // user-opened: don't let a later non-held transition close it
            holdPanel.present(below: statusItem)
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
        statusItem.menu = nil   // restore left-click panel behavior
    }

    /// Total character budget for the menu-bar text (excluding the leading space + icon).
    private static let menuBarBudget = 45

    private func updateButtonTitle() {
        guard let button = statusItem?.button else { return }
        guard model.settings.showTrackTitleInMenuBar, let np = model.nowPlaying, !np.name.isEmpty else {
            button.title = ""
            return
        }
        button.title = " " + Self.menuBarText(title: np.name, artists: model.artistText(for: np))
    }

    /// "Artist — Title" within `menuBarBudget`. The title is preserved; the artist list is
    /// trimmed (with an ellipsis) to whatever room is left. Falls back to a truncated
    /// title alone when even that doesn't fit.
    static func menuBarText(title: String, artists: String) -> String {
        let sep = " — "
        let artists = artists.trimmingCharacters(in: .whitespaces)
        guard !artists.isEmpty else {
            return title.count > menuBarBudget ? String(title.prefix(menuBarBudget - 1)) + "…" : title
        }
        // No room for the title + separator + at least one artist char → title only.
        let roomForArtists = menuBarBudget - title.count - sep.count
        guard roomForArtists >= 1 else {
            return title.count > menuBarBudget ? String(title.prefix(menuBarBudget - 1)) + "…" : title
        }
        let shownArtists = artists.count > roomForArtists
            ? String(artists.prefix(max(1, roomForArtists - 1))) + "…"
            : artists
        return shownArtists + sep + title
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

    // MARK: Discovery hold alerts (combinable: panel / badge / sound)

    private func presentHold() {
        let s = model.settings
        guard s.discoveryEnabled else { return }
        if s.alertSound { NSSound(named: NSSound.Name("Tink"))?.play() }
        if s.alertBadgeIcon { shadeIcon(held: true) }
        if s.alertAutoOpenPanel { presentedByHold = true; holdPanel.present(below: statusItem) }
    }

    private func dismissHold() {
        shadeIcon(held: false)
        // Only close the panel if discovery opened it; leave a user-opened panel in place.
        if presentedByHold { holdPanel.dismiss(); presentedByHold = false }
    }

    // MARK: Menu bar icon

    /// Discovery-themed icon: magnifying glass + music note as a single template image.
    /// `emphasized` draws it heavier for the "decision needed" (held) state.
    static func makeMenuBarIcon(emphasized: Bool = false) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: emphasized ? .bold : .regular)
        let glass = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Spotify Menu Bar")?
            .withSymbolConfiguration(config) ?? NSImage()
        let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        let spacing: CGFloat = 1
        let height = max(glass.size.height, note.size.height)
        let width = glass.size.width + spacing + note.size.width
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        glass.draw(at: NSPoint(x: 0, y: (height - glass.size.height) / 2),
                   from: .zero, operation: .sourceOver, fraction: 1)
        note.draw(at: NSPoint(x: glass.size.width + spacing, y: (height - note.size.height) / 2),
                  from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// Shade the icon solid/high-contrast while a song is held; revert when resolved.
    private func shadeIcon(held: Bool) {
        guard let button = statusItem?.button else { return }
        button.image = Self.makeMenuBarIcon(emphasized: held)
        button.contentTintColor = held ? .labelColor : nil
    }

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
