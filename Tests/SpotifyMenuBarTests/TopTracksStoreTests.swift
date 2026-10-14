import XCTest

/// Persistence rules for Top Tracks — above all, who may mint an `OwnedSyncPlaylist`.
///
/// That token is the only thing standing between an unattended job and a playlist the user
/// curated by hand, so every rule about when it exists is pinned here. Each test gets its own
/// temporary directory, so none of this touches the real store.
@MainActor
final class TopTracksStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_787_000_000)   // 2026-08-16T...Z

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TopTracksStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func playlist(_ id: String, name: String = "Top Tracks") -> Playlist {
        Playlist(id: id, name: name, uri: "spotify:playlist:\(id)", ownerId: "me", collaborative: false)
    }

    private func match(_ uri: String) -> TopTracksStore.MatchRecord {
        .init(uri: uri, trackId: String(uri.split(separator: ":").last ?? ""), name: "Song",
              artists: "Artist", score: 0.97, matchedAt: now)
    }

    // MARK: - Ownership

    func testFreshStoreOwnsNothing() {
        let store = TopTracksStore(directory: temporaryDirectory())
        XCTAssertNil(store.ownership(for: .allTime, targetPlaylistId: "p1"))
        XCTAssertNil(store.ownedPlaylistId(for: .allTime))
    }

    /// The token exists for exactly the (period, id) pair that was recorded — not for another
    /// playlist the user later pointed the period at, and not for the same playlist under
    /// another period.
    func testOwnershipIsMintedOnlyForTheRecordedPair() {
        let store = TopTracksStore(directory: temporaryDirectory())
        store.recordCreatedPlaylist(playlist("p1"), for: .sixMonths, now: now)

        let token = store.ownership(for: .sixMonths, targetPlaylistId: "p1")
        XCTAssertEqual(token?.playlistId, "p1")
        XCTAssertEqual(token?.period, .sixMonths)
        XCTAssertEqual(token?.createdAt, now)

        XCTAssertNil(store.ownership(for: .sixMonths, targetPlaylistId: "p2"))
        XCTAssertNil(store.ownership(for: .oneMonth, targetPlaylistId: "p1"))
    }

    func testForgettingOwnershipRevokesTheToken() {
        let store = TopTracksStore(directory: temporaryDirectory())
        store.recordCreatedPlaylist(playlist("p1"), for: .allTime, now: now)
        store.forgetOwnership(for: .allTime, reason: "test")
        XCTAssertNil(store.ownership(for: .allTime, targetPlaylistId: "p1"))
        XCTAssertNil(store.ownedPlaylistId(for: .allTime))
    }

    func testOwnershipSurvivesARelaunch() {
        let dir = temporaryDirectory()
        TopTracksStore(directory: dir).recordCreatedPlaylist(playlist("p1"), for: .oneMonth, now: now)
        XCTAssertNotNil(TopTracksStore(directory: dir).ownership(for: .oneMonth, targetPlaylistId: "p1"))
    }

    // MARK: - Per-period bookkeeping

    /// Retargeting clears that period's "already added" set and its clock — and nothing else.
    func testRetargetingClearsOnlyThatPeriodsBookkeeping() {
        let store = TopTracksStore(directory: temporaryDirectory())
        store.recordCreatedPlaylist(playlist("p1"), for: .allTime, now: now)
        store.setPlaylist("p1", for: .allTime)
        store.setPlaylist("p9", for: .oneMonth)
        store.markAdded(uris: ["u1"], for: .allTime)
        store.markAdded(uris: ["u9"], for: .oneMonth)
        store.finishSync(for: .allTime, at: now, summary: "ok", writtenURIs: ["u1"])

        store.setPlaylist("p2", for: .allTime)

        XCTAssertFalse(store.hasAdded(uri: "u1", for: .allTime))
        XCTAssertNil(store.lastSyncAt(for: .allTime))
        XCTAssertEqual(store.lastWrittenURIs(for: .allTime), [])
        XCTAssertTrue(store.hasAdded(uri: "u9", for: .oneMonth), "other periods are untouched")
        XCTAssertEqual(store.ownedPlaylistId(for: .allTime), "p1", "ownership describes a playlist, not a selection")
        XCTAssertNil(store.ownership(for: .allTime, targetPlaylistId: "p2"), "…and the new target is not it")
    }

    func testSettingTheSamePlaylistIsANoOp() {
        let store = TopTracksStore(directory: temporaryDirectory())
        store.setPlaylist("p1", for: .allTime)
        store.markAdded(uris: ["u1"], for: .allTime)
        store.setPlaylist("p1", for: .allTime)
        XCTAssertTrue(store.hasAdded(uri: "u1", for: .allTime))
    }

    func testFinishPauseAndInvalidate() {
        let store = TopTracksStore(directory: temporaryDirectory())
        store.finishSync(for: .allTime, at: now, summary: "done", writtenURIs: nil)
        XCTAssertEqual(store.lastSyncAt(for: .allTime), now)
        XCTAssertEqual(store.lastSummary(for: .allTime), "done")

        store.pauseSync(for: .allTime, summary: "paused")
        XCTAssertEqual(store.lastSyncAt(for: .allTime), now, "a pause leaves the clock alone")
        XCTAssertEqual(store.lastSummary(for: .allTime), "paused")

        store.invalidateSync(for: .allTime)
        XCTAssertNil(store.lastSyncAt(for: .allTime))
    }

    // MARK: - Match and miss caches

    func testMatchesAndMissesRoundTripThroughDisk() {
        let dir = temporaryDirectory()
        let a = TopTracksStore(directory: dir)
        a.recordMatches(["k1": match("spotify:track:1")])
        a.recordMisses(keys: ["k2"], now: now)
        a.recordMisses(keys: ["k2"], now: now.addingTimeInterval(60))

        let b = TopTracksStore(directory: dir)
        XCTAssertEqual(b.cachedMatch(key: "k1")?.uri, "spotify:track:1")
        XCTAssertEqual(b.cachedMiss(key: "k2")?.attempts, 2)
        XCTAssertEqual(b.cachedMiss(key: "k2")?.lastTriedAt, now.addingTimeInterval(60))
    }

    func testAHitRetiresTheMiss() {
        let store = TopTracksStore(directory: temporaryDirectory())
        store.recordMisses(keys: ["k"], now: now)
        store.recordMatches(["k": match("spotify:track:1")])
        XCTAssertNil(store.cachedMiss(key: "k"))
        XCTAssertNotNil(store.cachedMatch(key: "k"))
    }

    // MARK: - Durability

    /// A file that won't decode is backed up and the store starts empty — which loses the
    /// ownership record. That is the safe direction: Replace becomes Append, never the reverse.
    func testCorruptFileIsBackedUpAndOwnershipIsGone() throws {
        let dir = temporaryDirectory()
        let file = dir.appendingPathComponent("toptracks.json")
        try Data("{not json".utf8).write(to: file)

        let store = TopTracksStore(directory: dir)
        XCTAssertNil(store.ownership(for: .allTime, targetPlaylistId: "p1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("toptracks.json.corrupt").path))
    }

    /// A file from an older build with fewer keys must still decode rather than read as corrupt.
    func testOldSchemaDecodes() throws {
        let dir = temporaryDirectory()
        let file = dir.appendingPathComponent("toptracks.json")
        try Data(#"{"matches":{"k":{"uri":"spotify:track:1","trackId":"1","name":"n","artists":"a","score":1,"matchedAt":0}}}"#.utf8).write(to: file)
        let store = TopTracksStore(directory: dir)
        XCTAssertEqual(store.cachedMatch(key: "k")?.uri, "spotify:track:1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("toptracks.json.corrupt").path))
    }

    /// Two instances sharing one file: the second to save folds in the first's matches rather
    /// than overwriting them.
    func testConcurrentWriterMatchesAreMergedOnSave() {
        let dir = temporaryDirectory()
        let a = TopTracksStore(directory: dir)
        let b = TopTracksStore(directory: dir)
        b.recordMatches(["kb": match("spotify:track:b")])
        a.recordMatches(["ka": match("spotify:track:a")])

        let c = TopTracksStore(directory: dir)
        XCTAssertNotNil(c.cachedMatch(key: "ka"))
        XCTAssertNotNil(c.cachedMatch(key: "kb"))
    }
}
