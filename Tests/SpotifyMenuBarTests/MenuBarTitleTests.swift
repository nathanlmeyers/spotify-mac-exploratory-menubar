import XCTest
import CoreGraphics

/// Fitting the menu bar text to a *width* rather than a character count. The regression these
/// guard is real: a 45-character budget let a realistic artist+title render ~300pt wide, which
/// on a notched Mac doesn't fit the status area, so macOS hid the item and the app looked dead.
final class MenuBarTitleTests: XCTestCase {

    /// 10pt per character — proportional enough to catch count-vs-width confusion while
    /// keeping the arithmetic in these tests obvious.
    private let uniform: (String) -> CGFloat = { CGFloat($0.count) * 10 }

    /// A deliberately non-uniform measurer: "W" is 4x an "i". Mirrors the real font, where
    /// the same character count spans a 4x width range.
    private let proportional: (String) -> CGFloat = { s in
        s.reduce(CGFloat(0)) { total, ch in
            switch ch {
            case "W", "M": return total + 40
            case "i", "l", "…": return total + 10
            default: return total + 20
            }
        }
    }

    // MARK: fitted

    func testFullTextWhenItFits() {
        XCTAssertEqual(
            MenuBarTitle.fitted(title: "BESO", artists: "ROSALIA", maxWidth: 500, measure: uniform),
            "ROSALIA — BESO")
    }

    func testArtistIsSacrificedBeforeTheTitle() {
        // "ROSALIA — BESO" is 14 chars = 140pt. At 120pt the artist must give ground and the
        // title must survive intact — the song is the point of the label.
        let out = MenuBarTitle.fitted(title: "BESO", artists: "ROSALIA",
                                      maxWidth: 120, measure: uniform)
        XCTAssertTrue(out.hasSuffix(" — BESO"), "title should survive, got \(out)")
        XCTAssertTrue(out.contains("…"), "artist should be elided, got \(out)")
        XCTAssertLessThanOrEqual(uniform(out), 120)
    }

    func testTitleAloneWhenThereIsNoRoomForAnyArtist() {
        // 60pt fits neither the separator (30pt) nor a useful artist, so drop the artist.
        let out = MenuBarTitle.fitted(title: "Flowers", artists: "Oliver Tree",
                                      maxWidth: 60, measure: uniform)
        XCTAssertFalse(out.contains("—"), "separator should be gone, got \(out)")
        XCTAssertLessThanOrEqual(uniform(out), 60)
    }

    func testVeryLongTitleIsBoundedByWidth() {
        // The real case from the user's playlist: a ~200-character song title.
        let monster = String(repeating: "you said we were going out for half priced apps ", count: 5)
        let out = MenuBarTitle.fitted(title: monster, artists: "George William Thomas",
                                      maxWidth: 150, measure: uniform)
        XCTAssertLessThanOrEqual(uniform(out), 150)
        XCTAssertTrue(out.hasSuffix("…"))
    }

    func testWidthNotCharacterCountIsWhatBounds() {
        // Same character count, 4x the width. A character budget would pass both; a width
        // budget must clip the wide one. This is the actual bug being fixed.
        let narrow = MenuBarTitle.fitted(title: String(repeating: "i", count: 20),
                                         artists: "", maxWidth: 200, measure: proportional)
        let wide = MenuBarTitle.fitted(title: String(repeating: "W", count: 20),
                                       artists: "", maxWidth: 200, measure: proportional)
        XCTAssertEqual(narrow.count, 20, "narrow text fits whole")
        XCTAssertLessThan(wide.count, 20, "wide text must be clipped")
        XCTAssertLessThanOrEqual(proportional(wide), 200)
    }

    func testNoArtist() {
        XCTAssertEqual(
            MenuBarTitle.fitted(title: "BESO", artists: "", maxWidth: 500, measure: uniform),
            "BESO")
    }

    func testEmptyTitleYieldsNothing() {
        XCTAssertEqual(MenuBarTitle.fitted(title: "", artists: "ROSALIA",
                                           maxWidth: 500, measure: uniform), "")
        XCTAssertEqual(MenuBarTitle.fitted(title: "   ", artists: "ROSALIA",
                                           maxWidth: 500, measure: uniform), "")
    }

    func testZeroWidthYieldsNothing() {
        XCTAssertEqual(MenuBarTitle.fitted(title: "BESO", artists: "ROSALIA",
                                           maxWidth: 0, measure: uniform), "")
    }

    /// Whatever the inputs, the result must never exceed the budget — that is the whole
    /// contract, and the one that keeps the status item visible.
    func testNeverExceedsBudget() {
        let titles = ["", "a", "BESO", String(repeating: "W", count: 300), "Café ☕️ Mix"]
        let artists = ["", "x", "ROSALIA, Rauw Alejandro", String(repeating: "M", count: 120)]
        for width in [0, 1, 10, 45, 100, 150, 240, 1000].map(CGFloat.init) {
            for t in titles {
                for a in artists {
                    let out = MenuBarTitle.fitted(title: t, artists: a,
                                                  maxWidth: width, measure: proportional)
                    XCTAssertLessThanOrEqual(proportional(out), width,
                                             "overflow: width=\(width) title=\(t) artists=\(a) -> \(out)")
                }
            }
        }
    }

    // MARK: truncated

    func testTruncatedLeavesFittingStringsAlone() {
        XCTAssertEqual(MenuBarTitle.truncated("abc", toWidth: 100, measure: uniform), "abc")
    }

    func testTruncatedAddsEllipsisWithinBudget() {
        // 5 chars = 50pt; budget 30pt fits "ab…" (30pt) but not "abc…" (40pt).
        XCTAssertEqual(MenuBarTitle.truncated("abcde", toWidth: 30, measure: uniform), "ab…")
    }

    func testTruncatedReturnsEmptyWhenEvenEllipsisWontFit() {
        XCTAssertEqual(MenuBarTitle.truncated("abcde", toWidth: 5, measure: uniform), "")
    }

    /// Multi-scalar graphemes must not be split apart mid-cluster.
    func testTruncatedRespectsGraphemeClusters() {
        let flags = "🇺🇸🇬🇧🇯🇵🇩🇪"
        let out = MenuBarTitle.truncated(flags, toWidth: 25, measure: uniform)
        XCTAssertTrue(flags.hasPrefix(String(out.dropLast())), "cut on a grapheme boundary, got \(out)")
        XCTAssertLessThanOrEqual(uniform(out), 25)
    }
}
