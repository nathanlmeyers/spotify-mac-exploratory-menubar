import Foundation

/// Local persistence (Application Support JSON) for the New From Followed release radar:
///  - `seenAlbumKeys`, the cache that makes repeat scans cheap
///  - `addedTrackIds`, so a track removed from the playlist by hand doesn't come back
///  - the watermark, last-scan stamp, and resume cursor
///
/// Deliberately its own file rather than more keys in `history.json`: that file holds the
/// discovery review history, and a decode failure there costs the reviewed-set. Keeping the
/// radar's much larger, faster-growing state separate means a schema change on one side can't
/// take out the other.
@MainActor
final class NewReleaseStore {
    private struct Store: Codable {
        /// Every settled album ever *considered*, including rejected ones — re-rejecting for
        /// free is the point. Keyed per artist (`NewReleaseLogic.seenKey`), because an album
        /// considered for one followed artist says nothing about another's tracks on it.
        var seenAlbumKeys: Set<String> = []
        /// Track ids already appended to the destination playlist.
        var addedTrackIds: Set<String> = []
        /// Per-artist state for the `appears_on` crawl: where the next turn resumes, and how far
        /// back that artist's guest releases must still be admitted from. See
        /// `NewReleaseLogic.GuestCrawl`.
        var guestCrawls: [String: NewReleaseLogic.GuestCrawl] = [:]
        /// Stamped when the radar is switched on. Nothing released before it is ever added,
        /// which is what keeps the first run from sweeping in the whole back catalogue.
        var watermark: Date?
        var lastScanAt: Date?
        /// Artist id to resume from when a scan was interrupted (429 / quota / quit).
        var resumeArtistId: String?
        var lastSummary: String?
        /// Destination playlist the ids above refer to. Changing playlists must not carry the
        /// "already added" set across, or the new playlist would start out mostly empty and
        /// stay that way.
        var playlistId: String?

        init() {}

