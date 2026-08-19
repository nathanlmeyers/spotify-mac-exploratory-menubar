import Foundation

/// Which of several running copies of this app owns the menu bar.
///
/// Pure Foundation and separate from `InstanceGuard` so the rule can be tested directly rather
/// than by spawning processes — the same split as `DiscoveryLogic` / `NewReleaseLogic`.
enum InstanceRanking {
    /// A running copy, reduced to the three things ranking needs.
    struct Instance: Equatable {
        var pid: pid_t
        var launchDate: Date?
        var bundlePath: String

        init(pid: pid_t, launchDate: Date?, bundlePath: String) {
            self.pid = pid
            self.launchDate = launchDate
            self.bundlePath = bundlePath
        }
    }

    enum Decision: Equatable {
        /// This copy owns the menu bar. The listed instances should be terminated.
        case proceed(terminating: [Instance])
        /// A newer copy won; quit before building anything.
        case standDown(winner: Instance)
    }

    /// Decide whether `me` owns the menu bar.
    ///
    /// The rule is a **total order**, not "terminate everyone else". That distinction is the
    /// whole correctness argument: four copies launched within the same second each see the
    /// other three, and a naive "kill the others" leaves *zero* survivors. Ranking instead means
    /// every copy independently computes the same winner from the same list, so exactly one
    /// proceeds however the launches interleave — see `testExactlyOneWinnerAmongSimultaneousLaunches`.
    ///
    /// Newest wins. The opposite rule (a new copy backs off) would mean a rebuild silently does
    /// nothing, which is the same "the code running is not the code on disk" trap `BuildInfo`
    /// exists to close.
    static func decide(me: Instance, others: [Instance]) -> Decision {
        // No competition: the common case, and the only one on a clean machine.
        guard let newest = others.max(by: outranks) else { return .proceed(terminating: []) }
        if outranks(me, newest) { return .standDown(winner: newest) }
        return .proceed(terminating: others)
    }

    /// `outranks(a, b)` is true when `b` beats `a`: later launch wins, ties broken by pid.
    ///
    /// A missing launch date sorts oldest. That is only ever right for *other* processes — the
    /// current process substitutes `now` in `InstanceGuard.enforce()`, because reading as
    /// `.distantPast` would make a freshly launched copy stand down for every stale one on the
    /// machine, and the app would refuse to start at all.
    static func outranks(_ a: Instance, _ b: Instance) -> Bool {
        let dateA = a.launchDate ?? .distantPast
        let dateB = b.launchDate ?? .distantPast
        if dateA != dateB { return dateA < dateB }
        return a.pid < b.pid
    }
}
