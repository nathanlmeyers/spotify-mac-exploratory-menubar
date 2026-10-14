import Foundation
import Combine
import AppKit   // NSWorkspace, for opening an artist's page in Spotify

/// Proof that a playlist removal was initiated by the user pressing a button.
///
/// `SpotifyProvider.removeTrack` requires one, and only the handlers in THIS file can
/// construct one (`fileprivate init`). Discovery, timers, and any future automation are
/// therefore unable to delete a song — not by convention, but because the code won't
/// compile. This replaces a set of prose comments and advisory guards that a stale build
/// happily ignored while it walked a playlist deleting 15 songs.
struct UserRemovalIntent {
    /// What the user pressed, for the log line at the point of deletion.
    let gesture: String
    fileprivate init(_ gesture: String) { self.gesture = gesture }
}

/// A Remove that is waiting on a second, explicit confirmation because the track sits in the
/// source playlist more than once.
///
/// Spotify's delete takes a URI and no positions, so one press takes every copy — the local
/// bridge never learns the playing row's index, so there is no narrower call to make. The count
/// can't be prevented, only shown: this makes it part of the decision instead of something the
/// user discovers afterwards in a playlist that is short by four songs.
struct PendingDuplicateRemoval: Equatable {
    /// One playlist the press will delete from, and how many rows it takes there.
    struct Entry: Equatable {
        let playlistName: String
        /// 1 for a single row, or when the count couldn't be established (nil never blocks —
        /// see `occurrenceCount`).
        let count: Int
    }
    /// The track's name, when it's known — nil falls back to "This track" in the prompt.
    let trackName: String?
    /// Every playlist the press will hit, in order. At least one entry has `count > 1`; a
    /// press that takes one row everywhere never prompts.
    let entries: [Entry]

    var totalRows: Int { entries.reduce(0) { $0 + $1.count } }
    var duplicated: [Entry] { entries.filter { $0.count > 1 } }
    var singles: [Entry] { entries.filter { $0.count <= 1 } }
}

