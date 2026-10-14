import Foundation

/// Pure, side-effect-free rules for the curation buttons — unit-tested in isolation
/// (compiled directly into the test target), in the same spirit as `DiscoveryLogic`.
enum CurationLogic {
    /// Whether the Add button should show its "already there" face — a green checkmark, disabled —
    /// for `trackURI`.
    ///
    /// Deliberately false whenever the answer is *unknown*: no URI, a non-song, no target set, or a
    /// membership set that was loaded for a different playlist than the one Add would write to. The
    /// checked button is disabled, so a false positive strands a song with no way to add it. A false
    /// negative costs at most one redundant press, which `performAdd` already absorbs by reporting
    /// "Already in <target>" instead of writing a duplicate.
    ///
    /// - Parameters:
    ///   - membershipTargetId: the playlist `membership` was loaded for. Compared against
    ///     `currentTargetId` because the two genuinely diverge — switching target and having the
    ///     fetch fail leaves the previous playlist's contents in memory, and answering from those
    ///     would grey out Add for songs that are not in the new target at all.
    static func showsInTarget(trackURI: String?,
                              membershipTargetId: String?,
                              currentTargetId: String?,
                              membership: Set<String>) -> Bool {
        guard let uri = trackURI, !uri.isEmpty else { return false }
        // A `spotify:episode:` URI can be in the set — `playlistTrackURIs` stores whatever the
        // playlist holds — but Add can't act on one, so it must never wear the added face.
        guard NowPlaying.classify(uri).isCuratable else { return false }
        guard let target = currentTargetId, membershipTargetId == target else { return false }
        return membership.contains(uri)
    }

    // MARK: Remove — which playlists one press deletes from

    /// Which playlists a Remove press on `uri` deletes from, in order. Empty means there is
    /// nothing to remove from, and the button is disabled.
    ///
    /// Two legs, each with its own freshness proof, because a stale context is how the wrong
    /// song gets deleted from the wrong playlist:
    /// - **Source**: the playlist the song is playing from, when it's editable and `source` was
    ///   resolved for this exact track (`trackURI == uri`, the same test `mayRemoveFromSource`
    ///   makes).
    /// - **Discovery playlist**: when one is set, it isn't the source itself, the membership set
    ///   was loaded for it, it contains the song, and the lookup finished for this track
    ///   (`resolvedForURI == uri` — true for album/artist/Liked playback too, where `trackURI`
    ///   is nil). The held panel passes a frozen context, so the proof has to live here rather
    ///   than in the button's enabled state.
    ///
    /// This is the single decision behind the enabled state, the tooltip, the normal press and
    /// the held press, so none of them can disagree about what a press will do.
    static func removalTargets(uri: String,
                               source: SourceContext,
                               discoveryPlaylistId: String?,
                               discoveryPlaylistName: String?,
                               membershipLoadedFor: String?,
                               membership: Set<String>) -> [RemovalTarget] {
        guard !uri.isEmpty, NowPlaying.classify(uri).isCuratable else { return [] }
        var targets: [RemovalTarget] = []
        if source.isEditablePlaylist, let src = source.playlistId, source.trackURI == uri {
            targets.append(RemovalTarget(playlistId: src, playlistName: source.playlistName ?? "playlist"))
        }
        if let discovery = discoveryPlaylistId,
           discovery != source.playlistId,
           membershipLoadedFor == discovery,
           membership.contains(uri),
           source.resolvedForURI == uri {
            targets.append(RemovalTarget(playlistId: discovery,
                                         playlistName: discoveryPlaylistName ?? "discovery playlist"))
        }
        return targets
    }

    /// Tooltip for an enabled Remove button: "Remove from A" / "Remove from A and B".
    static func removeHelp(targets: [RemovalTarget]) -> String {
        "Remove from " + joined(targets.map(\.playlistName))
    }

    /// Status line after a press. `failed` pairs each playlist that refused with its error.
    static func removedStatus(succeeded: [String], failed: [(playlistName: String, error: String)]) -> String {
        let failures = failed.map { "couldn't remove from \($0.playlistName): \($0.error)" }
        if succeeded.isEmpty { return "Remove failed: " + failures.joined(separator: "; ") }
        var status = "Removed from " + joined(succeeded)
        if !failures.isEmpty { status += ", but " + failures.joined(separator: "; ") }
        return status
    }

    private static func joined(_ names: [String]) -> String {
        switch names.count {
        case 0: return "playlist"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
