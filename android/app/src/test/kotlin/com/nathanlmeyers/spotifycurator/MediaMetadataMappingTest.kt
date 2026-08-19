package com.nathanlmeyers.spotifycurator

import com.nathanlmeyers.spotifycurator.media.MediaMetadataMapping
import com.nathanlmeyers.spotifycurator.model.NowPlaying
import com.nathanlmeyers.spotifycurator.model.TrackKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Android counterpart of the macOS `LocalSpotifyMappingTests`.
 *
 * Position extrapolation is the piece Discovery mode's end-of-track hold rests on, and every
 * one of these failure modes produces a hold that fires at the wrong moment rather than an
 * obvious crash — so they're pinned here rather than discovered on the phone.
 */
class MediaMetadataMappingTest {

    // MARK: extrapolatePositionMs

    @Test
    fun `advances by elapsed time while playing`() {
        assertEquals(
            31_000L,
            MediaMetadataMapping.extrapolatePositionMs(
                basePositionMs = 30_000, lastUpdateTimeMs = 1_000, speed = 1f,
                isPlaying = true, nowElapsedRealtimeMs = 2_000, durationMs = 200_000,
            )
        )
    }

    @Test
    fun `respects playback speed`() {
        assertEquals(
            32_000L,
            MediaMetadataMapping.extrapolatePositionMs(
                basePositionMs = 30_000, lastUpdateTimeMs = 1_000, speed = 2f,
                isPlaying = true, nowElapsedRealtimeMs = 2_000, durationMs = 200_000,
            )
        )
    }

    @Test
    fun `a paused position never drifts`() {
        assertEquals(
            30_000L,
            MediaMetadataMapping.extrapolatePositionMs(
                basePositionMs = 30_000, lastUpdateTimeMs = 1_000, speed = 0f,
                isPlaying = false, nowElapsedRealtimeMs = 999_999, durationMs = 200_000,
            )
        )
    }

    @Test
    fun `a zero timestamp is not treated as the epoch`() {
        // A session that never reported an update time would otherwise have the device's entire
        // uptime added to its position — placing every track permanently "past the end", so the
        // hold either fires instantly or never.
        assertEquals(
            30_000L,
            MediaMetadataMapping.extrapolatePositionMs(
                basePositionMs = 30_000, lastUpdateTimeMs = 0, speed = 1f,
                isPlaying = true, nowElapsedRealtimeMs = 5_000_000, durationMs = 200_000,
            )
        )
    }

    @Test
    fun `a sample from the future is trusted over the arithmetic`() {
        assertEquals(
            30_000L,
            MediaMetadataMapping.extrapolatePositionMs(
                basePositionMs = 30_000, lastUpdateTimeMs = 9_000, speed = 1f,
                isPlaying = true, nowElapsedRealtimeMs = 8_000, durationMs = 200_000,
            )
        )
    }

    @Test
    fun `clamps to the duration`() {
        assertEquals(
            200_000L,
            MediaMetadataMapping.extrapolatePositionMs(
                basePositionMs = 199_000, lastUpdateTimeMs = 1_000, speed = 1f,
                isPlaying = true, nowElapsedRealtimeMs = 60_000, durationMs = 200_000,
            )
        )
    }

    @Test
    fun `an unknown duration disables the ceiling but not the floor`() {
        assertEquals(
            61_000L,
            MediaMetadataMapping.extrapolatePositionMs(
                basePositionMs = 1_000, lastUpdateTimeMs = 1_000, speed = 1f,
                isPlaying = true, nowElapsedRealtimeMs = 61_000, durationMs = 0,
            )
        )
        assertEquals(
            0L,
            MediaMetadataMapping.extrapolatePositionMs(
                basePositionMs = -5, lastUpdateTimeMs = 0, speed = 0f,
                isPlaying = false, nowElapsedRealtimeMs = 0, durationMs = 0,
            )
        )
    }

    // MARK: normalizeDurationMs

    @Test
    fun `unknown durations normalize to zero`() {
        // Sessions report -1 for live streams and briefly at track start; callers read 0 as
        // "no known end", which disables the hold rather than firing it early.
        assertEquals(0L, MediaMetadataMapping.normalizeDurationMs(-1))
        assertEquals(0L, MediaMetadataMapping.normalizeDurationMs(0))
        assertEquals(200_000L, MediaMetadataMapping.normalizeDurationMs(200_000))
    }

    // MARK: spotifyUriFrom

    @Test
    fun `passes through an explicit Spotify URI`() {
        assertEquals(
            "spotify:track:6rqhFgbbKwnb9MLmUQDhG6",
            MediaMetadataMapping.spotifyUriFrom("spotify:track:6rqhFgbbKwnb9MLmUQDhG6"),
        )
    }

    @Test
    fun `converts a typed open_spotify_com URL`() {
        assertEquals(
            "spotify:track:6rqhFgbbKwnb9MLmUQDhG6",
            MediaMetadataMapping.spotifyUriFrom("https://open.spotify.com/track/6rqhFgbbKwnb9MLmUQDhG6?si=x"),
        )
        assertEquals(
            "spotify:episode:abc123",
            MediaMetadataMapping.spotifyUriFrom("https://open.spotify.com/intl-de/episode/abc123"),
        )
    }

