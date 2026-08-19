import Foundation

/// Which listening window a hit came from.
///
/// The weights encode what the feature is actually for. This is a *follow* decision, not a
/// "what am I into this week" decision: following someone is a standing subscription, so
/// enduring taste counts for more than a recent binge. `long_term` therefore outweighs
/// `short_term` rather than the other way round.
enum ArtistTimeRange: String, Codable, Equatable, CaseIterable {
    case shortTerm = "short_term"
    case mediumTerm = "medium_term"
    case longTerm = "long_term"

    /// The `time_range` query value for `GET /me/top/{type}`.
    var queryValue: String { rawValue }

    /// How this window reads in a reason line.
    var label: String {
        switch self {
        case .shortTerm: return "last 4 weeks"
        case .mediumTerm: return "last 6 months"
        case .longTerm: return "all time"
        }
    }

    var weight: Double {
        switch self {
        case .shortTerm: return 0.8
        case .mediumTerm: return 1.0
        case .longTerm: return 1.2
        }
    }
}

/// A full artist object from `GET /me/top/artists` — the one place artwork arrives without
/// a separate request.
///
/// `popularity` and `followers` were removed from the artist object in February 2026, so
/// nothing here may depend on them: there is no way to tell a stadium act from a bedroom
/// producer, and the scoring below deliberately doesn't try.
struct ArtistSeed: Equatable {
    let id: String
    let name: String
    let imageURL: String?
    let genres: [String]
}

/// One appearance of an artist in `GET /me/top/artists`, for one time range.
struct TopArtistHit: Equatable {
    let artistId: String
    let name: String
    /// Zero-based position in the returned list.
    let rank: Int
    let range: ArtistTimeRange
}

/// One artist credit on a track from `GET /me/top/tracks`.
///
/// The artist objects nested in a track are *simplified* — id and name, no images — which is
/// why hydration exists (see `hydrationCap`).
struct TopTrackCredit: Equatable {
    let artistId: String
    let artistName: String
    let trackId: String
    let trackName: String
    /// Zero-based position of the *track* in the top-tracks list.
    let rank: Int
    let range: ArtistTimeRange
    /// True when this artist holds the first credit. A guest verse is much weaker evidence
    /// that you want this artist's releases in your feed.
    let isPrimary: Bool
}

/// An artist the user listens to but doesn't follow, with the evidence that says so.
struct ScoredArtist: Equatable, Identifiable {
    let id: String
    let name: String
    let score: Double
    /// Human-readable evidence, e.g. "#3 in your top artists (all time) · 5 songs in your top tracks".
    let reason: String
    /// Distinct time ranges this artist showed up in, across both sources. 3 is the maximum.
    let rangesSeen: Int
    /// Distinct tracks of theirs in your top tracks.
    let trackCount: Int
    /// The best-ranked track crediting them, if any — the fallback for the play button if a
    /// build ever has to stop sending bare artist URIs.
    let bestTrackId: String?
}

/// Pure, side-effect-free decisions for the "Artists to Follow" suggestion list — unit-tested
/// in isolation (compiled directly into the test target), in the same spirit as
/// `NewReleaseLogic` and `DiscoveryLogic`.
///
/// The whole feature exists inside a hard constraint: February 2026 removed
/// `GET /artists/{id}/top-tracks`, `/artists/{id}/related-artists`, `/recommendations`, and
/// the `popularity` field from every object. So "artists you should follow" cannot mean
/// "artists similar to ones you like" — there is no endpoint left that answers that. It can
/// only mean *artists already present in your own listening history that you never followed*,
/// which is what this scores.
enum ArtistSuggestionLogic {

    // MARK: - API shape constants

    /// `GET /me/top/{type}` caps `limit` at 50.
    static let topPageSize = 50

    /// How many artists get a `GET /artists/{id}` hydration request per refresh.
    ///
    /// The batch `GET /artists?ids=` endpoint was removed in February 2026, so artwork for an
    /// artist seen only through a track costs one request each. Six top-list requests plus
    /// this cap is the entire budget for a refresh; without a cap, a listening history spread
    /// across a few hundred artists would turn one window-open into a few hundred requests.
    ///
    /// Callers must report what the cap dropped rather than silently showing a short list.
    static let hydrationCap = 30

    /// How long a refresh stays good. Top lists are recomputed by Spotify on the order of a
    /// day, so re-fetching more often than this spends requests to learn nothing.
    static let staleAfter: TimeInterval = 6 * 60 * 60

    // MARK: - Scoring weights

