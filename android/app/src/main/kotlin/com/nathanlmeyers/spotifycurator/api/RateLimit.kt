package com.nathanlmeyers.spotifycurator.api

/**
 * Pure, side-effect-free rate-limit decisions — unit-tested in isolation.
 * Port of the macOS `RateLimit.swift`; milliseconds instead of seconds.
 */
object RateLimit {
    /** Default pause when Spotify sends a 429 without a usable `Retry-After`. */
    const val FALLBACK_MS = 5_000L

    /** Never silence the app for longer than this, whatever the header claims. */
    const val CAP_MS = 60_000L

    /** Never resume sooner than this, however small the header claims. */
    const val FLOOR_MS = 1_000L

    /**
     * How long to stop calling the API after a 429.
     *
     * `Retry-After` is documented as an integer number of seconds, but in practice it can be
     * absent, non-numeric, zero, negative, or implausibly large. A zero/negative value would mean
     * "resume immediately", which reproduces the hammering the backoff exists to stop; an
     * implausibly large one would wedge the app for hours. So: floor at 1s, cap at [CAP_MS].
     *
     * Non-finite values are rejected rather than clamped. `"NaN".toDoubleOrNull()` succeeds, and
     * NaN survives `coerceIn` untouched — it would reach the deadline arithmetic and produce a
     * value every comparison treats as false, silently disabling the backoff.
     */
    fun backoffMs(
        retryAfterHeader: String?,
        fallbackMs: Long = FALLBACK_MS,
        capMs: Long = CAP_MS,
    ): Long {
        val advertisedMs = retryAfterHeader
            ?.trim()
            ?.toDoubleOrNull()
            ?.takeIf { it.isFinite() }
            ?.let { (it * 1000).toLong() }
        return (advertisedMs ?: fallbackMs).coerceIn(FLOOR_MS, capMs)
    }
}
