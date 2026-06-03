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

    /// All playlists in the user's library (paginated).
    func allPlaylists() async throws -> [Playlist] {
        struct Page: Decodable {
            struct Item: Decodable {
                let id: String
                let name: String
                let uri: String
                let collaborative: Bool
                let owner: Owner
                struct Owner: Decodable { let id: String }
            }
            let items: [Item]
            let next: String?
        }
        var results: [Playlist] = []
        var url: URL? = urlForPath("/me/playlists", query: [.init(name: "limit", value: "50")])
        while let current = url {
            let page: Page = try await getJSON(absolute: current)
            results += page.items.map {
                Playlist(id: $0.id, name: $0.name, uri: $0.uri,
                         ownerId: $0.owner.id, collaborative: $0.collaborative)
            }
            url = page.next.flatMap { URL(string: $0) }
        }
        return results
    }

    struct CurrentlyPlaying {
        let contextURI: String?
        let contextType: String?
        let artistNames: [String]   // all credited artists (incl. features)
        let trackURI: String?
    }

    /// The currently-playing item: its playback context + the full artist list.
    /// Returns nil if nothing is playing.
    func currentContext() async throws -> CurrentlyPlaying? {
        let token = try await auth.validAccessToken()
        var req = URLRequest(url: urlForPath("/me/player/currently-playing"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 204 { return nil }        // nothing playing
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Resp: Decodable {
            struct Context: Decodable { let uri: String?; let type: String? }
            struct Item: Decodable {
                let uri: String?
                let artists: [Artist]?
                struct Artist: Decodable { let name: String? }
            }
            let context: Context?
            let item: Item?
        }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        let names = (r.item?.artists ?? []).compactMap { $0.name }.filter { !$0.isEmpty }
        return CurrentlyPlaying(contextURI: r.context?.uri, contextType: r.context?.type,
                                artistNames: names, trackURI: r.item?.uri)
    }

    func playlistInfo(id: String) async throws -> Playlist {
        struct Info: Decodable {
            let id: String
            let name: String
            let uri: String
            let collaborative: Bool
            let owner: Owner
            struct Owner: Decodable { let id: String }
        }
        let info: Info = try await getJSON("/playlists/\(id)",
                                           query: [.init(name: "fields", value: "id,name,uri,collaborative,owner(id)")])
        return Playlist(id: info.id, name: info.name, uri: info.uri,
                        ownerId: info.owner.id, collaborative: info.collaborative)
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
        var url: URL? = urlForPath("/playlists/\(id)/items", query: [.init(name: "limit", value: "100")])
        while let current = url {
            let page: Page = try await getJSON(absolute: current)
            for entry in page.items { if let uri = entry.uri { uris.insert(uri) } }
            url = page.next.flatMap { URL(string: $0) }
        }
        return uris
    }

    func addTrack(uri: String, toPlaylist id: String) async throws {
        try await send("/playlists/\(id)/items", method: "POST", json: ["uris": [uri]])
    }

    func removeTrack(uri: String, fromPlaylist id: String) async throws {
        try await send("/playlists/\(id)/items", method: "DELETE", json: ["items": [["uri": uri]]])
    }

    // MARK: - Request plumbing

    private func urlForPath(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    private func getJSON<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await getJSON(absolute: urlForPath(path, query: query))
    }

    private func getJSON<T: Decodable>(absolute url: URL) async throws -> T {
        let token = try await auth.validAccessToken()
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try throwIfError("GET \(url.path)", resp, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ path: String, method: String, json: Any) async throws {
        let token = try await auth.validAccessToken()
        var req = URLRequest(url: urlForPath(path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try throwIfError("\(method) \(path)", resp, data)
    }

    private func throwIfError(_ label: String, _ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
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
