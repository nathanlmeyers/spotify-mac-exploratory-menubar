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
}
