import Foundation

/// Which last.fm listening window a Top Tracks playlist mirrors.
///
/// The raw values are last.fm's own `period` parameter for `user.getTopTracks`, so the enum
/// is the wire format and there is nothing to map.
enum TopTracksPeriod: String, CaseIterable, Codable, Identifiable {
    case allTime = "overall"
    case sixMonths = "6month"
    case oneMonth = "1month"

    var id: String { rawValue }

    /// The `period` query value for last.fm.
    var lastFMPeriod: String { rawValue }

    var label: String {
        switch self {
        case .allTime: return "All time"
        case .sixMonths: return "Last 6 months"
        case .oneMonth: return "Last 30 days"
        }
    }

    /// What the "Create" button names the playlist it makes for this period.
    var defaultPlaylistName: String {
        switch self {
        case .allTime: return "Top Tracks — All Time"
        case .sixMonths: return "Top Tracks — 6 Months"
        case .oneMonth: return "Top Tracks — 30 Days"
        }
    }
}

/// How a period's playlist is kept in step with the top list.
///
/// `append` is the release radar's contract: only ever add, never touch what's there. `replace`
/// rewrites the playlist to mirror the current top-N in rank order, which drops songs that fell
/// out — and is therefore only permitted on a playlist this feature created itself (see
/// `OwnedSyncPlaylist`).
enum TopTracksSyncMode: String, Codable, CaseIterable, Identifiable {
    case append
    case replace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .append: return "Append"
        case .replace: return "Replace"
        }
    }
}

/// One row of `user.getTopTracks`. No Spotify id: that's what the matcher is for.
struct LastFMTopTrack: Equatable {
    /// One-based position in last.fm's list.
    let rank: Int
    let name: String
    let artist: String
    let playcount: Int
    let mbid: String?
}

/// A reduced `GET /search?type=track` hit.
///
/// `popularity` was stripped from track objects in February 2026, so nothing here can rank by
/// fame — the scorer works from names, credits and album type alone.
struct TrackSearchHit: Equatable {
    let id: String
    let uri: String
    let name: String
    /// Credit order; `[0]` is the primary artist.
    let artistNames: [String]
    let albumName: String
    /// `album` / `single` / `compilation`.
    let albumType: String
    let durationMs: Int?
}

/// A hit the scorer accepted, with the numbers that justified it (for the log).
struct TrackMatch: Equatable {
    let hit: TrackSearchHit
    let score: Double
    let artistScore: Double
}

/// Errors from parsing a last.fm response body.
enum LastFMParseError: LocalizedError, Equatable {
    /// last.fm answered with `{"error": N, "message": "…"}`.
    case api(code: Int, message: String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .api(let code, let message):
            switch code {
            case 6: return "last.fm doesn't know that user. Check the username in Settings."
            case 10: return "last.fm rejected the API key. Check LASTFM_API_KEY in Secrets.xcconfig."
            case 17: return "That last.fm profile is private, so its listening history can't be read."
            case 29: return "last.fm is rate limiting requests. Try again later."
            default: return "last.fm error \(code): \(message)"
            }
        case .malformed:
            return "last.fm returned a response this app couldn't read."
        }
    }
}

/// Pure decision logic for the Top Tracks feature: parsing last.fm, folding titles so a scrobble
/// and a Spotify track can be compared, scoring search hits, and planning playlist writes.
///
/// Everything here is deterministic and network-free so it can be pinned by tests — the quiet
/// failure in this feature is a wrong match (a karaoke cover of your most-played song), and the
/// only defence is rules you can read.
enum TopTracksLogic {

    // MARK: - Constants

    /// Development-mode cap on `GET /search` `limit`.
    static let searchPageSize = 10
    /// `PUT /playlists/{id}/items` accepts at most this many URIs in one body.
    static let replaceBatchCap = 100
    /// Playlist lengths the Settings picker offers.
    static let allowedLimits = [50, 100]
    static let defaultLimit = 50
    static let syncInterval: TimeInterval = 24 * 60 * 60
    /// How long a track that couldn't be matched waits before costing another search.
    static let missRetryInterval: TimeInterval = 30 * 24 * 60 * 60
    /// A hit below this is a miss, however good the alternatives aren't.
    static let acceptThreshold = 0.85
    /// A hit whose artist doesn't line up is a miss regardless of its title — the artist floor
    /// is what keeps tribute acts and karaoke versions out of the playlist.
    static let minArtistScore = 0.7
    /// Phrase written into every playlist this feature creates. Plain ASCII letters and spaces
    /// only, because Spotify entity-encodes descriptions and the check must survive that.
    static let ownershipMarker = "Maintained by Spotify Menu Bar"
    /// Spotify's documented ceiling on a description.
    static let maxDescriptionLength = 300
    /// Longest search query we'll send; Spotify's `q` is capped and very long titles only add noise.
    static let maxQueryLength = 200

