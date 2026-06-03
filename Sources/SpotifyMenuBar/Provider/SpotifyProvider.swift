import Foundation

/// Spotify implementation of `MusicProvider`: local app control for playback,
/// Web API for account/playlist operations.
@MainActor
final class SpotifyProvider: MusicProvider {
    private let local: LocalSpotifyController
    private let api: SpotifyWebAPI
    private var cachedUserId: String?

    init(local: LocalSpotifyController, api: SpotifyWebAPI) {
        self.local = local
        self.api = api
    }

    // MARK: Local playback
    var isAppRunning: Bool { local.isAppRunning }
    var isShuffling: Bool { local.isShuffling }
    func nowPlaying() -> NowPlaying? { local.nowPlaying() }
    func playPause() { local.playPause() }
    func pause() { local.pause() }
    func play() { local.play() }
    func next() { local.next() }
    func previous() { local.previous() }
    func seek(to seconds: Double) { local.seek(to: seconds) }
    func setShuffle(_ on: Bool) { local.setShuffle(on) }
    func activateApp() { local.activateSpotify() }

    // MARK: Account & playlists
    func currentUserId() async throws -> String {
        if let id = cachedUserId { return id }
        let id = try await api.currentUserId()
        cachedUserId = id
        DebugLog.log("me.id = \(id)")
        return id
    }

    func editablePlaylists() async throws -> [Playlist] {
        let me = try await currentUserId()
        let all = try await api.allPlaylists()
        let editable = all.filter { $0.isEditable(byUserId: me) }
        DebugLog.log("playlists: total=\(all.count) editable=\(editable.count) me=\(me) sampleOwners=\(all.prefix(6).map { $0.ownerId })")
        return editable
    }

    func currentSource() async throws -> SourceContext? {
        try await currentSourceAndArtists().source
    }

    /// Source context plus the currently-playing artist list (one API call).
    func currentSourceAndArtists() async throws -> (source: SourceContext, artists: [String], trackURI: String?) {
        guard let cp = try await api.currentContext() else { return (.none, [], nil) }
        guard cp.contextType == "playlist", let uri = cp.contextURI else {
            return (.none, cp.artistNames, cp.trackURI) // album / artist / liked / queue
        }
        let id = uri.components(separatedBy: ":").last ?? ""
        guard !id.isEmpty else { return (.none, cp.artistNames, cp.trackURI) }
        let me = try await currentUserId()
        let info = try await api.playlistInfo(id: id)
        let source = SourceContext(playlistId: id,
                                   playlistName: info.name,
                                   isEditablePlaylist: info.isEditable(byUserId: me))
        return (source, cp.artistNames, cp.trackURI)
    }

    func playlistContains(playlistId: String, trackURI: String) async throws -> Bool {
        try await api.playlistTrackURIs(id: playlistId).contains(trackURI)
    }

    func addTrack(uri: String, toPlaylist playlistId: String) async throws {
        try await api.addTrack(uri: uri, toPlaylist: playlistId)
    }

    func removeTrack(uri: String, fromPlaylist playlistId: String) async throws {
        try await api.removeTrack(uri: uri, fromPlaylist: playlistId)
    }
}
