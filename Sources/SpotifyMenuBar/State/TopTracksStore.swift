import Foundation

/// Proof that `playlistId` was created by the Top Tracks feature, for `period`, and is still
/// recorded as such in `TopTracksStore`.
///
/// `SpotifyWebAPI.replaceItems(in:…)` — the one call in the app that can drop tracks from a
/// playlist without a `UserRemovalIntent` — requires one. The init is `fileprivate`, so only
/// `TopTracksStore` can mint it, and it only does so when the id the caller wants to write to
/// equals the id it recorded at creation. Nothing can construct one for a playlist the user
/// picked from a list; that is the whole point.
///
/// This deliberately does *not* widen `UserRemovalIntent`. That type still gates every delete
/// and unsave in the app, and nothing in the Top Tracks feature can construct one.
struct OwnedSyncPlaylist {
    let playlistId: String
    let period: TopTracksPeriod
    let createdAt: Date
    fileprivate init(playlistId: String, period: TopTracksPeriod, createdAt: Date) {
        self.playlistId = playlistId
        self.period = period
        self.createdAt = createdAt
    }
}

/// Local persistence (Application Support JSON) for Top Tracks:
///  - the match cache, which is what makes the daily sync nearly free after the first run
///  - the miss cache, so a song Spotify doesn't have isn't searched for every day
///  - per-period bookkeeping: which playlist this feature *created*, what it has added, what it
///    last wrote, and when it last ran
///
/// Its own file for the same reason the radar has one: a decode failure here must not take out
/// the discovery history, and vice versa.
@MainActor
final class TopTracksStore {

    struct MatchRecord: Codable, Equatable {
        var uri: String
        var trackId: String
        var name: String
        var artists: String
        var score: Double
        var matchedAt: Date
    }

    struct MissRecord: Codable, Equatable {
        var lastTriedAt: Date
        var attempts: Int
    }

