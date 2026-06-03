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
    @Published var reviewState: ReviewState = .inactive

    private var discovery: DiscoveryEngine!
    private var pollTimer: Timer?
    private var lastURI: String?
    private var lastSourceId: String?
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

        discovery = DiscoveryEngine(
            provider: provider,
            settings: settings,
            history: history,
            targetMembership: { [weak self] in self?.targetMembership ?? [] },
            canAddNow: { [weak self] in self?.canAdd ?? false },
            canRemoveNow: { [weak self] in self?.canRemoveFromSource ?? false },
            sourceName: { [weak self] in self?.source.playlistName },
            targetName: { [weak self] in self?.settings.targetPlaylistName }
        )
        discovery.onStateChange = { [weak self] state in self?.handleReviewState(state) }
        // Toggling discovery off clears the per-URI/loop guards.
        settings.$discoveryEnabled.dropFirst().sink { [weak self] _ in self?.discovery.reset() }.store(in: &cancellables)
    }

    private func handleReviewState(_ state: ReviewState) {
        reviewState = state
        if state == .nothingNew { setStatus("Nothing new to review") }
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
        discovery.onTick(np: np, source: source)
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
        // A genuine source-playlist change starts a fresh discovery sweep.
        if let id = source.playlistId, id != lastSourceId {
            lastSourceId = id
            discovery.reset()
        }
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
        lastSourceId = nil
        discovery.reset()
    }

    // MARK: Curation

    func setTarget(_ playlist: Playlist) {
        settings.targetPlaylistId = playlist.id
        settings.targetPlaylistName = playlist.name
        DebugLog.log("target set: \"\(playlist.name)\" id=\(playlist.id) owner=\(playlist.ownerId) collab=\(playlist.collaborative)")
        Task { await loadTargetMembership(force: true) }
    }

    func addCurrentToTarget() {
        guard let np = nowPlaying else { return }
        let sourceCtx = source
        Task { await performAdd(uri: np.uri, sourceCtx: sourceCtx) }
    }

    func removeCurrentFromSource() {
        guard let np = nowPlaying, source.isEditablePlaylist, source.playlistId != nil else { return }
        let sourceCtx = source
        Task { await performRemoveFromSource(uri: np.uri, sourceCtx: sourceCtx) }
    }

    // MARK: Discovery held actions

    func heldAdd() {
        guard case .held(let held) = reviewState else { return }
        let uri = held.snapshot.uri
        let sourceCtx = source
        discovery.finishHold(judgedURI: uri, sourceId: sourceCtx.playlistId)   // advance immediately
        Task { await performAdd(uri: uri, sourceCtx: sourceCtx) }
    }

    func heldRemove() {
        guard case .held(let held) = reviewState else { return }
        let uri = held.snapshot.uri
        let sourceCtx = source
        discovery.finishHold(judgedURI: uri, sourceId: sourceCtx.playlistId)
        Task { await performRemoveFromSource(uri: uri, sourceCtx: sourceCtx) }
    }

    func heldSkip() {
        guard case .held(let held) = reviewState else { return }
        discovery.finishHold(judgedURI: held.snapshot.uri, sourceId: source.playlistId)
    }

    // MARK: Curation core (URI-explicit; shared by buttons + held actions)

    private func performAdd(uri: String, sourceCtx: SourceContext) async {
        guard let target = settings.targetPlaylistId else { return }
        let targetName = settings.targetPlaylistName ?? "target"
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
            if settings.removeFromSourceOnAdd, sourceCtx.isEditablePlaylist, let src = sourceCtx.playlistId {
                try await provider.removeTrack(uri: uri, fromPlaylist: src)
                setStatus("Moved to \(targetName)")
            }
        } catch {
            setStatus("Add failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func performRemoveFromSource(uri: String, sourceCtx: SourceContext) async {
        guard sourceCtx.isEditablePlaylist, let src = sourceCtx.playlistId else { return }
        let name = sourceCtx.playlistName ?? "playlist"
        isBusy = true
        defer { isBusy = false }
        do {
            try await provider.removeTrack(uri: uri, fromPlaylist: src)
            setStatus("Removed from \(name)")
        } catch {
            setStatus("Remove failed: \(error.localizedDescription)", isError: true)
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

    func setStatus(_ message: String, isError: Bool = false) {
        statusMessage = message
        statusClear?.cancel()
        // Errors stay on screen (until the next action) so they can actually be read;
        // success/info messages auto-clear.
        guard !isError else { return }
        let work = DispatchWorkItem { [weak self] in self?.statusMessage = nil }
        statusClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
