package com.nathanlmeyers.spotifycurator.media

/**
 * Pure mapping helpers for turning Spotify's MediaSession data into [com.nathanlmeyers.spotifycurator.model.NowPlaying].
 *
 * Deliberately free of any `android.media.*` types — the macOS app keeps `LocalSpotifyMapping`
 * free of ScriptingBridge for exactly this reason: the mapping is where the subtle bugs live,
 * so it has to be unit-testable without a device.
 */
object MediaMetadataMapping {

    /**
     * Current playback position, extrapolated from the last reported position.
     *
     * Android reports position as a *sample*: a value plus the `elapsedRealtime()` at which it
     * was measured, plus a speed. That makes exact position computable at any instant without
     * polling, which is what lets Discovery mode's end-of-track hold be precise.
     *
     * @param lastUpdateTimeMs `PlaybackState.getLastPositionUpdateTime()`, in `elapsedRealtime` units.
     * @param nowElapsedRealtimeMs `SystemClock.elapsedRealtime()` at the moment of the query.
     * @param durationMs clamp ceiling; pass 0 when unknown to skip clamping.
     */
    fun extrapolatePositionMs(
        basePositionMs: Long,
        lastUpdateTimeMs: Long,
        speed: Float,
        isPlaying: Boolean,
        nowElapsedRealtimeMs: Long,
        durationMs: Long,
    ): Long {
        val base = basePositionMs.coerceAtLeast(0)
        // A non-positive timestamp means the session never reported one — extrapolating from it
        // would add the entire uptime of the device to the position.
        if (!isPlaying || speed <= 0f || lastUpdateTimeMs <= 0L) return clamp(base, durationMs)
        val elapsed = nowElapsedRealtimeMs - lastUpdateTimeMs
        // A negative delta means the sample is from the future: a clock the session set after we
        // read it, or a stale read racing an update. Trust the sample, not the arithmetic.
        if (elapsed <= 0L) return clamp(base, durationMs)
        return clamp(base + (elapsed * speed).toLong(), durationMs)
    }

    private fun clamp(value: Long, durationMs: Long): Long =
        if (durationMs > 0) value.coerceIn(0, durationMs) else value.coerceAtLeast(0)

    /**
     * `METADATA_KEY_DURATION` is milliseconds by contract, but sessions report -1 (and
     * occasionally 0) for "unknown" — for live streams, ads, and briefly at track start.
     * Callers treat 0 as "no known end", which disables the hold rather than firing it early.
     */
    fun normalizeDurationMs(raw: Long): Long = if (raw <= 0L) 0L else raw

    /**
     * Best-effort Spotify URI from `METADATA_KEY_MEDIA_ID`.
     *
     * Returns `""` for anything whose *type* isn't explicit. A bare base-62 id could be a track,
     * an episode, or a local file, and acting on a wrong guess means adding or deleting the wrong
     * thing — so an unrecognised id defers to `GET /me/player` instead of guessing.
     */
    /**
     * The playlist id from Spotify's `CONTEXT_URI` metadata extra, or null if it isn't a playlist.
     *
     * Spotify publishes the playback context — the thing Remove acts on — right in its media
     * metadata, which means it can be read atomically alongside the track URI with no API call.
     *
     * Strictly playlists: an album, artist, collection ("Liked Songs") or show context has nothing
     * removable, and treating one as a playlist id would send a delete to a nonexistent playlist.
     * Anything else returns null, which greys Remove out.
     */
    fun playlistIdFromContextUri(contextUri: String?): String? {
        val uri = contextUri?.trim().orEmpty()
        if (!uri.startsWith(PLAYLIST_PREFIX)) return null
        val id = uri.removePrefix(PLAYLIST_PREFIX)
        // Ids are base-62. Reject anything with further colons (e.g. the old
        // `spotify:user:<name>:playlist:<id>` form, whose last segment isn't in this position).
        if (id.isEmpty() || !id.all { it.isLetterOrDigit() }) return null
        return id
    }

    private const val PLAYLIST_PREFIX = "spotify:playlist:"

    fun spotifyUriFrom(mediaId: String?): String {
        val id = mediaId?.trim().orEmpty()
        if (id.isEmpty()) return ""
        if (id.startsWith("spotify:")) return id
        // https://open.spotify.com/track/<id>?si=... — typed, so safe to convert.
        Regex("""^https?://open\.spotify\.com/(?:[a-z-]+/)?(track|episode)/([A-Za-z0-9]+)""")
            .find(id)?.let { m ->
                return "spotify:${m.groupValues[1]}:${m.groupValues[2]}"
            }
        return ""
    }
}
