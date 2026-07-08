import Foundation

/// Swift-facing wrapper over the Objective-C `SpotifyBridge` (ScriptingBridge).
/// All playback reads/controls are local and require no Premium / no login.
@MainActor
final class LocalSpotifyController {
    private let bridge = SpotifyBridge()
    private var didLogSnapshotKeys = false

    var isAppRunning: Bool { bridge.isRunning }
    /// Lightweight "actively playing here" probe (one Apple event, no track snapshot) —
    /// used by the per-second device-locality refresh.
    var isPlaying: Bool { bridge.isRunning && bridge.playerState == .playing }

    /// Current playback snapshot, or nil if Spotify isn't running / nothing is playing.
    ///
    /// Track-identity fields (uri/name/artist/album/artwork/duration) come from a single
    /// atomic `currentTrackSnapshot` so they can never straddle a track change. The
    /// app-level facts below (position/isPlaying/isShuffling) live on the app, not the
    /// track, so they're read separately — ordered state → snapshot → position so position
    /// is sampled closest to the identity it's paired with.
    func nowPlaying() -> NowPlaying? {
        guard bridge.isRunning else { return nil }
        let state = bridge.playerState
        guard state != .stopped else { return nil }

        guard let snapshot = bridge.currentTrackSnapshot() else { return nil }
        let position = bridge.playerPosition

        logSnapshotKeysOnce(snapshot)

        return NowPlayingMapping.makeNowPlaying(
            from: snapshot,
            positionSeconds: position,
            isPlaying: state == .playing,
            isShuffling: bridge.shuffling
        )
    }

    /// One-time diagnostic: which fields the snapshot actually populated (especially artwork
    /// + duration), so a wrong `-properties` key spelling is visible on-device without a
    /// rebuild loop. See `SpotifyBridge.currentTrackSnapshot`'s artwork-key fallback chain.
    private func logSnapshotKeysOnce(_ snapshot: [String: Any]) {
        guard !didLogSnapshotKeys else { return }
        didLogSnapshotKeys = true
        DebugLog.log("nowPlaying snapshot keys: \(snapshot.keys.sorted())")
    }

    func playPause() { bridge.playpause() }
    func play() { bridge.play() }
    func pause() { bridge.pause() }
    func next() { bridge.nextTrack() }
    func previous() { bridge.previousTrack() }
    func seek(to seconds: Double) { bridge.seek(to: seconds) }
    func setShuffle(_ on: Bool) { bridge.shuffling = on }
    func activateSpotify() { bridge.activateSpotify() }
}
