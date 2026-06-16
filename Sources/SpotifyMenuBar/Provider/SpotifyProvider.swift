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

    /// Source context, the currently-playing artist list, and whether playback is on this Mac
    /// (one API call). `deviceIsLocal` is nil when we can't tell. See `resolveLocality`.
    func currentSourceAndArtists() async throws -> (source: SourceContext, artists: [String], trackURI: String?, deviceIsLocal: Bool?) {
        guard let cp = try await api.currentContext() else { return (.none, [], nil, resolveLocality(nil)) }
        let deviceIsLocal = resolveLocality(cp.device)
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

    /// Whether playback is on this Mac (one lightweight `/me/player` call, no playlist
    /// resolution). nil when we can't tell. Used by the periodic poll to catch mid-song
    /// transfers that don't change the track. See `resolveLocality`.
    func activeDeviceIsLocal() async throws -> Bool? {
        let cp = try await api.currentContext()
        return resolveLocality(cp?.device)
    }

    /// Whether playback is on THIS Mac. Returns true when the active Connect device is this
    /// Mac, OR when no active *remote* device claims the session and the local desktop app is
    /// actually playing here (a hand-off to a phone/speaker/other computer always appears as an
    /// active remote device, so its absence means the audio is local). nil only when we can't
    /// tell (no remote device AND the local app isn't playing).
    private func resolveLocality(_ device: PlaybackDevice?) -> Bool? {
        if let device, device.isActive, !Self.deviceIsThisMac(device) { return false } // active remote device
        if let device, Self.deviceIsThisMac(device) { return true }                    // active = this Mac
        // No active remote device. If the desktop app is playing, the audio is on this Mac.
        if local.isAppRunning, let np = local.nowPlaying(), np.isPlaying {
            DebugLog.log("device: no active Connect device; local app playing → treating as local")
            return true
        }
        return nil
    }

    /// This Mac's name, as Spotify reports it for the desktop device
    /// (System Settings ▸ General ▸ About ▸ Name). Read once.
    private static let localComputerName: String? = Host.current().localizedName

    /// True only when the active Connect device is THIS Mac's desktop app: it must be a
    /// Computer whose name matches this Mac. Phones/speakers and other computers → false.
    /// Names are normalized (apostrophe/case/accents/" (n)" suffix) so a cosmetic difference
    /// between Spotify's name and the macOS computer name can't silently disable discovery.
    private static func deviceIsThisMac(_ device: PlaybackDevice) -> Bool {
        guard device.isActive, device.type == "Computer",
              let local = localComputerName, let name = device.name,
              !local.isEmpty, !name.isEmpty else { return false }
        return DiscoveryLogic.normalizedDeviceName(name) == DiscoveryLogic.normalizedDeviceName(local)
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
