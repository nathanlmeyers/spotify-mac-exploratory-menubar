import XCTest

/// Filters for the "New From Followed" release radar.
///
/// The failure mode here is quiet in both directions: a filter that's too loose fills a
/// discovery playlist with 1998 reissues and remix packages until it's useless, and one that's
/// too tight silently hides new music with nothing to notice. Both are invisible until you go
/// looking, so the rules are pinned here.
final class NewReleaseLogicTests: XCTestCase {

    // A fixed "now" so nothing depends on the day the suite runs.
    private let now = Date(timeIntervalSince1970: 1_787_000_000)   // 2026-08-16T...Z
    private var today: String { NewReleaseLogic.dayString(now) }

    private func album(_ id: String = "a1",
                       name: String = "New Record",
                       type: String = "album",
                       date: String,
                       precision: String = "day",
                       group: ReleaseGroup = .own) -> CandidateAlbum {
        CandidateAlbum(id: id, name: name, albumType: type,
                       releaseDate: date, releaseDatePrecision: precision, group: group)
    }

    private func track(_ id: String = "t1",
                       name: String = "Song",
                       artists: [String] = ["artist1"],
                       album: String = "a1",
                       matched: String = "artist1",
                       group: ReleaseGroup = .own) -> CandidateTrack {
        CandidateTrack(id: id, uri: "spotify:track:\(id)", name: name, artistIds: artists,
                       albumId: album, matchedArtistId: matched, group: group)
    }

    // MARK: - Dates

    func testDayStringIsUTCAndISOFormatted() {
        XCTAssertEqual(NewReleaseLogic.dayString(Date(timeIntervalSince1970: 0)), "1970-01-01")
        XCTAssertEqual(today.count, 10)
    }

    private let epoch = Date(timeIntervalSince1970: 0)

    /// The watermark is what keeps the first run cheap. If it's newer than the lookback window
    /// it must win, or enabling the feature sweeps in two weeks of back catalogue on day one.
    func testWatermarkWinsWhenNewerThanLookback() {
        let watermark = now.addingTimeInterval(-2 * 86_400)
        XCTAssertEqual(NewReleaseLogic.cutoffDay(now: now, watermark: watermark,
                                                 lastScanAt: nil, lookbackDays: 14),
                       NewReleaseLogic.dayString(watermark))
    }

    func testLookbackWinsWhenWatermarkIsOld() {
        XCTAssertEqual(NewReleaseLogic.cutoffDay(now: now, watermark: epoch,
                                                 lastScanAt: nil, lookbackDays: 14),
                       NewReleaseLogic.dayString(now.addingTimeInterval(-14 * 86_400)))
    }

    func testNegativeLookbackIsTreatedAsZero() {
        XCTAssertEqual(NewReleaseLogic.cutoffDay(now: now, watermark: epoch,
                                                 lastScanAt: nil, lookbackDays: -5),
                       today)
    }

    // MARK: - Coming back after the machine was off

    /// A recent scan changes nothing — the ordinary lookback still governs.
    func testRecentLastScanDoesNotWidenTheWindow() {
        XCTAssertEqual(NewReleaseLogic.cutoffDay(now: now, watermark: epoch,
                                                 lastScanAt: now.addingTimeInterval(-86_400),
                                                 lookbackDays: 14),
                       NewReleaseLogic.dayString(now.addingTimeInterval(-14 * 86_400)))
    }

    /// The gap this exists to close: away three weeks with a two-week lookback. Without
    /// reaching back to the last scan, that middle week of releases is lost permanently —
    /// it's already too old to qualify on the first scan back.
    func testALongAbsenceWidensTheWindowBackToTheLastScan() {
        let lastScan = now.addingTimeInterval(-21 * 86_400)
        XCTAssertEqual(NewReleaseLogic.cutoffDay(now: now, watermark: epoch,
                                                 lastScanAt: lastScan, lookbackDays: 14),
                       NewReleaseLogic.dayString(lastScan))
    }

    /// The watermark is still a hard floor — a long absence must not reach back past the day
    /// the feature was switched on.
    func testCatchUpNeverReachesPastTheWatermark() {
        let watermark = now.addingTimeInterval(-5 * 86_400)
        XCTAssertEqual(NewReleaseLogic.cutoffDay(now: now, watermark: watermark,
                                                 lastScanAt: now.addingTimeInterval(-90 * 86_400),
                                                 lookbackDays: 14),
                       NewReleaseLogic.dayString(watermark))
    }

