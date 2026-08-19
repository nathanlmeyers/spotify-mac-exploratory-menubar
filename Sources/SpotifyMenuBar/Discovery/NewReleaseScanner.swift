import Foundation

/// Sweeps the user's followed artists for new music and appends it to a playlist.
///
/// This is the "New From Followed" release radar — the app's own replacement for a paid
/// new-releases service. It runs unattended on a daily timer, which shapes every decision here:
///
///  - **It only ever reads and appends.** Nothing it can reach deletes anything (see
///    `SpotifyWebAPI+NewReleases.swift`). An unattended job must not be able to remove music.
///  - **It paces itself and parks on a 429.** Development-mode quota is counted per developer
///    account and its limits aren't published, so a scan that hammers would take the rest of the
///    app down with it — the 1 Hz now-playing poll shares the same budget.
///  - **It's resumable.** An interrupted sweep records where it stopped and continues from there
///    rather than restarting, so a scan that keeps getting throttled still makes progress.
@MainActor
final class NewReleaseScanner: ObservableObject {

    enum State: Equatable {
        case idle
        case running(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Last completed (or interrupted) run's summary, for the Settings pane.
    @Published private(set) var lastSummary: String?
    @Published private(set) var lastScanAt: Date?

    var isRunning: Bool { if case .running = state { return true }; return false }

    /// Minimum seconds between requests, giving ~2 req/s.
    ///
    /// The probe sustained 3.6 req/s over 60 requests without a 429, but a full sweep is a
    /// thousand-plus requests against a rolling 30-second window whose development-mode limit
    /// Spotify doesn't publish — and the app's own 1 Hz now-playing poll is spending from the
    /// same budget. Half the measured ceiling buys a scan that takes minutes instead of one
    /// that takes the rest of the app down with it.
    private let requestInterval: TimeInterval = 0.5

    private let api: SpotifyWebAPI
    private let auth: SpotifyAuth
    private let settings: Settings
    private let store: NewReleaseStore

    /// How long to wait before retrying after a scan was interrupted.
    ///
    /// An interrupted scan deliberately leaves `lastScanAt` unstamped so it stays due and
    /// resumes — but `scanIfDue` is asked once a second, so without a cooldown a scan that fails
    /// on its first request (which is exactly what happens while the API client's 429 gate is
    /// open) would restart every second, rewriting the store and the log each time.
    private let retryCooldown: TimeInterval = 5 * 60

    private var scanInFlight = false
    private var lastRequestAt: Date?
    /// In-memory only: a relaunch is a reasonable moment to try again.
    private var cooldownUntil: Date?

    init(api: SpotifyWebAPI, auth: SpotifyAuth, settings: Settings, store: NewReleaseStore) {
        self.api = api
        self.auth = auth
        self.settings = settings
        self.store = store
        lastSummary = store.lastSummary
        lastScanAt = store.lastScanAt
    }

    // MARK: - Entry points

    /// Called from the app's 1 Hz tick. Everything here is a cheap local check — the expensive
    /// work only starts when a scan is genuinely due.
    func scanIfDue(now: Date = Date()) {
        guard settings.newReleasesEnabled, !scanInFlight else { return }
        guard auth.isAuthorized, auth.hasFollowScopes else { return }
        guard settings.newReleasesPlaylistId != nil else { return }
        if let until = cooldownUntil, now < until { return }
        guard NewReleaseLogic.isScanDue(lastScanAt: store.lastScanAt, now: now) else { return }
        Task { await scan(now: now) }
    }

    /// The Settings "Scan now" button. Runs regardless of whether one is due, and clears any
    /// cooldown — an explicit press is a reason to try again right now.
    func scanNow() {
        guard !scanInFlight else { return }
        cooldownUntil = nil
        Task { await scan(now: Date()) }
    }

    /// Forget everything and sweep again from today — used when filters change, so the effect
    /// of a filter can actually be observed rather than being masked by the seen-album cache.
    func resetAndRescan() {
        guard !scanInFlight else { return }
        cooldownUntil = nil
        store.reset()
        lastSummary = nil
        lastScanAt = nil
        Task { await scan(now: Date()) }
    }

    // MARK: - The sweep

    private func scan(now: Date) async {
        guard !scanInFlight else { return }
        scanInFlight = true
        defer { scanInFlight = false }

        guard auth.isAuthorized else { return fail("Log in to Spotify first.") }
        guard auth.hasFollowScopes else {
            return fail("Log out and back in to grant access to your followed artists.")
        }
        guard let playlistId = settings.newReleasesPlaylistId else {
            return fail("Pick a destination playlist first.")
        }

        let filters = settings.newReleaseFilters
        let watermark = store.watermark(now: now)
        let lookback = NewReleaseLogic.effectiveLookbackDays(filters: filters)
        let cutoff = NewReleaseLogic.cutoffDay(now: now, watermark: watermark,
                                               lastScanAt: store.lastScanAt, lookbackDays: lookback)
        let horizon = NewReleaseLogic.horizonDay(now: now)
        let dayIndex = NewReleaseLogic.dayIndex(now: now)
        // Machine was off (or the app shut) for longer than the lookback: widen the window back
        // to the last scan and sweep every artist's features in this one run.
        let catchUp = NewReleaseLogic.isCatchUp(lastScanAt: store.lastScanAt, now: now,
                                                lookbackDays: lookback)

        state = .running("Reading your followed artists…")
        DebugLog.log("new-releases: scan starting (cutoff \(cutoff), horizon \(horizon)"
                     + (catchUp ? ", CATCH-UP since \(store.lastScanAt.map(NewReleaseLogic.dayString) ?? "?")" : "")
                     + ", filters \(filters))")

        var artists: [FollowedArtist]
        var existing: Set<String>
        do {
            // Both of these paginate internally — a few hundred followed artists or a big
            // destination playlist is dozens of requests — so the pacer has to go *in*, not
            // round the outside where it would only ever throttle the first of them.
            artists = try await api.followedArtists(pace: paceHook)
            // Read the destination once so appending to a playlist that already has music (a
            // real Crabhands playlist, say) doesn't re-add what's already there.
            existing = try await api.playlistTrackURIs(id: playlistId, pace: paceHook)
        } catch {
            DebugLog.log("new-releases: scan aborted before starting: \(error.localizedDescription)")
            return fail(error.localizedDescription)
        }

        // Resume where an interrupted sweep left off. `followedArtists` returns a stable order,
        // so the cursor stays meaningful across runs; if the artist is gone (unfollowed), start
        // from the top rather than silently scanning nothing.
        //
        // A catch-up run ignores the cursor. The artists before it were swept under the *old*
        // run's narrow window, and completing this one stamps the clock — so honouring the cursor
        // would close the widened window over a prefix that never got the benefit of it, losing
        // exactly the gap catch-up exists to fill. Re-sweeping them is the expensive path, which
        // is what catch-up already is.
        if !catchUp, let resumeId = store.resumeArtistId,
           let index = artists.firstIndex(where: { $0.id == resumeId }) {
            DebugLog.log("new-releases: resuming from \(artists[index].name) (\(index + 1)/\(artists.count))")
            artists = Array(artists[index...])
        }

        let total = artists.count
        var added = 0
        var contributingArtists = 0
        var done = 0

        // Switched off mid-sweep. Park exactly like an interrupted run — cursor kept, clock
        // unstamped — so switching back on continues rather than starting over.
        func stopBecauseDisabled(at artistId: String) {
            let summary = NewReleaseLogic.stoppedLabel(added: added, artistsDone: done,
                                                       artistsTotal: total)
            store.pauseScan(atArtistId: artistId, summary: summary)
            lastSummary = summary
            state = .idle
            DebugLog.log("new-releases: \(summary) (radar switched off mid-scan)")
        }

        for artist in artists {
            // A sweep is minutes of requests, so the toggle can't only be read at the door: a
            // user who switches the radar off is asking it to stop *now*, not to keep adding
            // music to their playlist until it's finished.
            guard settings.newReleasesEnabled else { return stopBecauseDisabled(at: artist.id) }
            state = .running(NewReleaseLogic.progressLabel(artistsDone: done, artistsTotal: total,
                                                           found: added))
            do {
                let sweep = try await newTracks(for: artist, filters: filters,
                                                cutoff: cutoff, horizon: horizon,
                                                watermark: watermark,
                                                dayIndex: dayIndex, catchUp: catchUp)
                let fresh = sweep.tracks.filter {
                    !existing.contains($0.uri) && !store.hasAdded(trackId: $0.id)
                }
                if !fresh.isEmpty {
                    // Checked again here because collecting one artist's tracks is itself many
                    // requests: this is the last moment before a write the user may have just
                    // told us not to make.
                    guard settings.newReleasesEnabled else { return stopBecauseDisabled(at: artist.id) }
                    try await api.addTracks(uris: fresh.map(\.uri), toPlaylist: playlistId,
                                            pace: paceHook)
                    store.markAdded(trackIds: fresh.map(\.id))
                    existing.formUnion(fresh.map(\.uri))
                    added += fresh.count
                    contributingArtists += 1
                    DebugLog.log("new-releases: +\(fresh.count) from \(artist.name) — "
                                 + fresh.map(\.name).joined(separator: ", "))
                }
                // Only now is it safe to cache, or to advance the guest-catalogue cursor past
                // pages whose tracks have landed. Committing either any earlier would mean an
                // interrupted run had already written off the very albums whose music it never
                // got round to adding, and the resumed run would skip them.
                store.markSeen(albumKeys: sweep.consideredAlbumKeys)
                if let crawl = sweep.guestCrawl {
                    store.setGuestCrawl(crawl, forArtist: artist.id)
                }
            } catch {
                // A 429 isn't a failure, it's "come back later" — and any other error partway
                // through has the same shape. Keep the cursor and the tracks already added;
                // `lastScanAt` stays unstamped so the run is still due and resumes from here.
                let summary = NewReleaseLogic.interruptedLabel(
                    added: added, artistsDone: done, artistsTotal: total,
                    reason: error.localizedDescription)
                store.pauseScan(atArtistId: artist.id, summary: summary)
                lastSummary = summary
                DebugLog.log("new-releases: \(summary)")
                return fail(summary)
            }
            done += 1
        }

        let summary = NewReleaseLogic.summaryLabel(added: added, artists: contributingArtists)
        store.finishScan(at: now, summary: summary)
        lastSummary = summary
        lastScanAt = now
        state = .idle
        DebugLog.log("new-releases: scan complete — \(summary) (\(total) artists)")
    }

    /// One artist's sweep: what to add, and the cache keys for every album it settled.
    ///
    /// The two travel together because the caller can only commit the album cache once the
    /// tracks have actually landed — see the call site.
    private struct ArtistSweep {
        let tracks: [CandidateTrack]
        let consideredAlbumKeys: [String]
        /// This artist's advanced guest crawl — `nil` when the guest catalogue wasn't crawled
        /// this run (features off, or not this artist's turn).
        let guestCrawl: NewReleaseLogic.GuestCrawl?
    }

    /// Everything new worth adding for one artist.
    private func newTracks(for artist: FollowedArtist,
                           filters: NewReleaseFilters,
                           cutoff: String,
                           horizon: String,
                           watermark: Date,
                           dayIndex: Int,
                           catchUp: Bool) async throws -> ArtistSweep {
        var candidates: [CandidateAlbum] = []
        var considered: [String] = []
        var advancedCrawl: NewReleaseLogic.GuestCrawl?

        for query in NewReleaseLogic.includeGroupsQueries(filters: filters) {
            // `appears_on` has to be crawled exhaustively (it isn't returned newest-first), so
            // it's swept for a different slice of artists each day to keep the daily cost flat.
            // A catch-up run ignores the rotation: the widened date window would close again
            // before most artists' slots came round, and the gap would go unfilled.
            if query.group == .appearsOn, !catchUp,
               !NewReleaseLogic.shouldDeepScan(artistId: artist.id, dayIndex: dayIndex) { continue }

            // The guest catalogue is crawled a page-cap at a time, resuming where the last turn
            // stopped; every other group is a newest-first listing that always starts at the top.
            //
            // It also gets its own, wider cutoff: a feature can sit unlooked-at for as long as a
            // full traversal takes, which is far longer than the look-back window. See
            // `guestCutoffDay`.
            let crawl = query.group == .appearsOn ? store.guestCrawl(forArtist: artist.id) : nil
            let start = query.group == .appearsOn ? (crawl?.offset ?? 0) : 0
            let queryCutoff = query.group == .appearsOn
                ? NewReleaseLogic.guestCutoffDay(normalCutoff: cutoff, crawl: crawl,
                                                 watermark: watermark)
                : cutoff
            var page = 0
            var itemsOnLastPage = 0
            var lastPageReachedWindow = false
            while NewReleaseLogic.shouldFetchNextPage(pagesFetched: page,
                                                      itemsOnLastPage: itemsOnLastPage,
                                                      lastPageReachedWindow: lastPageReachedWindow,
                                                      exhaustive: query.exhaustive) {
                let albums = try await api.artistAlbums(
                    artistId: artist.id,
                    includeGroups: query.groups,
                    group: query.group,
                    offset: start + page * NewReleaseLogic.albumPageSize)
                await pace()
                itemsOnLastPage = albums.count
                // Whether to page on is a question about dates, not about filters: a full page of
                // already-seen albums or remix packages says nothing about what page two holds.
                lastPageReachedWindow = NewReleaseLogic.pageReachesWindow(albums,
                                                                          cutoffDay: queryCutoff)
                candidates += albums.filter {
                    NewReleaseLogic.albumPasses($0, artistId: artist.id, filters: filters,
                                                seenAlbumKeys: store.seenAlbumKeys,
                                                cutoffDay: queryCutoff, horizonDay: horizon)
                }
                // Only albums whose date can no longer change the verdict: a release announced
                // for next month must stay uncached, or it would be skipped on the very day it
                // becomes eligible.
                considered += albums
                    .filter { NewReleaseLogic.isSettled($0, horizonDay: horizon) }
                    .map { NewReleaseLogic.seenKey(albumId: $0.id, artistId: artist.id) }
                page += 1
            }

            if query.group == .appearsOn {
                advancedCrawl = NewReleaseLogic.advancedGuestCrawl(
                    crawl, now: Date(), pagesFetched: page,
                    reachedEndOfList: itemsOnLastPage < NewReleaseLogic.albumPageSize)
            }
        }

        var tracks: [CandidateTrack] = []
        for album in candidates {
            let albumTracks = try await api.albumTracks(albumId: album.id, pace: paceHook)
            for track in albumTracks {
                // `albumTracks` can't know why it was asked; stamp the provenance here.
                let stamped = CandidateTrack(id: track.id, uri: track.uri, name: track.name,
                                             artistIds: track.artistIds, albumId: track.albumId,
                                             matchedArtistId: artist.id, group: album.group)
                guard NewReleaseLogic.trackMatches(stamped, artistId: artist.id, filters: filters)
                else { continue }
                tracks.append(stamped)
            }
        }

        // Own releases sort ahead of features so the canonical pressing survives dedupe.
        let ordered = tracks.sorted { lhs, rhs in lhs.group == .own && rhs.group == .appearsOn }
        return ArtistSweep(tracks: NewReleaseLogic.dedupe(ordered),
                           consideredAlbumKeys: considered,
                           guestCrawl: advancedCrawl)
    }

    /// Report a stop and hold off retrying for a while. Every exit that isn't a completed sweep
    /// goes through here, so none of them can leave the 1 Hz tick free to restart immediately.
    private func fail(_ message: String) {
        state = .failed(message)
        cooldownUntil = Date().addingTimeInterval(retryCooldown)
    }

    /// `pace()` as something an endpoint that paginates internally can call between its own
    /// pages, so a single `followedArtists()` can't fire off a dozen unthrottled requests.
    private var paceHook: () async -> Void {
        { [weak self] in await self?.pace() }
    }

    /// Called after each request: holds until `requestInterval` has passed before the caller
    /// issues the next one. Cooperative rather than enforced — the point is to stay far enough
    /// under the quota that the app's own polling isn't collateral damage when the radar runs.
    private func pace() async {
        let now = Date()
        if let last = lastRequestAt {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < requestInterval {
                try? await Task.sleep(nanoseconds: UInt64((requestInterval - elapsed) * 1_000_000_000))
            }
        }
        lastRequestAt = Date()
    }
}
