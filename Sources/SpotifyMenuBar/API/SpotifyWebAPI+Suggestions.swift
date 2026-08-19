import Foundation

/// Endpoints used only by the "Artists to Follow" suggestion list.
///
/// Every call here is a read or an **additive** write. Nothing in this file can unfollow,
/// unsave, or delete anything, which is why none of it takes a `UserRemovalIntent` — the same
/// deliberate property `SpotifyWebAPI+NewReleases.swift` has. It matters more than usual here
/// because the feature's "Not interested" button *looks* destructive: it must never reach the
/// API at all, and there is no call in this file it could reach if it tried.
///
/// The shape of this file is dictated by the February 2026 dev-mode migration:
///  - `GET /artists/{id}/top-tracks` was removed, and `popularity` was stripped from both
///    artist and track objects — so nothing here can rank or fetch an artist's best song.
///  - Batch `GET /artists?ids=` was removed, so `artistDetail` is one request per artist.
///  - `PUT /me/following` was folded into `PUT /me/library`, taking Spotify URIs.
extension SpotifyWebAPI {

    // MARK: - Top items

    /// The user's top artists for one time range. Requires the `user-top-read` scope.
    ///
    /// This is the only source in the feature that returns **full** artist objects, so it's the
    /// only one that carries `images` without a follow-up request — which is what makes the
    /// hydration cap affordable.
    ///
    /// Deliberately a single page: `limit` maxes at 50, and the tail of someone's top-50 is
    /// already weak evidence for a *follow* decision. Paging further would spend requests to
    /// surface artists the ranking is about to bury anyway.
    func topArtists(timeRange: ArtistTimeRange,
                    pace: (() async -> Void)? = nil) async throws -> [ArtistSeed] {
        struct Page: Decodable {
            struct Item: Decodable {
                let id: String?
                let name: String?
                let images: [SpotifyArtistImage]?
                let genres: [String]?
            }
            let items: [Item]
        }
        let page: Page = try await getJSON("/me/top/artists", query: [
            .init(name: "time_range", value: timeRange.queryValue),
            .init(name: "limit", value: String(ArtistSuggestionLogic.topPageSize)),
        ])
        await pace?()
        return page.items.compactMap { item in
            guard let id = item.id else { return nil }
            return ArtistSeed(id: id,
                              name: item.name ?? "(unknown artist)",
                              imageURL: Self.bestImageURL(item.images),
                              genres: item.genres ?? [])
        }
    }

    /// The artist credits on the user's top tracks for one time range, in list order.
    ///
    /// The artist objects nested in a track are *simplified* — id and name only, no images —
    /// so anyone who appears here and nowhere else needs a `artistDetail` call for artwork.
    ///
    /// Credit order is what distinguishes a primary artist from a feature, and it's the only
    /// thing that does: there is no field marking a featured credit, so index 0 is the whole
    /// signal.
    func topTracks(timeRange: ArtistTimeRange,
                   pace: (() async -> Void)? = nil) async throws -> [TopTrackCredit] {
        struct Page: Decodable {
            struct Item: Decodable {
                struct Artist: Decodable { let id: String?; let name: String? }
                let id: String?
                let name: String?
                let artists: [Artist]?
            }
            let items: [Item]
        }
        let page: Page = try await getJSON("/me/top/tracks", query: [
            .init(name: "time_range", value: timeRange.queryValue),
            .init(name: "limit", value: String(ArtistSuggestionLogic.topPageSize)),
        ])
        await pace?()

        var credits: [TopTrackCredit] = []
        for (rank, track) in page.items.enumerated() {
            // A track with no id can't be deduped against, and local files have no artists to
            // credit. Skipping is right: it drops one row of evidence, not an artist.
            guard let trackId = track.id else { continue }
            for (position, artist) in (track.artists ?? []).enumerated() {
                guard let artistId = artist.id else { continue }
                credits.append(TopTrackCredit(artistId: artistId,
                                              artistName: artist.name ?? "(unknown artist)",
                                              trackId: trackId,
                                              trackName: track.name ?? "(untitled)",
                                              rank: rank,
                                              range: timeRange,
                                              isPrimary: position == 0))
            }
        }
        return credits
    }

    // MARK: - Artist detail

    /// One artist, for the artwork the simplified objects on tracks don't carry.
    ///
    /// One request per artist because batch `GET /artists?ids=` was removed in February 2026 —
    /// which is the entire reason `ArtistSuggestionLogic.hydrationCap` exists. `popularity` and
    /// `followers` are gone from the response, so nothing may be built on them.
    func artistDetail(id: String, pace: (() async -> Void)? = nil) async throws -> ArtistSeed {
        struct Resp: Decodable {
            let id: String?
            let name: String?
            let images: [SpotifyArtistImage]?
            let genres: [String]?
        }
        let resp: Resp = try await getJSON("/artists/\(id)")
        await pace?()
        return ArtistSeed(id: resp.id ?? id,
                          name: resp.name ?? "(unknown artist)",
                          imageURL: Self.bestImageURL(resp.images),
                          genres: resp.genres ?? [])
    }

    // MARK: - Following

    /// Follow one artist. Requires the `user-follow-modify` scope.
    ///
    /// `PUT /me/following?type=artist&ids=…` was **removed** in February 2026 and now answers a
    /// bare `403 Forbidden` — the same status as a missing scope, so building against the old
    /// endpoint fails in a way that reads like a permissions bug. The replacement is the
    /// unified `PUT /me/library`, which takes Spotify URIs in a JSON body.
    ///
    /// One artist per call rather than a batch: this is only ever driven by a button press on a
    /// single row, and a batch signature would be an invitation to follow people in bulk from
    /// somewhere that isn't a button.
    func followArtist(id: String) async throws {
        try await send("/me/library", method: "PUT",
                       json: ["uris": [ArtistSuggestionLogic.artistURI(id: id)]])
    }

    // MARK: - Helpers

    /// Pick the artwork the list should actually load.
    ///
    /// Spotify returns images widest-first, and the widest is typically 640px for a row that
    /// draws at 56pt — on a list of 30 artists that's a lot of bandwidth for pixels nobody
    /// sees. Prefer the smallest image still bigger than the row (so it stays sharp on
    /// Retina), and fall back to the largest available when every option is tiny. Chosen by
    /// width rather than by position because the array is occasionally short or unsorted.
    static func bestImageURL(_ images: [SpotifyArtistImage]?) -> String? {
        let usable = (images ?? []).filter { $0.url != nil }
        guard !usable.isEmpty else { return nil }
        let bigEnough = usable.filter { ($0.width ?? 0) >= 128 }
        if let smallestBigEnough = bigEnough.min(by: { ($0.width ?? 0) < ($1.width ?? 0) }) {
            return smallestBigEnough.url
        }
        return usable.max(by: { ($0.width ?? 0) < ($1.width ?? 0) })?.url
    }
}

/// One entry of an artist object's `images` array.
///
/// Declared once at file scope rather than nested in each response type: two structurally
/// identical nested types are still different types to Swift, which would mean two copies of
/// the picker above.
struct SpotifyArtistImage: Decodable {
    let url: String?
    let width: Int?
}
