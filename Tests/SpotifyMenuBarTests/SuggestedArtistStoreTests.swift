import XCTest

/// Persistence rules for the "Artists to Follow" suggestion list.
///
/// `ArtistSuggestionLogicTests` covers what the feature decides; this covers what it
/// *remembers*. The stakes are asymmetric: the artist cache is a convenience that costs one
/// request per artist to rebuild, but `notInterested` is user-authored, has no copy anywhere
/// else, and losing it means every dismissed artist silently reappearing. So the rules that
/// matter most here are the ones about surviving a bad file.
///
/// Each test gets its own temporary directory, so none of this touches the real store.
@MainActor
final class SuggestedArtistStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SuggestedArtistStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func artist(_ name: String, image: String? = "https://img/\(UUID().uuidString)") -> SuggestedArtistStore.CachedArtist {
        SuggestedArtistStore.CachedArtist(name: name, imageURL: image,
                                          genres: ["shoegaze"], fetchedAt: now)
    }

    // MARK: - Dismissals

    func testDismissalSurvivesAReload() {
        let dir = temporaryDirectory()
        SuggestedArtistStore(directory: dir).dismiss(artistId: "a1", name: "Slowdive")
        XCTAssertEqual(SuggestedArtistStore(directory: dir).notInterested, ["a1"])
    }

    func testDismissalIsReversible() {
        let store = SuggestedArtistStore(directory: temporaryDirectory())
        store.dismiss(artistId: "a1", name: "Slowdive")
        store.undismiss(artistId: "a1")
        XCTAssertTrue(store.notInterested.isEmpty)
    }

    func testClearDismissalsRestoresEveryone() {
        let store = SuggestedArtistStore(directory: temporaryDirectory())
        store.dismiss(artistId: "a1", name: "One")
        store.dismiss(artistId: "a2", name: "Two")
        store.clearDismissals()
        XCTAssertTrue(store.notInterested.isEmpty)
    }

    func testDismissingTwiceIsIdempotent() {
        let store = SuggestedArtistStore(directory: temporaryDirectory())
        store.dismiss(artistId: "a1", name: "One")
        store.dismiss(artistId: "a1", name: "One")
        XCTAssertEqual(store.notInterested, ["a1"])
    }

    func testUndismissingSomeoneWhoWasNeverDismissedIsHarmless() {
        let store = SuggestedArtistStore(directory: temporaryDirectory())
        store.dismiss(artistId: "a1", name: "One")
        store.undismiss(artistId: "unknown")
        XCTAssertEqual(store.notInterested, ["a1"])
    }

    /// The Settings list needs names, and it should still list an artist whose cache entry has
    /// expired or was never written — falling back to the id rather than dropping the row.
    func testDismissedArtistsAreNamedWhereKnownAndSortedByName() {
        let store = SuggestedArtistStore(directory: temporaryDirectory())
        store.cache(["a1": artist("Zebra"), "a2": artist("Aardvark")])
        store.dismiss(artistId: "a1", name: "Zebra")
        store.dismiss(artistId: "a2", name: "Aardvark")
        store.dismiss(artistId: "a3", name: "Unknown")
        let listed = store.dismissedArtists()
        XCTAssertEqual(listed.map(\.name), ["a3", "Aardvark", "Zebra"])
        XCTAssertEqual(listed.map(\.id).sorted(), ["a1", "a2", "a3"])
    }

    // MARK: - Follows

    func testFollowedArtistsAreRemembered() {
        let dir = temporaryDirectory()
        SuggestedArtistStore(directory: dir).markFollowed(artistId: "a1", name: "Slowdive")
        XCTAssertEqual(SuggestedArtistStore(directory: dir).followedFromHere, ["a1"])
    }

    /// Following and dismissing are independent sets — a followed artist is not dismissed, and
    /// conflating them would make "Not interested" look like it unfollowed someone.
    func testFollowingDoesNotDismiss() {
        let store = SuggestedArtistStore(directory: temporaryDirectory())
        store.markFollowed(artistId: "a1", name: "One")
        XCTAssertTrue(store.notInterested.isEmpty)
    }

    // MARK: - Artist cache

    func testCachedArtworkSurvivesAReload() {
        let dir = temporaryDirectory()
        SuggestedArtistStore(directory: dir).cache(["a1": artist("Slowdive", image: "https://img/1")])
        let reloaded = SuggestedArtistStore(directory: dir).cachedArtist(id: "a1", now: now)
        XCTAssertEqual(reloaded?.name, "Slowdive")
        XCTAssertEqual(reloaded?.imageURL, "https://img/1")
        XCTAssertEqual(reloaded?.genres, ["shoegaze"])
    }

    func testCacheMissForUnknownArtist() {
        let store = SuggestedArtistStore(directory: temporaryDirectory())
        XCTAssertNil(store.cachedArtist(id: "nobody", now: now))
    }

    /// A stale entry must read as a miss, so a changed artist picture corrects itself without
    /// any "clear cache" affordance.
    func testExpiredCacheEntryReadsAsAMiss() {
        let store = SuggestedArtistStore(directory: temporaryDirectory())
        store.cache(["a1": artist("Slowdive")])
        let later = now.addingTimeInterval(SuggestedArtistStore.cacheLifetime + 1)
        XCTAssertNil(store.cachedArtist(id: "a1", now: later))
        XCTAssertNotNil(store.cachedArtist(id: "a1", now: now.addingTimeInterval(60)))
    }

    func testRecachingReplacesTheOlderEntry() {
        let store = SuggestedArtistStore(directory: temporaryDirectory())
        store.cache(["a1": artist("Old name", image: "https://img/old")])
        store.cache(["a1": artist("New name", image: "https://img/new")])
        XCTAssertEqual(store.cachedArtist(id: "a1", now: now)?.name, "New name")
        XCTAssertEqual(store.cachedArtist(id: "a1", now: now)?.imageURL, "https://img/new")
    }

    /// An artist with no picture is a legitimate cache entry — otherwise every refresh would
    /// re-request the same artists who simply have no image.
    func testArtistWithoutAnImageIsStillCached() {
        let store = SuggestedArtistStore(directory: temporaryDirectory())
        store.cache(["a1": artist("Nameless", image: nil)])
        let entry = store.cachedArtist(id: "a1", now: now)
        XCTAssertNotNil(entry)
        XCTAssertNil(entry?.imageURL)
    }

    // MARK: - Refresh bookkeeping

    func testRefreshStampSurvivesAReload() {
        let dir = temporaryDirectory()
        SuggestedArtistStore(directory: dir).finishRefresh(at: now)
        XCTAssertEqual(SuggestedArtistStore(directory: dir).lastRefreshAt, now)
    }

    /// The manual Refresh button must not be able to no-op against the staleness window.
    func testInvalidateMakesTheListStaleAgain() {
        let store = SuggestedArtistStore(directory: temporaryDirectory())
        store.finishRefresh(at: now)
        store.invalidateRefresh()
        XCTAssertNil(store.lastRefreshAt)
        XCTAssertTrue(ArtistSuggestionLogic.isStale(lastRefreshAt: store.lastRefreshAt, now: now))
    }

    // MARK: - Decoding

    /// A file written by a build that didn't have some field yet must still decode. A failed
    /// decode is treated as corruption and starts empty, which would throw away the dismissals.
    func testFileFromAnOlderBuildStillDecodes() {
        let dir = temporaryDirectory()
        let json = #"{"notInterested":["a1","a2"]}"#
        try? Data(json.utf8).write(to: dir.appendingPathComponent("suggestions.json"))
        let store = SuggestedArtistStore(directory: dir)
        XCTAssertEqual(store.notInterested, ["a1", "a2"])
        XCTAssertTrue(store.followedFromHere.isEmpty)
        XCTAssertNil(store.lastRefreshAt)
    }

    /// Likewise a cache entry from before `genres` existed.
    func testCachedArtistFromAnOlderBuildStillDecodes() {
        let dir = temporaryDirectory()
        let json = #"{"artistCache":{"a1":{"name":"Slowdive"}}}"#
        try? Data(json.utf8).write(to: dir.appendingPathComponent("suggestions.json"))
        let store = SuggestedArtistStore(directory: dir)
        // No `fetchedAt` means we can't date it, so it must not be served as fresh.
        XCTAssertNil(store.cachedArtist(id: "a1", now: now))
        // But the name is still there for the dismissed-artists list.
        store.dismiss(artistId: "a1", name: "Slowdive")
        XCTAssertEqual(store.dismissedArtists().first?.name, "Slowdive")
    }

    func testUnknownFieldsAreIgnored() {
        let dir = temporaryDirectory()
        let json = #"{"notInterested":["a1"],"somethingFromTheFuture":{"x":1}}"#
        try? Data(json.utf8).write(to: dir.appendingPathComponent("suggestions.json"))
        XCTAssertEqual(SuggestedArtistStore(directory: dir).notInterested, ["a1"])
    }

    /// A corrupt file is preserved before anything overwrites it — it's the only copy of a
    /// list the user built by hand, so it should be recoverable even if we can't read it.
    func testCorruptFileIsBackedUpRatherThanOverwritten() {
        let dir = temporaryDirectory()
        let path = dir.appendingPathComponent("suggestions.json")
        try? Data("this is not json".utf8).write(to: path)

        let store = SuggestedArtistStore(directory: dir)
        XCTAssertTrue(store.notInterested.isEmpty, "a corrupt file should start empty")
        store.dismiss(artistId: "a1", name: "One")   // forces a save() over the bad file

        let backup = dir.appendingPathComponent("suggestions.json.corrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try? String(contentsOf: backup, encoding: .utf8), "this is not json")
    }

    func testAbsentFileIsAFirstRunNotACorruption() {
        let dir = temporaryDirectory()
        let store = SuggestedArtistStore(directory: dir)
        XCTAssertTrue(store.notInterested.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("suggestions.json.corrupt").path))
    }

    // MARK: - Independence from the other stores

    /// The radar and the suggestion list must not share a file: a decode failure in one starts
    /// that store empty, and sharing would let a schema change in either wipe the other.
    func testUsesItsOwnFile() {
        let dir = temporaryDirectory()
        let store = SuggestedArtistStore(directory: dir)
        store.dismiss(artistId: "a1", name: "One")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("suggestions.json").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("newreleases.json").path))
    }
}