    func testCatchUpTriggersOnlyWhenTheGapExceedsTheLookback() {
        XCTAssertFalse(NewReleaseLogic.isCatchUp(lastScanAt: now.addingTimeInterval(-3 * 86_400),
                                                 now: now, lookbackDays: 14))
        XCTAssertFalse(NewReleaseLogic.isCatchUp(lastScanAt: now.addingTimeInterval(-14 * 86_400),
                                                 now: now, lookbackDays: 14))
        XCTAssertTrue(NewReleaseLogic.isCatchUp(lastScanAt: now.addingTimeInterval(-15 * 86_400),
                                                now: now, lookbackDays: 14))
    }

    /// A first-ever run isn't a catch-up: the watermark already pins it to today, and treating
    /// it as one would suspend the rotation and crawl every artist's whole guest catalogue for
    /// nothing.
    func testFirstRunIsNotACatchUp() {
        XCTAssertFalse(NewReleaseLogic.isCatchUp(lastScanAt: nil, now: now, lookbackDays: 14))
    }

    /// Clock moved backwards — don't read a future timestamp as an enormous gap.
    func testFutureLastScanIsNotACatchUp() {
        XCTAssertFalse(NewReleaseLogic.isCatchUp(lastScanAt: now.addingTimeInterval(86_400),
                                                 now: now, lookbackDays: 14))
    }

    private func inWindow(_ date: String, _ precision: String = "day") -> Bool {
        NewReleaseLogic.isWithinWindow(
            releaseDate: date, precision: precision,
            cutoffDay: NewReleaseLogic.cutoffDay(now: now, watermark: epoch,
                                                 lastScanAt: nil, lookbackDays: 14),
            horizonDay: NewReleaseLogic.horizonDay(now: now))
    }

    func testTodayIsInWindow() {
        XCTAssertTrue(inWindow(today))
    }

    func testJustInsideAndJustOutsideTheLookback() {
        XCTAssertTrue(inWindow(NewReleaseLogic.dayString(now.addingTimeInterval(-13 * 86_400))))
        XCTAssertFalse(inWindow(NewReleaseLogic.dayString(now.addingTimeInterval(-15 * 86_400))))
    }

    /// Spotify dates back-catalogue and reissues with coarse precision, and `appears_on` returns
    /// them by the boatload. Admitting them means a "new releases" playlist full of 1998.
    func testCoarsePrecisionIsNeverInWindow() {
        XCTAssertFalse(inWindow("2026", "year"))
        XCTAssertFalse(inWindow("2026-08", "month"))
        XCTAssertFalse(inWindow(today, "year"))
    }

    func testMalformedDateIsRejectedRatherThanCrashing() {
        XCTAssertFalse(inWindow("", "day"))
        XCTAssertFalse(inWindow("2026-8-1", "day"))
    }

    /// Pre-release announcements carry a future date and aren't playable yet; one day of slack
    /// absorbs the timezone gap between Spotify's date and ours.
    func testFarFutureReleasesAreExcludedButOneDayOfSlackIsAllowed() {
        XCTAssertTrue(inWindow(NewReleaseLogic.dayString(now.addingTimeInterval(86_400))))
        XCTAssertFalse(inWindow(NewReleaseLogic.dayString(now.addingTimeInterval(30 * 86_400))))
    }

    // MARK: - Remix detection

    func testRemixTitlesAreDetected() {
        for name in ["Song (Kaytranada Remix)",
                     "Song - RL Grime Remix",
                     "Song [Remix]",
                     "The Remixes",
                     "Song (Remixed by Four Tet)",
                     "Song (Bootleg)",
                     "Song (RMX)",
                     "Song / Other Mashup"] {
            XCTAssertTrue(NewReleaseLogic.isRemixTitle(name), "\(name) should read as a remix")
        }
    }

    /// A false positive hides music the user wanted and leaves no trace, so the rule stays
    /// narrow: word-boundary tokens only, and bare "... Mix" is not a remix — `Original Mix`
    /// and `Extended Mix` are usually the artist's own versions.
    func testNonRemixTitlesSurvive() {
        for name in ["Remixing My Heart",
                     "Original Mix",
                     "Extended Mix",
                     "Club Mix",
                     "Mixtape",
                     "Premixed",
                     "Song (Live)",
                     "Song - Radio Edit"] {
            XCTAssertFalse(NewReleaseLogic.isRemixTitle(name), "\(name) should NOT read as a remix")
        }
    }

