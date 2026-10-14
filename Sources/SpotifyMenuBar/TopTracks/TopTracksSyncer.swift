import Foundation

/// Keeps up to three playlists in step with the user's most played songs on last.fm.
///
/// This is the app's replacement for a paid listening-history sync service. It runs unattended
/// on the same daily cadence as the release radar and borrows its shape wholesale: cheap checks
/// on the 1 Hz tick, a paced request loop, a cooldown after a failure, and a re-check of the
/// enable toggle before every write.
///
/// Two things are different from the radar, and both are deliberate:
///
///  - **It matches by search.** last.fm knows artist and title, not Spotify ids, so every row
///    costs a `GET /search` the first time it's seen. The match and miss caches in
///    `TopTracksStore` make every later run almost free.
///  - **It can remove — but only from a playlist it made.** Replace mode rewrites the playlist
///    to mirror the top list. That is gated by `OwnedSyncPlaylist` (see `TopTracksStore`) and
///    `SpotifyWebAPI.replaceItems`; a playlist the user picked from the list is append-only no
///    matter what the mode says.
@MainActor
final class TopTracksSyncer: ObservableObject {

    enum State: Equatable {
        case idle
        case running(String)
        case failed(String)
    }

    struct PeriodStatus: Equatable {
        var lastSummary: String?
        var lastSyncAt: Date?
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var status: [TopTracksPeriod: PeriodStatus] = [:]

    var isRunning: Bool { if case .running = state { return true }; return false }
    var hasLastFMKey: Bool { lastFM.hasAPIKey }

    /// Matches `NewReleaseScanner.requestInterval`. A first run is ~100 searches per period;
    /// at 2 req/s that's under a minute and leaves the now-playing poll room to keep working.
    private let requestInterval: TimeInterval = 0.5
    /// After a failure, how long before the tick may try again (see the radar for why).
    private let retryCooldown: TimeInterval = 5 * 60

    private let api: SpotifyWebAPI
    private let lastFM: LastFMClient
    private let auth: SpotifyAuth
    private let settings: Settings
    private let store: TopTracksStore
    /// True while another daily job (the radar) is spending from the same quota; we wait.
    private let yieldWhile: () -> Bool

    private var syncInFlight = false
    private var lastRequestAt: Date?
    private var cooldownUntil: Date?

    private enum SyncError: LocalizedError {
        case playlistGone(String)
        case switchedOff

        var errorDescription: String? {
            switch self {
            case .playlistGone(let name):
                return "“\(name)” is no longer in your library. Pick another playlist or press Create."
            case .switchedOff:
                return "Switched off."
            }
        }
    }

    init(api: SpotifyWebAPI, lastFM: LastFMClient, auth: SpotifyAuth, settings: Settings,
         store: TopTracksStore, yieldWhile: @escaping () -> Bool) {
        self.api = api
        self.lastFM = lastFM
        self.auth = auth
        self.settings = settings
        self.store = store
        self.yieldWhile = yieldWhile
        for period in TopTracksPeriod.allCases {
            status[period] = PeriodStatus(lastSummary: store.lastSummary(for: period),
                                          lastSyncAt: store.lastSyncAt(for: period))
        }
    }

    // MARK: - Entry points

    /// Called from the app's 1 Hz tick. Everything here is a local check.
    func syncIfDue(now: Date = Date()) {
        guard !syncInFlight, auth.isAuthorized else { return }
        guard lastFM.hasAPIKey, !username.isEmpty else { return }
        if let until = cooldownUntil, now < until { return }
        guard !yieldWhile() else { return }
        guard !duePeriods(now: now).isEmpty else { return }
        Task { await sync(now: now, force: false) }
    }

    /// The Settings "Sync now" button: every enabled period, due or not.
    func syncNow() {
        guard !syncInFlight else { return }
        cooldownUntil = nil
        Task { await sync(now: Date(), force: true) }
    }

    /// Create this period's playlist and record that we own it — the single place ownership is
    /// ever granted.
    func createOwnedPlaylist(for period: TopTracksPeriod) async throws -> Playlist {
        let limit = TopTracksLogic.clampedLimit(settings.topTracksLimit)
        let playlist = try await api.createPlaylist(
            name: period.defaultPlaylistName,
            description: TopTracksLogic.playlistDescription(period: period, limit: limit))
        store.recordCreatedPlaylist(playlist, for: period, now: Date())
        return playlist
    }

    /// Whether the period's current target is the playlist this feature created for it.
    func targetIsOwned(_ period: TopTracksPeriod) -> Bool {
        guard let id = settings.topTracks(period).playlistId else { return false }
        return store.ownership(for: period, targetPlaylistId: id) != nil
    }

    // MARK: - The sync

