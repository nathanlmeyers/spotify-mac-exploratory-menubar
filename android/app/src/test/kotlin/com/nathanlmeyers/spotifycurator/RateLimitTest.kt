package com.nathanlmeyers.spotifycurator

import com.nathanlmeyers.spotifycurator.api.RateLimit
import org.junit.Assert.assertEquals
import org.junit.Test

/** Port of the macOS `RateLimitTests.swift`. */
class RateLimitTest {

    @Test
    fun `uses the advertised Retry-After`() {
        assertEquals(12_000L, RateLimit.backoffMs("12"))
    }

    @Test
    fun `tolerates surrounding whitespace`() {
        assertEquals(12_000L, RateLimit.backoffMs("  12 "))
    }

    @Test
    fun `falls back when the header is absent`() {
        assertEquals(RateLimit.FALLBACK_MS, RateLimit.backoffMs(null))
    }

    @Test
    fun `falls back when the header is not a number`() {
        assertEquals(RateLimit.FALLBACK_MS, RateLimit.backoffMs("soon"))
    }

    @Test
    fun `floors at one second`() {
        // "0" means "retry immediately", which is exactly the hammering the backoff exists to stop.
        assertEquals(RateLimit.FLOOR_MS, RateLimit.backoffMs("0"))
        assertEquals(RateLimit.FLOOR_MS, RateLimit.backoffMs("-30"))
    }

    @Test
    fun `caps at one minute`() {
        assertEquals(RateLimit.CAP_MS, RateLimit.backoffMs("86400"))
    }

    @Test
    fun `rejects non-finite values rather than clamping them`() {
        // "NaN".toDoubleOrNull() succeeds, and NaN survives coerceIn untouched — it would reach
        // the deadline arithmetic and produce a value every comparison treats as false, silently
        // disabling the backoff. Same trap as the Swift original.
        assertEquals(RateLimit.FALLBACK_MS, RateLimit.backoffMs("NaN"))
        assertEquals(RateLimit.FALLBACK_MS, RateLimit.backoffMs("Infinity"))
        assertEquals(RateLimit.FALLBACK_MS, RateLimit.backoffMs("-Infinity"))
    }
}
