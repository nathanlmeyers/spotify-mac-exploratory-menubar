import Foundation

/// Thin client for the Spotify Web API endpoints we use.
/// Auth tokens are fetched (and refreshed) via `SpotifyAuth`.
@MainActor
final class SpotifyWebAPI {
    private let auth: SpotifyAuth
    private let base = URL(string: "https://api.spotify.com/v1")!

    init(auth: SpotifyAuth) { self.auth = auth }

    enum APIError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let msg): return "Spotify API error \(code): \(msg)"
            }
        }
    }

    // MARK: - Public operations

    func currentUserId() async throws -> String {
        struct Me: Decodable { let id: String }
        let me: Me = try await getJSON("/me")
        return me.id
    }

    /// Spotify's playlist object, shared by the list and single-playlist endpoints.
    private struct PlaylistDTO: Decodable {
        let id: String
        let name: String
        let uri: String
        let collaborative: Bool
        let owner: Owner
        struct Owner: Decodable { let id: String }
        var playlist: Playlist {
            Playlist(id: id, name: name, uri: uri, ownerId: owner.id, collaborative: collaborative)
        }
    }

    /// All playlists in the user's library (paginated).
    func allPlaylists() async throws -> [Playlist] {
        struct Page: Decodable {
            let items: [PlaylistDTO]
            let next: String?
        }
        var results: [Playlist] = []
        try await paginate(from: urlForPath("/me/playlists", query: [.init(name: "limit", value: "50")]),
                           next: \Page.next) { results += $0.items.map(\.playlist) }
        return results
    }

    struct CurrentlyPlaying {
        let contextURI: String?
        let contextType: String?
        let artistNames: [String]   // all credited artists (incl. features)
        let trackURI: String?
        let device: PlaybackDevice? // the active Spotify Connect device (nil if unknown)
    }

    /// The currently-playing item: its playback context, the full artist list, and the
    /// active Connect device. Uses `/me/player` (not `/me/player/currently-playing`) because
    /// only that endpoint returns the `device` object — both come back in one call.
    /// Returns nil when there's no active playback session (HTTP 204).
    func currentContext() async throws -> CurrentlyPlaying? {
        let (data, http) = try await authorizedData(for: urlForPath("/me/player"))
        guard let http else { return nil }
        if http.statusCode == 204 { return nil }        // no active device / nothing playing
        try throwIfError("GET /me/player", http, data)
        struct Resp: Decodable {
            struct Device: Decodable {
                let id: String?
                let name: String?
                let type: String?
                let is_active: Bool?
            }
            struct Context: Decodable { let uri: String?; let type: String? }
            struct Item: Decodable {
                let uri: String?
                let artists: [Artist]?
                struct Artist: Decodable { let name: String? }
            }
            let device: Device?
            let context: Context?
            let item: Item?
        }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        let names = (r.item?.artists ?? []).compactMap { $0.name }.filter { !$0.isEmpty }
        let device = r.device.map {
            PlaybackDevice(id: $0.id, name: $0.name, type: $0.type, isActive: $0.is_active ?? false)
        }
        return CurrentlyPlaying(contextURI: r.context?.uri, contextType: r.context?.type,
                                artistNames: names, trackURI: r.item?.uri, device: device)
    }

    func playlistInfo(id: String) async throws -> Playlist {
        let info: PlaylistDTO = try await getJSON("/playlists/\(id)",
                                                  query: [.init(name: "fields", value: "id,name,uri,collaborative,owner(id)")])
        return info.playlist
    }

    /// All track URIs in a playlist (paginated) — used for duplicate detection.
    /// Uses the Feb-2026 `/items` endpoint; the nested object was renamed `track` -> `item`
    /// (we read either to stay robust).
    func playlistTrackURIs(id: String) async throws -> Set<String> {
        struct Page: Decodable {
            struct Item: Decodable {
                let item: Inner?
                let track: Inner?
                struct Inner: Decodable { let uri: String? }
                var uri: String? { item?.uri ?? track?.uri }
            }
            let items: [Item]
            let next: String?
        }
        var uris = Set<String>()
        try await paginate(from: urlForPath("/playlists/\(id)/items", query: [.init(name: "limit", value: "100")]),
                           next: \Page.next) { page in
            for entry in page.items { if let uri = entry.uri { uris.insert(uri) } }
        }
        return uris
    }

    func addTrack(uri: String, toPlaylist id: String) async throws {
        try await send("/playlists/\(id)/items", method: "POST", json: ["uris": [uri]])
    }

    /// The playlist's current `snapshot_id`, used for optimistic-concurrency on edits.
    func playlistSnapshotId(id: String) async throws -> String {
        struct Resp: Decodable { let snapshot_id: String }
        let r: Resp = try await getJSON("/playlists/\(id)", query: [.init(name: "fields", value: "snapshot_id")])
        return r.snapshot_id
    }

    /// Removes a track from a playlist.
    /// NOTE: identifying the track by URI only (no positions) removes EVERY occurrence of
    /// that URI in the playlist — the local ScriptingBridge doesn't expose the playing
    /// item's index, so single-occurrence removal isn't possible here. We include the
    /// current `snapshot_id` so the delete fails cleanly if the playlist changed since we
    /// read it, rather than acting on a stale playlist.
    func removeTrack(uri: String, fromPlaylist id: String) async throws {
        let snapshotId = try await playlistSnapshotId(id: id)
        try await send("/playlists/\(id)/items", method: "DELETE",
                       json: ["items": [["uri": uri]], "snapshot_id": snapshotId])
    }

    // MARK: - Request plumbing

    private func urlForPath(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    /// One authorized request: token + Bearer header + optional JSON body. No status check —
    /// callers that need special-case statuses (204) inspect the response themselves.
    private func authorizedData(for url: URL, method: String = "GET",
                                json: Any? = nil) async throws -> (Data, HTTPURLResponse?) {
        let token = try await auth.validAccessToken()
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, resp as? HTTPURLResponse)
    }

    private func getJSON<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await getJSON(absolute: urlForPath(path, query: query))
    }

    private func getJSON<T: Decodable>(absolute url: URL) async throws -> T {
        let (data, http) = try await authorizedData(for: url)
        try throwIfError("GET \(url.path)", http, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ path: String, method: String, json: Any) async throws {
        let (data, http) = try await authorizedData(for: urlForPath(path), method: method, json: json)
        try throwIfError("\(method) \(path)", http, data)
    }

    /// Follow a paginated endpoint from `start`, feeding each decoded page to `consume`.
    private func paginate<Page: Decodable>(from start: URL,
                                           next: (Page) -> String?,
                                           _ consume: (Page) -> Void) async throws {
        var url: URL? = start
        while let current = url {
            let page: Page = try await getJSON(absolute: current)
            consume(page)
            url = next(page).flatMap { URL(string: $0) }
        }
    }

    private func throwIfError(_ label: String, _ http: HTTPURLResponse?, _ data: Data) throws {
        guard let http, !(200..<300).contains(http.statusCode) else { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        DebugLog.log("API \(label) -> HTTP \(http.statusCode): \(body)")
        throw APIError.http(http.statusCode, Self.message(from: body))
    }

    /// Pull Spotify's `error.message` out of the JSON body for a readable status line.
    private static func message(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let m = err["message"] as? String {
            return m
        }
        return body.isEmpty ? "(no details)" : body
    }
}
