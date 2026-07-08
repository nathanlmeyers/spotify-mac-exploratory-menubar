import XCTest

/// Tests the pure discovery decisions used by DiscoveryEngine: auto-skip rule
/// precedence and loop-protection stop conditions.
final class DiscoveryLogicTests: XCTestCase {

    // MARK: Auto-skip precedence

    func testNoAutoSkipWhenRulesOff() {
        XCTAssertNil(DiscoveryLogic.autoSkipKind(
            sourceConfirmed: true, inTarget: true, reviewed: true,
            skipIfInTarget: false, skipAlreadyReviewed: false))
    }

    func testInTargetWins() {
        XCTAssertEqual(
            DiscoveryLogic.autoSkipKind(sourceConfirmed: true, inTarget: true, reviewed: true,
                                        skipIfInTarget: true, skipAlreadyReviewed: true),
            .inTarget)
    }

    func testReviewedWhenNotInTarget() {
        XCTAssertEqual(
            DiscoveryLogic.autoSkipKind(sourceConfirmed: true, inTarget: false, reviewed: true,
                                        skipIfInTarget: true, skipAlreadyReviewed: true),
            .reviewed)
    }

    func testFlagsGateEachRule() {
        // In target but the in-target rule is off, reviewed rule on -> reviewed.
        XCTAssertEqual(
            DiscoveryLogic.autoSkipKind(sourceConfirmed: true, inTarget: true, reviewed: true,
                                        skipIfInTarget: false, skipAlreadyReviewed: true),
            .reviewed)
        // Reviewed but that rule is off -> no skip.
        XCTAssertNil(
            DiscoveryLogic.autoSkipKind(sourceConfirmed: false, inTarget: false, reviewed: true,
                                        skipIfInTarget: true, skipAlreadyReviewed: false))
    }

    func testNoAutoSkipWhenSourceUnconfirmed() {
        // Stale source context (resolved for a different track): never skip, even when the
        // track is in target / reviewed and both rules are on. This is the regression guard
        // for playing the target playlist auto-skipping reviewed/in-target songs.
        XCTAssertNil(
            DiscoveryLogic.autoSkipKind(sourceConfirmed: false, inTarget: true, reviewed: true,
                                        skipIfInTarget: true, skipAlreadyReviewed: true))
    }

    // MARK: Loop protection

    func testExhaustsOnRepeatedURI() {
        XCTAssertTrue(DiscoveryLogic.isExhausted(
            uri: "spotify:track:a", visited: ["spotify:track:a"],
            consecutiveSoFar: 1, ceiling: 25))
    }

    func testExhaustsAtCeiling() {
        // 24 already skipped; recording the 25th hits the ceiling.
        XCTAssertTrue(DiscoveryLogic.isExhausted(
            uri: "spotify:track:new", visited: [], consecutiveSoFar: 24, ceiling: 25))
    }

    func testNotExhaustedBelowCeilingAndUnseen() {
        XCTAssertFalse(DiscoveryLogic.isExhausted(
            uri: "spotify:track:new", visited: ["spotify:track:other"],
            consecutiveSoFar: 3, ceiling: 25))
    }

    // MARK: Source == target (deletion guard for the reported mass-delete bug)

    func testSourceIsTargetWhenEqual() {
        XCTAssertTrue(DiscoveryLogic.sourceIsTarget(sourcePlaylistId: "p1", targetPlaylistId: "p1"))
    }

    func testSourceIsTargetWhenDifferent() {
        XCTAssertFalse(DiscoveryLogic.sourceIsTarget(sourcePlaylistId: "p1", targetPlaylistId: "p2"))
    }

    func testSourceIsTargetWithNils() {
        XCTAssertFalse(DiscoveryLogic.sourceIsTarget(sourcePlaylistId: nil, targetPlaylistId: nil))
        XCTAssertFalse(DiscoveryLogic.sourceIsTarget(sourcePlaylistId: nil, targetPlaylistId: "p1"))
        XCTAssertFalse(DiscoveryLogic.sourceIsTarget(sourcePlaylistId: "p1", targetPlaylistId: nil))
    }

