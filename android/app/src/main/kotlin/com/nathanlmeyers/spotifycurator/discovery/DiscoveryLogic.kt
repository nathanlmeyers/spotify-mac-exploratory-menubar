package com.nathanlmeyers.spotifycurator.discovery

import java.text.Normalizer
import java.util.Locale

/** Which auto-skip rule matched (if any). */
enum class AutoSkipKind { IN_TARGET, REVIEWED }

/**
 * Pure, side-effect-free discovery decisions — unit-tested in isolation.
 * Port of the macOS `DiscoveryLogic.swift`, with durations in milliseconds.
 */
object DiscoveryLogic {

    /**
     * First-match-wins auto-skip decision for a candidate track.
     *
     * [sourceConfirmed] gates the whole decision: the playback source context is resolved
     * asynchronously and lags the now-playing track. Acting on a stale context auto-skips the
     * wrong tracks — e.g. starting the target playlist while the source still reads as the
     * previous playlist skips reviewed/in-target songs. Wait for the context to confirm before
     * skipping. Mirrors [mayRemoveFromSource]'s freshness check.
     */
    fun autoSkipKind(
        sourceConfirmed: Boolean,
        inTarget: Boolean,
        reviewed: Boolean,
        skipIfInTarget: Boolean,
        skipAlreadyReviewed: Boolean,
    ): AutoSkipKind? {
        if (!sourceConfirmed) return null
        if (skipIfInTarget && inTarget) return AutoSkipKind.IN_TARGET
        if (skipAlreadyReviewed && reviewed) return AutoSkipKind.REVIEWED
        return null
    }

    /**
     * Loop-protection stop test, evaluated BEFORE recording the skip.
     *
     * Exhausted when this URI was already auto-skipped in the current sweep (we've cycled with
     * nothing new), or recording it would hit the ceiling.
     */
    fun isExhausted(uri: String, visited: Set<String>, consecutiveSoFar: Int, ceiling: Int): Boolean {
        if (visited.contains(uri)) return true
        if (consecutiveSoFar + 1 >= ceiling) return true
        return false
    }

    /**
     * True when a watched track advanced "naturally" (near its end / via crossfade) rather than
     * by a deliberate mid-song skip. Used to decide whether to reclaim a track that auto-advanced
     * before we could hold it. The window is wide (covers Spotify's max crossfade) so every
     * auto-advance qualifies; a far-from-end advance is a user skip. Sub-[minHoldableDurationMs]
     * interstitials are never reclaimed.
     */
    fun isNaturalAdvance(
        prevRemainingMs: Long,
        prevDurationMs: Long,
        crossfadeWindowMs: Long,
        minHoldableDurationMs: Long,
    ): Boolean {
        if (prevDurationMs <= minHoldableDurationMs) return false
        return prevRemainingMs <= crossfadeWindowMs
    }

    /**
     * The one classifier for "the track under watch/review left us — runoff or deliberate?"
     *
     * True (reclaim) only when the last observation showed the expected track itself still
     * playing near its end — a runoff (a pause that didn't take, a re-listen that reached the
     * end, or an auto-advance we didn't pre-empt). A parked-paused track that changed (the user
     * deliberately picked something else in the Spotify app) or a far-from-end change is
     * released instead — reclaiming there would fight the user.
     */
    fun shouldReclaimDeparture(
        prevUri: String?,
        prevWasPlaying: Boolean,
        prevRemainingMs: Long,
        prevDurationMs: Long,
        expectedUri: String,
        crossfadeWindowMs: Long,
        minHoldableDurationMs: Long,
    ): Boolean {
        if (prevUri != expectedUri || !prevWasPlaying) return false
        return isNaturalAdvance(prevRemainingMs, prevDurationMs, crossfadeWindowMs, minHoldableDurationMs)
    }

    /**
     * True when the playback source IS the playlist we curate into. Discovery must not run here:
     * every track is trivially "already in target", so auto-skip-and-remove would walk the
     * playlist deleting it. Null ids never match.
     */
    fun sourceIsTarget(sourcePlaylistId: String?, targetPlaylistId: String?): Boolean {
        if (sourcePlaylistId == null || targetPlaylistId == null) return false
        return sourcePlaylistId == targetPlaylistId
    }

    /**
     * Normalize a Spotify Connect device name for comparison against this phone's name.
     *
     * Spotify's reported device name and the name Android knows routinely differ in ways a
     * byte-exact compare misses: a curly apostrophe (U+2019) vs ASCII `'`, case, accents, and a
     * ` (2)`/` (3)` duplicate-collision suffix. Fold all of these so "this phone" is recognised
     * reliably — a false negative silently kills discovery.
     */
    fun normalizedDeviceName(s: String): String {
        var t = s.replace('’', '\'').replace('‘', '\'')
        // NFKD then strip combining marks == Swift's diacriticInsensitive + widthInsensitive.
        t = Normalizer.normalize(t, Normalizer.Form.NFKD).replace(COMBINING_MARKS, "")
        t = t.lowercase(Locale.ROOT)
        t = t.replace(DUPLICATE_SUFFIX, "")
        return t.trim()
    }

    /**
     * Whether it's safe to remove [actedUri] from the source playlist.
     *
     * - A move (auto-skip / move-on-add) must never delete from the target itself.
     * - Any removal must act on the source that was resolved for THIS exact track, otherwise a
     *   stale source could delete the wrong track from the wrong playlist.
     */
    fun mayRemoveFromSource(
        sourcePlaylistId: String?,
        targetPlaylistId: String?,
        sourceTrackUri: String?,
        actedUri: String,
        isMove: Boolean,
    ): Boolean {
        if (sourcePlaylistId == null) return false
        if (isMove && sourcePlaylistId == targetPlaylistId) return false // never move-delete from target
        return sourceTrackUri == actedUri // source must match the track
    }

    private val COMBINING_MARKS = Regex("\\p{Mn}+")
    private val DUPLICATE_SUFFIX = Regex(" \\(\\d+\\)$")
}