    // MARK: - Compilation detection

    func testCompilationDetection() {
        XCTAssertTrue(NewReleaseLogic.isCompilationLike(albumType: "compilation", name: "Whatever"))
        XCTAssertTrue(NewReleaseLogic.isCompilationLike(albumType: "COMPILATION", name: "Whatever"))
        XCTAssertTrue(NewReleaseLogic.isCompilationLike(albumType: "album", name: "Greatest Hits"))
        XCTAssertTrue(NewReleaseLogic.isCompilationLike(albumType: "album", name: "The Best Of Prince"))
    }

    func testCompilationDetectionDoesNotOverreach() {
        XCTAssertFalse(NewReleaseLogic.isCompilationLike(albumType: "album", name: "Hits Different"))
        XCTAssertFalse(NewReleaseLogic.isCompilationLike(albumType: "single", name: "Collection Agency"))
    }

    // MARK: - Album filter

    private func passes(_ a: CandidateAlbum,
                        _ filters: NewReleaseFilters = NewReleaseFilters(),
                        artist: String = "art1",
                        seen: Set<String> = []) -> Bool {
        NewReleaseLogic.albumPasses(
            a, artistId: artist, filters: filters, seenAlbumKeys: seen,
            cutoffDay: NewReleaseLogic.cutoffDay(now: now, watermark: epoch,
                                                 lastScanAt: nil, lookbackDays: 14),
            horizonDay: NewReleaseLogic.horizonDay(now: now))
    }

    func testFreshAlbumPasses() {
        XCTAssertTrue(passes(album(date: today)))
    }

    /// The cache is what makes repeat scans cheap — every settled album considered goes in,
    /// including rejected ones, so the next scan re-rejects them without a request.
    func testAlreadySeenAlbumIsSkipped() {
        let key = NewReleaseLogic.seenKey(albumId: "a1", artistId: "art1")
        XCTAssertFalse(passes(album("a1", date: today), seen: [key]))
    }

    /// Track selection is per followed artist, so the cache has to be too: a compilation swept
    /// for one artist must still be opened for the next one, whose tracks nobody has looked at.
    func testSeenIsPerArtistNotPerAlbum() {
        let key = NewReleaseLogic.seenKey(albumId: "a1", artistId: "art1")
        XCTAssertFalse(passes(album("a1", date: today), artist: "art1", seen: [key]))
        XCTAssertTrue(passes(album("a1", date: today), artist: "art2", seen: [key]))
    }

    /// A pre-announced release fails today's window for being past the horizon. Caching that
    /// verdict would skip it on the very day it becomes eligible.
    func testFutureDatedAlbumsAreNotCached() {
        let horizon = NewReleaseLogic.horizonDay(now: now)
        XCTAssertFalse(NewReleaseLogic.isSettled(album(date: "2027-01-01"), horizonDay: horizon))
        XCTAssertTrue(NewReleaseLogic.isSettled(album(date: today), horizonDay: horizon))
        // The horizon itself is the last settled day, since it's already eligible.
        XCTAssertTrue(NewReleaseLogic.isSettled(album(date: horizon), horizonDay: horizon))
    }

    /// Coarse dates can still be sharpened into the window later, and caching them saves nothing
    /// — a coarse album never passes the window, so it never costs a track request either.
    func testCoarseDatesAreNotCached() {
        let horizon = NewReleaseLogic.horizonDay(now: now)
        XCTAssertFalse(NewReleaseLogic.isSettled(album(date: "2019", precision: "year"),
                                                 horizonDay: horizon))
        XCTAssertFalse(NewReleaseLogic.isSettled(album(date: "2019-06", precision: "month"),
                                                 horizonDay: horizon))
    }

    func testOldAlbumIsSkipped() {
        XCTAssertFalse(passes(album(date: "2019-01-01")))
    }

    func testCompilationRespectsTheFilter() {
        let comp = album(name: "Greatest Hits", date: today)
        XCTAssertFalse(passes(comp))
        var off = NewReleaseFilters(); off.excludeCompilations = false
        XCTAssertTrue(passes(comp, off))
    }

    func testRemixAlbumRespectsTheFilter() {
        let remixes = album(name: "The Remixes", date: today)
        XCTAssertFalse(passes(remixes))
        var off = NewReleaseFilters(); off.excludeRemixes = false
        XCTAssertTrue(passes(remixes, off))
    }

    // MARK: - Track filter

