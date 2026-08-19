import XCTest

/// Persistence rules for the "New From Followed" release radar.
///
/// `NewReleaseLogicTests` covers what the radar decides; this covers what it *remembers*, which
/// is where the quiet failures live. Every rule here is one where getting it backwards costs the
/// user music — or re-adds music they deleted by hand — with nothing on screen to notice:
/// what a rescan keeps, what a destination change throws away, and whether a file written by an
/// older build still decodes rather than being treated as corrupt and started empty.
///
/// Each test gets its own temporary directory, so none of this touches the real store.
@MainActor
final class NewReleaseStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_787_000_000)   // 2026-08-16T...Z

    /// A fresh directory per test, removed afterwards. Created here rather than left to the
    /// store, so a test can write a fixture file into it first.
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewReleaseStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func crawl(offset: Int = 50) -> NewReleaseLogic.GuestCrawl {
        NewReleaseLogic.GuestCrawl(offset: offset,
                                   startedAt: now.addingTimeInterval(-7 * 86_400),
                                   windowFrom: now.addingTimeInterval(-14 * 86_400))
    }

    /// A store holding one of everything, pointed at `playlistId`.
    private func populatedStore(in dir: URL, playlist: String = "p1") -> NewReleaseStore {
        let store = NewReleaseStore(directory: dir)
        store.setPlaylist(playlist)
        store.startWatermarkIfNeeded(now: now)
        store.markSeen(albumKeys: [NewReleaseLogic.seenKey(albumId: "al1", artistId: "art1")])
        store.markAdded(trackIds: ["t1"])
        store.setGuestCrawl(crawl(), forArtist: "art1")
        store.finishScan(at: now, summary: "Added 1 track from 1 artist.")
        return store
    }

    // MARK: - Rescan from scratch

    /// The rule that keeps a rescan from undoing the user: a track missing from the playlist it
    /// was added to was taken out by hand, and clearing this set would post it straight back.
    func testRescanKeepsTheAddedTrackRecord() {
        let store = populatedStore(in: temporaryDirectory())
        store.reset()
        XCTAssertTrue(store.hasAdded(trackId: "t1"))
    }

    /// Restamping the watermark would make the next cutoff today whatever the look-back says —
    /// so a loosened filter would still never surface yesterday's releases.
    func testRescanKeepsTheWatermark() {
        let store = populatedStore(in: temporaryDirectory())
        store.reset()
        XCTAssertEqual(store.watermark(now: now.addingTimeInterval(86_400)), now)
    }

    /// Everything a filter change needs reconsidered does go: the album cache, the guest crawl
    /// cursors, and the clock that would otherwise hold the sweep off for a day.
    func testRescanClearsWhatWouldMaskAFilterChange() {
        let store = populatedStore(in: temporaryDirectory())
        store.reset()
        XCTAssertTrue(store.seenAlbumKeys.isEmpty)
        XCTAssertNil(store.guestCrawl(forArtist: "art1"))
        XCTAssertNil(store.lastScanAt)
        XCTAssertNil(store.resumeArtistId)
        XCTAssertNil(store.lastSummary)
    }

    // MARK: - Changing destination

    /// A new destination starts from a clean sheet. `addedTrackIds` means "already in *that*
    /// playlist"; the seen cache would leave the new one unable to receive anything found before
    /// the switch, since a cached album is never opened again.
    func testChangingDestinationClearsThePerPlaylistState() {
        let store = populatedStore(in: temporaryDirectory())
        store.setPlaylist("p2")
        XCTAssertFalse(store.hasAdded(trackId: "t1"))
        XCTAssertTrue(store.seenAlbumKeys.isEmpty)
        XCTAssertNil(store.guestCrawl(forArtist: "art1"))
        // Unstamped so the backfill sweep is due now rather than tomorrow.
        XCTAssertNil(store.lastScanAt)
    }

    /// The watermark is not per-playlist: switching destination must not pull in back catalogue.
    func testChangingDestinationKeepsTheWatermark() {
        let store = populatedStore(in: temporaryDirectory())
        store.setPlaylist("p2")
        XCTAssertEqual(store.watermark(now: now.addingTimeInterval(86_400)), now)
    }

    /// Re-selecting the playlist already in use must not throw the caches away — a settings pane
    /// that rewrites the same value shouldn't cost a full re-sweep.
    func testRepointingAtTheSamePlaylistChangesNothing() {
        let store = populatedStore(in: temporaryDirectory())
        store.setPlaylist("p1")
        XCTAssertTrue(store.hasAdded(trackId: "t1"))
        XCTAssertFalse(store.seenAlbumKeys.isEmpty)
        XCTAssertEqual(store.lastScanAt, now)
    }

    // MARK: - Scan bookkeeping

    /// An interrupted sweep leaves the clock unstamped on purpose, so the scan stays due and
    /// resumes from the cursor instead of waiting a full day.
    func testPausingKeepsTheScanDueAndRecordsWhereItStopped() {
        let store = NewReleaseStore(directory: temporaryDirectory())
        store.pauseScan(atArtistId: "art9", summary: "Paused.")
        XCTAssertNil(store.lastScanAt)
        XCTAssertEqual(store.resumeArtistId, "art9")
    }

    func testFinishingClearsTheCursorAndStampsTheClock() {
        let store = NewReleaseStore(directory: temporaryDirectory())
        store.pauseScan(atArtistId: "art9", summary: "Paused.")
        store.finishScan(at: now, summary: "Done.")
        XCTAssertNil(store.resumeArtistId)
        XCTAssertEqual(store.lastScanAt, now)
    }

    /// Stamped once and never moved by a later read, or the "nothing older than this" line would
    /// creep forward every scan.
    func testTheWatermarkIsStampedOnlyOnce() {
        let store = NewReleaseStore(directory: temporaryDirectory())
        store.startWatermarkIfNeeded(now: now)
        store.startWatermarkIfNeeded(now: now.addingTimeInterval(86_400))
        XCTAssertEqual(store.watermark(now: now.addingTimeInterval(172_800)), now)
    }

    // MARK: - Across relaunches

    func testEverythingSurvivesARelaunch() {
        let dir = temporaryDirectory()
        _ = populatedStore(in: dir)

        let reopened = NewReleaseStore(directory: dir)
        XCTAssertTrue(reopened.hasAdded(trackId: "t1"))
        XCTAssertEqual(reopened.seenAlbumKeys,
                       [NewReleaseLogic.seenKey(albumId: "al1", artistId: "art1")])
        XCTAssertEqual(reopened.guestCrawl(forArtist: "art1"), crawl())
        XCTAssertEqual(reopened.lastScanAt, now)
        XCTAssertEqual(reopened.watermark(now: now.addingTimeInterval(86_400)), now)
    }

    func testAnAbsentFileIsAFirstRunNotAFailure() {
        let store = NewReleaseStore(directory: temporaryDirectory())
        XCTAssertTrue(store.seenAlbumKeys.isEmpty)
        XCTAssertNil(store.lastScanAt)
    }

    // MARK: - Schema drift

    /// A file written by an older build must still load. A decode failure is treated as
    /// corruption and starts empty — which would cost the added-track record and re-add music the
    /// user has since deleted, so an added or renamed field must never be able to cause one.
    ///
    /// `seenAlbumIds` and `appearsOnOffsets` are real fields from earlier builds of this feature;
    /// their contents are dropped (the keys mean something different now) but everything else
    /// survives, which is the half that matters.
    func testAFileFromAnOlderSchemaStillLoads() {
        let dir = temporaryDirectory()
        let legacy = """
        {"seenAlbumIds":["al1"],"addedTrackIds":["t1","t2"],"appearsOnOffsets":{"art1":50},\
        "watermark":775000000,"lastScanAt":775086400,"playlistId":"p1"}
        """
        try? Data(legacy.utf8).write(to: dir.appendingPathComponent("newreleases.json"))

        let store = NewReleaseStore(directory: dir)
        XCTAssertTrue(store.hasAdded(trackId: "t1"))
        XCTAssertTrue(store.hasAdded(trackId: "t2"))
        XCTAssertEqual(store.lastScanAt, Date(timeIntervalSinceReferenceDate: 775_086_400))
        XCTAssertEqual(store.watermark(now: now), Date(timeIntervalSinceReferenceDate: 775_000_000))
        // Retired keys are ignored rather than misread: the crawl simply starts over.
        XCTAssertTrue(store.seenAlbumKeys.isEmpty)
        XCTAssertNil(store.guestCrawl(forArtist: "art1"))
    }

    /// A future build's extra keys must not fail the decode either.
    func testUnknownFieldsAreIgnored() {
        let dir = temporaryDirectory()
        let ahead = #"{"addedTrackIds":["t1"],"somethingNewer":{"a":1}}"#
        try? Data(ahead.utf8).write(to: dir.appendingPathComponent("newreleases.json"))

        XCTAssertTrue(NewReleaseStore(directory: dir).hasAdded(trackId: "t1"))
    }

    /// Genuinely unreadable is the one case that does start empty — but the file is preserved
    /// first, because the alternative is overwriting the only copy on the next save.
    func testAnUnreadableFileIsBackedUpBeforeStartingEmpty() {
        let dir = temporaryDirectory()
        let file = dir.appendingPathComponent("newreleases.json")
        try? Data("not json at all".utf8).write(to: file)

        let store = NewReleaseStore(directory: dir)
        XCTAssertTrue(store.seenAlbumKeys.isEmpty)

        let backup = dir.appendingPathComponent("newreleases.json.corrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try? String(contentsOf: backup, encoding: .utf8), "not json at all")
    }

    // MARK: - Guest crawl

    /// Wrapping back to the front is stored, not treated as "no record" — the window it carries
    /// is what keeps a late-found feature admissible.
    func testAWrappedCrawlIsStillRecorded() {
        let dir = temporaryDirectory()
        let store = NewReleaseStore(directory: dir)
        let wrapped = NewReleaseLogic.GuestCrawl(offset: 0, startedAt: now, windowFrom: now)
        store.setGuestCrawl(wrapped, forArtist: "art1")

        XCTAssertEqual(NewReleaseStore(directory: dir).guestCrawl(forArtist: "art1"), wrapped)
    }

    func testCrawlsAreIndependentPerArtist() {
        let store = NewReleaseStore(directory: temporaryDirectory())
        store.setGuestCrawl(crawl(offset: 50), forArtist: "art1")
        store.setGuestCrawl(crawl(offset: 250), forArtist: "art2")
        XCTAssertEqual(store.guestCrawl(forArtist: "art1")?.offset, 50)
        XCTAssertEqual(store.guestCrawl(forArtist: "art2")?.offset, 250)
        XCTAssertNil(store.guestCrawl(forArtist: "art3"))
    }
}
