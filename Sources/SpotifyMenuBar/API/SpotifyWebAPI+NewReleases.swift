import Foundation

/// Endpoints used only by the "New From Followed" release radar.
///
/// Every call here is a read or an append — nothing in this file can delete anything, which is
/// why none of it takes a `UserRemovalIntent`. The radar runs unattended on a timer, so that
/// property is deliberate: an unattended job must not be able to reach a destructive call.
extension SpotifyWebAPI {

    // MARK: - Followed artists

    /// Everyone the user follows. Requires the `user-follow-read` scope.
    ///
    /// Cursor-paginated and nested under an `artists` key rather than sitting at the top level
    /// like every other paged endpoint in this client, so it can't reuse `paginate` as-is.
    ///
    /// Someone following a few hundred artists is a handful of pages; `pace` runs between them
    /// so the sweep's throttle covers this call too rather than starting after it.
    func followedArtists(pace: (() async -> Void)? = nil) async throws -> [FollowedArtist] {
        struct Page: Decodable {
            struct Artists: Decodable {
                struct Item: Decodable { let id: String?; let name: String? }
                let items: [Item]
                let next: String?
            }
            let artists: Artists
        }
        var results: [FollowedArtist] = []
        var url: URL? = urlForPath("/me/following",
                                   query: [.init(name: "type", value: "artist"),
                                           .init(name: "limit", value: "50")])
        while let current = url {
            let page: Page = try await getJSON(absolute: current)
            await pace?()
            for item in page.artists.items {
                guard let id = item.id else { continue }
                results.append(FollowedArtist(id: id, name: item.name ?? "(unknown artist)"))
            }
            url = page.artists.next.flatMap { URL(string: $0) }
        }
        return results
    }

    // MARK: - Artist catalogue

    /// One page of an artist's albums for a single `include_groups` value.
    ///
    /// Deliberately *not* paginated internally: the caller decides whether to fetch the next
    /// page (see `NewReleaseLogic.shouldFetchNextPage`), because for most artists on most days
    /// page one is enough and blindly walking every page is the difference between a scan that
    /// costs hundreds of requests and one that costs thousands.
    ///
    /// `limit` is capped at 10 by the API as of February 2026. `album_group` no longer comes
    /// back, so `group` is stamped from the query that produced these results.
    func artistAlbums(artistId: String,
                      includeGroups: String,
                      group: ReleaseGroup,
                      offset: Int) async throws -> [CandidateAlbum] {
        struct Page: Decodable {
            struct Item: Decodable {
                let id: String?
                let name: String?
                let album_type: String?
                let release_date: String?
                let release_date_precision: String?
            }
            let items: [Item]
        }
        let page: Page = try await getJSON(
            "/artists/\(artistId)/albums",
            query: [.init(name: "include_groups", value: includeGroups),
                    .init(name: "limit", value: String(NewReleaseLogic.albumPageSize)),
                    .init(name: "offset", value: String(offset))])
        return page.items.compactMap { item in
            guard let id = item.id else { return nil }
            return CandidateAlbum(id: id,
                                  name: item.name ?? "",
                                  albumType: item.album_type ?? "album",
                                  releaseDate: item.release_date ?? "",
                                  releaseDatePrecision: item.release_date_precision ?? "year",
                                  group: group)
        }
    }

    /// Every track on an album.
    ///
    /// One request per album because the batch `GET /albums?ids=` endpoint was removed in
    /// February 2026. No `limit` is sent: the endpoint's own default (20) is used and `next` is
    /// followed, which avoids guessing at a cap that has already been reduced once — and `pace`
    /// runs between those pages, so a long tracklist doesn't burst.
    func albumTracks(albumId: String, pace: (() async -> Void)? = nil) async throws -> [CandidateTrack] {
        struct Page: Decodable {
            struct Item: Decodable {
                struct Artist: Decodable { let id: String? }
                let id: String?
                let uri: String?
                let name: String?
                let artists: [Artist]?
            }
            let items: [Item]
            let next: String?
        }
        var results: [CandidateTrack] = []
        try await paginate(from: urlForPath("/albums/\(albumId)/tracks"),
                           next: \Page.next, pace: pace) { page in
            for item in page.items {
                guard let id = item.id, let uri = item.uri else { continue }
                results.append(CandidateTrack(id: id,
                                              uri: uri,
                                              name: item.name ?? "",
                                              artistIds: (item.artists ?? []).compactMap(\.id),
                                              albumId: albumId,
                                              // Stamped by the caller, which knows why it asked.
                                              matchedArtistId: "",
                                              group: .own))
            }
        }
        return results
    }

    // MARK: - Playlist writes

    /// Creates a playlist owned by the current user.
    ///
    /// `POST /me/playlists`, not `POST /users/{id}/playlists` — the latter was deprecated in the
    /// February 2026 changes.
    func createPlaylist(name: String, description: String, isPublic: Bool = false) async throws -> Playlist {
        struct Resp: Decodable {
            let id: String
            let name: String
            let uri: String
            let collaborative: Bool
            struct Owner: Decodable { let id: String }
            let owner: Owner
        }
        let (data, http) = try await authorizedData(
            for: urlForPath("/me/playlists"), method: "POST",
            json: ["name": name, "description": description, "public": isPublic])
        try throwIfError("POST /me/playlists", http, data)
        let r = try JSONDecoder().decode(Resp.self, from: data)
        return Playlist(id: r.id, name: r.name, uri: r.uri,
                        ownerId: r.owner.id, collaborative: r.collaborative)
    }

    /// Appends tracks to a playlist, one request per 100 URIs, `pace` between batches.
    ///
    /// Returns how many were actually sent, so a run interrupted partway can report real
    /// progress rather than claiming everything or nothing.
    @discardableResult
    func addTracks(uris: [String], toPlaylist id: String,
                   pace: (() async -> Void)? = nil) async throws -> Int {
        var sent = 0
        for batch in LibraryLogic.batches(uris, size: NewReleaseLogic.addBatchSize) {
            try await send("/playlists/\(id)/items", method: "POST", json: ["uris": batch])
            await pace?()
            sent += batch.count
        }
        return sent
    }
}
