package com.nathanlmeyers.spotifycurator.curation

import com.nathanlmeyers.spotifycurator.model.NowPlaying

/**
 * Pure, side-effect-free rules for the curation buttons. Kotlin mirror of the macOS
 * `CurationLogic.swift`, in the same spirit as [com.nathanlmeyers.spotifycurator.discovery.DiscoveryLogic].
 */
object CurationLogic {

    /**
     * Whether the Add button should show its "already there" face — a green checkmark, disabled —
     * for [trackUri].
     *
     * Deliberately false whenever the answer is *unknown*: no URI, a non-song, no target set, or a
     * membership set that was loaded for a different playlist than the one Add would write to. The
     * checked button is disabled, so a false positive strands a song with no way to add it. A false
     * negative costs at most one redundant press, which `performAdd` already absorbs by reporting
     * "Already in <target>" instead of writing a duplicate.
     *
     * [membershipTargetId] is the playlist [membership] was loaded for. It is compared against
     * [currentTargetId] because the two genuinely diverge — switching target and having the fetch
     * fail leaves the previous playlist's contents in memory, and answering from those would grey
     * out Add for songs that are not in the new target at all.
     */
    fun showsInTarget(
        trackUri: String?,
        membershipTargetId: String?,
        currentTargetId: String?,
        membership: Set<String>,
    ): Boolean {
        if (trackUri.isNullOrEmpty()) return false
        // A `spotify:episode:` URI can be in the set — `playlistTrackUris` stores whatever the
        // playlist holds — but Add can't act on one, so it must never wear the added face.
        if (!NowPlaying.classify(trackUri).isCuratable) return false
        if (currentTargetId == null || membershipTargetId != currentTargetId) return false
        return membership.contains(trackUri)
    }
}
