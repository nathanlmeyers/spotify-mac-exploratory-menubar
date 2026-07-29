import Foundation

/// Pure, side-effect-free rate-limit decisions — unit-tested in isolation
/// (compiled directly into the test target), in the same spirit as `DiscoveryLogic`.
enum RateLimit {
    /// Default pause when Spotify sends a 429 without a usable `Retry-After`.
    static let fallback: TimeInterval = 5
    /// Never silence the app for longer than this, whatever the header claims.
    static let cap: TimeInterval = 60

    /// How long to stop calling the API after a 429.
    ///
    /// `Retry-After` is documented as an integer number of seconds, but in practice it can be
    /// absent, non-numeric, zero, negative, or implausibly large. A zero/negative value would
    /// mean "resume immediately", which reproduces the hammering the backoff exists to stop; an
    /// implausibly large one would wedge the app for hours. So: floor at 1s, cap at `cap`.
    ///
    /// Non-finite values are rejected rather than clamped. `Double("NaN")` parses successfully,
    /// and NaN survives `min`/`max` untouched — it would reach `addingTimeInterval` and produce
    /// an invalid deadline that every comparison treats as false, silently disabling the backoff.
    static func backoffInterval(retryAfterHeader: String?,
                                fallback: TimeInterval = RateLimit.fallback,
                                cap: TimeInterval = RateLimit.cap) -> TimeInterval {
        let advertised = retryAfterHeader
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap(Double.init)
            .flatMap { $0.isFinite ? $0 : nil }
        return min(max(advertised ?? fallback, 1), cap)
    }
}
