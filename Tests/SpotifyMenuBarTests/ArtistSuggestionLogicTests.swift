import XCTest

/// Scoring for "Artists to Follow".
///
/// The February 2026 API removals (`popularity`, `/artists/{id}/top-tracks`,
/// `/related-artists`, `/recommendations`) mean this ranking is the *only* judgement in the
/// feature — there's no popularity number to fall back on and no similarity endpoint to
/// cross-check against. So the ordering rules are pinned here rather than eyeballed in the UI.
final class ArtistSuggestionLogicTests: XCTestCase {

    // MARK: - Builders

    private func artistHit(_ id: String,
                           rank: Int,
                           _ range: ArtistTimeRange = .mediumTerm,
                           name: String? = nil) -> TopArtistHit {
        TopArtistHit(artistId: id, name: name ?? id.uppercased(), rank: rank, range: range)
    }

    private func credit(_ artistId: String,
                        track: String,
                        rank: Int,
                        _ range: ArtistTimeRange = .mediumTerm,
                        primary: Bool = true) -> TopTrackCredit {
        TopTrackCredit(artistId: artistId,
                       artistName: artistId.uppercased(),
                       trackId: track,
                       trackName: track,
                       rank: rank,
                       range: range,
                       isPrimary: primary)
    }

    private func score(of id: String, in list: [ScoredArtist]) -> Double {
        list.first { $0.id == id }?.score ?? 0
    }

    // MARK: - Rank decay

    func testRankWeightDecaysButNeverReachesZero() {
        let first = ArtistSuggestionLogic.rankWeight(0)
        let tenth = ArtistSuggestionLogic.rankWeight(9)
        let last = ArtistSuggestionLogic.rankWeight(49)
        XCTAssertGreaterThan(first, tenth)
        XCTAssertGreaterThan(tenth, last)
        // The tail must still count for something — a linear ramp would zero it out and make
        // the bottom half of a 50-item list invisible to the scoring.
        XCTAssertGreaterThan(last, 0.15)
        XCTAssertEqual(first, 1.0, accuracy: 0.0001)
    }

    func testRankWeightToleratesNegativeRank() {
        // Defensive: a malformed page shouldn't produce a NaN that poisons the whole sort.
        let w = ArtistSuggestionLogic.rankWeight(-3)
        XCTAssertFalse(w.isNaN)
        XCTAssertEqual(w, 1.0, accuracy: 0.0001)
    }

    // MARK: - Source weighting

    /// A place in your top *artists* is Spotify's aggregate over everything you played; a top
    /// *track* may be the only song of theirs you've ever heard. So a solidly-placed artist
    /// must outrank even your single most-played song.
    func testTopArtistOutweighsASingleTopTrack() {
        let scored = ArtistSuggestionLogic.score(
            topArtistHits: [artistHit("a", rank: 10)],
            topTrackCredits: [credit("b", track: "t1", rank: 0)])
        XCTAssertGreaterThan(score(of: "a", in: scored), score(of: "b", in: scored))
    }

    /// Pins where that crossover actually sits, so a future weight change has to face the
    /// question rather than move it by accident.
    func testTopArtistBeatsTheBestTrackDownToRoughlyRankFifteen() {
        func artistBeatsTopTrack(rank: Int) -> Bool {
            let scored = ArtistSuggestionLogic.score(
                topArtistHits: [artistHit("a", rank: rank)],
                topTrackCredits: [credit("b", track: "t1", rank: 0)])
            return score(of: "a", in: scored) > score(of: "b", in: scored)
        }
        XCTAssertTrue(artistBeatsTopTrack(rank: 0))
        XCTAssertTrue(artistBeatsTopTrack(rank: 13))
        // The two are exactly equal at rank 14 — `topArtistWeight` 4.0 × rankWeight(14) 0.25
        // — so the crossover is #15 in the list the user sees.
        XCTAssertFalse(artistBeatsTopTrack(rank: 15))
        // Far down the artist list, one much-played song is the better evidence.
        XCTAssertFalse(artistBeatsTopTrack(rank: 30))
        XCTAssertFalse(artistBeatsTopTrack(rank: 49))
    }

