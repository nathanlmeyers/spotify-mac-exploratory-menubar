package com.nathanlmeyers.spotifycurator.model

/**
 * Port of the macOS `Models.swift`.
 *
 * One deliberate difference: every duration/position here is in **milliseconds**, not seconds.
 * Android's `MediaMetadata` and `PlaybackState` are millisecond-native, and Discovery mode's
 * end-of-track hold wants integer millis rather than accumulated `Double` seconds.
 */

/** Classification of the currently-playing item, derived from its Spotify URI. */
enum class TrackKind {
    TRACK,      // spotify:track:...   — addable/removable
    EPISODE,    // spotify:episode:... — podcast (music-only v1: not curatable)
    LOCAL_FILE, // spotify:local:...   — Web API cannot add these
    AD,         // ad break (free tier)
    UNKNOWN;

    /** Only real tracks can be added to / removed from playlists in v1. */
    val isCuratable: Boolean get() = this == TRACK
}

/**
 * A snapshot of what Spotify is playing right now, read locally from its MediaSession.
 *
 * [uri] can be empty: unlike the Mac's ScriptingBridge, Android's `MediaMetadata` is not
 * guaranteed to carry the Spotify URI. When it is empty, the URI has to be resolved from
 * `GET /me/player` before anything can be added or removed — never guess from the title.
 */
data class NowPlaying(
    val uri: String,
    val name: String,
    val artist: String,
    val album: String,
    val artworkUri: String?,
    val durationMs: Long,
    val positionMs: Long,
    val isPlaying: Boolean,
    /**
     * Spotify is buffering or connecting: not playing, but not a user pause either.
     *
     * Discovery has to tell the two apart. `!isPlaying` alone reads a mid-track stall as "the
     * user pressed pause", which disarms the hold for the rest of the song, and reads a stall
     * that runs straight into the next track as "they skipped it", which loses the review.
     */
    val isStalled: Boolean = false,
) {
    val kind: TrackKind get() = classify(uri)

    /** Playing, or trying to: everything that isn't a deliberate stop. */
    val isAdvancing: Boolean get() = isPlaying || isStalled

    /** Milliseconds until the track's natural end, floored at zero. */
    val remainingMs: Long get() = (durationMs - positionMs).coerceAtLeast(0)

    /**
     * Identity for "is this still the same track?" when [uri] is empty.
     *
     * Only ever used to detect a *change*; never to decide what to add or remove.
     */
    val identity: String get() = if (uri.isNotEmpty()) uri else "$name $artist $durationMs"

    companion object {
        fun classify(uri: String): TrackKind = when {
            uri.startsWith("spotify:track:") -> TrackKind.TRACK
            uri.startsWith("spotify:episode:") -> TrackKind.EPISODE
            uri.startsWith("spotify:local:") -> TrackKind.LOCAL_FILE
            uri.startsWith("spotify:ad:") || uri.isEmpty() -> TrackKind.AD
            else -> TrackKind.UNKNOWN
        }
    }
}

/**
 * The Spotify Connect device playback is currently routed to.
 * [type] is Spotify's string ("Computer", "Smartphone", "Speaker", "TV", ...).
 */
data class PlaybackDevice(
    val id: String? = null,
    val name: String? = null,
    val type: String? = null,
    val isActive: Boolean = false,
)

/** A Spotify playlist (subset of fields we need). */
data class Playlist(
    val id: String,     // playlist id (not the URI)
    val name: String,
    val uri: String,    // spotify:playlist:<id>
    val ownerId: String,
    val collaborative: Boolean,
) {
    /** Editable == we own it, or it's collaborative. */
    fun isEditable(userId: String?): Boolean {
        if (userId == null) return false
        return collaborative || ownerId == userId
    }
}

/**
 * The playback "context" — what the current track is playing *from*.
 *
 * [playlistId] is null when playing an album/artist/liked-songs/queue (not a playlist).
 * [trackUri] is the track this context was resolved for: a removal must only act when it
 * still matches the track being curated, otherwise a stale source could delete the wrong
 * track from the wrong playlist.
 */
data class SourceContext(
    val playlistId: String? = null,
    val playlistName: String? = null,
    val isEditablePlaylist: Boolean = false,
    val trackUri: String? = null,
) {
    companion object {
        val NONE = SourceContext()
    }
}

/** What `GET /me/player` reports, before it is resolved into a [SourceContext]. */
data class CurrentlyPlaying(
    val contextUri: String? = null,
    val contextType: String? = null,
    val artistNames: List<String> = emptyList(),
    val trackUri: String? = null,
    val device: PlaybackDevice? = null,
)
