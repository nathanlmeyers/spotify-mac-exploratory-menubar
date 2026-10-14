import XCTest

/// The last.fm → Spotify matcher and the write plans for Top Tracks.
///
/// The failure that matters is a *wrong* match, not a missing one: a miss leaves a gap in the
/// playlist, a wrong match puts a karaoke cover of your most played song in it and nothing on
/// screen says so. So the rules lean towards refusing, and those refusals are pinned here.
final class TopTracksLogicTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_787_000_000)   // 2026-08-16T...Z

    private func scrobble(_ name: String, by artist: String, rank: Int = 1) -> LastFMTopTrack {
        LastFMTopTrack(rank: rank, name: name, artist: artist, playcount: 10, mbid: nil)
    }

    private func hit(_ name: String, by artists: [String], id: String = "t1",
                     albumType: String = "album") -> TrackSearchHit {
        TrackSearchHit(id: id, uri: "spotify:track:\(id)", name: name, artistNames: artists,
                       albumName: "Album", albumType: albumType, durationMs: 200_000)
    }

    // MARK: - Title normalisation

    func testNormalizedTitleStripsCredits() {
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Song (feat. Drake)"), "song")
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Song [ft. Drake]"), "song")
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Song feat. Drake"), "song")
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Song (with Drake)"), "song")
    }

    func testNormalizedTitleStripsPackagingSuffixes() {
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Song - Remastered 2011"), "song")
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Song (2011 Remaster)"), "song")
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Song - Radio Edit"), "song")
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Song (Official Video)"), "song")
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Song - Remastered 2011 - Radio Edit"), "song")
    }

    /// Different recordings keep their markers so the scorer can penalise a mismatch.
    func testNormalizedTitleKeepsRecordingVariants() {
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Song (Live)"), "song live")
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Song - Acoustic"), "song acoustic")
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Song (Taylor's Version)"), "song taylors version")
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Song (Remix)"), "song remix")
    }

    func testNormalizedTitleFoldsPunctuationAndDiacritics() {
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Don\u{2019}t Stop"), "dont stop")
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Don't Stop"), "dont stop")
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Caf\u{00E9}"), "cafe")
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Rock & Roll"), "rock and roll")
        XCTAssertEqual(TopTracksLogic.normalizedTitle("Dancing With Myself"), "dancing with myself")
    }

    func testLooseTitleDropsEveryGroupAndTail() {
        XCTAssertEqual(TopTracksLogic.looseTitle("Song - Live (Remastered) [Bonus]"), "song")
        XCTAssertEqual(TopTracksLogic.looseTitle("Song"), "song")
    }

    // MARK: - Artist normalisation

    func testArtistCandidatesSplitOnlyOnFeaturing() {
        XCTAssertEqual(TopTracksLogic.artistCandidates("Drake feat. Rihanna"), ["drake feat rihanna", "drake"])
        XCTAssertEqual(TopTracksLogic.artistCandidates("Simon & Garfunkel"), ["simon and garfunkel"])
        XCTAssertEqual(TopTracksLogic.artistCandidates("Tyler, The Creator"), ["tyler the creator"])
    }

    func testCacheKeyIsStableAcrossPunctuationAndCase() {
        XCTAssertEqual(TopTracksLogic.cacheKey(artist: "Drake", title: "Song (feat. X)"),
                       TopTracksLogic.cacheKey(artist: "DRAKE", title: "song"))
        XCTAssertEqual(TopTracksLogic.cacheKey(artist: "A", title: "B"), "a|b")
    }

    // MARK: - Queries

    func testSearchQueriesAreFilteredThenPlainWithNoFieldBreakingCharacters() {
        let queries = TopTracksLogic.searchQueries(for: scrobble("Song: Part 2", by: "Artist \"The\" Name"))
        XCTAssertEqual(queries, ["track:song part 2 artist:artist the name",
                                 "song part 2 artist the name"])
    }

    func testSearchQueriesAreCapped() {
        let long = String(repeating: "word ", count: 100)
        for q in TopTracksLogic.searchQueries(for: scrobble(long, by: "Artist")) {
            XCTAssertLessThanOrEqual(q.count, TopTracksLogic.maxQueryLength)
        }
        XCTAssertLessThanOrEqual(TopTracksLogic.searchQueries(for: scrobble("A", by: "B")).count, 2)
    }

    // MARK: - Scoring

    func testExactHitIsAccepted() {
        let match = TopTracksLogic.bestMatch([hit("Song", by: ["Artist"])], for: scrobble("Song", by: "Artist"))
        XCTAssertNotNil(match)
        XCTAssertGreaterThanOrEqual(match?.score ?? 0, TopTracksLogic.acceptThreshold)
    }

    /// The artist floor: a perfect title by somebody else is a tribute act, not a match.
    func testExactTitleByWrongArtistIsRefused() {
        XCTAssertNil(TopTracksLogic.bestMatch([hit("Song", by: ["Karaoke Kings"])],
                                              for: scrobble("Song", by: "Artist")))
    }

    func testLiveHitForStudioScrobbleIsRefused() {
        XCTAssertNil(TopTracksLogic.bestMatch([hit("Song - Live", by: ["Artist"])],
                                              for: scrobble("Song", by: "Artist")))
    }

    func testRemixHitForOriginalScrobbleIsRefused() {
        XCTAssertNil(TopTracksLogic.bestMatch([hit("Song (Remix)", by: ["Artist"])],
                                              for: scrobble("Song", by: "Artist")))
    }

    func testLiveScrobbleMatchesLiveHit() {
        let match = TopTracksLogic.bestMatch([hit("Song", by: ["Artist"], id: "studio"),
                                              hit("Song - Live", by: ["Artist"], id: "live")],
                                             for: scrobble("Song (Live)", by: "Artist"))
        XCTAssertEqual(match?.hit.id, "live")
    }

    func testPackagingDifferencesStillMatch() {
        let match = TopTracksLogic.bestMatch([hit("Song - Remastered 2011", by: ["Artist"])],
                                             for: scrobble("Song", by: "Artist"))
        XCTAssertNotNil(match)
    }

    func testAlbumPressingBeatsCompilationOnTie() {
        let match = TopTracksLogic.bestMatch([hit("Song", by: ["Artist"], id: "comp", albumType: "compilation"),
                                              hit("Song", by: ["Artist"], id: "album", albumType: "album")],
                                             for: scrobble("Song", by: "Artist"))
        XCTAssertEqual(match?.hit.id, "album")
    }

    func testSpotifyOrderBreaksExactTies() {
        let match = TopTracksLogic.bestMatch([hit("Song", by: ["Artist"], id: "first"),
                                              hit("Song", by: ["Artist"], id: "second")],
                                             for: scrobble("Song", by: "Artist"))
        XCTAssertEqual(match?.hit.id, "first")
    }

    func testFeaturedCreditCountsAsTheArtist() {
        XCTAssertEqual(TopTracksLogic.artistScore(hitArtists: ["Drake", "Rihanna"], scrobbleArtist: "Rihanna"), 1.0)
        XCTAssertEqual(TopTracksLogic.artistScore(hitArtists: ["Drake"], scrobbleArtist: "Drake feat. Rihanna"), 1.0)
        XCTAssertEqual(TopTracksLogic.artistScore(hitArtists: ["Weeknd"], scrobbleArtist: "The Weeknd"), 1.0)
        XCTAssertEqual(TopTracksLogic.artistScore(hitArtists: ["Simon & Garfunkel"], scrobbleArtist: "Simon and Garfunkel"), 1.0)
    }

    func testArtistPrefixIsPartialCredit() {
        XCTAssertEqual(TopTracksLogic.artistScore(hitArtists: ["Kaytranada"], scrobbleArtist: "Kaytranada and Friends"), 0.7)
        XCTAssertEqual(TopTracksLogic.artistScore(hitArtists: ["Nobody"], scrobbleArtist: "Artist"), 0)
    }

    func testVariantMarkers() {
        XCTAssertEqual(TopTracksLogic.variantMarkers("song 8 bit remix"), ["8 bit", "remix"])
        XCTAssertEqual(TopTracksLogic.variantMarkers("remixing my heart"), [])
    }

    // MARK: - Cache policy and scheduling

    func testMissRetryAfterInterval() {
        let day: TimeInterval = 86_400
        XCTAssertFalse(TopTracksLogic.shouldRetryMiss(lastTriedAt: now.addingTimeInterval(-29 * day), now: now))
        XCTAssertTrue(TopTracksLogic.shouldRetryMiss(lastTriedAt: now.addingTimeInterval(-31 * day), now: now))
        XCTAssertTrue(TopTracksLogic.shouldRetryMiss(lastTriedAt: now.addingTimeInterval(day), now: now))
    }

    func testIsSyncDue() {
        XCTAssertTrue(TopTracksLogic.isSyncDue(lastSyncAt: nil, now: now))
        XCTAssertFalse(TopTracksLogic.isSyncDue(lastSyncAt: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertTrue(TopTracksLogic.isSyncDue(lastSyncAt: now.addingTimeInterval(-25 * 3600), now: now))
        XCTAssertTrue(TopTracksLogic.isSyncDue(lastSyncAt: now.addingTimeInterval(3600), now: now))
    }

    // MARK: - Write plans

    func testDedupedRankOrderKeepsFirstOccurrence() {
        XCTAssertEqual(TopTracksLogic.dedupedRankOrder(["a", "b", "a", "c", "b"]), ["a", "b", "c"])
    }

    func testAppendPlanSkipsExistingAndHandRemoved() {
        let plan = TopTracksLogic.appendPlan(ranked: ["a", "b", "c", "d"], existing: ["b"]) { $0 == "c" }
        XCTAssertEqual(plan, ["a", "d"])
    }

    func testReplacePlanIsNilOnlyWhenIdentical() {
        XCTAssertNil(TopTracksLogic.replacePlan(ranked: ["a", "b"], current: ["a", "b"]))
        XCTAssertEqual(TopTracksLogic.replacePlan(ranked: ["a", "b"], current: ["b", "a"]), ["a", "b"])
        XCTAssertEqual(TopTracksLogic.replacePlan(ranked: ["a"], current: []), ["a"])
    }

    /// Replace is only ever honoured on a playlist we own and that no other period shares.
    func testEffectiveMode() {
        XCTAssertEqual(TopTracksLogic.effectiveMode(requested: .replace, targetIsOwned: true, targetSharedWithAnotherPeriod: false), .replace)
        XCTAssertEqual(TopTracksLogic.effectiveMode(requested: .replace, targetIsOwned: false, targetSharedWithAnotherPeriod: false), .append)
        XCTAssertEqual(TopTracksLogic.effectiveMode(requested: .replace, targetIsOwned: true, targetSharedWithAnotherPeriod: true), .append)
        XCTAssertEqual(TopTracksLogic.effectiveMode(requested: .append, targetIsOwned: true, targetSharedWithAnotherPeriod: false), .append)
    }

    func testClampedLimit() {
        XCTAssertEqual(TopTracksLogic.clampedLimit(0), 50)
        XCTAssertEqual(TopTracksLogic.clampedLimit(75), 50)
        XCTAssertEqual(TopTracksLogic.clampedLimit(100), 100)
    }

    // MARK: - Playlist identity

    func testOwnershipMarker() {
        XCTAssertFalse(TopTracksLogic.carriesOwnershipMarker(description: nil))
        XCTAssertFalse(TopTracksLogic.carriesOwnershipMarker(description: "My playlist"))
        XCTAssertTrue(TopTracksLogic.carriesOwnershipMarker(description: "Stuff. maintained by spotify menu bar."))
        XCTAssertTrue(TopTracksLogic.carriesOwnershipMarker(description: "Maintained by Spotify Menu Bar &amp; more"))
        let description = TopTracksLogic.playlistDescription(period: .oneMonth, limit: 50)
        XCTAssertTrue(TopTracksLogic.carriesOwnershipMarker(description: description))
        XCTAssertLessThanOrEqual(description.count, TopTracksLogic.maxDescriptionLength)
    }

    // MARK: - last.fm parsing

    private let fixture = """
    {"toptracks":{"track":[
      {"streamable":{"fulltrack":"0","#text":"0"},"mbid":"","name":"Song One",
       "artist":{"url":"u","name":"Artist A","mbid":""},"url":"u","duration":"0",
       "@attr":{"rank":"1"},"playcount":"123"},
      {"mbid":"abc-123","name":"Song Two","artist":{"name":"Artist B"},"playcount":"7"},
      {"name":"","artist":{"name":"Nobody"},"playcount":"1"}
    ],"@attr":{"user":"x","totalPages":"1","page":"1","perPage":"50","total":"3"}}}
    """

    func testParseTopTracksHandlesStringNumbersAndMissingFields() throws {
        let rows = try TopTracksLogic.parseTopTracks(Data(fixture.utf8))
        XCTAssertEqual(rows.count, 2, "a row with no title is dropped")
        XCTAssertEqual(rows[0], LastFMTopTrack(rank: 1, name: "Song One", artist: "Artist A", playcount: 123, mbid: nil))
        XCTAssertEqual(rows[1].rank, 2, "rank falls back to position when @attr is missing")
        XCTAssertEqual(rows[1].mbid, "abc-123")
    }

    func testParseTopTracksSurfacesTheAPIError() {
        let body = Data(#"{"error":6,"message":"User not found"}"#.utf8)
        XCTAssertEqual(TopTracksLogic.lastFMError(body)?.code, 6)
        XCTAssertThrowsError(try TopTracksLogic.parseTopTracks(body)) { error in
            XCTAssertEqual(error as? LastFMParseError, .api(code: 6, message: "User not found"))
        }
        XCTAssertThrowsError(try TopTracksLogic.parseTopTracks(Data("not json".utf8)))
    }

    // MARK: - Labels

    func testSummaries() {
        XCTAssertEqual(TopTracksLogic.appendSummary(added: 0, missed: 0), "Nothing new to add.")
        XCTAssertEqual(TopTracksLogic.appendSummary(added: 1, missed: 2), "Added 1 song. 2 not found on Spotify.")
        XCTAssertEqual(TopTracksLogic.replaceSummary(total: 50, added: 3, dropped: 2, unchanged: false, missed: 0),
                       "Updated — 50 songs, 3 new, 2 dropped.")
        XCTAssertEqual(TopTracksLogic.replaceSummary(total: 50, added: 0, dropped: 0, unchanged: true, missed: 1),
                       "Up to date — 50 songs. 1 not found on Spotify.")
    }
}