    /// An explicit place in your top *artists* is the strongest available signal — it's
    /// Spotify's own aggregate across everything you played, where a top *track* is a single
    /// song that might be the only one of theirs you've ever heard.
    ///
    /// Calibrated, not guessed: at 4.0 an artist inside roughly your top 15 outscores your
    /// single most-played track, and below that the track wins. That's the crossover the
    /// aggregate deserves — being your 11th-favourite artist really is more evidence than one
    /// song on repeat, and being your 40th really isn't.
    static let topArtistWeight = 4.0

    /// A track where this artist holds the first credit.
    static let primaryCreditWeight = 1.0

    /// A featured credit.
    ///
    /// Low enough that **one** featured credit never outscores a primary credit anywhere in a
    /// 50-track list from the same time range (the floor there is `rankWeight(49)` ≈ 0.176).
    /// That's deliberate: this list decides whose *releases* you want to follow, and a guest
    /// verse on a song you love says you love the song. Features still accumulate, so an
    /// artist guesting on five of your top tracks does surface — which is the case where the
    /// signal is real.
    static let featureCreditWeight = 0.15

    /// Per extra time range an artist appears in. Without `popularity` this is the only
    /// evidence available that an artist is a durable taste rather than one week's loop —
    /// showing up in the 4-week, 6-month *and* all-time lists is a different thing from
    /// showing up in one.
    static let crossRangeBonus = 0.15

    /// Positional decay within a top list.
    ///
    /// Logarithmic rather than linear: the gap between #1 and #5 genuinely matters, the gap
    /// between #45 and #50 does not, and a linear ramp would drive the tail to ~0 and make
    /// the bottom of a 50-item list contribute nothing at all.
    static func rankWeight(_ rank: Int) -> Double {
        1.0 / log2(Double(max(0, rank)) + 2.0)
    }

    // MARK: - Scoring

    /// Score every artist mentioned by either source, highest first.
    ///
    /// Track credits are deduped per (artist, track, range) before counting, but the *same*
    /// track appearing in two ranges is counted twice on purpose: a song that's in both your
    /// 4-week and your all-time list is stronger evidence than one in either alone. Distinct
    /// track ids are counted separately for the reason line, which should say "5 songs" rather
    /// than "5 song-slots".
    static func score(topArtistHits: [TopArtistHit],
                      topTrackCredits: [TopTrackCredit]) -> [ScoredArtist] {
        struct Accumulator {
            var name = ""
            var score = 0.0
            var ranges = Set<ArtistTimeRange>()
            var trackIds = Set<String>()
            var bestArtistHit: TopArtistHit?
            var bestTrack: TopTrackCredit?
        }
        var acc: [String: Accumulator] = [:]

        for hit in topArtistHits where !hit.artistId.isEmpty {
            var entry = acc[hit.artistId] ?? Accumulator()
            entry.name = entry.name.isEmpty ? hit.name : entry.name
            entry.score += topArtistWeight * hit.range.weight * rankWeight(hit.rank)
            entry.ranges.insert(hit.range)
            // Best = closest to the top of any list. Ties keep the first seen, and callers
            // pass ranges in a fixed order, so this is deterministic.
            if let best = entry.bestArtistHit {
                if hit.rank < best.rank { entry.bestArtistHit = hit }
            } else {
                entry.bestArtistHit = hit
            }
            acc[hit.artistId] = entry
        }

        var countedCredits = Set<String>()
        for credit in topTrackCredits where !credit.artistId.isEmpty {
            let key = "\(credit.artistId)|\(credit.trackId)|\(credit.range.rawValue)"
            guard countedCredits.insert(key).inserted else { continue }
            var entry = acc[credit.artistId] ?? Accumulator()
            entry.name = entry.name.isEmpty ? credit.artistName : entry.name
            let base = credit.isPrimary ? primaryCreditWeight : featureCreditWeight
            entry.score += base * credit.range.weight * rankWeight(credit.rank)
            entry.ranges.insert(credit.range)
            entry.trackIds.insert(credit.trackId)
            // Prefer a primary credit for the fallback track: playing someone's own song is a
            // better introduction than the track where they take the third verse.
            if let best = entry.bestTrack {
                let better = (credit.isPrimary && !best.isPrimary)
                    || (credit.isPrimary == best.isPrimary && credit.rank < best.rank)
                if better { entry.bestTrack = credit }
            } else {
                entry.bestTrack = credit
            }
            acc[credit.artistId] = entry
        }

        return acc.map { id, entry in
            let multiplier = 1.0 + crossRangeBonus * Double(max(0, entry.ranges.count - 1))
            return ScoredArtist(
                id: id,
                name: entry.name,
                score: entry.score * multiplier,
                reason: reasonLabel(bestArtistHit: entry.bestArtistHit,
                                    trackCount: entry.trackIds.count,
                                    rangesSeen: entry.ranges.count),
                rangesSeen: entry.ranges.count,
                trackCount: entry.trackIds.count,
                bestTrackId: entry.bestTrack?.trackId)
        }
        .sorted(by: ordering)
    }

