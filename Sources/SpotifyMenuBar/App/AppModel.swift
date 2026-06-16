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
    @Published var displayArtists: [String] = []   // full artist list from the Web API (incl. features)

    private var displayArtistsURI: String?
    private var discovery: DiscoveryEngine!
    private var pollTimer: Timer?
    private var lastURI: String?
    private var lastSourceId: String?
    // Whether Spotify's active Connect device is this Mac. nil = unknown (not yet confirmed).
    // Discovery treats anything but a confirmed `true` as "do not issue transport", so it never
    // pauses/skips a phone, speaker, or other computer — including at cold start (still nil) and
    // right after a hand-off (flips to false on the next poll). Only ever set from a known reading.
    private var activeDeviceIsLocal: Bool?
    // Wall-clock time of the last confirmed device reading. Used to age out a stale flag:
    // discovery must only act on a *recently* confirmed reading, so a value left over from
    // before sleep (or from a run of failed reads) can never authorize transport. Wall clock
    // (not systemUptime) is deliberate — it advances across sleep, so a post-wake reading
    // is automatically "old."
    private var lastDeviceConfirmedAt: Date?
    // A device reading older than this is treated as unknown (nil), never as actionable local.
    private let deviceFlagMaxAge: TimeInterval = 3.0
    private var deviceRefreshCounter = 0
    private let deviceRefreshEverySeconds = 1
    // Wall-clock time of the previous tick, to detect a long gap (sleep/stall) and force device re-validation.
    private var lastTickAt: Date?
    // Monotonic generation so a slow device read can't clobber a newer one (out-of-order writes).
    private var deviceGen = 0
    private var appliedDeviceGen = -1
    private var deviceRefreshInFlight = false
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
            targetName: { [weak self] in self?.settings.targetPlaylistName },
            activeDeviceIsLocal: { [weak self] in self?.confirmedLocalFlag() }
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
        // Confirm the active device on the very first tick so discovery doesn't wait ~2s to learn
        // playback is local (and can't pause a phone before the first reading lands).
        deviceRefreshCounter = deviceRefreshEverySeconds
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
        if isAuthorized { Task { await refreshAfterLogin() } }
    }

    private func tick() {
        // A long gap since the previous tick means the timer didn't fire on schedule — almost
        // always sleep (lid closed), but also App Nap / a stall. The pre-gap device reading is
        // now untrustworthy: distrust it immediately and force a refresh this tick so discovery
        // can't act (skip/pause/grab the session) on a stale flag before the truth lands.
        let now = Date()
        if let last = lastTickAt, now.timeIntervalSince(last) > 3.0 {
            activeDeviceIsLocal = nil
            deviceRefreshCounter = deviceRefreshEverySeconds
        }
        lastTickAt = now

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
        // The active device can change without the track changing (a mid-song Spotify Connect
        // hand-off). Refresh the device flag on a short cadence while discovery is armed and
        // something is playing, so we stop pausing promptly when playback leaves this Mac.
        if isAuthorized, settings.discoveryEnabled, np != nil {
            deviceRefreshCounter += 1
            if deviceRefreshCounter >= deviceRefreshEverySeconds {
                deviceRefreshCounter = 0
                Task { await refreshActiveDevice() }
            }
        } else {
            deviceRefreshCounter = 0
        }
        discovery.onTick(np: np, source: source)
    }

    /// Cheap, throttled refresh of just the active-device flag (one `/me/player` call).
    /// Catches mid-song Connect transfers that don't change the track URI. Single-flighted so
    /// overlapping ticks don't pile up calls.
    private func refreshActiveDevice() async {
        guard isAuthorized, !deviceRefreshInFlight else { return }
        deviceRefreshInFlight = true
        defer { deviceRefreshInFlight = false }
        deviceGen += 1; let gen = deviceGen
        do { applyDeviceResult(try await provider.activeDeviceIsLocal(), gen: gen) }
        catch { /* transient error: keep the last-known value rather than flip to a wrong state */ }
    }

    /// Apply a device reading. Ordered by `gen` so a slower read (e.g. refreshSource's, which has
    /// extra round-trips) can't resurrect a stale value over a newer one. nil (no active device /
    /// 204 / unknown) keeps the last known value rather than clobbering it.
    private func applyDeviceResult(_ local: Bool?, gen: Int) {
        guard gen > appliedDeviceGen else { return }
        appliedDeviceGen = gen
        if let local { activeDeviceIsLocal = local; lastDeviceConfirmedAt = Date() }
    }

    /// The device flag as discovery should see it: the cached reading only when it was confirmed
    /// recently. A stale reading (e.g. left over from before sleep, or a run of failed refreshes)
    /// returns nil — and discovery treats anything but a confirmed `true` as "issue no transport,"
    /// so it never skips/pauses/grabs the wrong device on an out-of-date flag.
    private func confirmedLocalFlag() -> Bool? {
        guard let local = activeDeviceIsLocal, let at = lastDeviceConfirmedAt,
              Date().timeIntervalSince(at) <= deviceFlagMaxAge else { return nil }
        return local
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
        guard isAuthorized else { source = .none; displayArtists = []; displayArtistsURI = nil; return }
        deviceGen += 1; let gen = deviceGen
        do {
            let result = try await provider.currentSourceAndArtists()
            source = result.source
            displayArtists = result.artists
            displayArtistsURI = result.trackURI
            applyDeviceResult(result.deviceIsLocal, gen: gen)
        } catch { source = .none }
        // A genuine source-playlist change starts a fresh discovery sweep.
        if let id = source.playlistId, id != lastSourceId {
            lastSourceId = id
            discovery.reset()
        }
    }

    /// Artist line for display: the full Web API artist list (incl. features) when it
    /// matches the current track, else the local primary artist.
    func artistText(for np: NowPlaying) -> String {
        if np.uri == displayArtistsURI, !displayArtists.isEmpty {
            return displayArtists.joined(separator: ", ")
        }
        return np.artist
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
        // Require the source to be resolved for the playing track — guards the brief window
        // after a track change where `source` still describes the previous track.
        return source.isEditablePlaylist && source.playlistId != nil
            && source.trackURI == np.uri && !isBusy
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
        if source.trackURI != np.uri { return "Confirming this track's playlist…" }
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
    func next() { discovery.noteUserTransport(); provider.next(); refreshSoon() }
    func previous() { discovery.noteUserTransport(); provider.previous(); refreshSoon() }
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
        // Curating mid-song counts as judging this track: don't let discovery hold it (or its
        // successor) when it ends — let playback advance naturally.
        discovery.noteManualReview(uri: np.uri, sourceId: sourceCtx.playlistId)
        Task {
            let ok = await performAdd(uri: np.uri, sourceCtx: sourceCtx)
            if ok, settings.skipToNextAfterAdd { next() }
        }
    }

    func removeCurrentFromSource() {
        guard let np = nowPlaying, source.isEditablePlaylist, source.playlistId != nil else { return }
        let sourceCtx = source
        discovery.noteManualReview(uri: np.uri, sourceId: sourceCtx.playlistId)
        Task {
            let ok = await performRemoveFromSource(uri: np.uri, sourceCtx: sourceCtx)
            if ok, settings.skipToNextAfterRemove { next() }
        }
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

    /// Returns true when the track ended up in (or was already in) the target.
    @discardableResult
    private func performAdd(uri: String, sourceCtx: SourceContext) async -> Bool {
        guard let target = settings.targetPlaylistId else { return false }
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
            // Move semantics: also remove from source when enabled & editable — but never
            // delete from the target itself, and only when the source was resolved for THIS
            // track (a stale source must not delete the wrong track from the wrong playlist).
            if settings.removeFromSourceOnAdd, sourceCtx.isEditablePlaylist, let src = sourceCtx.playlistId,
               DiscoveryLogic.mayRemoveFromSource(sourcePlaylistId: src,
                                                  targetPlaylistId: settings.targetPlaylistId,
                                                  sourceTrackURI: sourceCtx.trackURI, actedURI: uri, isMove: true) {
                try await provider.removeTrack(uri: uri, fromPlaylist: src)
                setStatus("Moved to \(targetName)")
            }
            return true
        } catch {
            setStatus("Add failed: \(error.localizedDescription)", isError: true)
            return false
        }
    }

    /// Returns true when the track was removed from the source playlist.
    @discardableResult
    private func performRemoveFromSource(uri: String, sourceCtx: SourceContext) async -> Bool {
        guard sourceCtx.isEditablePlaylist, let src = sourceCtx.playlistId else { return false }
        // Only remove when the source context was resolved for THIS exact track. If the
        // source is stale (just changed track, or a missed-preempt hold), refuse rather
        // than delete the wrong track from the wrong playlist.
        guard DiscoveryLogic.mayRemoveFromSource(sourcePlaylistId: src,
                                                 targetPlaylistId: settings.targetPlaylistId,
                                                 sourceTrackURI: sourceCtx.trackURI, actedURI: uri, isMove: false) else {
            setStatus("Couldn't confirm this track's playlist — try again.", isError: true)
            return false
        }
        let name = sourceCtx.playlistName ?? "playlist"
        isBusy = true
        defer { isBusy = false }
        do {
            try await provider.removeTrack(uri: uri, fromPlaylist: src)
            setStatus("Removed from \(name)")
            return true
        } catch {
            setStatus("Remove failed: \(error.localizedDescription)", isError: true)
            return false
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
