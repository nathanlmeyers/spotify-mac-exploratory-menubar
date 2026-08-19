import Foundation

/// Which query surfaced an album — the artist's own release, or one they only appear on.
///
/// February 2026 removed `album_group` from the album object, so this can no longer be read
/// off the response. It's inferred from *which* `include_groups` query produced the album,
/// which is why the scanner issues two separate queries instead of one combined one.
enum ReleaseGroup: String, Codable, Equatable { case own, appearsOn }

struct FollowedArtist: Equatable {
    let id: String
    let name: String
}

/// A simplified album as returned by `GET /artists/{id}/albums`, reduced to the fields the
/// filters actually read. `popularity` and `available_markets` were removed from the API in
/// February 2026, so nothing here may depend on them.
struct CandidateAlbum: Equatable {
    let id: String
    let name: String
    /// `album` | `single` | `compilation`
    let albumType: String
    /// `2026-08-18`, `2026-08`, or `2026` — see `releaseDatePrecision`.
    let releaseDate: String
    /// `day` | `month` | `year`
    let releaseDatePrecision: String
    let group: ReleaseGroup
}

/// A simplified track from `GET /albums/{id}/tracks`.
struct CandidateTrack: Equatable {
    let id: String
    let uri: String
    let name: String
    /// Credited artists in Spotify's order — `artistIds[0]` is the primary credit.
    let artistIds: [String]
    let albumId: String
    /// The followed artist this track was collected for, and how it was found.
    let matchedArtistId: String
    let group: ReleaseGroup
}

struct NewReleaseFilters: Equatable {
    /// Include albums the artist only appears on — the "features them" half of the feature.
    var includeFeatures = true
    /// Require the followed artist to hold the *first* credit on the track.
    var primaryArtistOnly = false
    var excludeRemixes = true
    var excludeCompilations = true
    var lookbackDays = 14
}

/// Pure, side-effect-free decisions for the "New From Followed" release radar — unit-tested in
/// isolation (compiled directly into the test target), in the same spirit as `DiscoveryLogic`
/// and `LibraryLogic`.
enum NewReleaseLogic {

    // MARK: - API shape constants

    /// `GET /artists/{id}/albums` caps `limit` at 10 as of February 2026 (it was 50).
    /// This is the single biggest cost driver in a scan, which is why paging stops early.
    static let albumPageSize = 10

    /// Hard ceiling on pages per artist per group, so one absurdly prolific artist can't
    /// consume the whole request budget.
    static let maxAlbumPagesPerGroup = 5

    /// `POST /playlists/{id}/items` accepts 100 URIs per request.
    static let addBatchSize = 100

    static let scanInterval: TimeInterval = 24 * 60 * 60

    /// How many days one full sweep of `appears_on` is spread over. See `shouldDeepScan`.
    static let appearsOnSlices = 7

    // MARK: - Dates

    /// `yyyy-MM-dd` in UTC. Fixed locale/timezone so the cutoff is reproducible and testable.
    ///
    /// Everything downstream compares release dates as *strings*. ISO-8601 dates sort
    /// lexicographically, so this sidesteps calendar and timezone arithmetic entirely — and
    /// Spotify's `release_date` carries no timezone to reconcile anyway.
    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// The oldest release date eligible for this scan.
    ///
    /// Three bounds, and the widest-but-clamped one wins:
    ///
    ///  - `watermark`, stamped when the feature is first enabled, is what keeps the first run
    ///    cheap: without it, enabling the feature would sweep in every back-catalogue album
    ///    within the lookback window on day one. It's a hard floor.
    ///  - `lookbackDays` back from now, the normal case.
    ///  - **`lastScanAt`, when the machine was off (or the app shut) for longer than the
    ///    lookback window.** Without this the window is purely relative to *now*, so coming back
    ///    from three weeks away with a two-week lookback would permanently lose the releases
    ///    from the uncovered week — they'd already be too old to qualify on the very first scan
    ///    back. Reaching back to the last completed scan closes the gap exactly.
    static func cutoffDay(now: Date, watermark: Date, lastScanAt: Date?, lookbackDays: Int) -> String {
        let byLookback = now.addingTimeInterval(-Double(max(0, lookbackDays)) * 86_400)
        // `min` because covering the gap means reaching *further back*, not less far.
        let start = lastScanAt.map { min(byLookback, $0) } ?? byLookback
        return dayString(max(start, watermark))
    }

