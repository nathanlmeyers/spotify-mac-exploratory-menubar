import XCTest

/// The rule behind the Add button's checkmark. It is disabled when checked, so a false positive
/// here is a song the user cannot add at all — every "unknown" case below must answer false.
final class CurationLogicTests: XCTestCase {

    private let song = "spotify:track:abc"
    private let target = "playlist1"

    private func shows(uri: String?,
                       loadedFor: String? = "playlist1",
                       current: String? = "playlist1",
                       membership: Set<String>) -> Bool {
        CurationLogic.showsInTarget(trackURI: uri,
                                    membershipTargetId: loadedFor,
                                    currentTargetId: current,
                                    membership: membership)
    }

    func testTrackInTheCurrentTargetShowsAsAdded() {
        XCTAssertTrue(shows(uri: song, membership: [song]))
    }

    func testTrackNotInTheTargetIsNotAdded() {
        XCTAssertFalse(shows(uri: song, membership: ["spotify:track:other"]))
    }

    /// Cold start, a rate-limited fetch, or an offline launch all land here. Unknown reads as
    /// "not added" so the button stays pressable.
    func testUnloadedMembershipIsNotAdded() {
        XCTAssertFalse(shows(uri: song, membership: []))
    }

    func testNilAndEmptyURIsAreNotAdded() {
        XCTAssertFalse(shows(uri: nil, membership: [song]))
        XCTAssertFalse(shows(uri: "", membership: [song, ""]))
    }

    /// `playlistTrackURIs` stores whatever the playlist holds, episodes included — but Add
    /// refuses non-songs, so one must never wear the checkmark.
    func testNonCuratableURIsAreNotAddedEvenWhenPresent() {
        for uri in ["spotify:episode:abc", "spotify:local:abc", "spotify:ad:abc", "nonsense"] {
            XCTAssertFalse(shows(uri: uri, membership: [uri]), uri)
        }
    }

    /// The set belongs to the playlist we just switched away from. Answering from it would grey
    /// out Add for songs that are not in the new target at all.
    func testMembershipLoadedForADifferentTargetIsNotAdded() {
        XCTAssertFalse(shows(uri: song, loadedFor: "playlist2", current: target, membership: [song]))
    }

    func testNoTargetSetIsNotAdded() {
        XCTAssertFalse(shows(uri: song, loadedFor: nil, current: nil, membership: [song]))
    }

    /// Both nil would compare equal; a target has to actually exist before Add can be "done".
    func testNilTargetDoesNotMatchNilMembershipTarget() {
        XCTAssertFalse(shows(uri: song, loadedFor: nil, current: nil, membership: [song]))
        XCTAssertFalse(shows(uri: song, loadedFor: target, current: nil, membership: [song]))
    }
}