    func testPrimaryCreditOutweighsAFeature() {
        let scored = ArtistSuggestionLogic.score(
            topArtistHits: [],
            topTrackCredits: [credit("lead", track: "t1", rank: 5, primary: true),
                              credit("guest", track: "t1", rank: 5, primary: false)])
        XCTAssertGreaterThan(score(of: "lead", in: scored), score(of: "guest", in: scored))
    }

    /// One heavily-played posse cut must not promote every guest on it above artists the user
    /// actually seeks out.
    ///
    /// The property, not one lucky pair: a *single* featured credit — even on your #1 track —
    /// outranks no primary credit anywhere in a 50-track list from the same range. This list
    /// decides whose releases you want to follow, and a guest verse on a song you love mostly
    /// says you love the song.
    func testASingleFeatureNeverOutranksAPrimaryCreditAnywhereInTheList() {
        for ownRank in 0..<ArtistSuggestionLogic.topPageSize {
            let scored = ArtistSuggestionLogic.score(
                topArtistHits: [],
                topTrackCredits: [credit("guest", track: "posse", rank: 0, primary: false),
                                  credit("own", track: "song", rank: ownRank, primary: true)])
            XCTAssertGreaterThan(score(of: "own", in: scored), score(of: "guest", in: scored),
                                 "a #1 feature beat a primary credit at rank \(ownRank)")
        }
    }

    /// Features are weak individually but real in aggregate — someone guesting across several
    /// of your top tracks is a genuine signal, and must be able to surface.
    func testRepeatedFeaturesStillAddUp() {
        let many = (0..<6).map { credit("guest", track: "t\($0)", rank: $0, primary: false) }
        let scored = ArtistSuggestionLogic.score(
            topArtistHits: [],
            topTrackCredits: many + [credit("own", track: "one", rank: 40, primary: true)])
        XCTAssertGreaterThan(score(of: "guest", in: scored), score(of: "own", in: scored))
    }

    func testLongTermOutweighsShortTermAtTheSameRank() {
        let scored = ArtistSuggestionLogic.score(
            topArtistHits: [artistHit("durable", rank: 3, .longTerm),
                            artistHit("recent", rank: 3, .shortTerm)],
            topTrackCredits: [])
        XCTAssertGreaterThan(score(of: "durable", in: scored), score(of: "recent", in: scored))
    }

    // MARK: - Cross-range bonus

    func testAppearingInEveryRangeBeatsOneStrongRange() {
        // Same rank in all three ranges vs. a better rank in one. Breadth should win: without
        // `popularity`, consistency across windows is the only durability signal left.
        let broad = [artistHit("broad", rank: 8, .shortTerm),
                     artistHit("broad", rank: 8, .mediumTerm),
                     artistHit("broad", rank: 8, .longTerm)]
        let narrow = [artistHit("narrow", rank: 2, .mediumTerm)]
        let scored = ArtistSuggestionLogic.score(topArtistHits: broad + narrow,
                                                 topTrackCredits: [])
        XCTAssertGreaterThan(score(of: "broad", in: scored), score(of: "narrow", in: scored))
        XCTAssertEqual(scored.first { $0.id == "broad" }?.rangesSeen, 3)
        XCTAssertEqual(scored.first { $0.id == "narrow" }?.rangesSeen, 1)
    }

    func testRangesSeenCountsAcrossBothSources() {
        let scored = ArtistSuggestionLogic.score(
            topArtistHits: [artistHit("x", rank: 0, .longTerm)],
            topTrackCredits: [credit("x", track: "t", rank: 0, .shortTerm)])
        XCTAssertEqual(scored.first?.rangesSeen, 2)
    }

    // MARK: - Dedupe