    @Test
    fun `refuses to guess the type of a bare id`() {
        // A bare base-62 id could be a track, an episode, or a local file. Guessing wrong means
        // adding or deleting the wrong thing, so an untyped id defers to GET /me/player instead.
        assertEquals("", MediaMetadataMapping.spotifyUriFrom("6rqhFgbbKwnb9MLmUQDhG6"))
        assertEquals("", MediaMetadataMapping.spotifyUriFrom(null))
        assertEquals("", MediaMetadataMapping.spotifyUriFrom("   "))
    }

    // MARK: playlistIdFromContextUri — decides which playlist a Remove deletes from

    @Test
    fun `extracts the id from a playlist context`() {
        assertEquals(
            "2OsDQntXER7vmPoRH9RvpU",
            MediaMetadataMapping.playlistIdFromContextUri("spotify:playlist:2OsDQntXER7vmPoRH9RvpU"),
        )
        assertEquals(
            "2OsDQntXER7vmPoRH9RvpU",
            MediaMetadataMapping.playlistIdFromContextUri("  spotify:playlist:2OsDQntXER7vmPoRH9RvpU  "),
        )
    }

    @Test
    fun `rejects every non-playlist context`() {
        // An album/artist/Liked-Songs context has nothing removable. Treating one as a playlist id
        // would aim a DELETE at a playlist that doesn't exist — or, worse, one that does.
        assertNull(MediaMetadataMapping.playlistIdFromContextUri("spotify:album:abc"))
        assertNull(MediaMetadataMapping.playlistIdFromContextUri("spotify:artist:abc"))
        assertNull(MediaMetadataMapping.playlistIdFromContextUri("spotify:collection:tracks"))
        assertNull(MediaMetadataMapping.playlistIdFromContextUri("spotify:show:abc"))
        assertNull(MediaMetadataMapping.playlistIdFromContextUri("spotify:track:abc"))
    }

    @Test
    fun `rejects malformed or empty playlist contexts`() {
        assertNull(MediaMetadataMapping.playlistIdFromContextUri(null))
        assertNull(MediaMetadataMapping.playlistIdFromContextUri(""))
        assertNull(MediaMetadataMapping.playlistIdFromContextUri("spotify:playlist:"))
        // The legacy `spotify:user:<name>:playlist:<id>` form doesn't put the id where this
        // parser looks, so it must not be read as one.
        assertNull(MediaMetadataMapping.playlistIdFromContextUri("spotify:user:nate:playlist:abc"))
        assertNull(MediaMetadataMapping.playlistIdFromContextUri("playlist:abc"))
    }

    // MARK: NowPlaying.classify

    @Test
    fun `only real tracks are curatable`() {
        assertEquals(TrackKind.TRACK, NowPlaying.classify("spotify:track:x"))
        assertEquals(TrackKind.EPISODE, NowPlaying.classify("spotify:episode:x"))
        assertEquals(TrackKind.LOCAL_FILE, NowPlaying.classify("spotify:local:x"))
        assertEquals(TrackKind.AD, NowPlaying.classify("spotify:ad:x"))
        assertEquals(TrackKind.AD, NowPlaying.classify(""))
        assertEquals(TrackKind.UNKNOWN, NowPlaying.classify("spotify:show:x"))

        assertTrue(TrackKind.TRACK.isCuratable)
        assertFalse(TrackKind.EPISODE.isCuratable)
        assertFalse(TrackKind.LOCAL_FILE.isCuratable)
        assertFalse(TrackKind.AD.isCuratable)
        assertFalse(TrackKind.UNKNOWN.isCuratable)
    }

    @Test
    fun `identity falls back to title and artist when there is no URI`() {
        val withUri = nowPlaying(uri = "spotify:track:x")
        assertEquals("spotify:track:x", withUri.identity)

        val without = nowPlaying(uri = "")
        assertEquals("Song Artist 200000", without.identity)
    }

    @Test
    fun `remaining is floored at zero`() {
        assertEquals(0L, nowPlaying(positionMs = 250_000).remainingMs)
        assertEquals(50_000L, nowPlaying(positionMs = 150_000).remainingMs)
    }

    @Test
    fun `a stall counts as advancing but a pause does not`() {
        // The distinction discovery rests on: a BUFFERING/CONNECTING blip mid-track must not
        // disarm the hold the way a deliberate pause does, and a stall that runs straight into
        // the next track is still a runoff worth reclaiming — not a user skip.
        assertTrue(nowPlaying(isPlaying = true).isAdvancing)
        assertTrue(nowPlaying(isPlaying = false, isStalled = true).isAdvancing)
        assertFalse(nowPlaying(isPlaying = false).isAdvancing)
    }

    private fun nowPlaying(
        uri: String = "spotify:track:x",
        positionMs: Long = 0,
        isPlaying: Boolean = true,
        isStalled: Boolean = false,
    ) = NowPlaying(
        uri = uri,
        name = "Song",
        artist = "Artist",
        album = "Album",
        artworkUri = null,
        durationMs = 200_000,
        positionMs = positionMs,
        isPlaying = isPlaying,
        isStalled = isStalled,
    )
}