        /// Every field is optional on the way in, so adding one (or renaming one, as
        /// `seenAlbumIds` → `seenAlbumKeys` was) can't fail the decode. It matters here: a
        /// failed decode is treated as corruption and starts empty, which would cost the
        /// already-added set and re-add music the user has since deleted by hand.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            seenAlbumKeys = try c.decodeIfPresent(Set<String>.self, forKey: .seenAlbumKeys) ?? []
            addedTrackIds = try c.decodeIfPresent(Set<String>.self, forKey: .addedTrackIds) ?? []
            guestCrawls = try c.decodeIfPresent([String: NewReleaseLogic.GuestCrawl].self,
                                                forKey: .guestCrawls) ?? [:]
            watermark = try c.decodeIfPresent(Date.self, forKey: .watermark)
            lastScanAt = try c.decodeIfPresent(Date.self, forKey: .lastScanAt)
            resumeArtistId = try c.decodeIfPresent(String.self, forKey: .resumeArtistId)
            lastSummary = try c.decodeIfPresent(String.self, forKey: .lastSummary)
            playlistId = try c.decodeIfPresent(String.self, forKey: .playlistId)
        }
    }

    private var store = Store()
    private let fileURL: URL

    /// `directory` exists so tests can point at a temporary one. The app always takes the
    /// default: these rules are subtle enough to be worth testing, and a suite that wrote to the
    /// real Application Support would clobber the user's own radar state to do it.
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpotifyMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("newreleases.json")
        load()
    }

    // MARK: Watermark

    /// The date before which nothing is ever added. Normally stamped when the radar is switched
    /// on; stamping here too is the fallback for a radar that was already on before there was
    /// anything to stamp it.
    func watermark(now: Date) -> Date {
        startWatermarkIfNeeded(now: now)
        return store.watermark ?? now
    }

    /// Stamp the watermark the moment the radar is switched on, rather than waiting for the
    /// first scan to stamp it lazily.
    ///
    /// The two can be days apart — enabling is often followed by logging in again for the follow
    /// scopes, or by picking a destination playlist — and everything released in between would
    /// otherwise land before the watermark and be silently skipped.
    func startWatermarkIfNeeded(now: Date) {
        guard store.watermark == nil else { return }
        store.watermark = now
        save()
    }

    // MARK: Album cache

    var seenAlbumKeys: Set<String> { store.seenAlbumKeys }

    /// Records albums as considered, by `NewReleaseLogic.seenKey`. Saved once per batch rather
    /// than per album: a scan walks thousands of these and a write per album would rewrite the
    /// whole file each time.
    func markSeen(albumKeys: [String]) {
        guard !albumKeys.isEmpty else { return }
        store.seenAlbumKeys.formUnion(albumKeys)
        save()
    }

    // MARK: `appears_on` crawl

    /// This artist's guest-catalogue crawl, or `nil` if it has never been crawled.
    func guestCrawl(forArtist artistId: String) -> NewReleaseLogic.GuestCrawl? {
        store.guestCrawls[artistId]
    }

    /// Written only once the artist's sweep has actually landed, for the same reason as
    /// `markSeen`: advancing the cursor past pages whose tracks were never added would step over
    /// them for a whole traversal.
    func setGuestCrawl(_ crawl: NewReleaseLogic.GuestCrawl, forArtist artistId: String) {
        guard store.guestCrawls[artistId] != crawl else { return }
        store.guestCrawls[artistId] = crawl
        save()
    }

    // MARK: Added tracks

    func hasAdded(trackId: String) -> Bool { store.addedTrackIds.contains(trackId) }

    func markAdded(trackIds: [String]) {
        guard !trackIds.isEmpty else { return }
        store.addedTrackIds.formUnion(trackIds)
        save()
    }

    // MARK: Scan bookkeeping

    var lastScanAt: Date? { store.lastScanAt }
    var lastSummary: String? { store.lastSummary }
    var resumeArtistId: String? { store.resumeArtistId }

    /// A completed sweep: clear the cursor and stamp the clock so the next one is a day out.
    func finishScan(at date: Date, summary: String) {
        store.lastScanAt = date
        store.lastSummary = summary
        store.resumeArtistId = nil
        save()
    }

    /// An interrupted sweep. `lastScanAt` is deliberately NOT stamped, so the scan is still due
    /// and resumes from `artistId` rather than waiting a full day to try again.
    func pauseScan(atArtistId artistId: String?, summary: String) {
        store.resumeArtistId = artistId
        store.lastSummary = summary
        save()
    }

    // MARK: Destination changes

    /// Point the store at a destination playlist, starting the new one from a clean sheet if it
    /// changed.
    ///
    /// `addedTrackIds` means "already in *that* playlist", so it can't carry across — and neither
    /// can `seenAlbumKeys`, for the same reason one step removed: an album already marked seen is
    /// never opened again, so keeping the cache would leave the new destination unable to receive
    /// anything found before the switch. Clearing both (and the scan clock, so the sweep is due
    /// now) is what fills the new playlist with the current window instead of leaving it empty
    /// until the next brand-new release. The watermark still bounds how far back that reaches.
    func setPlaylist(_ playlistId: String?) {
        guard store.playlistId != playlistId else { return }
        store.playlistId = playlistId
        store.seenAlbumKeys = []
        store.addedTrackIds = []
        store.guestCrawls = [:]
        store.lastScanAt = nil
        store.resumeArtistId = nil
        DebugLog.log("new-releases: destination changed to \(playlistId ?? "none"); cleared caches, next scan is due")
        save()
    }

    /// Wipe the album caches — the "rescan from scratch" affordance behind the filter controls,
    /// so changing a filter can actually be observed.
    ///
    /// Two things deliberately survive:
    ///
    ///  - **The watermark.** Restamping it to now would make the very next cutoff today whatever
    ///    the look-back says, so a user who loosens a filter and rescans would still never see
    ///    yesterday's releases — the one thing this button exists to do. Reaching back is already
    ///    bounded by the look-back window.
    ///  - **`addedTrackIds`.** It's the record of what this radar has already put in *this*
    ///    playlist, and a track missing from a playlist it was added to means the user took it
    ///    out by hand. Clearing it would make a rescan post it straight back — the same
    ///    "it undid what I did" the rest of the app goes out of its way to avoid.
    func reset() {
        store.seenAlbumKeys = []
        store.guestCrawls = [:]
        store.lastScanAt = nil
        store.resumeArtistId = nil
        store.lastSummary = nil
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
            // Preserve it before any save() overwrites it with the empty default.
            let backup = fileURL.appendingPathExtension("corrupt")
            try? data.write(to: backup, options: .atomic)
            DebugLog.log("NewReleaseStore: could not decode newreleases.json (\(error)); backed up to \(backup.lastPathComponent), starting empty")
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