    /// True when the last scan is older than the lookback window — the machine was off, asleep,
    /// or the app wasn't running, for long enough to leave a hole.
    ///
    /// A catch-up scan widens the date window (see `cutoffDay`) *and* suspends the `appears_on`
    /// rotation, so every artist is swept in that one run. It's the expensive path, which is
    /// exactly right for something that happens after a holiday rather than every day: spreading
    /// the catch-up over the next week would let the widened window close before most artists
    /// got their turn, which is the bug this exists to prevent.
    static func isCatchUp(lastScanAt: Date?, now: Date, lookbackDays: Int) -> Bool {
        guard let last = lastScanAt, last <= now else { return false }
        return now.timeIntervalSince(last) > Double(max(0, lookbackDays)) * 86_400
    }

    /// Releases dated further ahead than this are treated as announcements, not releases.
    /// One day of slack absorbs the timezone gap between Spotify's date and ours.
    static func horizonDay(now: Date) -> String {
        dayString(now.addingTimeInterval(86_400))
    }

    /// Is this album inside the scan's date window?
    ///
    /// Only `day` precision qualifies. Coarse precision (`2003`, `1998-06`) is how Spotify dates
    /// back-catalogue and reissues, which arrive by the boatload through `appears_on`; admitting
    /// them would mean a "new releases" playlist full of 1998. A genuinely new release is always
    /// dated to the day.
    static func isWithinWindow(releaseDate: String,
                               precision: String,
                               cutoffDay: String,
                               horizonDay: String) -> Bool {
        guard precision == "day", releaseDate.count == 10 else { return false }
        return releaseDate >= cutoffDay && releaseDate <= horizonDay
    }

    // MARK: - Title classifiers