    // MARK: mayRemoveFromSource (move-never-deletes-target + source-must-match-track)

    func testMoveNeverRemovesFromTarget() {
        // Move where the source IS the target: must refuse, even if the track matches.
        XCTAssertFalse(DiscoveryLogic.mayRemoveFromSource(
            sourcePlaylistId: "p1", targetPlaylistId: "p1",
            sourceTrackURI: "spotify:track:a", actedURI: "spotify:track:a", isMove: true))
    }

    func testMoveFromDifferentSourceAllowedWhenTrackMatches() {
        XCTAssertTrue(DiscoveryLogic.mayRemoveFromSource(
            sourcePlaylistId: "src", targetPlaylistId: "tgt",
            sourceTrackURI: "spotify:track:a", actedURI: "spotify:track:a", isMove: true))
    }

    func testManualRemoveFromTargetAllowedWhenTrackMatches() {
        // Explicit (non-move) removal from the target is a deliberate user action.
        XCTAssertTrue(DiscoveryLogic.mayRemoveFromSource(
            sourcePlaylistId: "p1", targetPlaylistId: "p1",
            sourceTrackURI: "spotify:track:a", actedURI: "spotify:track:a", isMove: false))
    }

    func testRemoveRefusedWhenSourceTrackMismatch() {
        // Stale source resolved for a different track than the one being acted on.
        XCTAssertFalse(DiscoveryLogic.mayRemoveFromSource(
            sourcePlaylistId: "src", targetPlaylistId: "tgt",
            sourceTrackURI: "spotify:track:OLD", actedURI: "spotify:track:NEW", isMove: false))
        XCTAssertFalse(DiscoveryLogic.mayRemoveFromSource(
            sourcePlaylistId: "src", targetPlaylistId: "tgt",
            sourceTrackURI: nil, actedURI: "spotify:track:NEW", isMove: true))
    }

    func testRemoveRefusedWhenNoSourcePlaylist() {
        XCTAssertFalse(DiscoveryLogic.mayRemoveFromSource(
            sourcePlaylistId: nil, targetPlaylistId: "tgt",
            sourceTrackURI: "spotify:track:a", actedURI: "spotify:track:a", isMove: false))
    }

    // MARK: Device-name normalization (this-Mac match must survive cosmetic differences)

    func testDeviceNameExactMatch() {
        XCTAssertEqual(DiscoveryLogic.normalizedDeviceName("Nathan's MacBook Pro"),
                       DiscoveryLogic.normalizedDeviceName("Nathan's MacBook Pro"))
    }

    func testDeviceNameCurlyVsStraightApostrophe() {
        // Spotify may report a straight apostrophe while macOS uses the curly U+2019.
        XCTAssertEqual(DiscoveryLogic.normalizedDeviceName("Nathan\u{2019}s MacBook Pro"),
                       DiscoveryLogic.normalizedDeviceName("Nathan's MacBook Pro"))
    }

    func testDeviceNameDropsCollisionSuffix() {
        // macOS appends " (2)" on name collisions; Spotify often omits it.
        XCTAssertEqual(DiscoveryLogic.normalizedDeviceName("Nathan\u{2019}s MacBook Pro (2)"),
                       DiscoveryLogic.normalizedDeviceName("Nathan's MacBook Pro"))
    }

    func testDeviceNameCaseInsensitive() {
        XCTAssertEqual(DiscoveryLogic.normalizedDeviceName("NATHAN\u{2019}s MacBook Pro (2)"),
                       DiscoveryLogic.normalizedDeviceName("nathan's macbook pro"))
    }

