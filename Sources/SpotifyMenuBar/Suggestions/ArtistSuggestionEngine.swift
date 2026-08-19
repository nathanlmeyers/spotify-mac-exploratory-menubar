import Foundation

/// Builds the "Artists to Follow" list: artists the user demonstrably listens to but has never
/// followed, ranked by how much of their listening they account for.
///
/// The feature only exists in this shape because of what the February 2026 dev-mode migration
/// took away. `/recommendations` and `/artists/{id}/related-artists` are gone, so "artists
/// similar to what you like" is not buildable; `popularity` is gone from every object, so
/// nothing can be ranked by fame. What's left is the user's own listening history, which turns
/// out to be the better answer anyway — a suggestion drawn from songs you already played is one
/// you can check.
///
/// Unlike the release radar this is **not** unattended: it runs when the window is opened or
/// the user presses Refresh, never on a timer. Everything it can reach is a read or an additive
/// write (see `SpotifyWebAPI+Suggestions.swift`) — "Not interested" is local-only and never
/// touches the account.
@MainActor
final class ArtistSuggestionEngine: ObservableObject {

    /// One row in the list: the scoring verdict plus whatever artwork we could find for it.
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let reason: String
        let imageURL: URL?
        let genres: [String]
        /// Set once the user presses Follow. The row stays on screen so the press is visible,
        /// and drops out on the next refresh.
        var isFollowed = false
    }

    enum State: Equatable {
        case idle
        case loading(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var rows: [Row] = []
    @Published private(set) var summary: String?
    @Published private(set) var lastRefreshAt: Date?
    /// The artist the user just dismissed, offered back as an Undo until the next action.
    @Published private(set) var undoable: (id: String, name: String)?

    var isLoading: Bool { if case .loading = state { return true }; return false }

    /// Matches `NewReleaseScanner.requestInterval` (~2 req/s). A refresh is ~40 requests, so it
    /// completes in about twenty seconds while leaving the 1 Hz now-playing poll — which spends
    /// from the same undocumented dev-mode quota — room to keep working.
    private let requestInterval: TimeInterval = 0.5

    private let api: SpotifyWebAPI
    private let auth: SpotifyAuth
    private let store: SuggestedArtistStore

    private var refreshInFlight = false
    private var lastRequestAt: Date?

    /// Every row the last refresh produced, in scored order, *including* ones since dismissed.
    ///
    /// This is what makes Undo free. Without it, restoring an artist would have to re-run the
    /// whole refresh — six top-list reads, the followed set, and up to thirty artist lookups —
    /// to recover one row we already had, which is both a twenty-second wait and forty requests
    /// against an undocumented quota, for a button that should feel instant.
    private var lastEligibleRows: [Row] = []
    /// How many candidates the hydration cap left out of the last refresh, for the footer.
    private var hiddenByCap = 0

    init(api: SpotifyWebAPI, auth: SpotifyAuth, store: SuggestedArtistStore) {
        self.api = api
        self.auth = auth
        self.store = store
        lastRefreshAt = store.lastRefreshAt
    }

    // MARK: - Entry points

    /// Called when the window opens. Cheap local checks only — a refresh inside the staleness
    /// window costs nothing, so opening the window repeatedly doesn't spend quota.
    func refreshIfStale() {
        guard auth.isAuthorized, auth.hasSuggestScopes, !refreshInFlight else { return }
        guard ArtistSuggestionLogic.isStale(lastRefreshAt: store.lastRefreshAt, now: Date()) else { return }
        Task { await refresh() }
    }

    /// The Refresh button. Always re-fetches, so the button can't appear to do nothing.
    func refreshNow() {
        guard !refreshInFlight else { return }
        store.invalidateRefresh()
        lastRefreshAt = nil
        Task { await refresh() }
    }

    // MARK: - The refresh

    private func refresh() async {
        guard !refreshInFlight else { return }
        guard auth.isAuthorized else { state = .failed("Log in to Spotify first."); return }
        guard auth.hasSuggestScopes else {
            state = .failed("Log out and log back in to grant the new permissions.")
            return
        }
        refreshInFlight = true
        defer { refreshInFlight = false }
        undoable = nil

        do {
            state = .loading("Reading your listening history…")
            var artistHits: [TopArtistHit] = []
            var trackCredits: [TopTrackCredit] = []
            // Seeds carry artwork; anyone who only turns up in a track needs hydrating.
            var seeds: [String: ArtistSeed] = [:]

            // Fixed range order so ties resolve the same way on every refresh — the scoring
            // keeps the first-seen best hit, and `allCases` order is stable.
            for range in ArtistTimeRange.allCases {
                let artists = try await api.topArtists(timeRange: range, pace: paceHook)
                for (rank, seed) in artists.enumerated() {
                    seeds[seed.id] = seeds[seed.id] ?? seed
                    artistHits.append(TopArtistHit(artistId: seed.id, name: seed.name,
                                                   rank: rank, range: range))
                }
                trackCredits += try await api.topTracks(timeRange: range, pace: paceHook)
            }

            state = .loading("Checking who you already follow…")
            let following = Set(try await api.followedArtists(pace: paceHook).map(\.id))

            let scored = ArtistSuggestionLogic.score(topArtistHits: artistHits,
                                                    topTrackCredits: trackCredits)
            // Everyone not followed, dismissals included. Keeping the dismissed ones here is
            // what lets Settings restore an artist dismissed in an earlier session and have
            // them reappear immediately — filtered out of `rows` at the end, not before.
            // `followedFromHere` covers the gap between pressing Follow and Spotify's own
            // followed list reflecting it, so someone just followed can't bounce back.
            let notFollowed = ArtistSuggestionLogic.eligible(
                scored: scored,
                following: following.union(store.followedFromHere),
                notInterested: [])

            let now = Date()
            // Hydration is planned over the *visible* candidates only. A dismissed artist
            // shouldn't cost a request to fetch a picture nobody is going to look at; if they're
            // ever restored they draw from cache, or get hydrated on the next refresh.
            let visible = notFollowed.filter { !store.notInterested.contains($0.id) }
            let plan = ArtistSuggestionLogic.hydrationPlan(eligible: visible) { candidate in
                self.artwork(for: candidate.id, seeds: seeds, now: now) == nil
            }

            var fetched: [String: SuggestedArtistStore.CachedArtist] = [:]
            for (index, candidate) in plan.fetch.enumerated() {
                state = .loading(ArtistSuggestionLogic.progressLabel(hydrated: index,
                                                                     total: plan.fetch.count))
                // One artist failing to hydrate costs that row its picture, not the refresh.
                guard let detail = try? await api.artistDetail(id: candidate.id, pace: paceHook)
                else { continue }
                fetched[candidate.id] = SuggestedArtistStore.CachedArtist(
                    name: detail.name, imageURL: detail.imageURL,
                    genres: detail.genres, fetchedAt: now)
            }
            // Seeds already carry artwork, so cache them too: an artist who slips out of the
            // top-50 next month is still drawable from the cache instead of costing a request.
            store.cache(seeds.mapValues {
                SuggestedArtistStore.CachedArtist(name: $0.name, imageURL: $0.imageURL,
                                                  genres: $0.genres, fetchedAt: now)
            })
            store.cache(fetched)

            lastEligibleRows = notFollowed.map { candidate in
                let art = artwork(for: candidate.id, seeds: seeds, now: now)
                return Row(id: candidate.id,
                           name: art?.name ?? candidate.name,
                           reason: candidate.reason,
                           imageURL: art?.imageURL.flatMap(URL.init(string:)),
                           genres: art?.genres ?? [])
            }
            hiddenByCap = plan.skipped
            rebuildRows()
            if plan.skipped > 0 {
                DebugLog.log("suggestions: hydration cap reached — \(plan.skipped) candidates not fetched this refresh")
            }
            DebugLog.log("suggestions: \(rows.count) candidates from \(scored.count) scored artists, \(following.count) already followed")

            store.finishRefresh(at: now)
            lastRefreshAt = now
            state = .idle
        } catch let error as SpotifyWebAPI.APIError {
            // A 429 mid-refresh leaves whatever rows we already had on screen rather than
            // blanking the window — the list is still perfectly usable, just not current.
            state = .failed(Self.message(for: error))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Artwork for a candidate: the top-artists response if they appeared there, otherwise the
    /// cache. `nil` means "needs a hydration request".
    private func artwork(for id: String,
                         seeds: [String: ArtistSeed],
                         now: Date) -> SuggestedArtistStore.CachedArtist? {
        if let seed = seeds[id], seed.imageURL != nil {
            return SuggestedArtistStore.CachedArtist(name: seed.name, imageURL: seed.imageURL,
                                                     genres: seed.genres, fetchedAt: now)
        }
        return store.cachedArtist(id: id, now: now)
    }

    private static func message(for error: SpotifyWebAPI.APIError) -> String {
        switch error {
        case .rateLimited(let retryAfter):
            return "Spotify is rate limiting us — try again in \(Int(retryAfter.rounded()))s."
        case .http(let code, let message):
            return message.isEmpty ? "Spotify returned HTTP \(code)." : message
        }
    }

    // MARK: - Row actions

    /// Follow an artist. The only write in the feature, and it's additive — there is no
    /// unfollow anywhere in this app.
    ///
    /// Optimistic: the row flips immediately and reverts if the call fails, because a Follow
    /// button that waits two seconds to acknowledge a press reads as broken.
    func follow(artistId: String) async {
        guard let index = rows.firstIndex(where: { $0.id == artistId }), !rows[index].isFollowed
        else { return }
        let name = rows[index].name
        rows[index].isFollowed = true
        undoable = nil
        do {
            try await api.followArtist(id: artistId)
            store.markFollowed(artistId: artistId, name: name)
        } catch {
            rows[index].isFollowed = false
            state = .failed("Couldn't follow \(name): \(error.localizedDescription)")
        }
    }

    /// Take an artist out of the pool. **Local only** — nothing is unfollowed and no request is
    /// made. Reversible via `undoDismiss` while the window is open, and via Settings afterwards.
    func dismiss(artistId: String) {
        guard let row = rows.first(where: { $0.id == artistId }) else { return }
        store.dismiss(artistId: artistId, name: row.name)
        undoable = (id: row.id, name: row.name)
        rebuildRows()
    }

    /// Puts a dismissed artist straight back, in their scored position, costing nothing — the
    /// row is still in `lastEligibleRows`.
    func undoDismiss() {
        guard let pending = undoable else { return }
        store.undismiss(artistId: pending.id)
        undoable = nil
        rebuildRows()
    }

    func clearUndo() { undoable = nil }

    /// Re-derive the visible list from the last refresh: drop whoever is dismissed right now,
    /// and carry over any Follow presses made since, so a dismissal doesn't reset the row next
    /// to it back to an un-followed state.
    private func rebuildRows() {
        let followed = Set(rows.filter(\.isFollowed).map(\.id))
        let dismissed = store.notInterested
        rows = lastEligibleRows
            .filter { !dismissed.contains($0.id) }
            .map { row in
                var copy = row
                copy.isFollowed = followed.contains(row.id)
                return copy
            }
        summary = ArtistSuggestionLogic.summaryLabel(shown: rows.count, hidden: hiddenByCap)
    }

    /// Drop everything on screen at logout.
    ///
    /// Only the in-memory list — the dismissal list on disk survives deliberately, so logging
    /// out and back in to the same account doesn't resurrect every artist the user has already
    /// said no to. Artist ids are account-independent, so nothing here leaks between accounts;
    /// what must not persist is the *suggestions*, which are derived from one user's history.
    func reset() {
        rows = []
        lastEligibleRows = []
        hiddenByCap = 0
        summary = nil
        undoable = nil
        state = .idle
    }

    // MARK: - Dismissal management (Settings)

    var dismissedCount: Int { store.notInterested.count }
    func dismissedArtists() -> [(id: String, name: String)] { store.dismissedArtists() }

    /// Restoring from Settings brings the row back for free if we still have the last refresh,
    /// and otherwise just marks the list stale — deliberately *not* an immediate fetch, because
    /// Settings is often open with the suggestions window closed and nothing would show for it.
    func restore(artistId: String) {
        store.undismiss(artistId: artistId)
        restoredFromSettings()
    }

    func restoreAllDismissed() {
        store.clearDismissals()
        restoredFromSettings()
    }

    private func restoredFromSettings() {
        if lastEligibleRows.isEmpty {
            store.invalidateRefresh()
            lastRefreshAt = nil
        } else {
            rebuildRows()
        }
    }

    // MARK: - Pacing

    private var paceHook: () async -> Void {
        { [weak self] in await self?.pace() }
    }

    /// Cooperative throttle between requests, matching the radar's. See `requestInterval`.
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