    /// True for titles that name a remix.
    ///
    /// Deliberately matches only unambiguous tokens, on word boundaries. The asymmetry matters:
    /// a false negative puts one extra song in the feed, while a false positive silently hides
    /// music the user wanted and leaves no trace to notice. So `Remixing My Heart` and a band
    /// named `Remix` must not match, and bare `... Mix` is not treated as a remix at all —
    /// `Original Mix` / `Extended Mix` / `Club Mix` are usually the artist's own versions.
    static func isRemixTitle(_ name: String) -> Bool {
        name.range(of: "\\b(remix(es|ed)?|rmx|bootleg|mashup)\\b",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// True for greatest-hits-style repackagings, which carry no new music.
    static func isCompilationLike(albumType: String, name: String) -> Bool {
        if albumType.caseInsensitiveCompare("compilation") == .orderedSame { return true }
        return name.range(of: "\\b(greatest hits|best of|anthology|retrospective|essentials|the collection)\\b",
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Album-level filter

    /// The seen-cache key: an album id is only meaningful *paired with the artist it was
    /// considered for*.
    ///
    /// Track selection is artist-specific (`trackMatches`), so having processed an album for one
    /// followed artist says nothing about another. A various-artists compilation carrying tracks
    /// by two followed artists is the ordinary case: keyed by album id alone, whoever was swept
    /// first would mark it seen and the second artist's tracks would be lost for good.
    static func seenKey(albumId: String, artistId: String) -> String { "\(artistId):\(albumId)" }

    /// Whether an album's verdict can be cached — i.e. whether its release date can still change
    /// the answer.
    ///
    /// A pre-announced release fails today's window check for being past the horizon, but it will
    /// qualify when its date arrives; caching it now would skip it forever. Coarse precision is
    /// the same story from the other end — `2027` can be sharpened to `2027-03-14` later — and
    /// caching it buys nothing anyway, since coarse dates never pass the window.
    ///
    /// Nothing is lost by not caching those: the cache's only saving is the
    /// `GET /albums/{id}/tracks` call, and an album that fails the window never reaches it.
    static func isSettled(_ album: CandidateAlbum, horizonDay: String) -> Bool {
        guard album.releaseDatePrecision == "day", album.releaseDate.count == 10 else { return false }
        return album.releaseDate <= horizonDay
    }

    /// Whether an album is worth spending a `GET /albums/{id}/tracks` call on.
    ///
    /// `seenAlbumKeys` is the cache that makes repeat scans cheap: every album whose verdict is
    /// final (see `isSettled`) goes in for the artist it was considered for, including rejected
    /// ones, so the next scan re-rejects them for free.
    static func albumPasses(_ album: CandidateAlbum,
                            artistId: String,
                            filters: NewReleaseFilters,
                            seenAlbumKeys: Set<String>,
                            cutoffDay: String,
                            horizonDay: String) -> Bool {
        if seenAlbumKeys.contains(seenKey(albumId: album.id, artistId: artistId)) { return false }
        guard isWithinWindow(releaseDate: album.releaseDate,
                             precision: album.releaseDatePrecision,
                             cutoffDay: cutoffDay,
                             horizonDay: horizonDay) else { return false }
        if filters.excludeCompilations,
           isCompilationLike(albumType: album.albumType, name: album.name) { return false }
        if filters.excludeRemixes, isRemixTitle(album.name) { return false }
        return true
    }

    // MARK: - Track-level filter

    /// Whether a track on a passing album should actually be added.
    ///
    /// The artist-credit check is what makes `appears_on` usable: a various-artists compilation
    /// is one album with twenty tracks, nineteen of which have nothing to do with the followed
    /// artist. Without this the feed would be mostly strangers.
    static func trackMatches(_ track: CandidateTrack,
                             artistId: String,
                             filters: NewReleaseFilters) -> Bool {
        if filters.excludeRemixes, isRemixTitle(track.name) { return false }
        if filters.primaryArtistOnly { return track.artistIds.first == artistId }
        return track.artistIds.contains(artistId)
    }

    // MARK: - Dedupe

    /// Fold a title to a comparison key: a lead single and its album cut are the same song.
    ///
    /// Strips only credit parentheticals (`(feat. …)`, `(with …)`), which routinely differ
    /// between a single and an album pressing, then reduces to alphanumerics. It does NOT strip
    /// arbitrary suffixes — collapsing `Song - Live` into `Song` would drop genuinely distinct
    /// recordings.
    static func titleKey(_ name: String) -> String {
        var t = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                             locale: nil)
        t = t.replacingOccurrences(of: "[\\(\\[]\\s*(feat|ft|featuring|with)\\b[^\\)\\]]*[\\)\\]]?",
                                   with: "",
                                   options: [.regularExpression, .caseInsensitive])
        return t.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    /// Order-preserving dedupe, first occurrence wins.
    ///
    /// Two passes because they catch different duplicates: the same track id can be reached via
    /// two followed artists on one collaboration, while a distinct id can still be the same song
    /// released as both a single and an album cut.
    ///
    /// Callers should pass `.own` releases before `.appearsOn` ones so the canonical pressing is
    /// the one that survives.
    static func dedupe(_ tracks: [CandidateTrack]) -> [CandidateTrack] {
        var seenIds = Set<String>()
        var seenSongs = Set<String>()
        var out: [CandidateTrack] = []
        for track in tracks {
            guard !seenIds.contains(track.id) else { continue }
            let song = "\(titleKey(track.name))|\(track.artistIds.first ?? "")"
            guard !seenSongs.contains(song) else { continue }
            seenIds.insert(track.id)
            seenSongs.insert(song)
            out.append(track)
        }
        return out
    }

    // MARK: - Paging

    /// One `include_groups` query against `GET /artists/{id}/albums`.
    struct AlbumQuery: Equatable {
        /// The `include_groups` value. Exactly one group — see `includeGroupsQueries`.
        let groups: String
        let group: ReleaseGroup
        /// Page to the cap regardless of hits, because this group isn't returned newest-first.
        let exhaustive: Bool
    }

    /// Which queries to issue for one artist, in the order results should be collected
    /// (own releases first — see `dedupe`).
    ///
    /// **One group per query, never a combined `album,single`.** The probe
    /// (`scripts/probe-new-releases.py`) showed a combined query returns each group's albums
    /// concatenated as separate descending runs — so the response *looks* unsorted and the
    /// stop-early rule would quit on the first old album of the first block, never reaching the
    /// singles. Split apart, each response is newest-first and paging can stop early.
    ///
    /// `appears_on` is genuinely unordered even queried alone, so it's exhaustive — and, being
    /// the expensive half, it's amortized across days by `shouldDeepScan`.
    ///
    /// `compilation` is only requested when compilations are wanted: with `limit` capped at 10,
    /// asking for a group we're about to discard would crowd real results out of page one.
    static func includeGroupsQueries(filters: NewReleaseFilters) -> [AlbumQuery] {
        var queries: [AlbumQuery] = [
            AlbumQuery(groups: "album", group: .own, exhaustive: false),
            AlbumQuery(groups: "single", group: .own, exhaustive: false),
        ]
        if !filters.excludeCompilations {
            queries.append(AlbumQuery(groups: "compilation", group: .own, exhaustive: true))
        }
        if filters.includeFeatures {
            queries.append(AlbumQuery(groups: "appears_on", group: .appearsOn, exhaustive: true))
        }
        return queries
    }

    // MARK: - Amortizing the expensive half

    /// FNV-1a. Swift's `hashValue` is seeded per process, so it would reshuffle which artists
    /// are deep-scanned on every launch — an artist could go weeks without their turn.
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100_0000_01b3
        }
        return h
    }

    /// Whole days since the epoch — the rotation counter for `shouldDeepScan`.
    static func dayIndex(now: Date) -> Int {
        Int((now.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// Whether this artist's `appears_on` catalogue gets its full crawl today.
    ///
    /// `appears_on` isn't returned newest-first, so finding a new feature means crawling the
    /// artist's whole guest catalogue — tens of requests for a prolific artist, which across a
    /// few hundred followed artists is far too much to do daily. Each artist is assigned a fixed
    /// slot by a stable hash, so every artist is swept once per `slices` days at a flat daily
    /// cost. The `lookbackDays` window (which must be ≥ `slices`) is what stops a feature
    /// released the day after an artist's slot from being missed.
    static func shouldDeepScan(artistId: String, dayIndex: Int, slices: Int = appearsOnSlices) -> Bool {
        guard slices > 1 else { return true }
        return Int(stableHash(artistId) % UInt64(slices)) == dayIndex % slices
    }

    /// The lookback window actually used.
    ///
    /// Clamped to at least `appearsOnSlices` whenever features are on: with a shorter window, a
    /// feature released just after an artist's deep-scan slot would fall out of range before
    /// their next slot came round, and would never be found at all.
    static func effectiveLookbackDays(filters: NewReleaseFilters) -> Int {
        filters.includeFeatures ? max(filters.lookbackDays, appearsOnSlices) : filters.lookbackDays
    }

    /// Whether a page of a newest-first listing has crossed the back edge of the date window.
    ///
    /// This — not "did anything on that page pass the filters" — is what decides whether to page
    /// deeper. The filters reject for reasons that say nothing about where the page sits in time:
    /// an album already in the seen cache, a remix package, a greatest-hits. A full page of those
    /// used to look identical to "we've run out of new music", so a genuine release sitting on
    /// page two was never reached.
    ///
    /// Dates only need to be *within reach* of the cutoff, not eligible: `>= cutoffDay` means
    /// this page hasn't fallen off the end of the window yet, so the next one might still hold
    /// something.
    static func pageReachesWindow(_ albums: [CandidateAlbum], cutoffDay: String) -> Bool {
        albums.contains { $0.releaseDate >= cutoffDay }
    }

    /// The stop-early paging rule.
    ///
    /// When Spotify returns albums newest-first, page one is already older than the window for
    /// almost every artist on almost every day, so a scan costs one request per group per
    /// artist. Paging deeper only happens while the dates are still in reach.
    ///
    /// `exhaustive` is the escape hatch for the case where ordering turns out not to be
    /// newest-first (see `scripts/probe-new-releases.py`): it pages to the cap regardless.
    static func shouldFetchNextPage(pagesFetched: Int,
                                    itemsOnLastPage: Int,
                                    lastPageReachedWindow: Bool,
                                    exhaustive: Bool) -> Bool {
        guard pagesFetched > 0 else { return true }             // page one is never optional
        guard itemsOnLastPage >= albumPageSize else { return false }  // short page = end of list
        guard pagesFetched < maxAlbumPagesPerGroup else { return false }
        return exhaustive || lastPageReachedWindow
    }

    // MARK: - Crawling `appears_on` across scans

    /// How far one artist's guest-catalogue crawl has got, and how far back its results must
    /// still reach.
    ///
    /// The crawl is capped at `maxAlbumPagesPerGroup` pages per turn so one prolific artist can't
    /// eat the request budget, and it resumes at `offset` on the next turn rather than restarting
    /// — otherwise the cap is a hard horizon and a guest appearance past the first 50 albums of an
    /// unordered listing can never be found. But that makes a *full* traversal take as many turns
    /// as the catalogue is long, which is the reason `windowFrom` exists: see `guestCutoffDay`.
    struct GuestCrawl: Codable, Equatable {
        /// Offset the next turn resumes from. Zero once a traversal has wrapped.
        var offset: Int = 0
        /// When the traversal currently in progress began.
        var startedAt: Date
        /// Start of the *previous* completed traversal — the earliest moment any position in this
        /// catalogue could last have been looked at. `nil` until the first traversal completes.
        var windowFrom: Date?
    }

    /// Advance an artist's crawl after a turn.
    ///
    /// Wrapping is the interesting case: reaching the end means every position has now been
    /// examined at some point since the traversal began, so the *next* traversal only has to
    /// admit releases dated after that — which is what rolling `windowFrom` forward to the
    /// finished traversal's start records.
    static func advancedGuestCrawl(_ current: GuestCrawl?,
                                   now: Date,
                                   pagesFetched: Int,
                                   reachedEndOfList: Bool) -> GuestCrawl {
        let startedAt = current?.startedAt ?? now
        guard reachedEndOfList else {
            return GuestCrawl(offset: max(0, current?.offset ?? 0) + pagesFetched * albumPageSize,
                              startedAt: startedAt,
                              windowFrom: current?.windowFrom)
        }
        return GuestCrawl(offset: 0, startedAt: now, windowFrom: startedAt)
    }

    /// The cutoff for guest releases, which has to reach back further than the look-back window.
    ///
    /// A guest appearance can land anywhere in an unordered listing, so it isn't seen until the
    /// crawl next reaches its position — up to a full traversal later, which for a prolific artist
    /// is weeks. Judged against the ordinary look-back it would be too old on arrival, get
    /// rejected, and then be cached as seen: found late and thrown away, permanently. So the
    /// window for this artist reaches back to the start of the last completed traversal, which is
    /// the furthest back any of these positions could have gone unlooked-at.
    ///
    /// The same property is what makes a per-artist boundary right after a long absence: it's
    /// anchored to when this artist's catalogue was actually last examined, not to a global
    /// last-scan stamp that a seventh of artists were never covered by.
    ///
    /// It only ever *widens*: never narrower than the ordinary cutoff, and never past the
    /// watermark, so this can't reach back before the day the radar was switched on.
    static func guestCutoffDay(normalCutoff: String, crawl: GuestCrawl?, watermark: Date) -> String {
        // No completed traversal yet — nothing in this catalogue has been ruled out, so the only
        // floor is the watermark.
        let floor = dayString(max(crawl?.windowFrom ?? .distantPast, watermark))
        return min(floor, normalCutoff)     // ISO dates: the lexicographic min is the earlier day
    }

    // MARK: - Scheduling

    /// True when a daily scan is due.
    ///
    /// A `lastScanAt` in the future means the clock moved backwards (timezone change, NTP
    /// correction). Treat that as due rather than blocking scans until real time catches up.
    static func isScanDue(lastScanAt: Date?, now: Date, interval: TimeInterval = scanInterval) -> Bool {
        guard let last = lastScanAt else { return true }
        if last > now { return true }
        return now.timeIntervalSince(last) >= interval
    }

    // MARK: - Labels

    static func progressLabel(artistsDone: Int, artistsTotal: Int, found: Int) -> String {
        "Scanning \(artistsDone) of \(artistsTotal) artists — \(found) new track\(found == 1 ? "" : "s")"
    }

    static func summaryLabel(added: Int, artists: Int) -> String {
        added == 0
            ? "No new releases found."
            : "Added \(added) track\(added == 1 ? "" : "s") from \(artists) artist\(artists == 1 ? "" : "s")."
    }

    /// What to report when a scan stops early — a 429 partway through leaves the playlist
    /// partly filled, and the resume cursor means the next attempt continues rather than
    /// restarting, so the message should say that.
    static func interruptedLabel(added: Int, artistsDone: Int, artistsTotal: Int, reason: String) -> String {
        "Paused after \(artistsDone) of \(artistsTotal) artists (\(added) added): \(reason) Will resume."
    }

    /// What to report when the user switches the radar off mid-sweep. No reason given and no
    /// promise to resume: they know why it stopped, and whether it ever continues is up to them.
    static func stoppedLabel(added: Int, artistsDone: Int, artistsTotal: Int) -> String {
        "Stopped after \(artistsDone) of \(artistsTotal) artists (\(added) added)."
    }
}
