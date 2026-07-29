import XCTest

/// The backoff that turns a 429 storm into a pause. The regression these guard is measured:
/// with no backoff, a throttled session logged exactly 60 "Too many requests" per minute —
/// one per poll tick — 403,329 times in a single debug log.
final class RateLimitTests: XCTestCase {

    func testHonorsTheAdvertisedDelay() {
        XCTAssertEqual(RateLimit.backoffInterval(retryAfterHeader: "3"), 3)
        XCTAssertEqual(RateLimit.backoffInterval(retryAfterHeader: "30"), 30)
    }

    func testMissingHeaderFallsBack() {
        XCTAssertEqual(RateLimit.backoffInterval(retryAfterHeader: nil), RateLimit.fallback)
    }

    func testUnparseableHeaderFallsBack() {
        // Spotify documents integer seconds, but an HTTP-date or junk must not become 0.
        XCTAssertEqual(RateLimit.backoffInterval(retryAfterHeader: "Wed, 29 Jul 2026 16:00:00 GMT"),
                       RateLimit.fallback)
        XCTAssertEqual(RateLimit.backoffInterval(retryAfterHeader: ""), RateLimit.fallback)
        XCTAssertEqual(RateLimit.backoffInterval(retryAfterHeader: "soon"), RateLimit.fallback)
    }

    func testWhitespaceIsTolerated() {
        XCTAssertEqual(RateLimit.backoffInterval(retryAfterHeader: " 7 "), 7)
    }

    /// Zero or negative would mean "resume immediately", which is exactly the hammering the
    /// backoff exists to prevent — so it must floor at a real pause.
    func testZeroOrNegativeStillPauses() {
        XCTAssertEqual(RateLimit.backoffInterval(retryAfterHeader: "0"), 1)
        XCTAssertEqual(RateLimit.backoffInterval(retryAfterHeader: "-5"), 1)
    }

    /// A huge value would silence the app for hours and look like a hang.
    func testImplausiblyLargeValueIsCapped() {
        XCTAssertEqual(RateLimit.backoffInterval(retryAfterHeader: "86400"), RateLimit.cap)
        XCTAssertEqual(RateLimit.backoffInterval(retryAfterHeader: "99999999"), RateLimit.cap)
    }

    /// Whatever arrives, the result is always a usable pause inside the allowed band.
    func testAlwaysWithinBounds() {
        let headers: [String?] = [nil, "", " ", "0", "-1", "1", "5", "59", "60", "61",
                                  "1e9", "NaN", "inf", "abc", "3.5"]
        for h in headers {
            let v = RateLimit.backoffInterval(retryAfterHeader: h)
            XCTAssertGreaterThanOrEqual(v, 1, "header \(h ?? "nil") produced \(v)")
            XCTAssertLessThanOrEqual(v, RateLimit.cap, "header \(h ?? "nil") produced \(v)")
            XCTAssertFalse(v.isNaN, "header \(h ?? "nil") produced NaN")
        }
    }
}