    /// The check that makes `appears_on` usable: a various-artists compilation is one album
    /// with twenty tracks, nineteen of which have nothing to do with the followed artist.
    func testUncreditedTracksOnAnAppearsOnAlbumAreDropped() {
        let stranger = track(artists: ["someoneElse"])
        XCTAssertFalse(NewReleaseLogic.trackMatches(stranger, artistId: "artist1",
                                                    filters: NewReleaseFilters()))
    }

    func testFeatureCreditCountsByDefault() {
        let feature = track(artists: ["headliner", "artist1"])
        XCTAssertTrue(NewReleaseLogic.trackMatches(feature, artistId: "artist1",
                                                   filters: NewReleaseFilters()))
    }

    func testPrimaryArtistOnlyRequiresTheFirstCredit() {
        var filters = NewReleaseFilters(); filters.primaryArtistOnly = true
        let feature = track(artists: ["headliner", "artist1"])
        let lead = track(artists: ["artist1", "guest"])
        XCTAssertFalse(NewReleaseLogic.trackMatches(feature, artistId: "artist1", filters: filters))
        XCTAssertTrue(NewReleaseLogic.trackMatches(lead, artistId: "artist1", filters: filters))
    }

    /// A remix can sit on an album whose own title is clean, so the title check runs at both levels.
    func testRemixTrackOnACleanAlbumIsStillDropped() {
        let remix = track(name: "Song (Skrillex Remix)")
        XCTAssertFalse(NewReleaseLogic.trackMatches(remix, artistId: "artist1",
                                                    filters: NewReleaseFilters()))
        var off = NewReleaseFilters(); off.excludeRemixes = false
        XCTAssertTrue(NewReleaseLogic.trackMatches(remix, artistId: "artist1", filters: off))
    }

    // MARK: - Dedupe

    func testTitleKeyIgnoresCreditParentheticals() {
        XCTAssertEqual(NewReleaseLogic.titleKey("Song (feat. Someone)"),
                       NewReleaseLogic.titleKey("Song"))
        XCTAssertEqual(NewReleaseLogic.titleKey("Song (with Someone)"),
                       NewReleaseLogic.titleKey("Song"))
        XCTAssertEqual(NewReleaseLogic.titleKey("Song [ft. Someone]"),
                       NewReleaseLogic.titleKey("Song"))
    }

    func testTitleKeyIgnoresCaseAccentsAndPunctuation() {
        XCTAssertEqual(NewReleaseLogic.titleKey("Café — Déjà Vu!"),
                       NewReleaseLogic.titleKey("cafe deja vu"))
    }

    /// Stripping arbitrary suffixes would collapse genuinely distinct recordings.
    func testTitleKeyKeepsMeaningfulSuffixes() {
        XCTAssertNotEqual(NewReleaseLogic.titleKey("Song - Live"),
                          NewReleaseLogic.titleKey("Song"))
    }

    func testDedupeCollapsesTheSameTrackId() {
        let out = NewReleaseLogic.dedupe([track("t1"), track("t1")])
        XCTAssertEqual(out.map(\.id), ["t1"])
    }

    /// The common real duplicate: a lead single and its album cut are different ids.
    func testDedupeCollapsesSingleAndAlbumCutOfTheSameSong() {
        let single = track("t1", name: "Song (feat. Guest)", album: "single1")
        let cut = track("t2", name: "Song", album: "album1")
        XCTAssertEqual(NewReleaseLogic.dedupe([single, cut]).map(\.id), ["t1"])
    }

    func testDedupeKeepsDistinctSongs() {
        let a = track("t1", name: "One")
        let b = track("t2", name: "Two")
        XCTAssertEqual(NewReleaseLogic.dedupe([a, b]).map(\.id), ["t1", "t2"])
    }

    /// Same title by a different primary artist is a different song, not a duplicate.
    func testDedupeDoesNotCollapseAcrossArtists() {
        let a = track("t1", name: "Song", artists: ["artistA"])
        let b = track("t2", name: "Song", artists: ["artistB"])
        XCTAssertEqual(NewReleaseLogic.dedupe([a, b]).map(\.id), ["t1", "t2"])
    }

    /// Callers pass `.own` releases first so the canonical pressing survives.
    func testDedupeIsOrderPreservingAndFirstWins() {
        let own = track("t1", name: "Song", group: .own)
        let comp = track("t2", name: "Song", group: .appearsOn)
        let out = NewReleaseLogic.dedupe([own, comp])
        XCTAssertEqual(out.map(\.group), [.own])
    }