    /// The same track in two ranges is genuine evidence and counts twice toward the score,
    /// but it's still one song in the reason line.
    func testSameTrackInTwoRangesScoresTwiceButCountsOnce() {
        let oneRange = ArtistSuggestionLogic.score(
            topArtistHits: [],
            topTrackCredits: [credit("a", track: "t", rank: 0, .mediumTerm)])
        let twoRanges = ArtistSuggestionLogic.score(
            topArtistHits: [],
            topTrackCredits: [credit("a", track: "t", rank: 0, .mediumTerm),
                              credit("a", track: "t", rank: 0, .longTerm)])
        XCTAssertGreaterThan(score(of: "a", in: twoRanges), score(of: "a", in: oneRange))
        XCTAssertEqual(twoRanges.first?.trackCount, 1)
    }

    /// A duplicated entry within one range is an API artifact, not extra evidence.
    func testExactDuplicateCreditIsCountedOnce() {
        let single = ArtistSuggestionLogic.score(
            topArtistHits: [],
            topTrackCredits: [credit("a", track: "t", rank: 4)])
        let doubled = ArtistSuggestionLogic.score(
            topArtistHits: [],
            topTrackCredits: [credit("a", track: "t", rank: 4),
                              credit("a", track: "t", rank: 4)])
        XCTAssertEqual(score(of: "a", in: doubled), score(of: "a", in: single), accuracy: 0.0001)
    }

    func testDistinctTracksAccumulate() {
        let scored = ArtistSuggestionLogic.score(
            topArtistHits: [],
            topTrackCredits: [credit("a", track: "t1", rank: 1),
                              credit("a", track: "t2", rank: 2),
                              credit("a", track: "t3", rank: 3)])
        XCTAssertEqual(scored.first?.trackCount, 3)
    }

    // MARK: - Ordering stability

