import Foundation

/// Abstraction over a music service so additional providers (Apple Music, etc.)
/// can be added without rewriting the app. Spotify is the first implementation.
///
/// Playback reads/controls are synchronous and main-actor (local app control);
/// account/playlist operations are async (network).
@MainActor
protocol MusicProvider: AnyObject {
    // MARK: Local playback
    var isAppRunning: Bool { get }
    var isShuffling: Bool { get }
    func nowPlaying() -> NowPlaying?
    func playPause()
    /// Hard pause / play (not a toggle) — discovery mode needs deterministic pause.
    func pause()
    func play()
    func next()
    func previous()
    func seek(to seconds: Double)
    func setShuffle(_ on: Bool)
    func activateApp()

    // MARK: Account & playlists (network)
    /// Current user's id (used to determine playlist editability).
    func currentUserId() async throws -> String
    /// Playlists the user can edit (owned or collaborative).
    func editablePlaylists() async throws -> [Playlist]
    /// The playlist (if any) the current track is playing from, and whether it's editable.
    func currentSource() async throws -> SourceContext?
    /// Whether a playlist already contains a track (for duplicate prevention).
    func playlistContains(playlistId: String, trackURI: String) async throws -> Bool
    func addTrack(uri: String, toPlaylist playlistId: String) async throws
    func removeTrack(uri: String, fromPlaylist playlistId: String) async throws
}
