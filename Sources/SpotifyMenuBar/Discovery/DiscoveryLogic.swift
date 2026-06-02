import Foundation

/// Which auto-skip rule matched (if any).
enum AutoSkipKind: Equatable { case inTarget, reviewed }

/// Pure, side-effect-free discovery decisions — unit-tested in isolation
/// (compiled directly into the test target).
enum DiscoveryLogic {
    /// First-match-wins auto-skip decision for a candidate track.
    static func autoSkipKind(inTarget: Bool,
                             reviewed: Bool,
                             skipIfInTarget: Bool,
                             skipAlreadyReviewed: Bool) -> AutoSkipKind? {
        if skipIfInTarget && inTarget { return .inTarget }
        if skipAlreadyReviewed && reviewed { return .reviewed }
        return nil
    }

    /// Loop-protection stop test, evaluated BEFORE recording the skip.
    /// Exhausted when this URI was already auto-skipped in the current sweep
    /// (we've cycled with nothing new), or recording it would hit the ceiling.
    static func isExhausted(uri: String,
                            visited: Set<String>,
                            consecutiveSoFar: Int,
                            ceiling: Int) -> Bool {
        if visited.contains(uri) { return true }
        if consecutiveSoFar + 1 >= ceiling { return true }
        return false
    }
}
