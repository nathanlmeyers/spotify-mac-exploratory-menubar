import Foundation

/// Swift-facing wrapper over the Objective-C `SpotifyBridge` (ScriptingBridge).
/// All playback reads/controls are local and require no Premium / no login.
@MainActor
final class LocalSpotifyController {
    private let bridge = SpotifyBridge()

    var isAppRunning: Bool { bridge.isRunning }
    var isShuffling: Bool { bridge.shuffling }

    /// Current playback snapshot, or nil if Spotify isn't running / nothing is playing.
    func nowPlaying() -> NowPlaying? {
        guard bridge.isRunning, bridge.playerState != .stopped else { return nil }
        guard let uri = bridge.currentTrackURI, !uri.isEmpty else { return nil }
        return NowPlaying(
            uri: uri,
            name: bridge.currentTrackName ?? "",
            artist: bridge.currentTrackArtist ?? "",
            album: bridge.currentTrackAlbum ?? "",
            artworkURL: bridge.currentArtworkURL.flatMap { URL(string: $0) },
            durationSeconds: bridge.durationSeconds,
            positionSeconds: bridge.playerPosition,
            isPlaying: bridge.playerState == .playing,
            isShuffling: bridge.shuffling
        )
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
