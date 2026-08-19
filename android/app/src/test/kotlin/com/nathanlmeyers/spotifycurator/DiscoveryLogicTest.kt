package com.nathanlmeyers.spotifycurator

import com.nathanlmeyers.spotifycurator.discovery.AutoSkipKind
import com.nathanlmeyers.spotifycurator.discovery.DiscoveryLogic
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the macOS `DiscoveryLogicTests.swift`. */
class DiscoveryLogicTest {

    // MARK: autoSkipKind

    @Test
    fun `no auto-skip until the source is confirmed`() {
        // A stale source auto-skips the wrong tracks — e.g. starting the target playlist while
        // the source still reads as the previous one skips everything already reviewed.
        assertNull(
            DiscoveryLogic.autoSkipKind(
                sourceConfirmed = false, inTarget = true, reviewed = true,
                skipIfInTarget = true, skipAlreadyReviewed = true,
            )
        )
    }

    @Test
    fun `in-target wins over reviewed`() {
        assertEquals(
            AutoSkipKind.IN_TARGET,
            DiscoveryLogic.autoSkipKind(
                sourceConfirmed = true, inTarget = true, reviewed = true,
                skipIfInTarget = true, skipAlreadyReviewed = true,
            )
        )
    }

    @Test
    fun `each rule respects its own toggle`() {
        assertEquals(
            AutoSkipKind.REVIEWED,
            DiscoveryLogic.autoSkipKind(
                sourceConfirmed = true, inTarget = true, reviewed = true,
                skipIfInTarget = false, skipAlreadyReviewed = true,
            )
        )
        assertNull(
            DiscoveryLogic.autoSkipKind(
                sourceConfirmed = true, inTarget = true, reviewed = true,
                skipIfInTarget = false, skipAlreadyReviewed = false,
            )
        )
    }

    // MARK: isExhausted

    @Test
    fun `a revisited URI means the sweep has cycled`() {
        assertTrue(DiscoveryLogic.isExhausted("a", setOf("a"), consecutiveSoFar = 0, ceiling = 10))
    }

    @Test
    fun `stops one short of the ceiling`() {
        assertFalse(DiscoveryLogic.isExhausted("a", emptySet(), consecutiveSoFar = 8, ceiling = 10))
        assertTrue(DiscoveryLogic.isExhausted("a", emptySet(), consecutiveSoFar = 9, ceiling = 10))
    }

    // MARK: isNaturalAdvance

    @Test
    fun `an advance near the end is natural`() {
        assertTrue(
            DiscoveryLogic.isNaturalAdvance(
                prevRemainingMs = 500, prevDurationMs = 200_000,
                crossfadeWindowMs = 12_000, minHoldableDurationMs = 5_000,
            )
        )
    }

    @Test
    fun `an advance far from the end is a user skip`() {
        assertFalse(
            DiscoveryLogic.isNaturalAdvance(
                prevRemainingMs = 90_000, prevDurationMs = 200_000,
                crossfadeWindowMs = 12_000, minHoldableDurationMs = 5_000,
            )
        )
    }

    @Test
    fun `short interstitials are never natural advances`() {
        assertFalse(
            DiscoveryLogic.isNaturalAdvance(
                prevRemainingMs = 0, prevDurationMs = 3_000,
                crossfadeWindowMs = 12_000, minHoldableDurationMs = 5_000,
            )
        )
    }

    // MARK: shouldReclaimDeparture

    @Test
    fun `reclaims only the expected track running off its end while playing`() {
        assertTrue(
            DiscoveryLogic.shouldReclaimDeparture(
                prevUri = "spotify:track:a", prevWasPlaying = true,
                prevRemainingMs = 300, prevDurationMs = 200_000,
                expectedUri = "spotify:track:a",
                crossfadeWindowMs = 12_000, minHoldableDurationMs = 5_000,
            )
        )
    }

