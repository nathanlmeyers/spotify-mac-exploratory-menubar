import Foundation

/// Classification of the currently-playing item, derived from its Spotify URI.
enum TrackKind: Equatable {
    case track       // spotify:track:...   — addable/removable
    case episode     // spotify:episode:... — podcast (music-only v1: not curatable)
    case localFile   // spotify:local:...   — Web API cannot add these
    case ad          // ad break (free tier)
    case unknown

    /// Only real tracks can be added to / removed from playlists in v1.
    var isCuratable: Bool { self == .track }
}

/// A snapshot of what Spotify is playing right now (read locally via ScriptingBridge).
struct NowPlaying: Equatable {
    var uri: String
    var name: String
    var artist: String
    var album: String
    var artworkURL: URL?
    var durationSeconds: Double
    var positionSeconds: Double
    var isPlaying: Bool
    var isShuffling: Bool

    var kind: TrackKind { NowPlaying.classify(uri) }

    static func classify(_ uri: String) -> TrackKind {
        if uri.hasPrefix("spotify:track:") { return .track }
        if uri.hasPrefix("spotify:episode:") { return .episode }
        if uri.hasPrefix("spotify:local:") { return .localFile }
        if uri.hasPrefix("spotify:ad:") || uri.isEmpty { return .ad }
        return .unknown
    }
}

/// A Spotify playlist (subset of fields we need).
struct Playlist: Identifiable, Equatable, Codable, Hashable {
    var id: String          // playlist id (not the URI)
    var name: String
    var uri: String         // spotify:playlist:<id>
    var ownerId: String
    var collaborative: Bool

    /// Editable == we own it, or it's collaborative.
    func isEditable(byUserId userId: String?) -> Bool {
        guard let userId else { return false }
        return collaborative || ownerId == userId
    }
}

/// The playback "context" — what the current track is playing *from*.
/// `playlistId` is nil when playing an album/artist/liked-songs/queue (not a playlist).
/// `trackURI` is the track this context was resolved for: a removal must only act when
/// it still matches the track being curated, otherwise a stale source could delete the
/// wrong track from the wrong playlist.
struct SourceContext: Equatable {
    var playlistId: String?
    var playlistName: String?
    var isEditablePlaylist: Bool
    var trackURI: String?

    static let none = SourceContext(playlistId: nil, playlistName: nil, isEditablePlaylist: false, trackURI: nil)
}
