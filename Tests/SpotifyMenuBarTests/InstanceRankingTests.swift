import XCTest

/// The rule that keeps one copy of the app in the menu bar.
///
/// Worth testing directly: the failure it exists to prevent (four copies resident, four of every
/// Spotify poll, the API quota exhausted for 18 hours at a stretch) is expensive and slow to
/// reproduce by hand, and the interesting case — simultaneous launches — is a race that a manual
/// check would pass by luck.
final class InstanceRankingTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_787_000_000)

    private func instance(_ pid: pid_t, _ secondsAfterEpoch: TimeInterval?) -> InstanceRanking.Instance {
        InstanceRanking.Instance(pid: pid,
                                 launchDate: secondsAfterEpoch.map { epoch.addingTimeInterval($0) },
                                 bundlePath: "/build-\(pid)/SpotifyMenuBar.app")
    }

    // MARK: - The ordinary cases

    /// A clean machine: nothing to displace, nothing to stand down for.
    func testTheOnlyCopyProceedsWithNothingToTerminate() {
        let decision = InstanceRanking.decide(me: instance(100, 0), others: [])
        XCTAssertEqual(decision, .proceed(terminating: []))
    }

    /// The case this whole guard is for: a rebuild takes over from what's already running.
    func testAFreshBuildDisplacesTheOlderCopy() {
        let stale = instance(100, 0)
        let decision = InstanceRanking.decide(me: instance(200, 60), others: [stale])
        XCTAssertEqual(decision, .proceed(terminating: [stale]))
    }

    /// Newest wins means the *older* arrival is the one that quits — otherwise two copies both
    /// think they own the menu bar.
    func testAnOlderCopyStandsDownForANewerOne() {
        let newer = instance(200, 60)
        let decision = InstanceRanking.decide(me: instance(100, 0), others: [newer])
        XCTAssertEqual(decision, .standDown(winner: newer))
    }

    /// Every stale copy goes, not just the newest of them — four accumulated over a week must
    /// collapse to one, not to two.
    func testAllOlderCopiesAreTerminatedNotJustTheNewest() {
        let older = [instance(100, 0), instance(101, 10), instance(102, 20)]
        let decision = InstanceRanking.decide(me: instance(200, 60), others: older)
        XCTAssertEqual(decision, .proceed(terminating: older))
    }

    // MARK: - Ties

    /// `open` from a script can start two copies inside the same millisecond, leaving the launch
    /// dates genuinely equal. Something still has to break the tie, or both stand down.
    func testIdenticalLaunchDatesAreBrokenByPid() {
        XCTAssertEqual(InstanceRanking.decide(me: instance(100, 0), others: [instance(200, 0)]),
                       .standDown(winner: instance(200, 0)))
        XCTAssertEqual(InstanceRanking.decide(me: instance(200, 0), others: [instance(100, 0)]),
                       .proceed(terminating: [instance(100, 0)]))
    }

    /// A copy whose launch date the system won't report must not be able to win by default —
    /// that's how a stale build would keep displacing every fresh one.
    func testAnUnknownLaunchDateSortsOldest() {
        let unknown = instance(300, nil)
        XCTAssertEqual(InstanceRanking.decide(me: instance(100, 0), others: [unknown]),
                       .proceed(terminating: [unknown]))
    }

    // MARK: - The property that matters

    /// The reason the rule is a total order rather than "terminate everyone else".
    ///
    /// Four copies launching together each see the other three. Under "kill the others" they all
    /// kill each other and the menu bar ends up empty; under a ranking every copy computes the
    /// same winner from the same list. Checked over every arrangement of ties and distinct dates,
    /// with each copy independently running the rule it would run at startup.
    func testExactlyOneWinnerAmongSimultaneousLaunches() {
        let launchOffsets: [[TimeInterval?]] = [
            [0, 0, 0, 0],           // a dead heat: pid alone decides
            [0, 0, 1, 1],           // tied pairs
            [0, 1, 2, 3],           // cleanly staggered
            [3, 2, 1, 0],           // staggered, pids in the opposite order
            [nil, nil, 0, 1],       // launch dates unavailable
            [nil, nil, nil, nil],   // none available at all
        ]

        for offsets in launchOffsets {
            let all = offsets.enumerated().map { instance(pid_t(100 + $0.offset), $0.element) }

            let winners = all.filter { me in
                let others = all.filter { $0.pid != me.pid }
                if case .proceed = InstanceRanking.decide(me: me, others: others) { return true }
                return false
            }

            XCTAssertEqual(winners.count, 1,
                           "expected exactly one survivor for offsets \(offsets), got \(winners.map(\.pid))")

            // And everyone else must agree on who it is, or a loser quits for a copy that is
            // itself quitting.
            let winner = winners[0]
            for me in all where me.pid != winner.pid {
                let others = all.filter { $0.pid != me.pid }
                XCTAssertEqual(InstanceRanking.decide(me: me, others: others),
                               .standDown(winner: winner),
                               "pid \(me.pid) picked a different winner for offsets \(offsets)")
            }
        }
    }
}