    // MARK: - Playlist identity

    static func clampedLimit(_ n: Int) -> Int {
        allowedLimits.contains(n) ? n : defaultLimit
    }

    /// The description a created playlist carries. Contains `ownershipMarker`, which
    /// `SpotifyWebAPI.replaceItems` re-reads before every rewrite.
    static func playlistDescription(period: TopTracksPeriod, limit: Int) -> String {
        let text = "Your \(limit) most played songs, \(period.label.lowercased()), from your last.fm history. "
            + "\(ownershipMarker)."
        return String(text.prefix(maxDescriptionLength))
    }

    static func carriesOwnershipMarker(description: String?) -> Bool {
        guard let description else { return false }
        return description.range(of: ownershipMarker, options: .caseInsensitive) != nil
    }

    static func playlistURI(id: String) -> String { "spotify:playlist:\(id)" }
    static func playlistWebURL(id: String) -> String { "https://open.spotify.com/playlist/\(id)" }

    // MARK: - last.fm parsing

    /// Decode a `user.getTopTracks` body.
    ///
    /// Done with `JSONSerialization` rather than `Codable`: last.fm sends every number as a
    /// string, `mbid` as `""` when unknown, and the rank under `"@attr"`, none of which a
    /// generated decoder handles gracefully.
    static func parseTopTracks(_ data: Data) throws -> [LastFMTopTrack] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LastFMParseError.malformed
        }
        if let (code, message) = apiError(in: root) {
            throw LastFMParseError.api(code: code, message: message)
        }
        guard let top = root["toptracks"] as? [String: Any],
              let rows = top["track"] as? [[String: Any]] else {
            throw LastFMParseError.malformed
        }
        var out: [LastFMTopTrack] = []
        for (index, row) in rows.enumerated() {
            guard let name = row["name"] as? String, !name.isEmpty,
                  let artistObj = row["artist"] as? [String: Any],
                  let artist = artistObj["name"] as? String, !artist.isEmpty else { continue }
            let attr = row["@attr"] as? [String: Any]
            let rank = intValue(attr?["rank"]) ?? (index + 1)
            let playcount = intValue(row["playcount"]) ?? 0
            let mbid = (row["mbid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            out.append(LastFMTopTrack(rank: rank, name: name, artist: artist,
                                      playcount: playcount, mbid: mbid))
        }
        return out
    }

    /// last.fm's error envelope, if the body is one.
    static func lastFMError(_ data: Data) -> (code: Int, message: String)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return apiError(in: root)
    }

    private static func apiError(in root: [String: Any]) -> (code: Int, message: String)? {
        guard let code = intValue(root["error"]) else { return nil }
        return (code, (root["message"] as? String) ?? "")
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let s = any as? String { return Int(s) }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    // MARK: - Normalisation

    /// Case, diacritics, width, and the typographic punctuation scrobblers and Spotify disagree on.
    private static func fold(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                          locale: nil)
        t = t.replacingOccurrences(of: "[\u{2019}\u{2018}`\u{00B4}]", with: "'", options: .regularExpression)
        t = t.replacingOccurrences(of: "[\u{201C}\u{201D}]", with: "\"", options: .regularExpression)
        t = t.replacingOccurrences(of: "[\u{2013}\u{2014}\u{2010}]", with: "-", options: .regularExpression)
        return t
    }

    /// Reduce to lowercase alphanumeric words. `&` becomes `and` first so "Simon & Garfunkel"
    /// and "Simon and Garfunkel" fold together; apostrophes vanish rather than split, so
    /// "Don't" is one token and "Taylor's" doesn't shed a stray "s".
    private static func words(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "&", with: " and ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Bracketed credits — `(feat. X)`, `[ft. X]`, `(with X)` — and a trailing unbracketed
    /// `feat. X`. `with` is only honoured inside brackets: stripping it bare would take the tail
    /// off "Dancing With Myself".
    private static let bracketedCredit =
        "[\\(\\[]\\s*(feat|ft|featuring|with)\\b[^\\)\\]]*[\\)\\]]?"
    private static let trailingCredit =
        "\\s+(feat|ft|featuring)\\.?\\s+.*$"

    /// Suffixes that name the *same recording* in different packaging. Safe to strip from both
    /// sides. Deliberately absent: live, acoustic, remix, demo, instrumental, sped up, slowed,
    /// `(Taylor's Version)` — those are different recordings and the scrobble may be exactly
    /// that one; `variantMarkers` handles them instead.
    private static let safeSuffix =
        "(\\d{4}\\s+)?(digital(ly)?\\s+)?remaster(ed)?(\\s+\\d{4})?(\\s+version)?"
        + "|radio\\s+edit|single\\s+version|album\\s+version|(mono|stereo)(\\s+(version|mix))?"
        + "|bonus\\s+track|explicit(\\s+version)?|deluxe(\\s+(edition|version))?|original\\s+mix"
        + "|official\\s+(music\\s+)?(video|audio|lyric\\s+video|visuali[sz]er)"
        + "|from\\s+[\"'].*[\"']|from\\s+the\\s+.*"
    private static let bracketedSafeSuffix = "\\s*[\\(\\[]\\s*(" + safeSuffix + ")\\s*[\\)\\]]"
    private static let dashedSafeSuffix = "\\s+-\\s+(" + safeSuffix + ")\\s*$"

    private static func stripCredits(_ s: String) -> String {
        var t = s.replacingOccurrences(of: bracketedCredit, with: "",
                                       options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: trailingCredit, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        return t
    }

    private static func stripSafeSuffixes(_ s: String) -> String {
        var t = s
        // A title can stack several ("Song - Remastered 2011 - Radio Edit"); a few passes is enough.
        for _ in 0..<3 {
            let before = t
            t = t.replacingOccurrences(of: bracketedSafeSuffix, with: "",
                                       options: [.regularExpression, .caseInsensitive])
            t = t.replacingOccurrences(of: dashedSafeSuffix, with: "",
                                       options: [.regularExpression, .caseInsensitive])
            if t == before { break }
        }
        return t
    }

    /// The title as the scorer compares it: folded, credits gone, packaging suffixes gone,
    /// everything else — including `(Live)` — kept.
    static func normalizedTitle(_ s: String) -> String {
        words(stripSafeSuffixes(stripCredits(fold(s))))
    }

    /// The title with *every* bracketed group and ` - ` tail removed. Only ever a secondary
    /// signal: it collapses "Song - Live" into "Song", which is exactly what `normalizedTitle`
    /// refuses to do.
    static func looseTitle(_ s: String) -> String {
        var t = fold(s)
        t = t.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]?", with: "",
                                   options: .regularExpression)
        if let range = t.range(of: " - ") { t = String(t[..<range.lowerBound]) }
        return words(t)
    }

    static func normalizedArtist(_ s: String) -> String { words(fold(s)) }

    /// The artist strings worth matching a scrobble's artist against, most specific first.
    ///
    /// last.fm records collaborations as one string ("A feat. B"); Spotify credits them
    /// separately. Split only on featuring words — never on `&`, `and` or `x`, which are part
    /// of real band names.
    static func artistCandidates(_ lastFMArtist: String) -> [String] {
        let full = normalizedArtist(lastFMArtist)
        var out: [String] = []
        if !full.isEmpty { out.append(full) }
        let primary = fold(lastFMArtist).replacingOccurrences(
            of: "\\s+(feat|ft|featuring|with)\\.?\\s+.*$", with: "",
            options: [.regularExpression, .caseInsensitive])
        let primaryNorm = normalizedArtist(primary)
        if !primaryNorm.isEmpty, primaryNorm != full { out.append(primaryNorm) }
        return out
    }

    /// Key for the match and miss caches. Both sides are reduced to alphanumerics so the same
    /// song scrobbled with different punctuation shares one entry.
    static func cacheKey(artist: String, title: String) -> String {
        let a = normalizedArtist(artist).replacingOccurrences(of: " ", with: "")
        let t = normalizedTitle(title).replacingOccurrences(of: " ", with: "")
        return "\(a)|\(t)"
    }

    // MARK: - Queries

    /// What goes into a `track:` / `artist:` filter. Colons would start a new field and quotes
    /// force exact-phrase matching, which fails on trivial differences; both are dropped.
    private static func filterValue(_ s: String) -> String {
        s.replacingOccurrences(of: "[:\"]", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// At most two queries per track, filtered first, plain second. Bounded so a track that
    /// Spotify simply doesn't have costs a known number of requests before it's recorded as a
    /// miss.
    static func searchQueries(for track: LastFMTopTrack) -> [String] {
        let candidates = artistCandidates(track.artist)
        let primary = candidates.last ?? normalizedArtist(track.artist)
        let filteredTitle = filterValue(stripSafeSuffixes(stripCredits(fold(track.name))))
        var out: [String] = []
        if !filteredTitle.isEmpty, !primary.isEmpty {
            out.append(cap("track:\(filteredTitle) artist:\(primary)"))
        }
        let plain = cap("\(looseTitle(track.name)) \(primary)")
        if !plain.trimmingCharacters(in: .whitespaces).isEmpty, !out.contains(plain) {
            out.append(plain)
        }
        return out
    }

    private static func cap(_ q: String) -> String {
        q.count <= maxQueryLength ? q : String(q.prefix(maxQueryLength))
    }

    // MARK: - Scoring

    /// Words that mark a different recording of the same song. Computed on normalised titles,
    /// so "8-bit" has already become "8 bit".
    private static let variantPattern =
        "\\b(live|unplugged|remix(es|ed)?|rmx|acoustic|instrumental|demo|karaoke|cover|tribute"
        + "|sped up|slowed|reverb|nightcore|8 bit|lullaby|orchestral|piano version)\\b"

    static func variantMarkers(_ normalizedTitle: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: variantPattern) else { return [] }
        let ns = normalizedTitle as NSString
        let matches = regex.matches(in: normalizedTitle, range: NSRange(location: 0, length: ns.length))
        return Set(matches.map { ns.substring(with: $0.range(at: 1)) })
    }

    /// Dice coefficient over word tokens — partial credit for "Song Pt 2" vs "Song Part 2".
    static func tokenSimilarity(_ a: String, _ b: String) -> Double {
        let ta = Set(a.split(separator: " ")), tb = Set(b.split(separator: " "))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        return 2 * Double(ta.intersection(tb).count) / Double(ta.count + tb.count)
    }

    static func titleScore(hit: String, scrobble: String) -> Double {
        let h = normalizedTitle(hit), s = normalizedTitle(scrobble)
        if h == s { return 1.0 }
        if looseTitle(hit) == looseTitle(scrobble) { return 0.9 }
        return tokenSimilarity(h, s)
    }

    private static func dropLeadingThe(_ s: String) -> String {
        s.hasPrefix("the ") ? String(s.dropFirst(4)) : s
    }

    static func artistScore(hitArtists: [String], scrobbleArtist: String) -> Double {
        let candidates = artistCandidates(scrobbleArtist)
        guard !candidates.isEmpty, !hitArtists.isEmpty else { return 0 }
        let hits = hitArtists.map(normalizedArtist).filter { !$0.isEmpty }
        let joinedForms = [hits.joined(separator: " "), hits.joined(separator: " and ")]
        for c in candidates {
            for h in hits where h == c || dropLeadingThe(h) == dropLeadingThe(c) { return 1.0 }
            if joinedForms.contains(c) { return 1.0 }
        }
        for c in candidates {
            for h in hits {
                let (short, long) = h.count < c.count ? (h, c) : (c, h)
                if long.hasPrefix(short + " ") { return 0.7 }
            }
        }
        return 0
    }

    private static func albumTypeBonus(_ type: String) -> Double {
        switch type.lowercased() {
        case "album": return 0.03
        case "single": return 0.02
        default: return 0
        }
    }

    /// Score one hit against the scrobble. `index` is its position in Spotify's own ordering,
    /// used only to break exact ties the way Spotify would.
    static func score(_ hit: TrackSearchHit, index: Int, against track: LastFMTopTrack)
        -> (total: Double, artist: Double) {
        let title = titleScore(hit: hit.name, scrobble: track.name)
        let artist = artistScore(hitArtists: hit.artistNames, scrobbleArtist: track.artist)
        let hitMarkers = variantMarkers(normalizedTitle(hit.name))
        let scrobbleMarkers = variantMarkers(normalizedTitle(track.name))
        var penalty = 0.0
        if !hitMarkers.subtracting(scrobbleMarkers).isEmpty { penalty += 0.3 }
        if !scrobbleMarkers.subtracting(hitMarkers).isEmpty { penalty += 0.2 }
        let total = 0.6 * title + 0.4 * artist - penalty + albumTypeBonus(hit.albumType)
            - 0.01 * Double(index)
        return (total, artist)
    }

    /// The hit to use, or nil when nothing clears both the score threshold and the artist floor.
    static func bestMatch(_ hits: [TrackSearchHit], for track: LastFMTopTrack) -> TrackMatch? {
        var best: TrackMatch?
        for (index, hit) in hits.enumerated() {
            let (total, artist) = score(hit, index: index, against: track)
            guard artist >= minArtistScore, total >= acceptThreshold else { continue }
            if let current = best, current.score >= total { continue }
            best = TrackMatch(hit: hit, score: total, artistScore: artist)
        }
        return best
    }

    // MARK: - Cache policy

    /// A miss is retried after `interval`. A `lastTriedAt` in the future means the clock moved
    /// back; retry rather than wait for real time to catch up.
    static func shouldRetryMiss(lastTriedAt: Date, now: Date,
                                interval: TimeInterval = missRetryInterval) -> Bool {
        if lastTriedAt > now { return true }
        return now.timeIntervalSince(lastTriedAt) >= interval
    }

    // MARK: - Write plans

    /// Order-preserving unique: two scrobble titles can resolve to one Spotify track.
    static func dedupedRankOrder(_ uris: [String]) -> [String] {
        var seen = Set<String>()
        return uris.filter { seen.insert($0).inserted }
    }

    /// Append mode: what's missing, in rank order. `alreadyAdded` is the radar's rule — a track
    /// this feature added that is no longer there was removed by hand and is not re-added.
    static func appendPlan(ranked: [String], existing: Set<String>,
                           alreadyAdded: (String) -> Bool) -> [String] {
        ranked.filter { !existing.contains($0) && !alreadyAdded($0) }
    }

    /// Replace mode: the full list to write, or nil when the playlist already reads exactly so.
    static func replacePlan(ranked: [String], current: [String]) -> [String]? {
        ranked == current ? nil : ranked
    }

    /// Replace is only honoured on a playlist this feature owns, and never on one that another
    /// period is also appending to — one period's rewrite would wipe the other's additions.
    static func effectiveMode(requested: TopTracksSyncMode, targetIsOwned: Bool,
                              targetSharedWithAnotherPeriod: Bool) -> TopTracksSyncMode {
        guard requested == .replace, targetIsOwned, !targetSharedWithAnotherPeriod else { return .append }
        return .replace
    }

    /// Same rule as `NewReleaseLogic.isScanDue`: a future stamp means the clock moved back.
    static func isSyncDue(lastSyncAt: Date?, now: Date, interval: TimeInterval = syncInterval) -> Bool {
        guard let last = lastSyncAt else { return true }
        if last > now { return true }
        return now.timeIntervalSince(last) >= interval
    }

    // MARK: - Labels

    static func progressLabel(period: TopTracksPeriod, resolved: Int, total: Int) -> String {
        "\(period.label): matching \(resolved) of \(total) songs…"
    }

    private static func plural(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }

    private static func missedSuffix(_ missed: Int) -> String {
        missed == 0 ? "" : " \(missed) not found on Spotify."
    }

    static func appendSummary(added: Int, missed: Int) -> String {
        (added == 0 ? "Nothing new to add." : "Added \(plural(added, "song")).") + missedSuffix(missed)
    }

    static func replaceSummary(total: Int, added: Int, dropped: Int, unchanged: Bool, missed: Int) -> String {
        let body = unchanged
            ? "Up to date — \(plural(total, "song"))."
            : "Updated — \(plural(total, "song")), \(added) new, \(dropped) dropped."
        return body + missedSuffix(missed)
    }

    static func interruptedLabel(reason: String) -> String {
        "Paused: \(reason) Will retry."
    }
}
