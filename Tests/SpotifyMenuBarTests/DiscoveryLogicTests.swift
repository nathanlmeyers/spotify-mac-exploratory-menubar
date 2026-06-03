import XCTest

/// Tests the pure discovery decisions used by DiscoveryEngine: auto-skip rule
/// precedence and loop-protection stop conditions.
final class DiscoveryLogicTests: XCTestCase {

    // MARK: Auto-skip precedence

    func testNoAutoSkipWhenRulesOff() {
        XCTAssertNil(DiscoveryLogic.autoSkipKind(
            inTarget: true, reviewed: true,
            skipIfInTarget: false, skipAlreadyReviewed: false))
    }

    func testInTargetWins() {
        XCTAssertEqual(
            DiscoveryLogic.autoSkipKind(inTarget: true, reviewed: true,
                                        skipIfInTarget: true, skipAlreadyReviewed: true),
            .inTarget)
    }

    func testReviewedWhenNotInTarget() {
        XCTAssertEqual(
            DiscoveryLogic.autoSkipKind(inTarget: false, reviewed: true,
                                        skipIfInTarget: true, skipAlreadyReviewed: true),
            .reviewed)
    }

    func testFlagsGateEachRule() {
        // In target but the in-target rule is off, reviewed rule on -> reviewed.
        XCTAssertEqual(
            DiscoveryLogic.autoSkipKind(inTarget: true, reviewed: true,
                                        skipIfInTarget: false, skipAlreadyReviewed: true),
            .reviewed)
        // Reviewed but that rule is off -> no skip.
        XCTAssertNil(
            DiscoveryLogic.autoSkipKind(inTarget: false, reviewed: true,
                                        skipIfInTarget: true, skipAlreadyReviewed: false))
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
}
