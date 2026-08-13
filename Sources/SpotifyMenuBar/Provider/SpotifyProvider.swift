import Foundation

/// The app's one music-service facade: local app control for playback,
/// Web API for account/playlist operations.
@MainActor
final class SpotifyProvider {
    private let local: LocalSpotifyController
    private let api: SpotifyWebAPI
    // User-scoped caches — cleared on logout (resetCaches) so accounts can't leak into
    // each other. Playlist info (name/owner/collaborative) essentially never changes
    // mid-session; entries are refreshed whenever the full playlist list is fetched.
    private var cachedUserId: String?
    private var cachedPlaylistInfo: [String: Playlist] = [:]

    init(local: LocalSpotifyController, api: SpotifyWebAPI) {
        self.local = local
        self.api = api
    }

    func resetCaches() {
        cachedUserId = nil
        cachedPlaylistInfo.removeAll()
    }

    // MARK: Local playback
    var isAppRunning: Bool { local.isAppRunning }
    /// Whether Spotify is answering Apple events. False means every local reading below is
    /// stale — display it if you like, but never act on it.
    var isResponsive: Bool { local.isResponsive }

    /// Last known playback, served from cache — never blocks. Use for rendering.
    func nowPlaying() -> NowPlaying? { local.lastKnown }
    /// Take a new reading (the 1s poll). Returns nil if it couldn't be taken; see `isResponsive`.
    func refreshNowPlaying() async -> NowPlaying? { await local.refresh() }
    /// Force a fresh reading where a stale track identity would be harmful — see
    /// `LocalSpotifyController.freshNowPlaying`.
    func freshNowPlaying() async -> NowPlaying? { await local.freshNowPlaying() }
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
        for p in all { cachedPlaylistInfo[p.id] = p }   // freshens the source-info cache too
        let editable = all.filter { $0.isEditable(byUserId: me) }
        DebugLog.log("playlists: total=\(all.count) editable=\(editable.count) me=\(me) sampleOwners=\(all.prefix(6).map { $0.ownerId })")
        return editable
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
        let info = try await playlistInfo(id: id)
        let source = SourceContext(playlistId: id,
                                   playlistName: info.name,
                                   isEditablePlaylist: info.isEditable(byUserId: me),
                                   trackURI: cp.trackURI)
        return (source, cp.artistNames, cp.trackURI, deviceIsLocal)
    }

    /// Playlist metadata, cached per session — `refreshSource` runs on every track change,
    /// so an uncached read would refetch the same playlist once per song.
    private func playlistInfo(id: String) async throws -> Playlist {
        if let cached = cachedPlaylistInfo[id] { return cached }
        let info = try await api.playlistInfo(id: id)
        cachedPlaylistInfo[id] = info
        return info
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
        // (Read from the poll's cached snapshot — this runs once per second while discovery is
        // armed, and spending its own Apple event on it would double the app's event rate.)
        if local.isPlaying {
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

    func addTrack(uri: String, toPlaylist playlistId: String) async throws {
        try await api.addTrack(uri: uri, toPlaylist: playlistId)
    }

    /// Deletes a track from a playlist. Requires a `UserRemovalIntent`, which only
    /// AppModel's button handlers can construct — so nothing automated can reach here.
    /// Always logged: this is the one destructive call in the app, and an unlogged
    /// deletion is invisible in a 400k-line debug log.
    func removeTrack(uri: String, fromPlaylist playlistId: String,
                     intent: UserRemovalIntent) async throws {
        DebugLog.log("REMOVE [\(intent.gesture)] \(uri) from playlist \(playlistId)")
        do {
            try await api.removeTrack(uri: uri, fromPlaylist: playlistId, intent: intent)
            DebugLog.log("REMOVE ok \(uri)")
        } catch {
            DebugLog.log("REMOVE FAILED \(uri): \(error.localizedDescription)")
            throw error
        }
    }

    /// Everything currently in "Your Episodes" (the saved-episode library, not a playlist).
    func savedEpisodes() async throws -> [SpotifyWebAPI.SavedEpisode] {
        try await api.savedEpisodes()
    }

    /// Removes one batch of library items. Same contract as `removeTrack`: a `UserRemovalIntent`
    /// only AppModel's button handlers can construct, and a log line per batch listing every URI —
    /// with no recovery file, that log is the sole record of what a bulk clear removed.
    func removeLibraryItems(uris: [String], intent: UserRemovalIntent) async throws {
        DebugLog.log("REMOVE [\(intent.gesture)] \(uris.count) library items: \(uris.joined(separator: ","))")
        do {
            try await api.removeLibraryItems(uris: uris, intent: intent)
            DebugLog.log("REMOVE ok \(uris.count) library items")
        } catch {
            DebugLog.log("REMOVE FAILED \(uris.count) library items: \(error.localizedDescription)")
            throw error
        }
    }
}