    /// Highest score first; name then id break ties so the list doesn't reshuffle between
    /// refreshes (dictionary iteration order is not stable across runs).
    static func ordering(_ a: ScoredArtist, _ b: ScoredArtist) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.name != b.name { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
        return a.id < b.id
    }

    // MARK: - Eligibility

    /// Everyone worth suggesting: scored, minus who you already follow, minus who you've
    /// dismissed.
    ///
    /// The followed set is re-read on every refresh rather than cached, because it's the one
    /// exclusion that can change outside this app — following someone in the Spotify client
    /// should make them disappear here without any extra step.
    static func eligible(scored: [ScoredArtist],
                         following: Set<String>,
                         notInterested: Set<String>) -> [ScoredArtist] {
        scored.filter { !following.contains($0.id) && !notInterested.contains($0.id) }
    }

    /// The artists worth spending a hydration request on this refresh — the top of the list.
    ///
    /// Returns `(shown, dropped)` so the caller can say what it left out. An artist already
    /// carrying artwork (they came from `GET /me/top/artists`) doesn't need one and shouldn't
    /// consume a slot, which is what `needsHydration` filters.
    static func hydrationPlan(eligible: [ScoredArtist],
                              needsHydration: (ScoredArtist) -> Bool,
                              cap: Int = hydrationCap) -> (fetch: [ScoredArtist], skipped: Int) {
        let wanted = eligible.filter(needsHydration)
        guard wanted.count > cap else { return (wanted, 0) }
        return (Array(wanted.prefix(cap)), wanted.count - cap)
    }

    // MARK: - Labels

    /// The evidence line under an artist's name.
    ///
    /// Says *why this artist is here* in the user's own terms. Without it a suggestion list is
    /// unfalsifiable — you can't tell a good recommendation from a bug, which for a feature
    /// whose whole job is judgement is the difference between trusting it and ignoring it.
    static func reasonLabel(bestArtistHit: TopArtistHit?,
                            trackCount: Int,
                            rangesSeen: Int) -> String {
        var parts: [String] = []
        if let hit = bestArtistHit {
            parts.append("#\(hit.rank + 1) in your top artists (\(hit.range.label))")
        }
        if trackCount > 0 {
            parts.append("\(trackCount) song\(trackCount == 1 ? "" : "s") in your top tracks")
        }
        if parts.isEmpty { parts.append("in your listening history") }
        if rangesSeen >= ArtistTimeRange.allCases.count {
            parts.append("across every time range")
        }
        return parts.joined(separator: " · ")
    }

    /// The footer line. Names what was left out rather than quietly showing a short list — a
    /// truncated list and a complete one look identical otherwise.
    static func summaryLabel(shown: Int, hidden: Int) -> String {
        guard shown > 0 else { return "No suggestions right now." }
        let head = "\(shown) artist\(shown == 1 ? "" : "s") you listen to but don't follow"
        return hidden > 0 ? "\(head) — \(hidden) more not shown this refresh" : head
    }

    static func progressLabel(hydrated: Int, total: Int) -> String {
        "Loading artwork \(hydrated) of \(total)…"
    }

    // MARK: - Freshness

    /// Whether the list is old enough to re-fetch when the window opens.
    ///
    /// A `lastRefreshAt` in the future means the clock moved backwards (timezone change, NTP
    /// correction); treat that as stale rather than freezing the list until real time catches up.
    static func isStale(lastRefreshAt: Date?, now: Date, interval: TimeInterval = staleAfter) -> Bool {
        guard let last = lastRefreshAt else { return true }
        if last > now { return true }
        return now.timeIntervalSince(last) >= interval
    }

    static func updatedLabel(lastRefreshAt: Date?, now: Date) -> String {
        guard let last = lastRefreshAt, last <= now else { return "Never updated" }
        let seconds = Int(now.timeIntervalSince(last))
        switch seconds {
        case ..<60: return "Updated just now"
        case ..<3_600:
            let m = seconds / 60
            return "Updated \(m) minute\(m == 1 ? "" : "s") ago"
        case ..<86_400:
            let h = seconds / 3_600
            return "Updated \(h) hour\(h == 1 ? "" : "s") ago"
        default:
            let d = seconds / 86_400
            return "Updated \(d) day\(d == 1 ? "" : "s") ago"
        }
    }

    // MARK: - URIs

    static func artistURI(id: String) -> String { "spotify:artist:\(id)" }

    /// The web fallback for "open in Spotify", used when the desktop app can't be reached.
    static func artistWebURL(id: String) -> String { "https://open.spotify.com/artist/\(id)" }
}
