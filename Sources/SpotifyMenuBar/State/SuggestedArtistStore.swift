import Foundation

/// Local persistence (Application Support JSON) for the "Artists to Follow" suggestion list:
///  - `notInterested`, the artists the user has dismissed
///  - `followedFromHere`, so a followed artist stays visible for the session and is never
///    re-suggested even if the followed-artists read is briefly unavailable
///  - `artistCache`, so artwork survives a relaunch instead of costing a request per artist
///
/// Deliberately its own file rather than more keys in `newreleases.json` or `history.json`,
/// for the reason `NewReleaseStore` gives: a decode failure is treated as corruption and
/// starts empty, so sharing a file means a schema change on one feature can silently wipe
/// another's state. Here that would mean every dismissed artist coming back.
@MainActor
final class SuggestedArtistStore {

    /// What we know about an artist without asking the API again.
    ///
    /// `popularity` and `followers` were removed from the artist object in February 2026, and
    /// the batch `GET /artists?ids=` endpoint with them — so this is one request per artist to
    /// fill, which is exactly why it's cached rather than re-fetched each time the window opens.
    struct CachedArtist: Codable, Equatable {
        var name: String
        var imageURL: String?
        var genres: [String] = []
        var fetchedAt: Date

        init(name: String, imageURL: String?, genres: [String] = [], fetchedAt: Date) {
            self.name = name
            self.imageURL = imageURL
            self.genres = genres
            self.fetchedAt = fetchedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
            genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
            fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast
        }
    }

    private struct Store: Codable {
        /// Artists the user pressed "Not interested" on. **Local only** — dismissing someone
        /// here never touches the Spotify account, it just takes them out of this list.
        var notInterested: Set<String> = []
        /// Artists followed through this window. The followed-artists read already excludes
        /// them on the next refresh; this is the belt-and-braces copy so a failed or rate-limited
        /// read can't resurrect someone the user just followed.
        var followedFromHere: Set<String> = []
        var artistCache: [String: CachedArtist] = [:]
        var lastRefreshAt: Date?

        init() {}

        /// Every field optional on the way in, so adding one later can't fail the decode and
        /// throw away the dismissal list — the one piece of state here the user actually
        /// authored by hand.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            notInterested = try c.decodeIfPresent(Set<String>.self, forKey: .notInterested) ?? []
            followedFromHere = try c.decodeIfPresent(Set<String>.self, forKey: .followedFromHere) ?? []
            artistCache = try c.decodeIfPresent([String: CachedArtist].self, forKey: .artistCache) ?? [:]
            lastRefreshAt = try c.decodeIfPresent(Date.self, forKey: .lastRefreshAt)
        }
    }

    /// Artwork URLs go stale when an artist changes their picture; a month is long enough that
    /// the cache still saves nearly every request and short enough that a stale image corrects
    /// itself without any "clear cache" affordance.
    static let cacheLifetime: TimeInterval = 30 * 24 * 60 * 60

    private var store = Store()
    private let fileURL: URL

    /// `directory` exists so tests can point at a temporary one — a suite that wrote to the real
    /// Application Support would clobber the user's own dismissal list to do it.
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpotifyMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("suggestions.json")
        load()
    }

    // MARK: Dismissals

    var notInterested: Set<String> { store.notInterested }

    /// Dismissing is local and reversible. Nothing is unfollowed, nothing is deleted, and no
    /// request is made — see `undismiss` and `clearDismissals` for the ways back.
    func dismiss(artistId: String, name: String) {
        guard store.notInterested.insert(artistId).inserted else { return }
        DebugLog.log("suggestions: not interested in \(name) (\(artistId)) — local only, nothing unfollowed")
        save()
    }

    func undismiss(artistId: String) {
        guard store.notInterested.remove(artistId) != nil else { return }
        DebugLog.log("suggestions: restored \(artistId) to the pool")
        save()
    }

    func clearDismissals() {
        guard !store.notInterested.isEmpty else { return }
        DebugLog.log("suggestions: restored all \(store.notInterested.count) dismissed artists")
        store.notInterested = []
        save()
    }

    /// The dismissed artists, with whatever names the cache still knows, for the Settings list.
    /// Sorted by name so the list doesn't reshuffle between openings.
    func dismissedArtists() -> [(id: String, name: String)] {
        store.notInterested
            .map { (id: $0, name: store.artistCache[$0]?.name ?? $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Follows

    var followedFromHere: Set<String> { store.followedFromHere }

    func markFollowed(artistId: String, name: String) {
        guard store.followedFromHere.insert(artistId).inserted else { return }
        DebugLog.log("suggestions: followed \(name) (\(artistId))")
        save()
    }

    // MARK: Artist cache

    /// A cached artist, or `nil` when absent or too old to trust.
    func cachedArtist(id: String, now: Date) -> CachedArtist? {
        guard let entry = store.artistCache[id] else { return nil }
        guard now.timeIntervalSince(entry.fetchedAt) < Self.cacheLifetime else { return nil }
        return entry
    }

    /// Written in one batch per refresh rather than per artist: `save()` rewrites the whole
    /// file, and a refresh hydrates up to `ArtistSuggestionLogic.hydrationCap` artists.
    func cache(_ artists: [String: CachedArtist]) {
        guard !artists.isEmpty else { return }
        store.artistCache.merge(artists) { _, new in new }
        save()
    }

    // MARK: Refresh bookkeeping

    var lastRefreshAt: Date? { store.lastRefreshAt }

    func finishRefresh(at date: Date) {
        store.lastRefreshAt = date
        save()
    }

    /// Force the next window-open to re-fetch — used by the manual Refresh button so it can't
    /// no-op against the staleness window.
    func invalidateRefresh() {
        store.lastRefreshAt = nil
        save()
    }

    // MARK: Persistence

    private func load() {
        // File absent → legitimate first run; start empty.
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            store = try JSONDecoder().decode(Store.self, from: data)
        } catch {
            // File exists but is unreadable (corrupt / partial write / schema change).
            // Preserve it before any save() overwrites it with the empty default — the
            // dismissal list is user-authored and has no other copy.
            let backup = fileURL.appendingPathExtension("corrupt")
            try? data.write(to: backup, options: .atomic)
            DebugLog.log("SuggestedArtistStore: could not decode suggestions.json (\(error)); backed up to \(backup.lastPathComponent), starting empty")
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
