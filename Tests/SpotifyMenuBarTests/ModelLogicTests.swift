import XCTest

/// These test the pure model logic (URI classification + playlist editability),
/// which is the part most likely to silently break curation behavior.
final class ModelLogicTests: XCTestCase {

    func testURIClassification() {
        XCTAssertEqual(NowPlaying.classify("spotify:track:abc"), .track)
        XCTAssertEqual(NowPlaying.classify("spotify:episode:abc"), .episode)
        XCTAssertEqual(NowPlaying.classify("spotify:local:x:y:z"), .localFile)
        XCTAssertEqual(NowPlaying.classify("spotify:ad:abc"), .ad)
        XCTAssertEqual(NowPlaying.classify(""), .ad)
        XCTAssertEqual(NowPlaying.classify("spotify:show:abc"), .unknown)
    }

    func testOnlyTracksAreCuratable() {
        XCTAssertTrue(TrackKind.track.isCuratable)
        XCTAssertFalse(TrackKind.episode.isCuratable)
        XCTAssertFalse(TrackKind.localFile.isCuratable)
        XCTAssertFalse(TrackKind.ad.isCuratable)
        XCTAssertFalse(TrackKind.unknown.isCuratable)
    }

    func testEditability() {
        let owned = Playlist(id: "1", name: "Crab Hands", uri: "spotify:playlist:1",
                             ownerId: "me", collaborative: false)
        let collab = Playlist(id: "2", name: "Shared", uri: "spotify:playlist:2",
                              ownerId: "friend", collaborative: true)
        let foreign = Playlist(id: "3", name: "Discover Weekly", uri: "spotify:playlist:3",
                               ownerId: "spotify", collaborative: false)

        XCTAssertTrue(owned.isEditable(byUserId: "me"))
        XCTAssertTrue(collab.isEditable(byUserId: "me"))
        XCTAssertFalse(foreign.isEditable(byUserId: "me"))
        XCTAssertFalse(owned.isEditable(byUserId: nil))
    }
}
