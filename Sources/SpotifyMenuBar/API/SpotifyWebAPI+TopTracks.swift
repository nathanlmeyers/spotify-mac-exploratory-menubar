import Foundation

/// Endpoints used only by the Top Tracks (last.fm) sync.
///
/// Unlike `SpotifyWebAPI+NewReleases.swift` and `+Suggestions.swift`, this file **does** contain
/// a call that can remove tracks from a playlist: `replaceItems`. It is the one exception to the
/// rule that removals require a `UserRemovalIntent`, and it is fenced three ways rather than one:
///
///  1. It requires an `OwnedSyncPlaylist`, which only `TopTracksStore` can construct, and only
///     for a playlist id it recorded at the moment this feature created that playlist. A
///     playlist the user picked from a list can never be passed here — the type won't exist.
///  2. Before writing, it re-reads the playlist and refuses unless the current user owns it and
///     its description still carries `TopTracksLogic.ownershipMarker`.
///  3. It refuses to write an empty list, so a run where nothing matched can't wipe a playlist.
///
/// `UserRemovalIntent` itself is untouched; `removeTrack` and `removeLibraryItems` remain
/// unreachable from anything but a button handler in `AppModel`.
extension SpotifyWebAPI {

    // MARK: - Search

    /// `GET /search?type=track`, one page. `limit` is capped at 10 in development mode, so this
    /// is the whole candidate set the matcher ever sees for a query.
    func searchTracks(query: String, pace: (() async -> Void)? = nil) async throws -> [TrackSearchHit] {
        struct Resp: Decodable {
            struct Tracks: Decodable { let items: [Item] }
            struct Item: Decodable {
                struct Artist: Decodable { let name: String? }
                struct Album: Decodable { let name: String?; let album_type: String? }
                let id: String?
                let uri: String?
                let name: String?
                let artists: [Artist]?
                let album: Album?
                let duration_ms: Int?
            }
            let tracks: Tracks?
        }
        let resp: Resp = try await getJSON("/search", query: [
            .init(name: "q", value: query),
            .init(name: "type", value: "track"),
            .init(name: "limit", value: String(TopTracksLogic.searchPageSize)),
        ])
        await pace?()
        return (resp.tracks?.items ?? []).compactMap { item in
            guard let id = item.id, let uri = item.uri else { return nil }
            return TrackSearchHit(id: id, uri: uri,
                                  name: item.name ?? "",
                                  artistNames: (item.artists ?? []).compactMap(\.name),
                                  albumName: item.album?.name ?? "",
                                  albumType: item.album?.album_type ?? "",
                                  durationMs: item.duration_ms)
        }
    }

    // MARK: - Playlist reads

    /// Every item URI in playlist order (duplicates included). Replace mode compares this to
    /// the ranked list so an already-correct playlist costs no write.
    func playlistTrackURIList(id: String, pace: (() async -> Void)? = nil) async throws -> [String] {
        var uris: [String] = []
        try await forEachPlaylistItemURI(id: id, pace: pace) { uris.append($0) }
        return uris
    }

    struct PlaylistOwnershipInfo: Equatable {
        let name: String
        let description: String?
        let ownerId: String
    }

    /// The three fields the replace guard checks. Spotify entity-encodes `description`, which
    /// is why the marker is plain ASCII.
    func playlistOwnershipInfo(id: String) async throws -> PlaylistOwnershipInfo {
        struct Resp: Decodable {
            struct Owner: Decodable { let id: String? }
            let name: String?
            let description: String?
            let owner: Owner?
        }
        let r: Resp = try await getJSON("/playlists/\(id)", query: [
            .init(name: "fields", value: "name,description,owner(id)"),
        ])
        return PlaylistOwnershipInfo(name: r.name ?? "", description: r.description,
                                     ownerId: r.owner?.id ?? "")
    }

    // MARK: - Replace

    enum ReplaceRefusal: LocalizedError, Equatable {
        case markerMissing(name: String)
        case notOwner(name: String)
        case emptyList
        case tooManyItems(Int)

        var errorDescription: String? {
            switch self {
            case .markerMissing(let name):
                return "“\(name)” no longer says it's maintained by this app in its description, so Replace is off for it."
            case .notOwner(let name):
                return "“\(name)” isn't owned by the logged-in account, so Replace is off for it."
            case .emptyList:
                return "Nothing matched on Spotify, so the playlist was left as it was."
            case .tooManyItems(let n):
                return "Can't replace with \(n) songs at once (limit \(TopTracksLogic.replaceBatchCap))."
            }
        }
    }

    /// `PUT /playlists/{id}/items` — rewrite the playlist to exactly `uris`, in order.
    ///
    /// See the file header for the three fences. The before/after lists go to the debug log:
    /// that line is the only record of what a replace removed.
    func replaceItems(in owned: OwnedSyncPlaylist, uris: [String], currentUserId: String,
                      pace: (() async -> Void)? = nil) async throws {
        guard !uris.isEmpty else { throw ReplaceRefusal.emptyList }
        guard uris.count <= TopTracksLogic.replaceBatchCap else { throw ReplaceRefusal.tooManyItems(uris.count) }

        let info = try await playlistOwnershipInfo(id: owned.playlistId)
        await pace?()
        guard info.ownerId == currentUserId else { throw ReplaceRefusal.notOwner(name: info.name) }
        guard TopTracksLogic.carriesOwnershipMarker(description: info.description) else {
            throw ReplaceRefusal.markerMissing(name: info.name)
        }

        DebugLog.log("REPLACE [top-tracks \(owned.period.rawValue)] \"\(info.name)\" id=\(owned.playlistId) "
                     + "← \(uris.count) uris: \(uris.joined(separator: ","))")
        try await send("/playlists/\(owned.playlistId)/items", method: "PUT", json: ["uris": uris])
        await pace?()
    }
}