    func testDeviceNameDistinctComputersStillDiffer() {
        // Two genuinely different Macs must NOT normalize to the same value.
        XCTAssertNotEqual(DiscoveryLogic.normalizedDeviceName("Nathan's MacBook Pro"),
                          DiscoveryLogic.normalizedDeviceName("Work MacBook Air"))
    }

    // MARK: Natural-advance gate (reclaim a track that auto-advanced before we held it)

    func testNaturalAdvanceWhenNearEnd() {
        // 2s left on a 200s track, within the 13s crossfade window -> auto-advance.
        XCTAssertTrue(DiscoveryLogic.isNaturalAdvance(
            prevRemaining: 2, prevDuration: 200, crossfadeWindow: 13, minHoldableDuration: 3))
    }

    func testNaturalAdvanceCoversMaxCrossfade() {
        // 12s left (Spotify's max crossfade) still counts as an auto-advance.
        XCTAssertTrue(DiscoveryLogic.isNaturalAdvance(
            prevRemaining: 12, prevDuration: 200, crossfadeWindow: 13, minHoldableDuration: 3))
    }

    func testNotNaturalAdvanceWhenFarFromEnd() {
        // 60s left -> deliberate mid-song skip; don't reclaim.
        XCTAssertFalse(DiscoveryLogic.isNaturalAdvance(
            prevRemaining: 60, prevDuration: 200, crossfadeWindow: 13, minHoldableDuration: 3))
    }

    func testNotNaturalAdvanceForShortInterstitial() {
        // A sub-minHoldableDuration item is never reclaimed even if "near end".
        XCTAssertFalse(DiscoveryLogic.isNaturalAdvance(
            prevRemaining: 0.5, prevDuration: 2, crossfadeWindow: 13, minHoldableDuration: 3))
    }

    // MARK: Departure classifier (watched/held track left us — runoff vs deliberate)

    private let held = "spotify:track:held"

    private func reclaimDeparture(prevURI: String?, playing: Bool, remaining: Double,
                                  duration: Double = 200) -> Bool {
        DiscoveryLogic.shouldReclaimDeparture(
            prevURI: prevURI, prevWasPlaying: playing,
            prevRemaining: remaining, prevDuration: duration,
            expectedURI: held, crossfadeWindow: 13, minHoldableDuration: 3)
    }

    func testDepartureReclaimedOnRunoff() {
        // The pause didn't take: last tick showed the expected track playing 1s from its end.
        XCTAssertTrue(reclaimDeparture(prevURI: held, playing: true, remaining: 1.0))
    }

    func testDepartureReclaimedOnRelistenRunoff() {
        // Re-listen tail at the poll-granularity worst case (re-pin window edge).
        XCTAssertTrue(reclaimDeparture(prevURI: held, playing: true, remaining: 2.3))
    }

    func testDepartureReleasedWhenParkedPaused() {
        // Parked (paused) track changed: the user picked another song in the Spotify app.
        // Release — never fight a deliberate selection. Applies to holds AND paused watching.
        XCTAssertFalse(reclaimDeparture(prevURI: held, playing: false, remaining: 1.3))
    }

    func testDepartureReleasedOnMidSongSkip() {
        // Deliberate skip far from the end (e.g. after scrubbing back during a re-listen).
        XCTAssertFalse(reclaimDeparture(prevURI: held, playing: true, remaining: 60))
    }

    func testDepartureReleasedWhenPrevAlreadySuccessor() {
        // Post-sleep/gap: by the time we look, the previous tick already showed the
        // successor (or nothing) — too late to know what happened; release.
        XCTAssertFalse(reclaimDeparture(prevURI: "spotify:track:successor", playing: true, remaining: 1.0))
        XCTAssertFalse(reclaimDeparture(prevURI: nil, playing: true, remaining: 1.0))
    }

    func testDepartureReleasedForShortInterstitial() {
        XCTAssertFalse(reclaimDeparture(prevURI: held, playing: true, remaining: 0.5, duration: 2))
    }
}