    func testDedupeOfEmptyInput() {
        XCTAssertTrue(NewReleaseLogic.dedupe([]).isEmpty)
    }

    // MARK: - Query planning

    func testFeaturesOffAsksOnlyForOwnReleases() {
        var filters = NewReleaseFilters(); filters.includeFeatures = false
        let queries = NewReleaseLogic.includeGroupsQueries(filters: filters)
        XCTAssertEqual(queries.map(\.groups), ["album", "single"])
    }

    /// The regression the probe caught: a combined `album,single` query returns each group's
    /// albums as separate descending runs concatenated, so the stop-early rule would quit on
    /// the first old album and never reach the singles. One group per query, always.
    func testEachGroupIsQueriedSeparately() {
        for query in NewReleaseLogic.includeGroupsQueries(filters: NewReleaseFilters()) {
            XCTAssertFalse(query.groups.contains(","),
                           "\(query.groups) combines groups; ordering only holds per group")
        }
    }

    /// With `limit` capped at 10, asking for a group we're about to discard would crowd real
    /// results out of page one.
    func testCompilationGroupIsNotRequestedWhenCompilationsAreExcluded() {
        let queries = NewReleaseLogic.includeGroupsQueries(filters: NewReleaseFilters())
        XCTAssertEqual(queries.map(\.groups), ["album", "single", "appears_on"])
    }

    func testCompilationGroupIsRequestedWhenWanted() {
        var filters = NewReleaseFilters(); filters.excludeCompilations = false
        let queries = NewReleaseLogic.includeGroupsQueries(filters: filters)
        XCTAssertEqual(queries.map(\.groups), ["album", "single", "compilation", "appears_on"])
    }

    func testOwnReleasesAreQueriedFirstSoDedupeKeepsThem() {
        XCTAssertEqual(NewReleaseLogic.includeGroupsQueries(filters: NewReleaseFilters()).first?.group,
                       .own)
    }

    /// Own-release groups come back newest-first so they can stop early; `appears_on` does not.
    func testOnlyAppearsOnIsExhaustive() {
        for query in NewReleaseLogic.includeGroupsQueries(filters: NewReleaseFilters()) {
            XCTAssertEqual(query.exhaustive, query.group == .appearsOn, "\(query.groups)")
        }
    }

    // MARK: - Amortizing appears_on

    /// Swift's `hashValue` is seeded per process; using it would reshuffle the deep-scan
    /// rotation on every launch and an artist could go weeks without their turn.
    func testStableHashIsNotProcessSeeded() {
        XCTAssertEqual(NewReleaseLogic.stableHash("4LEiUm1SRbFMgfqnQTwUbQ"),
                       NewReleaseLogic.stableHash("4LEiUm1SRbFMgfqnQTwUbQ"))
        XCTAssertNotEqual(NewReleaseLogic.stableHash("artistA"), NewReleaseLogic.stableHash("artistB"))
    }

    /// Every artist must come up exactly once per cycle — an artist assigned to no slot would
    /// never have their features scanned at all.
    func testEveryArtistIsDeepScannedExactlyOncePerCycle() {
        let slices = NewReleaseLogic.appearsOnSlices
        for artist in (0..<50).map({ "artist\($0)" }) {
            let hits = (0..<slices).filter {
                NewReleaseLogic.shouldDeepScan(artistId: artist, dayIndex: $0, slices: slices)
            }
            XCTAssertEqual(hits.count, 1, "\(artist) got \(hits.count) slots per cycle")
        }
    }

    /// The load must actually spread — everyone landing on one day defeats the point.
    func testDeepScanLoadIsSpreadAcrossSlices() {
        let slices = NewReleaseLogic.appearsOnSlices
        let artists = (0..<400).map { "artist\($0)" }
        for day in 0..<slices {
            let due = artists.filter { NewReleaseLogic.shouldDeepScan(artistId: $0, dayIndex: day) }
            XCTAssertGreaterThan(due.count, artists.count / (slices * 3),
                                 "day \(day) got only \(due.count) of \(artists.count)")
        }
    }

    func testSingleSliceMeansEveryArtistEveryDay() {
        XCTAssertTrue(NewReleaseLogic.shouldDeepScan(artistId: "a", dayIndex: 3, slices: 1))
        XCTAssertTrue(NewReleaseLogic.shouldDeepScan(artistId: "b", dayIndex: 3, slices: 0))
    }