    @Test
    fun `does not reclaim a parked-paused track the user changed`() {
        // Reclaiming here would fight the user's deliberate choice in the Spotify app.
        assertFalse(
            DiscoveryLogic.shouldReclaimDeparture(
                prevUri = "spotify:track:a", prevWasPlaying = false,
                prevRemainingMs = 300, prevDurationMs = 200_000,
                expectedUri = "spotify:track:a",
                crossfadeWindowMs = 12_000, minHoldableDurationMs = 5_000,
            )
        )
    }

    @Test
    fun `does not reclaim when a different track was playing`() {
        assertFalse(
            DiscoveryLogic.shouldReclaimDeparture(
                prevUri = "spotify:track:b", prevWasPlaying = true,
                prevRemainingMs = 300, prevDurationMs = 200_000,
                expectedUri = "spotify:track:a",
                crossfadeWindowMs = 12_000, minHoldableDurationMs = 5_000,
            )
        )
    }

    // MARK: sourceIsTarget

    @Test
    fun `null ids never match`() {
        assertFalse(DiscoveryLogic.sourceIsTarget(null, null))
        assertFalse(DiscoveryLogic.sourceIsTarget("p1", null))
        assertFalse(DiscoveryLogic.sourceIsTarget(null, "p1"))
        assertTrue(DiscoveryLogic.sourceIsTarget("p1", "p1"))
    }

    // MARK: normalizedDeviceName

    @Test
    fun `folds apostrophes case accents and the duplicate suffix`() {
        val a = DiscoveryLogic.normalizedDeviceName("Nate’s Pixel")
        assertEquals(a, DiscoveryLogic.normalizedDeviceName("Nate's pixel"))
        assertEquals(a, DiscoveryLogic.normalizedDeviceName("Nate's Pixel (2)"))
        assertEquals(
            DiscoveryLogic.normalizedDeviceName("Renee"),
            DiscoveryLogic.normalizedDeviceName("Renée"),
        )
    }

    @Test
    fun `only a trailing parenthesised number is stripped`() {
        assertEquals("pixel (pro)", DiscoveryLogic.normalizedDeviceName("Pixel (Pro)"))
        assertEquals("pixel (2) x", DiscoveryLogic.normalizedDeviceName("Pixel (2) x"))
    }

    // MARK: mayRemoveFromSource — the guard that stops a wrong deletion

    @Test
    fun `refuses when there is no source playlist`() {
        assertFalse(
            DiscoveryLogic.mayRemoveFromSource(
                sourcePlaylistId = null, targetPlaylistId = "t",
                sourceTrackUri = "u", actedUri = "u", isMove = false,
            )
        )
    }

    @Test
    fun `a move never deletes out of the target itself`() {
        // Otherwise auto-skip-and-move would walk the target playlist deleting it.
        assertFalse(
            DiscoveryLogic.mayRemoveFromSource(
                sourcePlaylistId = "t", targetPlaylistId = "t",
                sourceTrackUri = "u", actedUri = "u", isMove = true,
            )
        )
    }

    @Test
    fun `an explicit Remove may delete from the target`() {
        // Pressing Remove while listening to the target playlist is a legitimate gesture.
        assertTrue(
            DiscoveryLogic.mayRemoveFromSource(
                sourcePlaylistId = "t", targetPlaylistId = "t",
                sourceTrackUri = "u", actedUri = "u", isMove = false,
            )
        )
    }

    @Test
    fun `refuses when the source was resolved for a different track`() {
        // This is the stale-source case: deleting here removes the wrong track from the playlist.
        assertFalse(
            DiscoveryLogic.mayRemoveFromSource(
                sourcePlaylistId = "s", targetPlaylistId = "t",
                sourceTrackUri = "spotify:track:previous", actedUri = "spotify:track:current",
                isMove = false,
            )
        )
    }

    @Test
    fun `refuses when the source has no track URI at all`() {
        assertFalse(
            DiscoveryLogic.mayRemoveFromSource(
                sourcePlaylistId = "s", targetPlaylistId = "t",
                sourceTrackUri = null, actedUri = "spotify:track:current", isMove = false,
            )
        )
    }
}