    func testOrderingIsStableForEqualScores() {
        // Dictionary iteration order isn't stable across runs, so equal scores must break by
        // name — otherwise the list reshuffles every refresh for no visible reason.
        let hits = [artistHit("id1", rank: 5, name: "Zebra"),
                    artistHit("id2", rank: 5, name: "Aardvark")]
        let first = ArtistSuggestionLogic.score(topArtistHits: hits, topTrackCredits: [])
        let second = ArtistSuggestionLogic.score(topArtistHits: hits.reversed(), topTrackCredits: [])
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.name), ["Aardvark", "Zebra"])
    }

    func testResultIsSortedByScoreDescending() {
        let scored = ArtistSuggestionLogic.score(
            topArtistHits: [artistHit("low", rank: 40), artistHit("high", rank: 0),
                            artistHit("mid", rank: 12)],
            topTrackCredits: [])
        XCTAssertEqual(scored.map(\.id), ["high", "mid", "low"])
    }

    func testEmptyInputProducesNoSuggestions() {
        XCTAssertTrue(ArtistSuggestionLogic.score(topArtistHits: [], topTrackCredits: []).isEmpty)
    }

    func testBlankArtistIdsAreIgnored() {
        let scored = ArtistSuggestionLogic.score(
            topArtistHits: [artistHit("", rank: 0)],
            topTrackCredits: [credit("", track: "t", rank: 0)])
        XCTAssertTrue(scored.isEmpty)
    }

    // MARK: - Best track

    func testBestTrackPrefersAPrimaryCreditOverABetterRankedFeature() {
        let scored = ArtistSuggestionLogic.score(
            topArtistHits: [],
            topTrackCredits: [credit("a", track: "feature", rank: 0, primary: false),
                              credit("a", track: "own", rank: 30, primary: true)])
        XCTAssertEqual(scored.first?.bestTrackId, "own")
    }

    func testBestTrackFallsBackToTheHighestRankedFeature() {
        let scored = ArtistSuggestionLogic.score(
            topArtistHits: [],
            topTrackCredits: [credit("a", track: "later", rank: 20, primary: false),
                              credit("a", track: "earlier", rank: 3, primary: false)])
        XCTAssertEqual(scored.first?.bestTrackId, "earlier")
    }

    func testArtistWithNoTrackCreditsHasNoBestTrack() {
        let scored = ArtistSuggestionLogic.score(topArtistHits: [artistHit("a", rank: 0)],
                                                 topTrackCredits: [])
        XCTAssertNil(scored.first?.bestTrackId)
    }

    // MARK: - Eligibility

    func testFollowedAndDismissedArtistsAreExcluded() {
        let scored = ArtistSuggestionLogic.score(
            topArtistHits: [artistHit("followed", rank: 0), artistHit("dismissed", rank: 1),
                            artistHit("fresh", rank: 2)],
            topTrackCredits: [])
        let out = ArtistSuggestionLogic.eligible(scored: scored,
                                                 following: ["followed"],
                                                 notInterested: ["dismissed"])
        XCTAssertEqual(out.map(\.id), ["fresh"])
    }

    func testEligibilityPreservesScoreOrder() {
        let scored = ArtistSuggestionLogic.score(
            topArtistHits: [artistHit("a", rank: 0), artistHit("b", rank: 1),
                            artistHit("c", rank: 2)],
            topTrackCredits: [])
        let out = ArtistSuggestionLogic.eligible(scored: scored, following: [], notInterested: [])
        XCTAssertEqual(out.map(\.id), ["a", "b", "c"])
    }

    // MARK: - Hydration plan

    func testHydrationSkipsArtistsThatAlreadyHaveArtwork() {
        let scored = ArtistSuggestionLogic.score(
            topArtistHits: [artistHit("has", rank: 0), artistHit("needs", rank: 1)],
            topTrackCredits: [])
        let plan = ArtistSuggestionLogic.hydrationPlan(eligible: scored,
                                                       needsHydration: { $0.id == "needs" })
        XCTAssertEqual(plan.fetch.map(\.id), ["needs"])
        XCTAssertEqual(plan.skipped, 0)
    }

    /// The cap exists because the batch `GET /artists?ids=` endpoint was removed — hydration
    /// is one request per artist, so an uncapped refresh could be hundreds of requests.
    func testHydrationCapReportsWhatItDropped() {
        let hits = (0..<40).map { artistHit("a\($0)", rank: $0) }
        let scored = ArtistSuggestionLogic.score(topArtistHits: hits, topTrackCredits: [])
        let plan = ArtistSuggestionLogic.hydrationPlan(eligible: scored,
                                                       needsHydration: { _ in true },
                                                       cap: 30)
        XCTAssertEqual(plan.fetch.count, 30)
        XCTAssertEqual(plan.skipped, 10)
        // The ones kept must be the best-scoring ones, not an arbitrary 30.
        XCTAssertEqual(plan.fetch.first?.id, "a0")
    }

    func testHydrationUnderTheCapDropsNothing() {
        let hits = (0..<5).map { artistHit("a\($0)", rank: $0) }
        let scored = ArtistSuggestionLogic.score(topArtistHits: hits, topTrackCredits: [])
        let plan = ArtistSuggestionLogic.hydrationPlan(eligible: scored,
                                                       needsHydration: { _ in true },
                                                       cap: 30)
        XCTAssertEqual(plan.fetch.count, 5)
        XCTAssertEqual(plan.skipped, 0)
    }

    // MARK: - Reason lines

    func testReasonNamesTheRankAndTheRange() {
        let reason = ArtistSuggestionLogic.reasonLabel(
            bestArtistHit: TopArtistHit(artistId: "a", name: "A", rank: 2, range: .longTerm),
            trackCount: 0,
            rangesSeen: 1)
        XCTAssertEqual(reason, "#3 in your top artists (all time)")
    }

    func testReasonCombinesBothSources() {
        let reason = ArtistSuggestionLogic.reasonLabel(
            bestArtistHit: TopArtistHit(artistId: "a", name: "A", rank: 0, range: .shortTerm),
            trackCount: 5,
            rangesSeen: 2)
        XCTAssertEqual(reason, "#1 in your top artists (last 4 weeks) · 5 songs in your top tracks")
    }

    func testReasonSingularizesOneSong() {
        let reason = ArtistSuggestionLogic.reasonLabel(bestArtistHit: nil,
                                                       trackCount: 1,
                                                       rangesSeen: 1)
        XCTAssertEqual(reason, "1 song in your top tracks")
    }

    func testReasonCallsOutAppearingInEveryRange() {
        let reason = ArtistSuggestionLogic.reasonLabel(bestArtistHit: nil,
                                                       trackCount: 2,
                                                       rangesSeen: 3)
        XCTAssertTrue(reason.hasSuffix("across every time range"), reason)
    }

    func testReasonIsNeverEmpty() {
        let reason = ArtistSuggestionLogic.reasonLabel(bestArtistHit: nil,
                                                       trackCount: 0,
                                                       rangesSeen: 0)
        XCTAssertFalse(reason.isEmpty)
    }

    // MARK: - Summary

    func testSummaryNamesWhatWasLeftOut() {
        XCTAssertEqual(ArtistSuggestionLogic.summaryLabel(shown: 30, hidden: 12),
                       "30 artists you listen to but don't follow — 12 more not shown this refresh")
    }

    func testSummaryOmitsTheTailWhenNothingWasDropped() {
        XCTAssertEqual(ArtistSuggestionLogic.summaryLabel(shown: 4, hidden: 0),
                       "4 artists you listen to but don't follow")
    }

    func testSummaryHandlesEmptyAndSingular() {
        XCTAssertEqual(ArtistSuggestionLogic.summaryLabel(shown: 0, hidden: 0),
                       "No suggestions right now.")
        XCTAssertTrue(ArtistSuggestionLogic.summaryLabel(shown: 1, hidden: 0).hasPrefix("1 artist you"))
    }

    // MARK: - Freshness

    func testStalenessWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(ArtistSuggestionLogic.isStale(lastRefreshAt: nil, now: now))
        XCTAssertFalse(ArtistSuggestionLogic.isStale(
            lastRefreshAt: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(ArtistSuggestionLogic.isStale(
            lastRefreshAt: now.addingTimeInterval(-ArtistSuggestionLogic.staleAfter - 1), now: now))
    }

    /// A clock that jumped backwards must not freeze the list until real time catches up.
    func testFutureTimestampCountsAsStale() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(ArtistSuggestionLogic.isStale(
            lastRefreshAt: now.addingTimeInterval(3_600), now: now))
    }

    func testUpdatedLabelReadsInPlainUnits() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ArtistSuggestionLogic.updatedLabel(lastRefreshAt: nil, now: now),
                       "Never updated")
        XCTAssertEqual(ArtistSuggestionLogic.updatedLabel(
            lastRefreshAt: now.addingTimeInterval(-5), now: now), "Updated just now")
        XCTAssertEqual(ArtistSuggestionLogic.updatedLabel(
            lastRefreshAt: now.addingTimeInterval(-60), now: now), "Updated 1 minute ago")
        XCTAssertEqual(ArtistSuggestionLogic.updatedLabel(
            lastRefreshAt: now.addingTimeInterval(-7_200), now: now), "Updated 2 hours ago")
        XCTAssertEqual(ArtistSuggestionLogic.updatedLabel(
            lastRefreshAt: now.addingTimeInterval(-86_400 * 3), now: now), "Updated 3 days ago")
    }

    // MARK: - URIs

    func testURIsAreWellFormed() {
        XCTAssertEqual(ArtistSuggestionLogic.artistURI(id: "abc123"), "spotify:artist:abc123")
        XCTAssertEqual(ArtistSuggestionLogic.artistWebURL(id: "abc123"),
                       "https://open.spotify.com/artist/abc123")
    }
}
