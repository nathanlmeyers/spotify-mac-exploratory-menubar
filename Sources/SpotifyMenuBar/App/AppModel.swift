import Foundation
import Combine

/// Central observable state + intents for the UI. Owns the provider, auth, settings,
/// and a 1s poll of local playback.
@MainActor
final class AppModel: ObservableObject {
    let auth: SpotifyAuth
    let settings: Settings
    let provider: SpotifyProvider

    private let local = LocalSpotifyController()
    private let api: SpotifyWebAPI
    private let history = ReviewHistory()

    @Published var nowPlaying: NowPlaying?
    @Published var source: SourceContext = .none
    @Published var editablePlaylists: [Playlist] = []
    @Published var statusMessage: String?
    @Published var isBusy = false

    private var pollTimer: Timer?
    private var lastURI: String?
    private var targetMembership: Set<String> = []
    private var statusClear: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init() {
        let auth = SpotifyAuth()
        self.auth = auth
        self.settings = Settings()
        self.api = SpotifyWebAPI(auth: auth)
        self.provider = SpotifyProvider(local: local, api: api)

        // Re-publish nested ObservableObject changes so SwiftUI views refresh.
        auth.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    var isAuthorized: Bool { auth.isAuthorized }
    var hasClientID: Bool { auth.hasClientID }
    var isSpotifyRunning: Bool { provider.isAppRunning }

    // MARK: Lifecycle

    func start() {
        settings.bootstrap()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
        if isAuthorized { Task { await refreshAfterLogin() } }
    }

    private func tick() {
        let np = provider.nowPlaying()
        nowPlaying = np
        if np?.uri != lastURI {
            lastURI = np?.uri
            if isAuthorized, np != nil {
                Task { await refreshSource() }
            } else {
                source = .none
            }
        }
    }

    func refreshAfterLogin() async {
        await loadPlaylists()
        await refreshSource()
        await loadTargetMembership(force: true)
    }

    func loadPlaylists() async {
        guard isAuthorized else { return }
        do { editablePlaylists = try await provider.editablePlaylists() }
        catch { setStatus("Couldn't load playlists: \(error.localizedDescription)") }
    }

    func refreshSource() async {
        guard isAuthorized else { source = .none; return }
        do { source = (try await provider.currentSource()) ?? .none }
        catch { source = .none }
    }

    private func loadTargetMembership(force: Bool) async {
        guard let target = settings.targetPlaylistId else { targetMembership = []; return }
        if !force, let cached = history.cachedMembership(targetId: target) {
            targetMembership = cached
            return
        }
        do {
            let uris = try await api.playlistTrackURIs(id: target)
            targetMembership = uris
            history.setMembership(targetId: target, uris: uris)
        } catch {
            if let cached = history.cachedMembership(targetId: target) { targetMembership = cached }
        }
    }

    // MARK: Capabilities (drive enabled/disabled UI + tooltips)

    /// Target is set and (if playlists are loaded) still present & editable.
    var targetIsValid: Bool {
        guard let id = settings.targetPlaylistId else { return false }
        if editablePlaylists.isEmpty { return true } // not loaded yet — don't pre-disable
        return editablePlaylists.contains { $0.id == id }
    }

    var canAdd: Bool {
        guard isAuthorized, let np = nowPlaying, np.kind.isCuratable else { return false }
        return targetIsValid && !isBusy
    }

    var canRemoveFromSource: Bool {
        guard isAuthorized, let np = nowPlaying, np.kind.isCuratable else { return false }
        return source.isEditablePlaylist && source.playlistId != nil && !isBusy
    }

    var addDisabledReason: String? {
        if !isAuthorized { return "Log in to add songs." }
        guard let np = nowPlaying else { return "Nothing playing." }
        if !np.kind.isCuratable { return reasonForNonTrack(np.kind, verb: "add") }
        if settings.targetPlaylistId == nil { return "Set a target playlist in Settings." }
        if !targetIsValid { return "Your target playlist is no longer available — pick another in Settings." }
        return nil
    }

    var removeDisabledReason: String? {
        if !isAuthorized { return "Log in to remove songs." }
        guard let np = nowPlaying else { return "Nothing playing." }
        if !np.kind.isCuratable { return reasonForNonTrack(np.kind, verb: "remove") }
        if source.playlistId == nil { return "Not playing from a playlist — nothing to remove from." }
        if !source.isEditablePlaylist { return "You can't edit “\(source.playlistName ?? "this playlist")”." }
        return nil
    }

    private func reasonForNonTrack(_ kind: TrackKind, verb: String) -> String {
        switch kind {
        case .ad: return "An ad is playing."
        case .episode: return "Podcasts can't be curated."
        case .localFile: return "Local files can't be \(verb)ed via Spotify."
        default: return "This item can't be \(verb)ed."
        }
    }

    // MARK: Transport

    func togglePlayPause() { provider.playPause(); refreshSoon() }
    func next() { provider.next(); refreshSoon() }
    func previous() { provider.previous(); refreshSoon() }
    func toggleShuffle() { provider.setShuffle(!(nowPlaying?.isShuffling ?? false)); refreshSoon() }
    func seek(to seconds: Double) { provider.seek(to: seconds); refreshSoon() }
    func openSpotify() { provider.activateApp() }

    // MARK: Auth

    func login() { auth.beginLogin() }
    func logout() {
        auth.logout()
        editablePlaylists = []
        source = .none
        targetMembership = []
    }

    // MARK: Curation

    func setTarget(_ playlist: Playlist) {
        settings.targetPlaylistId = playlist.id
        settings.targetPlaylistName = playlist.name
        Task { await loadTargetMembership(force: true) }
    }

    func addCurrentToTarget() {
        guard let np = nowPlaying, let target = settings.targetPlaylistId else { return }
        let uri = np.uri
        let targetName = settings.targetPlaylistName ?? "target"
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                if targetMembership.contains(uri) {
                    setStatus("Already in \(targetName)")
                } else {
                    try await provider.addTrack(uri: uri, toPlaylist: target)
                    targetMembership.insert(uri)
                    history.addToMembership(targetId: target, uri: uri)
                    setStatus("Added to \(targetName)")
                }
                // Move semantics: also remove from source when enabled & editable.
                if settings.removeFromSourceOnAdd, source.isEditablePlaylist, let src = source.playlistId {
                    try await provider.removeTrack(uri: uri, fromPlaylist: src)
                    setStatus("Moved to \(targetName)")
                }
            } catch {
                setStatus("Add failed: \(error.localizedDescription)")
            }
        }
    }

    func removeCurrentFromSource() {
        guard let np = nowPlaying, source.isEditablePlaylist, let src = source.playlistId else { return }
        let uri = np.uri
        let name = source.playlistName ?? "playlist"
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await provider.removeTrack(uri: uri, fromPlaylist: src)
                setStatus("Removed from \(name)")
            } catch {
                setStatus("Remove failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Helpers

    /// Spotify needs a beat to apply transport changes; re-read shortly after.
    private func refreshSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            tick()
        }
    }

    func setStatus(_ message: String) {
        statusMessage = message
        statusClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.statusMessage = nil }
        statusClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
