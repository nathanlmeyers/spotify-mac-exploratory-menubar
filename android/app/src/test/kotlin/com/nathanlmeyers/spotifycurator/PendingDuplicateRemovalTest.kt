package com.nathanlmeyers.spotifycurator

import com.nathanlmeyers.spotifycurator.curation.PendingDuplicateRemoval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The notification's second-press confirmation. This is the one place in the app where a button
 * press means "delete several rows", so every bound on it is tested: wrong track, wrong playlist,
 * or too long ago must all fall through to a fresh count instead of deleting.
 */
class PendingDuplicateRemovalTest {

    private val armedAt = 1_000_000L

    private fun pending(uri: String = "spotify:track:abc", playlistId: String = "pl1") =
        PendingDuplicateRemoval(
            uri = uri,
            trackName = "Song",
            playlistId = playlistId,
            playlistName = "Road Trip",
            count = 4,
            armedAtMs = armedAt,
        )

    @Test
    fun `a prompt press on the same track and playlist confirms`() {
        assertTrue(pending().isConfirmedBy("spotify:track:abc", "pl1", armedAt + 1_000))
    }

    @Test
    fun `an immediate second press confirms`() {
        assertTrue(pending().isConfirmedBy("spotify:track:abc", "pl1", armedAt))
    }

    /** The press that armed it is one track; by the time it's answered it must still be that one. */
    @Test
    fun `a different track does not confirm`() {
        assertFalse(pending().isConfirmedBy("spotify:track:other", "pl1", armedAt + 1_000))
    }

    /** Same song, different playlist — the count was taken against one of them, not both. */
    @Test
    fun `a different playlist does not confirm`() {
        assertFalse(pending().isConfirmedBy("spotify:track:abc", "pl2", armedAt + 1_000))
    }

    @Test
    fun `the last millisecond of the window still confirms`() {
        assertTrue(
            pending().isConfirmedBy("spotify:track:abc", "pl1", armedAt + PendingDuplicateRemoval.WINDOW_MS),
        )
    }

    /** A phone back in a pocket must not stay armed. */
    @Test
    fun `one millisecond past the window does not confirm`() {
        assertFalse(
            pending().isConfirmedBy(
                "spotify:track:abc",
                "pl1",
                armedAt + PendingDuplicateRemoval.WINDOW_MS + 1,
            ),
        )
    }

    /**
     * `System.currentTimeMillis()` is wall clock, so it can step backwards (NTP, a timezone-less
     * clock correction). A negative age must read as "not confirmed" rather than sneaking under
     * the `<= WINDOW_MS` test.
     */
    @Test
    fun `a clock that stepped backwards does not confirm`() {
        assertFalse(pending().isConfirmedBy("spotify:track:abc", "pl1", armedAt - 5_000))
    }

    @Test
    fun `the prompt names the track, the playlist and the count`() {
        assertEquals(
            "“Song” is in Road Trip 4 times — press Remove again to delete all 4.",
            pending().prompt(),
        )
    }

    /** The name comes from the live snapshot, which a held or just-changed track may not match. */
    @Test
    fun `the prompt still reads without a track name`() {
        val unnamed = pending().copy(trackName = null)
        assertEquals(
            "This track is in Road Trip 4 times — press Remove again to delete all 4.",
            unnamed.prompt(),
        )
    }
}
