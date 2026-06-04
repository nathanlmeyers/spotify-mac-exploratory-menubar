import Foundation

/// Keys for the dictionary returned by `SpotifyBridge.currentTrackSnapshot`. These string
/// literals are the contract between the Objective-C bridge and the Swift mapper; the bridge
/// emits the same literals. Kept in pure Swift (no ObjC dependency) so the mapper below can
/// be unit-tested without linking the ScriptingBridge shim.
enum SpotifyTrackKey {
    static let id = "id"                  // track URI (gate)
    static let name = "name"
    static let artist = "artist"
    static let album = "album"
    static let artworkURL = "artworkUrl"
    static let durationRaw = "durationRaw" // raw track duration (NSNumber), normalized here
}

/// Pure mapping from a now-playing snapshot dictionary to `NowPlaying`. No Spotify /
/// ScriptingBridge dependency — unit-testable in isolation.
enum NowPlayingMapping {
    /// Builds a `NowPlaying` from an atomic track snapshot plus the app-level player facts
    /// (position / isPlaying / isShuffling, which live on the app, not the track, and are
    /// threaded in by the caller). Returns nil when there is no usable track identity.
    static func makeNowPlaying(
        from snapshot: [String: Any],
        positionSeconds: Double,
        isPlaying: Bool,
        isShuffling: Bool
    ) -> NowPlaying? {
        guard let uri = snapshot[SpotifyTrackKey.id] as? String, !uri.isEmpty else { return nil }
        let artworkURL = (snapshot[SpotifyTrackKey.artworkURL] as? String).flatMap(URL.init(string:))
        return NowPlaying(
            uri: uri,
            name: snapshot[SpotifyTrackKey.name] as? String ?? "",
            artist: snapshot[SpotifyTrackKey.artist] as? String ?? "",
            album: snapshot[SpotifyTrackKey.album] as? String ?? "",
            artworkURL: artworkURL,
            durationSeconds: normalizeDuration(snapshot[SpotifyTrackKey.durationRaw]),
            positionSeconds: positionSeconds,
            isPlaying: isPlaying,
            isShuffling: isShuffling
        )
    }

    /// Spotify's track duration dictionary says "seconds" but has historically returned
    /// milliseconds. Anything implausibly large (> 10000) is treated as milliseconds.
    static func normalizeDuration(_ raw: Any?) -> Double {
        let value: Double
        switch raw {
        case let i as Int: value = Double(i)
        case let d as Double: value = d
        case let n as NSNumber: value = n.doubleValue
        default: return 0
        }
        return value > 10000 ? value / 1000.0 : value
    }
}
