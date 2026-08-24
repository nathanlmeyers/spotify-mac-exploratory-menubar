package com.nathanlmeyers.spotifycurator

import com.nathanlmeyers.spotifycurator.curation.CurationLogic
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Port of the macOS `CurationLogicTests.swift`.
 *
 * The rule behind the Add button's checkmark. It is disabled when checked, so a false positive
 * here is a song the user cannot add at all — every "unknown" case below must answer false.
 */
class CurationLogicTest {

    private val song = "spotify:track:abc"
    private val target = "playlist1"

    private fun shows(
        uri: String?,
        loadedFor: String? = "playlist1",
        current: String? = "playlist1",
        membership: Set<String>,
    ) = CurationLogic.showsInTarget(
        trackUri = uri,
        membershipTargetId = loadedFor,
        currentTargetId = current,
        membership = membership,
    )

    @Test
    fun `a track in the current target shows as added`() {
        assertTrue(shows(uri = song, membership = setOf(song)))
    }

    @Test
    fun `a track that is not in the target is not added`() {
        assertFalse(shows(uri = song, membership = setOf("spotify:track:other")))
    }

    /**
     * Cold start, a rate-limited fetch, or an offline launch all land here. Unknown reads as
     * "not added" so the button stays pressable.
     */
    @Test
    fun `unloaded membership is not added`() {
        assertFalse(shows(uri = song, membership = emptySet()))
    }

    @Test
    fun `null and empty URIs are not added`() {
        assertFalse(shows(uri = null, membership = setOf(song)))
        assertFalse(shows(uri = "", membership = setOf(song, "")))
    }

    /**
     * `playlistTrackUris` stores whatever the playlist holds, episodes included — but Add refuses
     * non-songs, so one must never wear the checkmark.
     */
    @Test
    fun `non-curatable URIs are not added even when present`() {
        for (uri in listOf("spotify:episode:abc", "spotify:local:abc", "spotify:ad:abc", "nonsense")) {
            assertFalse(uri, shows(uri = uri, membership = setOf(uri)))
        }
    }

    /**
     * The set belongs to the playlist we just switched away from. Answering from it would grey out
     * Add for songs that are not in the new target at all.
     */
    @Test
    fun `membership loaded for a different target is not added`() {
        assertFalse(shows(uri = song, loadedFor = "playlist2", current = target, membership = setOf(song)))
    }

    /** Both null would compare equal; a target has to actually exist before Add can be "done". */
    @Test
    fun `no target set is not added`() {
        assertFalse(shows(uri = song, loadedFor = null, current = null, membership = setOf(song)))
        assertFalse(shows(uri = song, loadedFor = target, current = null, membership = setOf(song)))
    }
}