    func testDayIndexAdvancesOncePerDay() {
        let base = NewReleaseLogic.dayIndex(now: now)
        XCTAssertEqual(NewReleaseLogic.dayIndex(now: now.addingTimeInterval(86_400)), base + 1)
    }

    /// A feature released the day after an artist's slot must still be in range at their next
    /// slot, or it is never found at all.
    func testLookbackIsClampedToCoverTheDeepScanCycle() {
        var tight = NewReleaseFilters(); tight.lookbackDays = 2
        XCTAssertEqual(NewReleaseLogic.effectiveLookbackDays(filters: tight),
                       NewReleaseLogic.appearsOnSlices)

        var noFeatures = tight; noFeatures.includeFeatures = false
        XCTAssertEqual(NewReleaseLogic.effectiveLookbackDays(filters: noFeatures), 2)

        var wide = NewReleaseFilters(); wide.lookbackDays = 30
        XCTAssertEqual(NewReleaseLogic.effectiveLookbackDays(filters: wide), 30)
    }

    // MARK: - Paging

    func testPageOneIsAlwaysFetched() {
        XCTAssertTrue(NewReleaseLogic.shouldFetchNextPage(pagesFetched: 0, itemsOnLastPage: 0,
                                                          lastPageReachedWindow: false,
                                                          exhaustive: false))
    }

    func testAShortPageEndsPaging() {
        XCTAssertFalse(NewReleaseLogic.shouldFetchNextPage(pagesFetched: 1, itemsOnLastPage: 4,
                                                           lastPageReachedWindow: true,
                                                           exhaustive: true))
    }

    func testPagingStopsOnceAFullPageIsOlderThanTheWindow() {
        XCTAssertFalse(NewReleaseLogic.shouldFetchNextPage(
            pagesFetched: 1, itemsOnLastPage: NewReleaseLogic.albumPageSize,
            lastPageReachedWindow: false, exhaustive: false))
    }

    func testPagingContinuesWhileDatesAreStillInReach() {
        XCTAssertTrue(NewReleaseLogic.shouldFetchNextPage(
            pagesFetched: 1, itemsOnLastPage: NewReleaseLogic.albumPageSize,
            lastPageReachedWindow: true, exhaustive: false))
    }

    /// The stop signal is the date boundary, not the filters. A page of albums already in the
    /// seen cache — or of remix packages — is still inside the window, and page two of a
    /// newest-first listing can hold a release that isn't.
    func testAPageOfRejectedButRecentAlbumsStillPagesOn() {
        let cutoff = NewReleaseLogic.cutoffDay(now: now, watermark: epoch,
                                               lastScanAt: nil, lookbackDays: 14)
        let recent = [album("a1", name: "The Remixes", date: today),
                      album("a2", name: "Greatest Hits", date: today)]
        XCTAssertTrue(NewReleaseLogic.pageReachesWindow(recent, cutoffDay: cutoff))
    }

    func testAPageEntirelyOlderThanTheCutoffEndsTheCrawl() {
        let cutoff = NewReleaseLogic.cutoffDay(now: now, watermark: epoch,
                                               lastScanAt: nil, lookbackDays: 14)
        let old = [album("a1", date: "2019-01-01"), album("a2", date: "2003", precision: "year")]
        XCTAssertFalse(NewReleaseLogic.pageReachesWindow(old, cutoffDay: cutoff))
        XCTAssertFalse(NewReleaseLogic.pageReachesWindow([], cutoffDay: cutoff))
    }

    /// The escape hatch for groups Spotify does not return newest-first.
    func testExhaustiveModePagesEvenOutsideTheWindow() {
        XCTAssertTrue(NewReleaseLogic.shouldFetchNextPage(
            pagesFetched: 1, itemsOnLastPage: NewReleaseLogic.albumPageSize,
            lastPageReachedWindow: false, exhaustive: true))
    }

    /// One absurdly prolific artist must not be able to consume the whole request budget.
    func testPageCapHoldsEvenInExhaustiveMode() {
        XCTAssertFalse(NewReleaseLogic.shouldFetchNextPage(
            pagesFetched: NewReleaseLogic.maxAlbumPagesPerGroup,
            itemsOnLastPage: NewReleaseLogic.albumPageSize,
            lastPageReachedWindow: true, exhaustive: true))
    }

    // MARK: - The `appears_on` crawl

    private func days(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }

    /// The page cap is a rate, not a horizon: each turn resumes where the last one stopped, so a
    /// guest appearance past the first 50 albums is reachable rather than permanently invisible.
    func testTheGuestCrawlResumesWhereItStopped() {
        let cap = NewReleaseLogic.maxAlbumPagesPerGroup
        let first = NewReleaseLogic.advancedGuestCrawl(nil, now: now, pagesFetched: cap,
                                                       reachedEndOfList: false)
        XCTAssertEqual(first.offset, cap * NewReleaseLogic.albumPageSize)
        let second = NewReleaseLogic.advancedGuestCrawl(first, now: now, pagesFetched: cap,
                                                        reachedEndOfList: false)
        XCTAssertEqual(second.offset, 2 * cap * NewReleaseLogic.albumPageSize)
        // A traversal in progress keeps its start, and with it the window it has to cover.
        XCTAssertEqual(second.startedAt, first.startedAt)
        XCTAssertNil(second.windowFrom)
    }

    /// Reaching the end wraps to the front, where new guest appearances are likeliest — and only
    /// then can the window shrink, because only then has every position been looked at.
    func testCompletingATraversalWrapsAndRollsTheWindow() {
        let started = NewReleaseLogic.GuestCrawl(offset: 200, startedAt: days(30), windowFrom: days(70))
        let wrapped = NewReleaseLogic.advancedGuestCrawl(started, now: now, pagesFetched: 2,
                                                         reachedEndOfList: true)
        XCTAssertEqual(wrapped.offset, 0)
        XCTAssertEqual(wrapped.startedAt, now)
        XCTAssertEqual(wrapped.windowFrom, days(30))   // the traversal that just finished
    }

    /// A turn that fetched nothing (not this artist's slot) must not walk the cursor forward.
    func testASkippedTurnLeavesTheCursorAlone() {
        let crawl = NewReleaseLogic.GuestCrawl(offset: 50, startedAt: days(3), windowFrom: days(10))
        let same = NewReleaseLogic.advancedGuestCrawl(crawl, now: now, pagesFetched: 0,
                                                      reachedEndOfList: false)
        XCTAssertEqual(same, crawl)
    }

    // MARK: - The guest window

    /// The whole point: a feature released during a long traversal is not yet visible when it
    /// comes out, and must still be admitted when the crawl finally reaches its position — weeks
    /// later, and far outside the ordinary look-back.
    func testAFeatureFoundLateInALongTraversalIsStillAdmitted() {
        let normal = NewReleaseLogic.cutoffDay(now: now, watermark: days(365),
                                               lastScanAt: days(1), lookbackDays: 14)
        // Ten turns a week apart: this artist's catalogue takes 70 days to traverse.
        let crawl = NewReleaseLogic.GuestCrawl(offset: 450, startedAt: days(35), windowFrom: days(105))
        let guest = NewReleaseLogic.guestCutoffDay(normalCutoff: normal, crawl: crawl,
                                                   watermark: days(365))
        let featureFrom30DaysAgo = NewReleaseLogic.dayString(days(30))
        XCTAssertLessThan(featureFrom30DaysAgo, normal)          // the old rule would reject it
        XCTAssertGreaterThanOrEqual(featureFrom30DaysAgo, guest) // the traversal window admits it
    }

    /// Never narrower than the ordinary window: a catalogue that wraps every turn shouldn't lose
    /// the normal look-back just because its last traversal was quick.
    func testTheGuestWindowOnlyEverWidens() {
        let normal = NewReleaseLogic.cutoffDay(now: now, watermark: days(365),
                                               lastScanAt: days(1), lookbackDays: 14)
        let quick = NewReleaseLogic.GuestCrawl(offset: 0, startedAt: now, windowFrom: days(1))
        XCTAssertEqual(NewReleaseLogic.guestCutoffDay(normalCutoff: normal, crawl: quick,
                                                      watermark: days(365)), normal)
    }

    /// Never past the watermark, whatever the traversal says — switching the radar on must not
    /// pull in the back catalogue by way of the guest crawl.
    func testTheGuestWindowStopsAtTheWatermark() {
        let watermark = days(5)
        let normal = NewReleaseLogic.cutoffDay(now: now, watermark: watermark,
                                               lastScanAt: nil, lookbackDays: 14)
        let old = NewReleaseLogic.GuestCrawl(offset: 300, startedAt: days(200), windowFrom: days(400))
        XCTAssertEqual(NewReleaseLogic.guestCutoffDay(normalCutoff: normal, crawl: old,
                                                      watermark: watermark),
                       NewReleaseLogic.dayString(watermark))
    }

