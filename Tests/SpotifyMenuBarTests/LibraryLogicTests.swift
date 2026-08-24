import XCTest

/// Batching for the "Clear Your Episodes" bulk unsave. This is the app's only bulk delete, and
/// the failure it can produce is quiet: a chunk that drops ids leaves the library partly cleared
/// with no error, and one that duplicates them wastes requests against a rate limit.
final class LibraryLogicTests: XCTestCase {

    private func ids(_ n: Int) -> [String] { (0..<n).map { "ep\($0)" } }

    func testEmptyInputProducesNoRequests() {
        XCTAssertTrue(LibraryLogic.batches([]).isEmpty)
    }

    func testExactlyOneFullBatch() {
        let batches = LibraryLogic.batches(ids(40))
        XCTAssertEqual(batches.map(\.count), [40])
    }

    func testOneOverFillsThenRemainder() {
        XCTAssertEqual(LibraryLogic.batches(ids(41)).map(\.count), [40, 1])
    }

    func testTwoFullBatches() {
        XCTAssertEqual(LibraryLogic.batches(ids(80)).map(\.count), [40, 40])
    }

    func testSingleIdIsOneBatch() {
        XCTAssertEqual(LibraryLogic.batches(ids(1)), [["ep0"]])
    }

    /// `DELETE /me/library` caps at 40. The per-type endpoint it replaced allowed 50, and
    /// batching at the old size is a 400 on every request — pin the number.
    func testBatchSizeMatchesTheLibraryEndpointCap() {
        XCTAssertEqual(LibraryLogic.maxLibraryURIsPerRequest, 40)
    }

    /// The property that actually matters: every id appears exactly once, in order.
    func testNoIdIsDroppedOrDuplicated() {
        for count in [0, 1, 7, 39, 40, 41, 79, 80, 81, 364] {
            let input = ids(count)
            let flattened = LibraryLogic.batches(input).flatMap { $0 }
            XCTAssertEqual(flattened, input, "count \(count) round-tripped wrong")
            XCTAssertEqual(Set(flattened).count, count, "count \(count) duplicated an id")
        }
    }

    func testNoBatchExceedsSpotifysCap() {
        for count in [1, 40, 41, 364, 1000] {
            for batch in LibraryLogic.batches(ids(count)) {
                XCTAssertLessThanOrEqual(batch.count, LibraryLogic.maxLibraryURIsPerRequest)
                XCTAssertFalse(batch.isEmpty)
            }
        }
    }

    // MARK: URI form

    func testEpisodeURI() {
        XCTAssertEqual(LibraryLogic.episodeURI(id: "5vFGUJpNSFcj3TmgqOIA6v"),
                       "spotify:episode:5vFGUJpNSFcj3TmgqOIA6v")
    }

    /// The regression that cost a round-trip: `DELETE /me/episodes` (bare ids, JSON body) was
    /// removed in Feb 2026 and answers a bare 403, which reads like a scope problem. The
    /// replacement takes percent-encoded URIs in the query string.
    func testURIsAreEncodedTheWaySpotifyDocuments() {
        XCTAssertEqual(LibraryLogic.percentEncodedURI("spotify:episode:abc123"),
                       "spotify%3Aepisode%3Aabc123")
    }

    /// Commas separate the list and must stay literal — encoding them makes the whole thing
    /// one unparseable URI.
    func testCommasSeparateButColonsAreEncoded() {
        let query = LibraryLogic.urisQuery(["spotify:episode:a", "spotify:episode:b"])
        XCTAssertEqual(query, "uris=spotify%3Aepisode%3Aa,spotify%3Aepisode%3Ab")
    }

    func testSingleURIQueryHasNoTrailingComma() {
        XCTAssertEqual(LibraryLogic.urisQuery(["spotify:episode:a"]), "uris=spotify%3Aepisode%3Aa")
    }

