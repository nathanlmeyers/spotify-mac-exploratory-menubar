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

    /// Source context, the currently-playing artist list, and whether the active Connect
    /// device is this Mac (one API call). `deviceIsLocal` is nil when unknown.
    func currentSourceAndArtists() async throws -> (source: SourceContext, artists: [String], trackURI: String?, deviceIsLocal: Bool?) {
        guard let cp = try await api.currentContext() else { return (.none, [], nil, nil) }
        let deviceIsLocal = cp.device.map { Self.deviceIsThisMac($0) }
        guard cp.contextType == "playlist", let uri = cp.contextURI else {
            return (.none, cp.artistNames, cp.trackURI, deviceIsLocal) // album / artist / liked / queue
        }
        let id = uri.components(separatedBy: ":").last ?? ""
        guard !id.isEmpty else { return (.none, cp.artistNames, cp.trackURI, deviceIsLocal) }
        let me = try await currentUserId()
        let info = try await api.playlistInfo(id: id)
        let source = SourceContext(playlistId: id,
                                   playlistName: info.name,
                                   isEditablePlaylist: info.isEditable(byUserId: me),
                                   trackURI: cp.trackURI)
        return (source, cp.artistNames, cp.trackURI, deviceIsLocal)
    }

    /// Whether the active Connect device is this Mac (one lightweight `/me/player` call,
    /// no playlist resolution). nil when unknown (no active device / not logged in).
    /// Used by the periodic poll to catch mid-song transfers that don't change the track.
    func activeDeviceIsLocal() async throws -> Bool? {
        guard let cp = try await api.currentContext() else { return nil }
        return cp.device.map { Self.deviceIsThisMac($0) }
    }

    /// This Mac's name, as Spotify reports it for the desktop device
    /// (System Settings ▸ General ▸ About ▸ Name). Read once.
    private static let localComputerName: String? = Host.current().localizedName

    /// True only when the active Connect device is THIS Mac's desktop app: it must be a
    /// Computer whose name matches this Mac. Phones/speakers and other computers → false.
    private static func deviceIsThisMac(_ device: PlaybackDevice) -> Bool {
        guard device.isActive, device.type == "Computer",
              let local = localComputerName, let name = device.name,
              !local.isEmpty, !name.isEmpty else { return false }
        return name.caseInsensitiveCompare(local) == .orderedSame
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
