import Foundation

/// Which auto-skip rule matched (if any).
enum AutoSkipKind: Equatable { case inTarget, reviewed }

/// Pure, side-effect-free discovery decisions — unit-tested in isolation
/// (compiled directly into the test target).
enum DiscoveryLogic {
    /// First-match-wins auto-skip decision for a candidate track.
    static func autoSkipKind(inTarget: Bool,
                             reviewed: Bool,
                             skipIfInTarget: Bool,
                             skipAlreadyReviewed: Bool) -> AutoSkipKind? {
        if skipIfInTarget && inTarget { return .inTarget }
        if skipAlreadyReviewed && reviewed { return .reviewed }
        return nil
    }

    /// Loop-protection stop test, evaluated BEFORE recording the skip.
    /// Exhausted when this URI was already auto-skipped in the current sweep
    /// (we've cycled with nothing new), or recording it would hit the ceiling.
    static func isExhausted(uri: String,
                            visited: Set<String>,
                            consecutiveSoFar: Int,
                            ceiling: Int) -> Bool {
        if visited.contains(uri) { return true }
        if consecutiveSoFar + 1 >= ceiling { return true }
        return false
    }

    /// True when a watched track advanced "naturally" (near its end / via crossfade) rather
    /// than by a deliberate mid-song skip. Used to decide whether to reclaim a track that
    /// auto-advanced before we could hold it. The window is wide (covers Spotify's max
    /// crossfade) so every auto-advance qualifies; a far-from-end advance is a user skip.
    /// Sub-`minHoldableDuration` interstitials are never reclaimed.
    static func isNaturalAdvance(prevRemaining: Double,
                                 prevDuration: Double,
                                 crossfadeWindow: Double,
                                 minHoldableDuration: Double) -> Bool {
        guard prevDuration > minHoldableDuration else { return false }
        return prevRemaining <= crossfadeWindow
    }

    /// True when the playback source IS the playlist we curate into. Discovery must not
    /// run here: every track is trivially "already in target", so auto-skip-and-remove
    /// would walk the playlist deleting it. Nil ids never match.
    static func sourceIsTarget(sourcePlaylistId: String?, targetPlaylistId: String?) -> Bool {
        guard let s = sourcePlaylistId, let t = targetPlaylistId else { return false }
        return s == t
    }

    /// Whether it's safe to remove `actedURI` from the source playlist.
    /// - A move (auto-skip / move-on-add) must never delete from the target itself.
    /// - Any removal must act on the source that was resolved for THIS exact track,
    ///   otherwise a stale source could delete the wrong track from the wrong playlist.
    static func mayRemoveFromSource(sourcePlaylistId: String?,
                                    targetPlaylistId: String?,
                                    sourceTrackURI: String?,
                                    actedURI: String,
                                    isMove: Bool) -> Bool {
        guard let src = sourcePlaylistId else { return false }
        if isMove, src == targetPlaylistId { return false }     // never move-delete from target
        return sourceTrackURI == actedURI                       // source must match the track
    }
}