    /// Whatever the ids look like, the assembled query must survive URL parsing intact.
    func testQueryRoundTripsThroughURLComponents() {
        let uris = ids(40).map { LibraryLogic.episodeURI(id: $0) }
        var comps = URLComponents(string: "https://api.spotify.com/v1/me/library")!
        comps.percentEncodedQuery = LibraryLogic.urisQuery(uris)
        let url = comps.url
        XCTAssertNotNil(url)
        let decoded = URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "uris" })?.value
        XCTAssertEqual(decoded, uris.joined(separator: ","))
    }

    /// A zero or negative size would loop forever in `stride`; refuse rather than hang.
    func testNonPositiveSizeProducesNoBatches() {
        XCTAssertTrue(LibraryLogic.batches(ids(10), size: 0).isEmpty)
        XCTAssertTrue(LibraryLogic.batches(ids(10), size: -1).isEmpty)
    }

    func testCustomSize() {
        XCTAssertEqual(LibraryLogic.batches(ids(10), size: 3).map(\.count), [3, 3, 3, 1])
    }

    func testProgressLabelPluralization() {
        XCTAssertEqual(LibraryLogic.progressLabel(done: 0, total: 1), "Removed 0 of 1 episode…")
        XCTAssertEqual(LibraryLogic.progressLabel(done: 150, total: 340), "Removed 150 of 340 episodes…")
    }

    /// Stopping partway must say how far it got — "clear failed" after 150 deletions is a lie.
    func testPartialFailureLabelDistinguishesNothingRemoved() {
        XCTAssertEqual(LibraryLogic.partialFailureLabel(done: 0, total: 340, error: "boom"),
                       "Couldn't clear Your Episodes: boom")
        XCTAssertEqual(LibraryLogic.partialFailureLabel(done: 150, total: 340, error: "boom"),
                       "Stopped after removing 150 of 340: boom")
    }

    // MARK: - removableURIs
    //
    // The confirm button names a number. These are the cases where the library underneath it has
    // moved on between the count and the press — the clear must never exceed what that number
    // covered.

    func testUnchangedLibraryRemovesEverythingApproved() {
        let list = ids(5)
        XCTAssertEqual(LibraryLogic.removableURIs(confirmed: list, current: list), list)
    }

    /// The case this exists for: two episodes saved while the confirm sat on screen. "Remove 3"
    /// must remove 3, not 5.
    func testEpisodesSavedAfterTheCountAreLeftAlone() {
        let confirmed = ["ep0", "ep1", "ep2"]
        let current = ["ep0", "ep1", "ep2", "new1", "new2"]
        XCTAssertEqual(LibraryLogic.removableURIs(confirmed: confirmed, current: current), confirmed)
    }

    /// Unsaved elsewhere in the meantime: gone is gone, and asking Spotify to unsave it again
    /// would just waste a slot in the batch.
    func testEpisodesUnsavedAfterTheCountDropOut() {
        XCTAssertEqual(LibraryLogic.removableURIs(confirmed: ids(4), current: ["ep0", "ep3"]),
                       ["ep0", "ep3"])
    }

    /// Both at once — the general shape of a library that kept living between the two presses.
    func testAdditionsAndRemovalsTogether() {
        XCTAssertEqual(LibraryLogic.removableURIs(confirmed: ["a", "b", "c"],
                                                  current: ["b", "new", "c", "other"]),
                       ["b", "c"])
    }

    /// Order follows the fresh read, so a clear that dies partway has taken the oldest saves.
    func testOrderFollowsTheCurrentLibraryNotTheApprovedList() {
        XCTAssertEqual(LibraryLogic.removableURIs(confirmed: ["c", "b", "a"],
                                                  current: ["a", "b", "c"]),
                       ["a", "b", "c"])
    }

    func testNothingInCommonRemovesNothing() {
        XCTAssertTrue(LibraryLogic.removableURIs(confirmed: ["a"], current: ["b"]).isEmpty)
        XCTAssertTrue(LibraryLogic.removableURIs(confirmed: [], current: ids(3)).isEmpty)
        XCTAssertTrue(LibraryLogic.removableURIs(confirmed: ids(3), current: []).isEmpty)
    }

    /// The result is what gets batched, so the two have to compose without dropping anything.
    func testResultBatchesCleanly() {
        let confirmed = ids(100)
        let current = ids(120)   // 20 saved since
        let removable = LibraryLogic.removableURIs(confirmed: confirmed, current: current)
        XCTAssertEqual(removable.count, 100)
        XCTAssertEqual(LibraryLogic.batches(removable).flatMap { $0 }, confirmed)
    }
}
