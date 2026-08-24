import Foundation

/// Pure, side-effect-free helpers for bulk library edits — unit-tested in isolation
/// (compiled directly into the test target), in the same spirit as `DiscoveryLogic`.
enum LibraryLogic {
    /// Spotify's documented cap for `DELETE /me/library`. Lives here rather than on
    /// `SpotifyWebAPI` so the test target — which compiles only pure-logic sources — can see it.
    ///
    /// 40, not the 50 the retired per-type endpoints allowed: the unified library endpoint is
    /// stricter, and going over is a 400 rather than a partial success.
    static let maxLibraryURIsPerRequest = 40

    /// The `spotify:episode:…` URI for a saved-episode id. `DELETE /me/library` takes URIs;
    /// the endpoint that took bare ids (`DELETE /me/episodes`) was removed in February 2026.
    static func episodeURI(id: String) -> String { "spotify:episode:\(id)" }

    /// Percent-encodes one URI for the `uris` query list.
    ///
    /// Spotify's documented form is `spotify%3Aepisode%3A…`, joined by literal commas — the comma
    /// is the list separator and must stay unencoded, so the encoding is applied per-URI, not to
    /// the joined string. Encoding everything outside `[A-Za-z0-9]` is safe because Spotify ids
    /// are base62.
    static func percentEncodedURI(_ uri: String) -> String {
        uri.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? uri
    }

    /// Builds the `uris=` query for `DELETE /me/library`, already percent-encoded.
    static func urisQuery(_ uris: [String]) -> String {
        "uris=" + uris.map(percentEncodedURI).joined(separator: ",")
    }

    /// Splits URIs into request-sized chunks, preserving order and dropping nothing.
    ///
    /// The batching is what makes "clear 340 episodes" 9 requests instead of 340, and a chunk
    /// that silently dropped or duplicated a URI would leave the library half-cleared with no
    /// obvious symptom — hence the tests.
    static func batches(_ uris: [String], size: Int = LibraryLogic.maxLibraryURIsPerRequest) -> [[String]] {
        guard size > 0, !uris.isEmpty else { return [] }
        return stride(from: 0, to: uris.count, by: size).map {
            Array(uris[$0 ..< min($0 + size, uris.count)])
        }
    }

    /// What a confirmed clear should actually remove: everything still saved that the user
    /// approved, in the library's own order.
    ///
    /// The confirm step re-reads the library rather than trusting a count that may be minutes
    /// old — but that fresh read can legitimately be *larger*, because an episode saved between
    /// the count and the press is genuinely there now. Removing it too would unsave something
    /// the number on the button never covered, so the fresh list is filtered down to the
    /// approved set. Anything unsaved elsewhere in the meantime just drops out.
    ///
    /// Order follows `current` (oldest-saved first), so a clear that stops partway has still
    /// removed the oldest episodes — the ones least likely to be wanted back.
    static func removableURIs(confirmed: [String], current: [String]) -> [String] {
        let approved = Set(confirmed)
        return current.filter { approved.contains($0) }
    }

    /// Progress caption for a running clear, e.g. "Removed 150 of 340 episodes…".
    static func progressLabel(done: Int, total: Int) -> String {
        "Removed \(done) of \(total) episode\(total == 1 ? "" : "s")…"
    }

    /// What to report when a clear stops early — a 429 backoff or an API error partway through
    /// leaves the library partly emptied, and saying so is more useful than a bare error.
    static func partialFailureLabel(done: Int, total: Int, error: String) -> String {
        done == 0
            ? "Couldn't clear Your Episodes: \(error)"
            : "Stopped after removing \(done) of \(total): \(error)"
    }
}