    private struct PeriodState: Codable {
        /// The current target (mirrors Settings) so the per-playlist sets below can be scoped.
        var playlistId: String?
        /// The playlist this feature created for this period, if it ever did. The only id a
        /// Replace is ever allowed to touch.
        var ownedPlaylistId: String?
        var ownedPlaylistName: String?
        var ownedCreatedAt: Date?
        /// Append mode: tracks this feature put in `playlistId`. One missing from the playlist
        /// was removed by hand and is not re-added.
        var addedURIs: Set<String> = []
        /// Replace mode: the list as last written, for the log line and the summary.
        var lastWrittenURIs: [String] = []
        var lastSyncAt: Date?
        var lastSummary: String?

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            playlistId = try c.decodeIfPresent(String.self, forKey: .playlistId)
            ownedPlaylistId = try c.decodeIfPresent(String.self, forKey: .ownedPlaylistId)
            ownedPlaylistName = try c.decodeIfPresent(String.self, forKey: .ownedPlaylistName)
            ownedCreatedAt = try c.decodeIfPresent(Date.self, forKey: .ownedCreatedAt)
            addedURIs = try c.decodeIfPresent(Set<String>.self, forKey: .addedURIs) ?? []
            lastWrittenURIs = try c.decodeIfPresent([String].self, forKey: .lastWrittenURIs) ?? []
            lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
            lastSummary = try c.decodeIfPresent(String.self, forKey: .lastSummary)
        }
    }

    private struct Store: Codable {
        /// Keyed by `TopTracksLogic.cacheKey`. Shared across periods: "all time" and "6 months"
        /// overlap heavily, and a match is a match whichever list asked.
        var matches: [String: MatchRecord] = [:]
        var misses: [String: MissRecord] = [:]
        /// Keyed by `TopTracksPeriod.rawValue`.
        var periods: [String: PeriodState] = [:]

        init() {}

        /// Every field optional on the way in, so a schema change can't read as corruption —
        /// a failed decode starts empty, which here means losing the ownership record and
        /// silently turning Replace into Append.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            matches = try c.decodeIfPresent([String: MatchRecord].self, forKey: .matches) ?? [:]
            misses = try c.decodeIfPresent([String: MissRecord].self, forKey: .misses) ?? [:]
            periods = try c.decodeIfPresent([String: PeriodState].self, forKey: .periods) ?? [:]
        }

        /// Fold in a copy written by another process. Caches merge keeping the newer entry; a
        /// period's added-set unions when both copies point at the same playlist; every other
        /// scalar stays ours, because this instance is the one still running.
        mutating func formUnion(with other: Store) {
            matches.merge(other.matches) { mine, theirs in mine.matchedAt >= theirs.matchedAt ? mine : theirs }
            misses.merge(other.misses) { mine, theirs in mine.lastTriedAt >= theirs.lastTriedAt ? mine : theirs }
            for (key, theirs) in other.periods {
                guard var mine = periods[key] else { periods[key] = theirs; continue }
                if mine.playlistId == theirs.playlistId {
                    mine.addedURIs.formUnion(theirs.addedURIs)
                }
                periods[key] = mine
            }
        }
    }

    private var store = Store()
    private let fileURL: URL
    private var lastKnownModification: Date?

    /// `directory` exists so tests can point at a temporary one. The app always takes the
    /// default.
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpotifyMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("toptracks.json")
        load()
    }

    // MARK: - Match cache

    func cachedMatch(key: String) -> MatchRecord? { store.matches[key] }
    func cachedMiss(key: String) -> MissRecord? { store.misses[key] }

    var matchCount: Int { store.matches.count }
    var missCount: Int { store.misses.count }

    /// Record hits, one save per batch. A hit retires any miss recorded under the same key.
    func recordMatches(_ records: [String: MatchRecord]) {
        guard !records.isEmpty else { return }
        for (key, record) in records {
            store.matches[key] = record
            store.misses.removeValue(forKey: key)
        }
        save()
    }

    func recordMisses(keys: [String], now: Date) {
        guard !keys.isEmpty else { return }
        for key in keys {
            let attempts = (store.misses[key]?.attempts ?? 0) + 1
            store.misses[key] = MissRecord(lastTriedAt: now, attempts: attempts)
        }
        save()
    }

    // MARK: - Ownership

    /// Record a playlist this feature just created. The only call site is directly after
    /// `SpotifyWebAPI.createPlaylist` in `TopTracksSyncer.createOwnedPlaylist`.
    func recordCreatedPlaylist(_ playlist: Playlist, for period: TopTracksPeriod, now: Date) {
        var state = store.periods[period.rawValue] ?? PeriodState()
        state.ownedPlaylistId = playlist.id
        state.ownedPlaylistName = playlist.name
        state.ownedCreatedAt = now
        store.periods[period.rawValue] = state
        DebugLog.log("top-tracks: created and now own \"\(playlist.name)\" id=\(playlist.id) for \(period.rawValue)")
        save()
    }

    func ownedPlaylistId(for period: TopTracksPeriod) -> String? {
        store.periods[period.rawValue]?.ownedPlaylistId
    }

    /// The Replace authorisation, minted only when `targetPlaylistId` is exactly the playlist
    /// recorded as created for `period`.
    func ownership(for period: TopTracksPeriod, targetPlaylistId: String) -> OwnedSyncPlaylist? {
        guard let state = store.periods[period.rawValue],
              let owned = state.ownedPlaylistId, owned == targetPlaylistId else { return nil }
        return OwnedSyncPlaylist(playlistId: owned, period: period,
                                 createdAt: state.ownedCreatedAt ?? .distantPast)
    }

    /// Drop the ownership record — the playlist is gone from the library, or its marker is.
    /// Replace on this period silently becomes Append until the user creates a new one.
    func forgetOwnership(for period: TopTracksPeriod, reason: String) {
        guard var state = store.periods[period.rawValue], state.ownedPlaylistId != nil else { return }
        DebugLog.log("top-tracks: forgetting ownership of \(state.ownedPlaylistId ?? "?") for \(period.rawValue): \(reason)")
        state.ownedPlaylistId = nil
        state.ownedPlaylistName = nil
        state.ownedCreatedAt = nil
        state.lastWrittenURIs = []
        store.periods[period.rawValue] = state
        save(merging: false)
    }

    // MARK: - Per-period bookkeeping

    /// Point a period at a target. A change starts the per-playlist sets from a clean sheet and
    /// makes the sync due, so the new playlist fills now rather than on the next list change.
    /// Ownership is untouched: it describes a playlist, not a selection.
    func setPlaylist(_ playlistId: String?, for period: TopTracksPeriod) {
        var state = store.periods[period.rawValue] ?? PeriodState()
        guard state.playlistId != playlistId else { return }
        state.playlistId = playlistId
        state.addedURIs = []
        state.lastWrittenURIs = []
        state.lastSyncAt = nil
        store.periods[period.rawValue] = state
        DebugLog.log("top-tracks: \(period.rawValue) target changed to \(playlistId ?? "none"); next sync is due")
        save(merging: false)
    }

    func hasAdded(uri: String, for period: TopTracksPeriod) -> Bool {
        store.periods[period.rawValue]?.addedURIs.contains(uri) ?? false
    }

    func markAdded(uris: [String], for period: TopTracksPeriod) {
        guard !uris.isEmpty else { return }
        var state = store.periods[period.rawValue] ?? PeriodState()
        state.addedURIs.formUnion(uris)
        store.periods[period.rawValue] = state
        save()
    }

    func lastWrittenURIs(for period: TopTracksPeriod) -> [String] {
        store.periods[period.rawValue]?.lastWrittenURIs ?? []
    }

    /// A completed sync: stamp the clock so the next one is a day out. `writtenURIs` is the
    /// Replace list, nil in Append mode.
    func finishSync(for period: TopTracksPeriod, at date: Date, summary: String, writtenURIs: [String]?) {
        var state = store.periods[period.rawValue] ?? PeriodState()
        state.lastSyncAt = date
        state.lastSummary = summary
        if let writtenURIs { state.lastWrittenURIs = writtenURIs }
        store.periods[period.rawValue] = state
        save()
    }

    /// An interrupted sync. The clock is deliberately NOT stamped, so it is still due and runs
    /// again after the syncer's cooldown.
    func pauseSync(for period: TopTracksPeriod, summary: String) {
        var state = store.periods[period.rawValue] ?? PeriodState()
        state.lastSummary = summary
        store.periods[period.rawValue] = state
        save()
    }

    /// Make the period due now — the playlist length changed, so the list is wrong by definition.
    func invalidateSync(for period: TopTracksPeriod) {
        guard var state = store.periods[period.rawValue], state.lastSyncAt != nil else { return }
        state.lastSyncAt = nil
        store.periods[period.rawValue] = state
        save()
    }

    func lastSyncAt(for period: TopTracksPeriod) -> Date? { store.periods[period.rawValue]?.lastSyncAt }
    func lastSummary(for period: TopTracksPeriod) -> String? { store.periods[period.rawValue]?.lastSummary }

    // MARK: - Persistence

    private func load() {
        lastKnownModification = modificationDate()
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            store = try JSONDecoder().decode(Store.self, from: data)
        } catch {
            let backup = fileURL.appendingPathExtension("corrupt")
            try? data.write(to: backup, options: .atomic)
            DebugLog.log("TopTracksStore: could not decode toptracks.json (\(error)); backed up to \(backup.lastPathComponent), starting empty")
        }
    }

    /// See `NewReleaseStore.save(merging:)` — same two-process rule. Clearing operations pass
    /// `false` so a reset can't be undone by a merge.
    private func save(merging: Bool = true) {
        if merging, let onDisk = concurrentlyWrittenStore() { store.formUnion(with: onDisk) }
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: fileURL, options: .atomic)
        lastKnownModification = modificationDate()
    }

    private func concurrentlyWrittenStore() -> Store? {
        guard let current = modificationDate(), current != lastKnownModification,
              let data = try? Data(contentsOf: fileURL),
              let onDisk = try? JSONDecoder().decode(Store.self, from: data)
        else { return nil }
        DebugLog.log("TopTracksStore: toptracks.json changed underneath us; merging before save")
        return onDisk
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }
}