/// Where the "Clear Your Episodes" flow is, so Settings can render it without owning any logic.
///
/// `.confirming` exists to make the count part of the decision: Spotify's saved-episode library
/// has no bulk unsave and no undo, so the user sees the real number before the one destructive
/// press, not after.
enum ClearEpisodesState: Equatable {
    case idle
    case counting
    case confirming(count: Int)
    case clearing(done: Int, total: Int)
    case finished(removed: Int)
    case failed(String)
}

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
    private let newReleaseStore: NewReleaseStore
    /// The New From Followed release radar. Exposed so Settings can drive and observe it.
    let newReleases: NewReleaseScanner
    private let suggestedArtistStore: SuggestedArtistStore
    /// The Artists to Follow list. Exposed so its window and Settings can drive and observe it.
    let suggestions: ArtistSuggestionEngine

    @Published var nowPlaying: NowPlaying?
    @Published var source: SourceContext = .none
    @Published var editablePlaylists: [Playlist] = []
    @Published var statusMessage: String?
    @Published var isBusy = false
    @Published var reviewState: ReviewState = .inactive
    @Published private(set) var clearEpisodes: ClearEpisodesState = .idle
    /// Set when a Remove press turned out to be a multi-row deletion; the panel swaps the
    /// curation buttons for a confirmation while this is non-nil.
    @Published private(set) var pendingDuplicateRemoval: PendingDuplicateRemoval?
    @Published var displayArtists: [String] = []   // full artist list from the Web API (incl. features)
    /// False while Spotify is running but not answering Apple events. Published so the panel can
    /// say so, rather than silently showing a frozen track as if it were live.
    @Published private(set) var isSpotifyResponsive = true

    private var displayArtistsURI: String?
    private var discovery: DiscoveryEngine!
    private var pollTimer: Timer?
    private var lastURI: String?
    private var lastSourceId: String?
    // Whether playback is on this Mac. nil = unknown (not yet confirmed). Local means the active
    // Connect device is this Mac OR no remote device claims the session and the desktop app is
    // playing here (see SpotifyProvider.resolveLocality). Discovery treats anything but a confirmed
    // `true` as "do not issue transport", so it never pauses/skips a phone, speaker, or other
    // computer — including at cold start (still nil) and right after a hand-off (flips to false on
    // the next poll). Only ever set from a known reading.
    private var activeDeviceIsLocal: Bool?
    // Wall-clock time of the last confirmed device reading. Used to age out a stale flag:
    // discovery must only act on a *recently* confirmed reading, so a value left over from
    // before sleep (or from a run of failed reads) can never authorize transport. Wall clock
    // (not systemUptime) is deliberate — it advances across sleep, so a post-wake reading
    // is automatically "old."
    private var lastDeviceConfirmedAt: Date?
    // A device reading older than this is treated as unknown (nil), never as actionable local.
    // Also the tick-gap threshold for distrusting a pre-sleep reading — the two must stay
    // equal so a reading that survives a gap is by definition fresh enough to act on.
    private let deviceFlagMaxAge: TimeInterval = 3.0
    // Wall-clock time of the previous tick, to detect a long gap (sleep/stall) and force device re-validation.
    private var lastTickAt: Date?
    // Monotonic generation so a slow device read can't clobber a newer one (out-of-order writes).
    private var deviceGen = 0
    private var appliedDeviceGen = -1
    private var deviceRefreshInFlight = false
    // Ticks are async now (the local read runs off-main under a deadline), so they must not
    // overlap and interleave their writes to the state above.
    private var tickInFlight = false
    // A track's source can fail to resolve on its first (URI-change) refresh when that read
    // races a hold/slip/reclaim transient — a just-paused track briefly drops its playlist
    // context from /me/player. Retry a bounded number of times while the source is unconfirmed
    // so Remove and the "From" line can catch up; bounded so album/queue playback (which
    // legitimately has no playlist source) doesn't poll forever. Single-flighted.
    private var sourceResolveTries = 0
    private let maxSourceResolveTries = 5
    private var sourceRefreshInFlight = false
    /// URIs known to be in the target playlist: the duplicate guard for Add, and what puts the
    /// checkmark on the Add button. Published so the panel re-renders the moment it changes.
    /// Never `sink` on this — see the willSet note in `AppDelegate`.
    @Published private(set) var targetMembership: Set<String> = []
    /// Which playlist `targetMembership` describes. Tracked because it can lag
    /// `settings.targetPlaylistId`: a target switch whose fetch fails would otherwise leave the
    /// previous playlist's contents standing behind a disabled Add button.
    private var membershipTargetId: String?
    /// URIs known to be in the discovery playlist (`settings.discoveryPlaylistId`): what lets
    /// Remove reach into it for a song playing from an album, an artist page, Liked Songs or
    /// another playlist. Same shape and caveats as `targetMembership`.
    @Published private(set) var discoveryPlaylistMembership: Set<String> = []
    private var membershipDiscoveryPlaylistId: String?
    /// When the discovery set was last fetched. The playlist gains songs from outside this app,
    /// so the panel re-reads it when this is old enough (`refreshDiscoveryMembershipIfStale`).
    private var discoveryMembershipLoadedAt: Date?
    /// Bumped by every local edit to either membership set. A fetch captures it before the walk
    /// and discards its result if it moved — otherwise a panel-open read that lands after a
    /// Remove would put the just-deleted URI straight back and re-enable the button for a song
    /// that is already gone.
    private var membershipGen = 0
    /// What the confirmed press will delete, frozen at the moment the counts came back. Held
    /// separately from the published prompt so the view never sees a URI, and so the deletion
    /// targets exactly the track that was counted rather than whatever is playing by the time
    /// the button is pressed. No `UserRemovalIntent` is stored: the confirming press is itself a
    /// button, and mints its own — an intent is proof of a gesture, so keeping one on ice would
    /// be exactly the stale authorization the type exists to prevent.
    private var pendingRemovalWork: (uri: String, targets: [RemovalTarget])?
    /// The episode URIs behind the number on the "Remove N episodes" button. Held from the
    /// counting pass to the confirmed press so the clear can't exceed what was approved.
    private var approvedEpisodeURIs: [String] = []
    private var statusClear: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init() {
        let auth = SpotifyAuth()
        self.auth = auth
        let settings = Settings()
        self.settings = settings
        let api = SpotifyWebAPI(auth: auth)
        self.api = api
        self.provider = SpotifyProvider(local: local, api: api)
        let newReleaseStore = NewReleaseStore()
        self.newReleaseStore = newReleaseStore
        self.newReleases = NewReleaseScanner(api: api, auth: auth, settings: settings,
                                             store: newReleaseStore)
        let suggestedArtistStore = SuggestedArtistStore()
        self.suggestedArtistStore = suggestedArtistStore
        self.suggestions = ArtistSuggestionEngine(api: api, auth: auth,
                                                  store: suggestedArtistStore)

        // Re-publish nested ObservableObject changes so SwiftUI views refresh.
        auth.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        newReleases.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        suggestions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        // Switching destination playlists must not carry the per-playlist caches across, or the
        // new playlist starts out empty and stays that way.
        settings.$newReleasesPlaylistId.dropFirst()
            .sink { [weak self] id in self?.newReleaseStore.setPlaylist(id) }
            .store(in: &cancellables)

        // Stamp the "nothing older than this" line when the radar is switched on, not when it
        // first manages to run — those can be days apart if the user still has to log back in
        // for the follow scopes or pick a destination, and everything released in between would
        // land before the watermark and be skipped.
        settings.$newReleasesEnabled.dropFirst()
            .sink { [weak self] enabled in
                guard enabled else { return }
                self?.newReleaseStore.startWatermarkIfNeeded(now: Date())
            }
            .store(in: &cancellables)

        discovery = DiscoveryEngine(
            provider: provider,
            settings: settings,
            history: history,
            targetMembership: { [weak self] in self?.targetMembership ?? [] },
            canAddNow: { [weak self] in self?.canAdd ?? false },
            targetName: { [weak self] in self?.settings.targetPlaylistName },
            activeDeviceIsLocal: { [weak self] in self?.confirmedLocalFlag() }
        )
        discovery.onStateChange = { [weak self] state in self?.handleReviewState(state) }
        // Toggling discovery off clears the per-URI/loop guards.
        settings.$discoveryEnabled.dropFirst().sink { [weak self] _ in self?.discovery.reset() }.store(in: &cancellables)
    }

    private func handleReviewState(_ state: ReviewState) {
        reviewState = state
        // A just-committed hold is paused and settled, so /me/player will now report its
        // playlist context reliably — give it a fresh budget to (re)confirm the source even
        // if the hold's initial resolve raced the pause and left Remove/provenance stuck.
        if case .held = state { sourceResolveTries = 0 }
        if state == .nothingNew { setStatus("Nothing new to review") }
    }

    /// The source for a held track: prefer the source frozen at hold time (authoritative for
    /// the held track), falling back to the live source when the frozen source is nil (e.g.
    /// the hold raced source resolution). Never fall through to the successor.
    private func heldSourceContext(_ held: HeldTrack) -> SourceContext? {
        // The frozen source is only authoritative when it confirmed a *playlist* for the held
        // track (`trackURI`). A transient no-context read at hold time is frozen as nil, and the
        // live source — which the tick keeps retrying — is consulted instead. That fallback
        // matches on `resolvedForURI`, so an album hold yields a settled no-playlist context
        // rather than nil, which is what lets Remove reach the discovery playlist for it.
        if held.source?.trackURI == held.snapshot.uri { return held.source }
        if source.resolvedForURI == held.snapshot.uri { return source }
        return nil
    }

    /// The "From" playlist for the held panel. This uses the same held-specific source guard
    /// as the Remove button/actions so provenance and behavior cannot disagree.
    func heldSourceName(_ held: HeldTrack) -> String? {
        heldSourceContext(held)?.playlistName
    }

    func canRemoveHeld(_ held: HeldTrack) -> Bool {
        guard isAuthorized, held.snapshot.kind.isCuratable, !isBusy,
              let source = heldSourceContext(held) else { return false }
        if staleEditableSource(source, for: held.snapshot.uri) { return false }
        return !removalTargets(for: held.snapshot.uri, source: source).isEmpty
    }

    /// Tooltip for the held panel's Remove: what the press will delete from.
    func heldRemoveHelp(_ held: HeldTrack) -> String {
        guard let source = heldSourceContext(held) else { return "Remove" }
        return CurationLogic.removeHelp(targets: removalTargets(for: held.snapshot.uri, source: source))
    }

    func heldRemoveDisabledReason(_ held: HeldTrack) -> String? {
        if !isAuthorized { return "Log in to remove songs." }
        if !held.snapshot.kind.isCuratable { return reasonForNonTrack(held.snapshot.kind, verb: "remove") }
        guard let source = heldSourceContext(held) else { return "Confirming this track's playlist…" }
        return removeDisabledReason(uri: held.snapshot.uri, source: source)
    }

    /// An editable playlist source whose confirmation is for a different track. Remove must
    /// wait rather than fall back to a discovery-only removal — one press owes both legs.
    private func staleEditableSource(_ source: SourceContext, for uri: String) -> Bool {
        source.isEditablePlaylist && source.playlistId != nil && source.trackURI != uri
    }

    var isAuthorized: Bool { auth.isAuthorized }
    var hasClientID: Bool { auth.hasClientID }
    /// False on a token minted before the library scopes were requested — a refresh can't widen
    /// scopes, so clearing Your Episodes needs a fresh login first.
    var hasLibraryScopes: Bool { auth.hasLibraryScopes }
    /// Likewise for reading followed artists, which the release radar needs.
    var hasFollowScopes: Bool { auth.hasFollowScopes }
    /// Likewise for reading your top artists/tracks and following someone, which the Artists
    /// to Follow list needs.
    var hasSuggestScopes: Bool { auth.hasSuggestScopes }
    var isSpotifyRunning: Bool { provider.isAppRunning }

    // MARK: Lifecycle

    func start() {
        settings.bootstrap()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await tick() }
        if isAuthorized { Task { await refreshAfterLogin() } }
    }

    private func tick() async {
        // The local read is now asynchronous and can take up to its deadline, so ticks could
        // otherwise overlap and interleave their state writes. One at a time.
        guard !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }

        // A long gap since the previous tick means the timer didn't fire on schedule — almost
        // always sleep (lid closed), but also App Nap / a stall. The pre-gap device reading is
        // now untrustworthy: distrust it immediately so discovery can't act (skip/pause/grab
        // the session) on a stale flag before the per-tick refresh below lands the truth.
        let now = Date()
        if let last = lastTickAt, now.timeIntervalSince(last) > deviceFlagMaxAge {
            activeDeviceIsLocal = nil
        }
        lastTickAt = now

        // Daily release radar. Everything but an actually-due scan is a local date comparison,
        // so this is safe to ask once a second; the scan itself runs detached and paces its own
        // requests rather than blocking the tick.
        newReleases.scanIfDue(now: now)

        let np = await provider.refreshNowPlaying()

        // Spotify stopped answering Apple events. Hold the last known track on screen (the UI
        // labels it via `isSpotifyResponsive`) instead of blanking, and mark locality unknown
        // so discovery issues no transport — never act on a reading we couldn't take.
        if isSpotifyResponsive != provider.isResponsive { isSpotifyResponsive = provider.isResponsive }
        guard isSpotifyResponsive else {
            activeDeviceIsLocal = nil
            await discovery.onTick(np: nil, source: source)
            return
        }

        // Only publish genuine changes: while parked (a hold) or idle the snapshot is
        // value-equal every tick, and re-publishing would re-render the panel and title 1x/s.
        if np != nowPlaying { nowPlaying = np }

        // Whether this tick already spends a `/me/player` call on refreshSource. That call
        // reports the active device too (it feeds applyDeviceResult), so pairing it with a
        // separate refreshActiveDevice would burn two requests for one tick's worth of truth.
        var willRefreshSource = false
        if np?.uri != lastURI {
            lastURI = np?.uri
            sourceResolveTries = 0
            if isAuthorized, np != nil {
                willRefreshSource = true
            } else {
                source = .none
            }
        } else if isAuthorized, let np, source.trackURI != np.uri, sourceResolveTries < maxSourceResolveTries {
            // Source didn't resolve for the current track (its first refresh raced a hold/slip/
            // reclaim transient). Retry so Remove / provenance can confirm the playlist.
            sourceResolveTries += 1
            willRefreshSource = true
        }
        if willRefreshSource { Task { await refreshSource() } }

        // The active device can change without the track changing (a mid-song Spotify Connect
        // hand-off). Refresh the device flag every tick while discovery is armed and something
        // is playing, so we stop pausing promptly when playback leaves this Mac. Single-flighted
        // inside refreshActiveDevice, so ticks can't pile up calls.
        if isAuthorized, settings.discoveryEnabled, np != nil, !willRefreshSource {
            Task { await refreshActiveDevice() }
        }
        await discovery.onTick(np: np, source: source)
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
        // Independent fetches — overlap the network round-trips.
        async let playlists: Void = loadPlaylists()
        async let sourceRefresh: Void = refreshSource()
        async let membership: Void = loadTargetMembership(force: true)
        async let discoveryMembership: Void = loadDiscoveryPlaylistMembership(force: true)
        _ = await (playlists, sourceRefresh, membership, discoveryMembership)
    }

    func loadPlaylists() async {
        guard isAuthorized else { return }
        do { editablePlaylists = try await provider.editablePlaylists() }
        catch { setStatus("Couldn't load playlists: \(error.localizedDescription)") }
    }

    func refreshSource() async {
        guard isAuthorized else { source = .none; displayArtists = []; displayArtistsURI = nil; return }
        guard !sourceRefreshInFlight else { return }   // don't pile up /me/player calls across ticks
        sourceRefreshInFlight = true
        defer { sourceRefreshInFlight = false }
        deviceGen += 1; let gen = deviceGen
        do {
            let result = try await provider.currentSourceAndArtists()
            source = result.source
            displayArtists = result.artists
            displayArtistsURI = result.trackURI
            applyDeviceResult(result.deviceIsLocal, gen: gen)
        } catch SpotifyWebAPI.APIError.rateLimited {
            // Being throttled says nothing about what's playing. Keep the last known source
            // rather than blanking it — `.none` greys out Remove and drops the "From" line,
            // and during a backoff that would persist for the whole window.
        } catch {
            source = .none
        }
        // A genuine source-playlist change starts a fresh discovery sweep — but never while a
        // review is held: finally resolving a held/slipped track's own source (a delayed first
        // read, not a real playlist change) must not tear down the hold. A real source change
        // always arrives with a track change and is handled on the next URI change.
        if let id = source.playlistId, id != lastSourceId {
            lastSourceId = id
            if !isReviewHeld { discovery.reset() }
        }
    }

    private var isReviewHeld: Bool {
        if case .held = reviewState { return true }
        return false
    }

    /// The track the UI (menu bar title, panels) should display: while a review is held,
    /// the held snapshot — merged with the live read when it's still the same track, so
    /// position/isPlaying stay fresh — otherwise live now-playing. Keeps a transient
    /// successor read (crossfade flip, late pause, reclaim in flight) from ever naming
    /// the NEXT song while the user is reviewing the held one.
    var displayTrack: NowPlaying? {
        if case .held(let held) = reviewState {
            if let np = nowPlaying, np.uri == held.snapshot.uri { return np }
            return held.snapshot
        }
        return nowPlaying
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
        guard let target = settings.targetPlaylistId else {
            targetMembership = []
            membershipTargetId = nil
            return
        }
        // Seed from disk *before* the fetch, for both directions of wrongness. It drops the
        // previous target's contents the instant the target changes, rather than letting them
        // stand until (or past) a fetch that may fail — and it means a cold start answers
        // "already in <target>" from the last known contents instead of from an empty set, which
        // would show every song as unadded and let the first Add write a duplicate.
        if membershipTargetId != target {
            targetMembership = history.cachedMembership(targetId: target) ?? []
            membershipTargetId = target
        } else if !force, !targetMembership.isEmpty {
            return
        }
        // The target can change while this is in flight; publishing then would attribute one
        // playlist's contents to another.
        guard let uris = await fetchMembership(playlistId: target),
              settings.targetPlaylistId == target else { return }
        targetMembership = uris
        membershipTargetId = target
        history.setMembership(targetId: target, uris: uris)
    }

    /// One full read of a playlist's URIs, or nil when it couldn't be had — or when a local
    /// Add/Remove landed while it was in flight (`membershipGen`), in which case the read is
    /// already wrong about at least one song and the caller keeps what it has.
    ///
    /// Nil keeps the seed. An unknown answer must read as "not added" — never as added, which
    /// with a disabled Add button would leave no way to add the song at all.
    private func fetchMembership(playlistId: String) async -> Set<String>? {
        let gen = membershipGen
        do {
            let uris = try await api.playlistTrackURIs(id: playlistId)
            guard membershipGen == gen else {
                DebugLog.log("membership read of \(playlistId) discarded: edited while in flight")
                return nil
            }
            return uris
        } catch {
            DebugLog.log("membership read of \(playlistId) failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func loadDiscoveryPlaylistMembership(force: Bool) async {
        guard let playlistId = settings.discoveryPlaylistId else {
            discoveryPlaylistMembership = []
            membershipDiscoveryPlaylistId = nil
            discoveryMembershipLoadedAt = nil
            return
        }
        if membershipDiscoveryPlaylistId != playlistId {
            discoveryPlaylistMembership = history.cachedMembership(targetId: playlistId) ?? []
            membershipDiscoveryPlaylistId = playlistId
            discoveryMembershipLoadedAt = nil
        } else if !force, !discoveryPlaylistMembership.isEmpty {
            return
        }
        // Same playlist as the Add target and that set is fresh: copy it rather than walk the
        // playlist a second time.
        if playlistId == membershipTargetId, playlistId == settings.targetPlaylistId, !targetMembership.isEmpty, !force {
            discoveryPlaylistMembership = targetMembership
            discoveryMembershipLoadedAt = Date()
            return
        }
        guard let uris = await fetchMembership(playlistId: playlistId),
              settings.discoveryPlaylistId == playlistId else { return }
        discoveryPlaylistMembership = uris
        membershipDiscoveryPlaylistId = playlistId
        discoveryMembershipLoadedAt = Date()
        history.setMembership(targetId: playlistId, uris: uris)
        DebugLog.log("discovery playlist membership: \(uris.count) uris in \(playlistId)")
    }

    /// Re-read the discovery playlist when the panel opens and the set is old. The playlist
    /// gains songs from outside this app (the release radar, Spotify itself), and a disabled
    /// Remove suppresses its own tooltip, so the panel click is the cheap moment to catch up.
    /// Shorter window when the current song plays from no playlist and isn't in the set — that
    /// is exactly the case where a stale read is what's greying the button out.
    func refreshDiscoveryMembershipIfStale() async {
        guard isAuthorized, let playlistId = settings.discoveryPlaylistId else { return }
        let age = discoveryMembershipLoadedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        var window: TimeInterval = 5 * 60
        if let np = nowPlaying, source.playlistId == nil, !discoveryPlaylistMembership.contains(np.uri) {
            window = 30
        }
        guard membershipDiscoveryPlaylistId != playlistId || discoveryPlaylistMembership.isEmpty || age > window
        else { return }
        await loadDiscoveryPlaylistMembership(force: true)
    }

    /// Forget `uri` in whichever membership sets describe `playlistId` — disk always, memory
    /// only when the in-memory set is actually this playlist's. Mutating a set loaded for a
    /// different playlist would edit the wrong playlist's view of itself.
    private func noteRemoved(uri: String, from playlistId: String) {
        membershipGen += 1
        history.removeFromMembership(targetId: playlistId, uri: uri)
        if membershipTargetId == playlistId { targetMembership.remove(uri) }
        if membershipDiscoveryPlaylistId == playlistId { discoveryPlaylistMembership.remove(uri) }
    }

    /// The Add counterpart of `noteRemoved`.
    private func noteAdded(uri: String, to playlistId: String) {
        membershipGen += 1
        history.addToMembership(targetId: playlistId, uri: uri)
        if membershipTargetId == playlistId { targetMembership.insert(uri) }
        if membershipDiscoveryPlaylistId == playlistId { discoveryPlaylistMembership.insert(uri) }
    }

    /// Whether the Add button should wear its "already in the target" face for this track.
    func isInTarget(_ np: NowPlaying?) -> Bool {
        CurationLogic.showsInTarget(trackURI: np?.uri,
                                    membershipTargetId: membershipTargetId,
                                    currentTargetId: settings.targetPlaylistId,
                                    membership: targetMembership)
    }

    /// The same, for whatever the panel is currently showing — `displayTrack`, not `nowPlaying`,
    /// so a hold's frozen snapshot wins over a transient read of its successor.
    var currentIsInTarget: Bool { isInTarget(displayTrack) }

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

    /// What a Remove press on `uri` deletes from — see `CurationLogic.removalTargets`.
    private func removalTargets(for uri: String, source: SourceContext) -> [RemovalTarget] {
        CurationLogic.removalTargets(uri: uri,
                                     source: source,
                                     discoveryPlaylistId: settings.discoveryPlaylistId,
                                     discoveryPlaylistName: settings.discoveryPlaylistName,
                                     membershipLoadedFor: membershipDiscoveryPlaylistId,
                                     membership: discoveryPlaylistMembership)
    }

    /// Whether the source lookup for the playing track is settled enough to act on.
    ///
    /// A playlist context is settled as soon as it's resolved. A *no-playlist* context is only
    /// trusted once the tick's retries are spent: `/me/player` briefly reports no context for a
    /// track that really is in a playlist (the transient those retries exist for), and acting on
    /// that would remove from the discovery playlist alone when one press owed both legs. The
    /// cost is a few seconds of "Confirming…" after an album or Liked Songs track starts.
    private func sourceSettled(for np: NowPlaying) -> Bool {
        guard source.resolvedForURI == np.uri else { return false }
        return source.playlistId != nil || sourceResolveTries >= maxSourceResolveTries
    }

    var canRemove: Bool {
        guard isAuthorized, let np = nowPlaying, np.kind.isCuratable, !isBusy else { return false }
        // Require the source to be settled for the playing track — guards the brief window
        // after a track change where `source` still describes the previous track.
        guard sourceSettled(for: np), !staleEditableSource(source, for: np.uri) else { return false }
        return !removalTargets(for: np.uri, source: source).isEmpty
    }

    /// Tooltip for an enabled Remove: what the press will delete from.
    var removeHelp: String {
        guard let np = nowPlaying else { return "Remove" }
        return CurationLogic.removeHelp(targets: removalTargets(for: np.uri, source: source))
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
        if !sourceSettled(for: np) { return "Confirming this track's playlist…" }
        return removeDisabledReason(uri: np.uri, source: source)
    }

    /// The part of the Remove tooltip shared by the normal and held panels, once the context
    /// is known to be resolved for `uri`. Nil when the press would do something.
    private func removeDisabledReason(uri: String, source: SourceContext) -> String? {
        if staleEditableSource(source, for: uri) { return "Confirming this track's playlist…" }
        if !removalTargets(for: uri, source: source).isEmpty { return nil }
        if source.playlistId != nil, !source.isEditablePlaylist, settings.discoveryPlaylistId == nil {
            return "You can't edit “\(source.playlistName ?? "this playlist")”."
        }
        if let discoveryName = settings.discoveryPlaylistName {
            return "Not in \(discoveryName) or a playlist you can edit — nothing to remove from."
        }
        return "Not playing from a playlist — nothing to remove from."
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

    // MARK: Artists to Follow
    //
    // Every intent here is additive or local. There is no unfollow: "Not interested" only
    // writes to this app's own JSON, and the Follow button only ever adds. That's the same
    // property `UserRemovalIntent` enforces for playlist and library deletions — this feature
    // simply has no destructive call to gate.

    /// Play a suggested artist through the Spotify desktop app.
    ///
    /// Sends the bare `spotify:artist:` URI and lets Spotify pick the song, which is the only
    /// way left to play "their biggest track": February 2026 removed
    /// `GET /artists/{id}/top-tracks` and stripped `popularity` from every object, so the Web
    /// API can't rank an artist's songs at all. The desktop app still can, and this costs no
    /// quota and needs no Premium.
    func playArtist(id: String) {
        provider.play(uri: ArtistSuggestionLogic.artistURI(id: id))
        refreshSoon()
    }

    /// Open an artist's page. Prefers the desktop app; the web player is the fallback for a
    /// Mac where the `spotify:` scheme isn't registered.
    func openArtistInSpotify(id: String) {
        if let appURL = URL(string: ArtistSuggestionLogic.artistURI(id: id)),
           NSWorkspace.shared.urlForApplication(toOpen: appURL) != nil {
            NSWorkspace.shared.open(appURL)
            return
        }
        if let webURL = URL(string: ArtistSuggestionLogic.artistWebURL(id: id)) {
            NSWorkspace.shared.open(webURL)
        }
    }

    func followSuggested(id: String, name: String) {
        Task {
            await suggestions.follow(artistId: id)
            setStatus("Following \(name).")
        }
    }

    /// Local only — takes the artist out of this list and touches nothing on Spotify.
    func dismissSuggested(id: String) { suggestions.dismiss(artistId: id) }

    // MARK: Auth

    func login() { auth.beginLogin() }
    func logout() {
        auth.logout()
        provider.resetCaches()   // user-scoped caches (user id, playlist info) must not leak accounts
        editablePlaylists = []
        source = .none
        targetMembership = []
        membershipTargetId = nil
        discoveryPlaylistMembership = []
        membershipDiscoveryPlaylistId = nil
        discoveryMembershipLoadedAt = nil
        lastSourceId = nil
        discovery.reset()
        clearEpisodes = .idle    // never leave another account's episode count on screen
        suggestions.reset()      // nor another account's listening history
    }

    // MARK: Curation

    func setTarget(_ playlist: Playlist) {
        settings.targetPlaylistId = playlist.id
        settings.targetPlaylistName = playlist.name
        DebugLog.log("target set: \"\(playlist.name)\" id=\(playlist.id) owner=\(playlist.ownerId) collab=\(playlist.collaborative)")
        Task { await loadTargetMembership(force: true) }
    }

    func setDiscoveryPlaylist(_ playlist: Playlist) {
        settings.discoveryPlaylistId = playlist.id
        settings.discoveryPlaylistName = playlist.name
        DebugLog.log("discovery playlist set: \"\(playlist.name)\" id=\(playlist.id) owner=\(playlist.ownerId) collab=\(playlist.collaborative)")
        Task { await loadDiscoveryPlaylistMembership(force: true) }
    }

    func clearDiscoveryPlaylist() {
        settings.discoveryPlaylistId = nil
        settings.discoveryPlaylistName = nil
        DebugLog.log("discovery playlist cleared")
        Task { await loadDiscoveryPlaylistMembership(force: true) }   // drops the set
    }

    // MARK: New releases

    /// Point the release radar at an existing playlist.
    func setNewReleasesTarget(_ playlist: Playlist) {
        settings.newReleasesPlaylistId = playlist.id
        settings.newReleasesPlaylistName = playlist.name
        DebugLog.log("new-releases target set: \"\(playlist.name)\" id=\(playlist.id)")
    }

    /// Create the default "New From Followed" playlist and point the radar at it.
    ///
    /// Creating it here rather than asking the user to make one in Spotify means the app can
    /// guarantee it owns and can write to the destination — the most common way the radar would
    /// otherwise fail is being pointed at a playlist the user can't edit.
    func createNewReleasesPlaylist() {
        guard isAuthorized else { setStatus("Log in to Spotify first.", isError: true); return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let playlist = try await api.createPlaylist(
                    name: "New From Followed",
                    description: "New music from artists you follow. Updated daily by Spotify Menu Bar.")
                setNewReleasesTarget(playlist)
                await loadPlaylists()
                setStatus("Created “\(playlist.name)”")
            } catch {
                setStatus("Couldn't create the playlist: \(error.localizedDescription)", isError: true)
            }
        }
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
        // `canRemove` is the whole gate: a song playing from an album can be removable (from
        // the discovery playlist) with no editable source at all.
        guard canRemove, let np = nowPlaying else { return }
        let sourceCtx = source
        let intent = UserRemovalIntent("Remove button")
        discovery.noteManualReview(uri: np.uri, sourceId: sourceCtx.playlistId)
        Task {
            let ok = await performRemove(uri: np.uri, sourceCtx: sourceCtx, intent: intent)
            if ok, settings.skipToNextAfterRemove { next() }
        }
    }

    // MARK: Discovery held actions

    func heldAdd() { resolveHeld { await self.performAdd(uri: $0, sourceCtx: $1) } }

    func heldRemove() {
        let intent = UserRemovalIntent("held-panel Remove button")
        resolveHeld { await self.performRemove(uri: $0, sourceCtx: $1, intent: intent) }
    }

    func heldSkip() { resolveHeld() }

    /// Resolve the held review: advance playback immediately (finishHold), then run the
    /// curation action (if any) against the held snapshot's URI and the frozen source.
    private func resolveHeld(then action: ((String, SourceContext) async -> Bool)? = nil) {
        guard case .held(let held) = reviewState else { return }
        let uri = held.snapshot.uri
        let sourceCtx = heldSourceContext(held) ?? .none
        // `uri` and `sourceCtx` are frozen above, so the curation action is unaffected by
        // anything finishHold's fresh read observes — it just runs after playback has advanced.
        Task {
            await discovery.finishHold(judgedURI: uri, sourceId: sourceCtx.playlistId)
            if let action { _ = await action(uri, sourceCtx) }
        }
    }

    // MARK: Curation core (URI-explicit; shared by buttons + held actions)

    /// Returns true when the track ended up in (or was already in) the target.
    @discardableResult
    private func performAdd(uri: String, sourceCtx: SourceContext) async -> Bool {
        guard let target = settings.targetPlaylistId else { return false }
        let targetName = settings.targetPlaylistName ?? "target"
        isBusy = true
        defer { isBusy = false }
        // A target switch and this press can race. Never consult (or extend) the previous
        // target's set — that is how a song reads as "already in" a playlist it was never added
        // to. Mirrors Android's `selectMembershipTarget`.
        if membershipTargetId != target {
            targetMembership = history.cachedMembership(targetId: target) ?? []
            membershipTargetId = target
        }
        do {
            if targetMembership.contains(uri) {
                setStatus("Already in \(targetName)")
            } else {
                try await provider.addTrack(uri: uri, toPlaylist: target)
                noteAdded(uri: uri, to: target)
                setStatus("Added to \(targetName)")
            }
        } catch {
            setStatus("Add failed: \(error.localizedDescription)", isError: true)
            return false
        }
        // Move semantics: also remove from source when enabled & editable — but never
        // delete from the target itself, and only when the source was resolved for THIS
        // track (a stale source must not delete the wrong track from the wrong playlist).
        //
        // Its own do/catch: the add above has already landed and the Add button is already
        // wearing its checkmark, so reporting a failure here as "Add failed" would contradict
        // what the user is looking at. Only the half that failed gets named.
        if settings.removeFromSourceOnAdd, sourceCtx.isEditablePlaylist, let src = sourceCtx.playlistId,
           DiscoveryLogic.mayRemoveFromSource(sourcePlaylistId: src,
                                              targetPlaylistId: settings.targetPlaylistId,
                                              sourceTrackURI: sourceCtx.trackURI, actedURI: uri, isMove: true) {
            let sourceName = sourceCtx.playlistName ?? "the source"
            // A move whose source holds several copies would delete all of them. Unlike the
            // Remove button there's nowhere to prompt — an add is normally followed straight
            // away by a skip, and a confirmation left on screen would be answered against the
            // next track or silently dropped. So the add stands, the delete doesn't, and the
            // user is told; pressing Remove afterwards offers the confirmation properly.
            if settings.warnOnDuplicateRemoval,
               let count = await occurrenceCount(of: uri, inPlaylist: src), count > 1 {
                DebugLog.log("move: refusing to auto-delete \(count) copies of \(uri) from playlist \(src)")
                setStatus("Added to \(targetName) — left \(count) copies in \(sourceName). Press Remove to delete them all.")
                return true
            }
            do {
                try await provider.removeTrack(uri: uri, fromPlaylist: src,
                                               intent: UserRemovalIntent("Add button (move)"))
                setStatus("Moved to \(targetName)")
            } catch {
                setStatus("Added to \(targetName), but couldn't remove from source: " +
                          error.localizedDescription, isError: true)
            }
        }
        return true
    }

    /// Returns true when the track was removed from at least one playlist (the source it's
    /// playing from, the discovery playlist, or both — see `CurationLogic.removalTargets`).
    /// `intent` is the user gesture that authorized this — see `UserRemovalIntent`.
    ///
    /// A press that would take more than one row anywhere doesn't delete: it arms
    /// `pendingDuplicateRemoval` and returns false, and the second press (`confirmDuplicateRemoval`)
    /// is what reaches `commitRemove`.
    @discardableResult
    private func performRemove(uri: String, sourceCtx: SourceContext,
                               intent: UserRemovalIntent) async -> Bool {
        // Only remove from the source when it was resolved for THIS exact track. If the
        // source is stale (just changed track, or a missed-preempt hold), refuse the whole
        // press rather than delete the wrong track from the wrong playlist — or quietly do
        // only the discovery leg of a press that owed two.
        if sourceCtx.isEditablePlaylist, let src = sourceCtx.playlistId,
           !DiscoveryLogic.mayRemoveFromSource(sourcePlaylistId: src,
                                               targetPlaylistId: settings.targetPlaylistId,
                                               sourceTrackURI: sourceCtx.trackURI, actedURI: uri, isMove: false) {
            setStatus("Couldn't confirm this track's playlist — try again.", isError: true)
            return false
        }
        let targets = removalTargets(for: uri, source: sourceCtx)
        guard !targets.isEmpty else { return false }
        // Held for the counts *and* the delete: `occurrenceCount` and `commitRemove` deliberately
        // don't touch `isBusy` themselves, so it's raised once per action rather than flickering
        // off between network calls of the same press.
        isBusy = true
        defer { isBusy = false }
        if settings.warnOnDuplicateRemoval {
            // Each count is a full read of its playlist; run them side by side so a two-playlist
            // press doesn't take twice as long.
            let counts: [Int?] = await withTaskGroup(of: (Int, Int?).self) { group in
                for (i, t) in targets.enumerated() {
                    group.addTask { await (i, self.occurrenceCount(of: uri, inPlaylist: t.playlistId)) }
                }
                var out = [Int?](repeating: nil, count: targets.count)
                for await (i, count) in group { out[i] = count }
                return out
            }
            let entries = zip(targets, counts).map {
                PendingDuplicateRemoval.Entry(playlistName: $0.playlistName, count: max($1 ?? 1, 1))
            }
            if entries.contains(where: { $0.count > 1 }) {
                pendingRemovalWork = (uri: uri, targets: targets)
                pendingDuplicateRemoval = PendingDuplicateRemoval(trackName: trackName(forURI: uri),
                                                                 entries: entries)
                let detail = zip(targets, entries).map { "\($1.count) in \($0.playlistId)" }.joined(separator: ", ")
                DebugLog.log("REMOVE held for confirmation [\(intent.gesture)] \(uri): \(detail)")
                return false
            }
        }
        return await commitRemove(uri: uri, targets: targets, intent: intent)
    }

    /// The rows `uri` occupies in the playlist, or nil when that couldn't be established.
    ///
    /// Nil is deliberately not treated as "stop": a rate-limited or offline count would then turn
    /// every Remove into a dead button. The removal proceeds with the behavior it has always had,
    /// and the log records that the check didn't run.
    private func occurrenceCount(of uri: String, inPlaylist playlistId: String) async -> Int? {
        do {
            return try await provider.playlistOccurrences(of: uri, inPlaylist: playlistId)
        } catch {
            DebugLog.log("duplicate check skipped for \(uri) in \(playlistId): \(error.localizedDescription)")
            return nil
        }
    }

    /// The user pressed "Remove all N". This is the only caller that deletes without counting —
    /// the count is what they were just shown.
    func confirmDuplicateRemoval() {
        guard let work = pendingRemovalWork else { return }
        pendingRemovalWork = nil
        pendingDuplicateRemoval = nil
        let intent = UserRemovalIntent("Remove all N (confirmed)")
        Task {
            isBusy = true
            defer { isBusy = false }
            let ok = await commitRemove(uri: work.uri, targets: work.targets, intent: intent)
            if ok, settings.skipToNextAfterRemove, nowPlaying?.uri == work.uri { next() }
        }
    }

    /// Dismiss the prompt without deleting anything.
    ///
    /// Nothing dismisses this automatically — not even a track change. The held-review Remove
    /// arms the prompt *after* `finishHold` has already advanced playback, so expiring it on the
    /// next URI would silently swallow that path's removal. The prompt names its own track and
    /// playlist and acts on a frozen context, so it stays correct however long it sits there.
    func cancelDuplicateRemoval() {
        guard pendingRemovalWork != nil || pendingDuplicateRemoval != nil else { return }
        pendingRemovalWork = nil
        pendingDuplicateRemoval = nil
    }

    /// The deletion itself, past every guard — one call per playlist in `targets`. Split out so
    /// the confirmed path and the single-row path share one body — a second copy is how the two
    /// would drift. Callers own `isBusy`. Returns true when at least one playlist let go of the
    /// song, so a skip-after-remove still follows a press that half succeeded.
    private func commitRemove(uri: String, targets: [RemovalTarget],
                              intent: UserRemovalIntent) async -> Bool {
        var succeeded: [String] = []
        var failed: [(playlistName: String, error: String)] = []
        for target in targets {
            do {
                try await provider.removeTrack(uri: uri, fromPlaylist: target.playlistId, intent: intent)
                // The membership caches must forget the track — otherwise it still reads as
                // "already in target" (and auto-skip keeps skipping a song that is no longer
                // there), or Remove stays lit for a song the discovery playlist already lost.
                noteRemoved(uri: uri, from: target.playlistId)
                succeeded.append(target.playlistName)
            } catch {
                failed.append((target.playlistName, error.localizedDescription))
            }
        }
        setStatus(CurationLogic.removedStatus(succeeded: succeeded, failed: failed), isError: !failed.isEmpty)
        return !succeeded.isEmpty
    }

    /// The display name for a URI, for the confirmation prompt. Nil when neither the live track
    /// nor the held snapshot is the track in question.
    private func trackName(forURI uri: String) -> String? {
        if let np = nowPlaying, np.uri == uri, !np.name.isEmpty { return np.name }
        if case .held(let held) = reviewState, held.snapshot.uri == uri, !held.snapshot.name.isEmpty {
            return held.snapshot.name
        }
        return nil
    }

    // MARK: Library — clear "Your Episodes"

    /// Step 1 of 2: count what's there. Counting is a separate step precisely so the confirm
    /// prompt can name a real number instead of asking the user to approve an unknown quantity.
    ///
    /// The URIs behind that number are kept, not just the count: step 2 removes the intersection
    /// of this list with a fresh read, so the press can never unsave more than what was approved.
    func beginClearYourEpisodes() {
        guard isAuthorized, hasLibraryScopes else { return }
        guard clearEpisodes == .idle else { return }
        clearEpisodes = .counting
        Task {
            do {
                let episodes = try await provider.savedEpisodes()
                approvedEpisodeURIs = episodes.map(\.uri)
                // Nothing to do — skip the confirm rather than asking to delete zero things.
                clearEpisodes = episodes.isEmpty ? .finished(removed: 0)
                                                 : .confirming(count: episodes.count)
            } catch {
                approvedEpisodeURIs = []
                clearEpisodes = .failed(error.localizedDescription)
            }
        }
    }

    func cancelClearYourEpisodes() {
        approvedEpisodeURIs = []
        clearEpisodes = .idle
    }

    /// Dismiss a terminal result and return the row to its resting state.
    func acknowledgeClearYourEpisodes() {
        switch clearEpisodes {
        case .finished, .failed:
            approvedEpisodeURIs = []
            clearEpisodes = .idle
        default: break
        }
    }

    /// Step 2 of 2: the destructive press, and the only place a bulk-unsave intent is created.
    ///
    /// Re-reads the library first: the confirmed count came from a fetch that may be minutes old,
    /// and acting on that stale list could unsave an episode that has since been removed
    /// elsewhere. The fresh read is then narrowed to what the user actually approved
    /// (`LibraryLogic.removableURIs`) — otherwise "Remove 340 episodes" could quietly unsave 342
    /// because two more were saved while the confirm sat on screen. Stops at the first failure
    /// (including a 429 backoff) and reports how far it got — silently retrying a bulk delete
    /// against a rate limit is how you turn one problem into two.
    func confirmClearYourEpisodes() {
        guard case .confirming = clearEpisodes else { return }
        guard isAuthorized, hasLibraryScopes else { return }
        let approved = approvedEpisodeURIs
        let intent = UserRemovalIntent("Clear Your Episodes button (confirmed)")
        clearEpisodes = .clearing(done: 0, total: 0)
        Task {
            var removed = 0
            var total = 0
            do {
                let current = try await provider.savedEpisodes().map(\.uri)
                let uris = LibraryLogic.removableURIs(confirmed: approved, current: current)
                if current.count > uris.count {
                    DebugLog.log("clear Your Episodes: leaving \(current.count - uris.count) episode(s) saved since you confirmed")
                }
                total = uris.count
                guard total > 0 else {
                    clearEpisodes = .finished(removed: 0)
                    return
                }
                clearEpisodes = .clearing(done: 0, total: total)
                DebugLog.log("clear Your Episodes: starting, \(total) saved episodes")
                for batch in LibraryLogic.batches(uris) {
                    try await provider.removeLibraryItems(uris: batch, intent: intent)
                    removed += batch.count
                    clearEpisodes = .clearing(done: removed, total: total)
                }
                DebugLog.log("clear Your Episodes: removed \(removed) of \(total)")
                clearEpisodes = .finished(removed: removed)
                setStatus("Cleared \(removed) episode\(removed == 1 ? "" : "s")")
            } catch {
                let message = LibraryLogic.partialFailureLabel(done: removed, total: total,
                                                               error: error.localizedDescription)
                DebugLog.log("clear Your Episodes FAILED: \(message)")
                clearEpisodes = .failed(message)
                setStatus(message, isError: true)
            }
        }
    }

    // MARK: Helpers

    /// Spotify needs a beat to apply transport changes; re-read shortly after.
    private func refreshSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            await tick()
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
