import XCTest

/// Tests the pure now-playing snapshot → `NowPlaying` mapping. This is the layer that
/// fixes the intermittent "wrong song" bug: the Objective-C bridge hands up a single,
/// internally-consistent snapshot dictionary and this mapper turns it into `NowPlaying`.
/// Field mapping, missing-key handling, and the ms↔s duration heuristic are all exercised
/// here without needing Spotify running.
final class LocalSpotifyMappingTests: XCTestCase {

    func testFullSnapshotMapsAllFields() {
        let snapshot: [String: Any] = [
            SpotifyTrackKey.id: "spotify:track:abc",
            SpotifyTrackKey.name: "Crab Rave",
            SpotifyTrackKey.artist: "Noisestorm",
            SpotifyTrackKey.album: "Crab Rave",
            SpotifyTrackKey.artworkURL: "https://i.scdn.co/image/abc",
            SpotifyTrackKey.durationRaw: 175,
        ]
        let np = NowPlayingMapping.makeNowPlaying(
            from: snapshot, positionSeconds: 42, isPlaying: true, isShuffling: false)

        XCTAssertEqual(np?.uri, "spotify:track:abc")
        XCTAssertEqual(np?.name, "Crab Rave")
        XCTAssertEqual(np?.artist, "Noisestorm")
        XCTAssertEqual(np?.album, "Crab Rave")
        XCTAssertEqual(np?.artworkURL, URL(string: "https://i.scdn.co/image/abc"))
        XCTAssertEqual(np?.durationSeconds, 175)
        // App-level facts pass through verbatim.
        XCTAssertEqual(np?.positionSeconds, 42)
        XCTAssertEqual(np?.isPlaying, true)
        XCTAssertEqual(np?.isShuffling, false)
    }

    func testMissingFieldsDefaultSafely() {
        // Only an id (the gate). Everything else absent.
        let np = NowPlayingMapping.makeNowPlaying(
            from: [SpotifyTrackKey.id: "spotify:track:xyz"],
            positionSeconds: 0, isPlaying: false, isShuffling: true)

        XCTAssertEqual(np?.uri, "spotify:track:xyz")
        XCTAssertEqual(np?.name, "")
        XCTAssertEqual(np?.artist, "")
        XCTAssertEqual(np?.album, "")
        XCTAssertNil(np?.artworkURL)
        XCTAssertEqual(np?.durationSeconds, 0)
        XCTAssertEqual(np?.isShuffling, true)
    }

    func testEmptyOrMissingIdReturnsNil() {
        XCTAssertNil(NowPlayingMapping.makeNowPlaying(
            from: [:], positionSeconds: 0, isPlaying: false, isShuffling: false))
        XCTAssertNil(NowPlayingMapping.makeNowPlaying(
            from: [SpotifyTrackKey.id: ""], positionSeconds: 0, isPlaying: false, isShuffling: false))
    }

    func testNonStringArtworkIsIgnored() {
        let snapshot: [String: Any] = [
            SpotifyTrackKey.id: "spotify:track:abc",
            SpotifyTrackKey.artworkURL: 12345,   // not a String
        ]
        let np = NowPlayingMapping.makeNowPlaying(
            from: snapshot, positionSeconds: 0, isPlaying: true, isShuffling: false)
        XCTAssertNotNil(np)
        XCTAssertNil(np?.artworkURL)
    }

    // MARK: - Duration normalization (Spotify reports seconds, historically milliseconds)

    func testDurationNormalizationSeconds() {
        XCTAssertEqual(NowPlayingMapping.normalizeDuration(210), 210)
        XCTAssertEqual(NowPlayingMapping.normalizeDuration(210.5), 210.5)
    }

    func testDurationNormalizationMilliseconds() {
        XCTAssertEqual(NowPlayingMapping.normalizeDuration(210000), 210)
    }

    func testDurationNormalizationBoundary() {
        // 10000 is the threshold: kept as-is; just over it is treated as milliseconds.
        XCTAssertEqual(NowPlayingMapping.normalizeDuration(10000), 10000)
        XCTAssertEqual(NowPlayingMapping.normalizeDuration(10001), 10.001, accuracy: 0.0001)
    }

    func testDurationNormalizationAcceptsNSNumberAndMissing() {
        XCTAssertEqual(NowPlayingMapping.normalizeDuration(NSNumber(value: 175)), 175)
        XCTAssertEqual(NowPlayingMapping.normalizeDuration(NSNumber(value: 240000)), 240)
        XCTAssertEqual(NowPlayingMapping.normalizeDuration(nil), 0)
        XCTAssertEqual(NowPlayingMapping.normalizeDuration("not a number"), 0)
    }
}