    /// An artist never crawled has ruled nothing out, so their whole post-watermark guest
    /// catalogue is fair game the first time through.
    func testAnUncrawledArtistReachesBackToTheWatermark() {
        let watermark = days(60)
        let normal = NewReleaseLogic.cutoffDay(now: now, watermark: watermark,
                                               lastScanAt: days(1), lookbackDays: 14)
        XCTAssertEqual(NewReleaseLogic.guestCutoffDay(normalCutoff: normal, crawl: nil,
                                                      watermark: watermark),
                       NewReleaseLogic.dayString(watermark))
    }

    /// The per-artist window is also what survives a long absence: a guest release from before
    /// the last global scan is still admitted, because this artist's catalogue hadn't been looked
    /// at since well before then. `lastScanAt` covers everyone's own releases, nobody's features.
    func testTheGuestWindowOutlivesTheGlobalScanStamp() {
        let normal = NewReleaseLogic.cutoffDay(now: now, watermark: days(365),
                                               lastScanAt: days(21), lookbackDays: 14)
        XCTAssertEqual(normal, NewReleaseLogic.dayString(days(21)))   // catch-up back to last scan
        let crawl = NewReleaseLogic.GuestCrawl(offset: 100, startedAt: days(28), windowFrom: days(56))
        let guest = NewReleaseLogic.guestCutoffDay(normalCutoff: normal, crawl: crawl,
                                                   watermark: days(365))
        let featureFrom26DaysAgo = NewReleaseLogic.dayString(days(26))
        XCTAssertLessThan(featureFrom26DaysAgo, normal)
        XCTAssertGreaterThanOrEqual(featureFrom26DaysAgo, guest)
    }

    /// Pinned: `GET /artists/{id}/albums` dropped from 50 to 10 in Feb 2026, and paging with
    /// the old size silently returns only the first 10 of each page's worth.
    func testPageSizeMatchesTheEndpointCap() {
        XCTAssertEqual(NewReleaseLogic.albumPageSize, 10)
        XCTAssertEqual(NewReleaseLogic.addBatchSize, 100)
    }

    // MARK: - Scheduling

    func testFirstScanIsDue() {
        XCTAssertTrue(NewReleaseLogic.isScanDue(lastScanAt: nil, now: now))
    }

    func testRecentScanIsNotDue() {
        XCTAssertFalse(NewReleaseLogic.isScanDue(lastScanAt: now.addingTimeInterval(-3600), now: now))
    }

    func testScanIsDueAfterADay() {
        XCTAssertTrue(NewReleaseLogic.isScanDue(lastScanAt: now.addingTimeInterval(-25 * 3600),
                                                now: now))
    }

    /// A clock that moved backwards (timezone change, NTP correction) would otherwise block
    /// scans until real time caught up.
    func testAFutureLastScanIsTreatedAsDue() {
        XCTAssertTrue(NewReleaseLogic.isScanDue(lastScanAt: now.addingTimeInterval(86_400), now: now))
    }

    // MARK: - Labels

    func testSummaryLabelPluralization() {
        XCTAssertEqual(NewReleaseLogic.summaryLabel(added: 0, artists: 0), "No new releases found.")
        XCTAssertEqual(NewReleaseLogic.summaryLabel(added: 1, artists: 1),
                       "Added 1 track from 1 artist.")
        XCTAssertEqual(NewReleaseLogic.summaryLabel(added: 12, artists: 9),
                       "Added 12 tracks from 9 artists.")
    }

    func testProgressLabel() {
        XCTAssertEqual(NewReleaseLogic.progressLabel(artistsDone: 40, artistsTotal: 412, found: 1),
                       "Scanning 40 of 412 artists — 1 new track")
    }

    /// Stopping partway must say how far it got and that it will pick up — the resume cursor
    /// means the next attempt continues rather than restarting.
    func testInterruptedLabelReportsProgress() {
        XCTAssertEqual(
            NewReleaseLogic.interruptedLabel(added: 3, artistsDone: 40, artistsTotal: 412,
                                             reason: "Rate limited."),
            "Paused after 40 of 412 artists (3 added): Rate limited. Will resume.")
    }

    /// Switching the radar off mid-sweep isn't a failure and carries no promise to continue.
    func testStoppedLabelDoesNotPromiseToResume() {
        XCTAssertEqual(
            NewReleaseLogic.stoppedLabel(added: 3, artistsDone: 40, artistsTotal: 412),
            "Stopped after 40 of 412 artists (3 added).")
    }
}