    private var username: String {
        settings.topTracksLastFMUser.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func enabledPeriods() -> [TopTracksPeriod] {
        TopTracksPeriod.allCases.filter {
            let s = settings.topTracks($0)
            return s.enabled && s.playlistId != nil
        }
    }

    private func duePeriods(now: Date) -> [TopTracksPeriod] {
        enabledPeriods().filter { TopTracksLogic.isSyncDue(lastSyncAt: store.lastSyncAt(for: $0), now: now) }
    }

    private func sync(now: Date, force: Bool) async {
        guard !syncInFlight else { return }
        syncInFlight = true
        defer { syncInFlight = false }

        guard auth.isAuthorized else { return fail("Log in to Spotify first.") }
        guard lastFM.hasAPIKey else { return fail(LastFMClient.LastFMError.missingAPIKey.localizedDescription) }
        let user = username
        guard !user.isEmpty else { return fail("Enter your last.fm username first.") }
        let periods = force ? enabledPeriods() : duePeriods(now: now)
        guard !periods.isEmpty else {
            if force { return fail("Turn on at least one period and pick a playlist for it.") }
            return
        }

        state = .running("Reading your playlists…")
        DebugLog.log("top-tracks: sync starting for \(periods.map(\.rawValue).joined(separator: ",")) as last.fm user \(user)")

        // Library membership is the reliable "the user deleted it" check: Spotify's delete is
        // an unfollow, and the id itself can keep resolving long after it left the sidebar.
        let me: String
        let myPlaylistIds: Set<String>
        do {
            me = try await api.currentUserId()
            await pace()
            myPlaylistIds = Set(try await api.allPlaylists().map(\.id))
            await pace()
        } catch {
            DebugLog.log("top-tracks: sync aborted before starting: \(error.localizedDescription)")
            return fail(error.localizedDescription)
        }

        for period in periods {
            let config = settings.topTracks(period)
            guard config.enabled, let playlistId = config.playlistId else { continue }
            do {
                let summary = try await syncPeriod(period, playlistId: playlistId,
                                                   playlistName: config.playlistName ?? period.label,
                                                   user: user, now: now,
                                                   myPlaylistIds: myPlaylistIds, me: me)
                status[period] = PeriodStatus(lastSummary: summary, lastSyncAt: now)
            } catch SyncError.switchedOff {
                // The user asked it to stop; no cooldown, nothing to report.
                let summary = "Stopped."
                store.pauseSync(for: period, summary: summary)
                status[period]?.lastSummary = summary
                state = .idle
                DebugLog.log("top-tracks: \(period.rawValue) switched off mid-sync")
                return
            } catch {
                // A 429 isn't a failure, it's "come back later" — the clock stays unstamped so
                // the period is still due, and the match cache keeps whatever was resolved.
                let summary = TopTracksLogic.interruptedLabel(reason: error.localizedDescription)
                store.pauseSync(for: period, summary: summary)
                status[period]?.lastSummary = summary
                DebugLog.log("top-tracks: \(period.rawValue) \(summary)")
                return fail(summary)
            }
        }
        state = .idle
        DebugLog.log("top-tracks: sync complete")
    }

    /// One period, start to finish. Returns the summary for Settings.
    private func syncPeriod(_ period: TopTracksPeriod, playlistId: String, playlistName: String,
                            user: String, now: Date,
                            myPlaylistIds: Set<String>, me: String) async throws -> String {
        guard myPlaylistIds.contains(playlistId) else {
            // Clear the target rather than re-creating: re-making a playlist the user just
            // deleted is the "it undid what I did" the rest of the app avoids.
            store.forgetOwnership(for: period, reason: "not in the library any more")
            settings.updateTopTracks(period) { $0.playlistId = nil; $0.playlistName = nil; $0.mode = .append }
            throw SyncError.playlistGone(playlistName)
        }

        state = .running("\(period.label): reading last.fm…")
        let limit = TopTracksLogic.clampedLimit(settings.topTracksLimit)
        let tracks = try await lastFM.topTracks(user: user, period: period, limit: limit)
        DebugLog.log("top-tracks: \(period.rawValue) last.fm returned \(tracks.count) rows")

        let resolution = try await resolve(tracks, period: period, now: now)
        let ranked = TopTracksLogic.dedupedRankOrder(resolution.uris)

        let requested = settings.topTracks(period).mode
        let shared = TopTracksPeriod.allCases.contains {
            $0 != period && settings.topTracks($0).enabled && settings.topTracks($0).playlistId == playlistId
        }
        let ownership = store.ownership(for: period, targetPlaylistId: playlistId)
        let mode = TopTracksLogic.effectiveMode(requested: requested,
                                                targetIsOwned: ownership != nil,
                                                targetSharedWithAnotherPeriod: shared)

        var summary: String
        switch mode {
        case .append:
            state = .running("\(period.label): reading the playlist…")
            let existing = try await api.playlistTrackURIs(id: playlistId, pace: paceHook)
            let plan = TopTracksLogic.appendPlan(ranked: ranked, existing: existing) {
                store.hasAdded(uri: $0, for: period)
            }
            // The last moment before a write the user may just have told us not to make.
            guard settings.topTracks(period).enabled else { throw SyncError.switchedOff }
            if !plan.isEmpty {
                try await api.addTracks(uris: plan, toPlaylist: playlistId, pace: paceHook)
                store.markAdded(uris: plan, for: period)
            }
            summary = TopTracksLogic.appendSummary(added: plan.count, missed: resolution.missed)
            store.finishSync(for: period, at: now, summary: summary, writtenURIs: nil)

        case .replace:
            guard let ownership else { throw SyncError.switchedOff }   // unreachable: effectiveMode checked it
            state = .running("\(period.label): reading the playlist…")
            let current = try await api.playlistTrackURIList(id: playlistId, pace: paceHook)
            if let plan = TopTracksLogic.replacePlan(ranked: ranked, current: current) {
                guard settings.topTracks(period).enabled else { throw SyncError.switchedOff }
                do {
                    try await api.replaceItems(in: ownership, uris: plan, currentUserId: me, pace: paceHook)
                } catch let refusal as SpotifyWebAPI.ReplaceRefusal {
                    // The playlist is no longer provably ours: drop the record and the mode so
                    // the next run appends, and say why.
                    if refusal != .emptyList {
                        store.forgetOwnership(for: period, reason: refusal.localizedDescription)
                        settings.updateTopTracks(period) { $0.mode = .append }
                    }
                    throw refusal
                }
                let added = Set(plan).subtracting(current).count
                let dropped = Set(current).subtracting(plan).count
                summary = TopTracksLogic.replaceSummary(total: plan.count, added: added, dropped: dropped,
                                                        unchanged: false, missed: resolution.missed)
                store.finishSync(for: period, at: now, summary: summary, writtenURIs: plan)
            } else {
                summary = TopTracksLogic.replaceSummary(total: current.count, added: 0, dropped: 0,
                                                        unchanged: true, missed: resolution.missed)
                store.finishSync(for: period, at: now, summary: summary, writtenURIs: current)
            }
        }

        if requested == .replace, mode == .append {
            summary += shared
                ? " Appending only: another period uses this playlist."
                : " Appending only: this playlist wasn't created by the app."
        }
        DebugLog.log("top-tracks: \(period.rawValue) [\(mode.rawValue)] \(summary)")
        return summary
    }

    // MARK: - Matching

    private struct Resolution {
        var uris: [String] = []
        var missed = 0
        var searched = 0
    }

    /// Turn last.fm rows into Spotify URIs, in rank order, consulting the caches first.
    ///
    /// Progress is committed to the store on the way out — including the error path — so a
    /// run cut short by a 429 doesn't pay for the same searches again.
    private func resolve(_ tracks: [LastFMTopTrack], period: TopTracksPeriod, now: Date)
        async throws -> Resolution {
        var result = Resolution()
        var newMatches: [String: TopTracksStore.MatchRecord] = [:]
        var newMisses: [String] = []
        func commit() {
            store.recordMatches(newMatches)
            store.recordMisses(keys: newMisses, now: now)
        }

        do {
            for (index, track) in tracks.enumerated() {
                state = .running(TopTracksLogic.progressLabel(period: period, resolved: index,
                                                              total: tracks.count))
                let key = TopTracksLogic.cacheKey(artist: track.artist, title: track.name)
                if let cached = store.cachedMatch(key: key) {
                    result.uris.append(cached.uri)
                    continue
                }
                if let miss = store.cachedMiss(key: key),
                   !TopTracksLogic.shouldRetryMiss(lastTriedAt: miss.lastTriedAt, now: now) {
                    result.missed += 1
                    continue
                }

                var found: TrackMatch?
                for query in TopTracksLogic.searchQueries(for: track) {
                    let hits = try await api.searchTracks(query: query, pace: paceHook)
                    result.searched += 1
                    if let match = TopTracksLogic.bestMatch(hits, for: track) { found = match; break }
                }
                if let match = found {
                    result.uris.append(match.hit.uri)
                    newMatches[key] = .init(uri: match.hit.uri, trackId: match.hit.id,
                                            name: match.hit.name,
                                            artists: match.hit.artistNames.joined(separator: ", "),
                                            score: match.score, matchedAt: now)
                    DebugLog.log(String(format: "top-tracks: matched \"%@\" — %@ → \"%@\" — %@ (%.2f)",
                                        track.name, track.artist, match.hit.name,
                                        match.hit.artistNames.joined(separator: ", "), match.score))
                } else {
                    result.missed += 1
                    newMisses.append(key)
                    DebugLog.log("top-tracks: no match for \"\(track.name)\" — \(track.artist)")
                }
            }
        } catch {
            commit()
            throw error
        }
        commit()
        DebugLog.log("top-tracks: \(period.rawValue) resolved \(result.uris.count) of \(tracks.count) "
                     + "(\(result.searched) searches, \(result.missed) missed)")
        return result
    }

    // MARK: - Pacing and failure

    private func fail(_ message: String) {
        state = .failed(message)
        cooldownUntil = Date().addingTimeInterval(retryCooldown)
    }

    private var paceHook: () async -> Void {
        { [weak self] in await self?.pace() }
    }

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
