import AppKit

/// Enforces that exactly one copy of this app owns a menu bar icon.
///
/// Every workspace checkout builds its own bundle into its own DerivedData directory, and
/// `scripts/run.sh` ends in `open` — so running it from four checkouts left four copies
/// resident at once. The visible symptom was extra menu bar icons (three visible, the fourth
/// hidden behind the notch). The expensive symptom was invisible: four copies share one prefs
/// domain, one Application Support directory and one Keychain token, so they polled Spotify in
/// lockstep — four identical `GET /me/player` calls a second, 216k quota-exceeded responses,
/// and `Retry-After` values up to 18 hours, which left the app looking broken for a day at a
/// time.
///
/// The ranking rule lives in `InstanceRanking`; this type is the AppKit half that finds the
/// other copies and terminates them.
enum InstanceGuard {
    typealias Instance = InstanceRanking.Instance
    typealias Decision = InstanceRanking.Decision

    /// Opt out when deliberately running two builds side by side.
    static let overrideEnvKey = "SPOTIFYMENUBAR_ALLOW_MULTIPLE"

    /// Rank this copy against the live process list, terminating losers or reporting that we are
    /// one. Call before constructing anything: a copy that stands down must not touch the
    /// Keychain, the shared JSON state, or the API.
    @MainActor
    static func enforce() -> Decision {
        guard ProcessInfo.processInfo.environment[overrideEnvKey] != "1" else {
            DebugLog.log("instance-guard: disabled by \(overrideEnvKey)=1")
            return .proceed(terminating: [])
        }

        let current = NSRunningApplication.current
        let me = Instance(pid: current.processIdentifier,
                          launchDate: current.launchDate ?? Date(),
                          bundlePath: BuildInfo.bundlePath)
        let others = siblings(of: current)
        if !others.isEmpty {
            // Silent on a clean launch; a line only when there was actually a contest to settle.
            DebugLog.log("instance-guard: \(others.count) other copy/copies running \(others.map(\.pid))")
        }
        let decision = InstanceRanking.decide(me: me, others: others)

        switch decision {
        case .standDown(let winner):
            DebugLog.log("instance-guard: standing down — pid \(winner.pid) is newer (\(winner.bundlePath))")
        case .proceed(let doomed):
            for other in doomed {
                DebugLog.log("instance-guard: terminating pid \(other.pid) (\(other.bundlePath))")
            }
            terminate(doomed)
        }
        return decision
    }

    /// Other running copies of this same bundle id. Every workspace build shares the id, which
    /// is what lets one lookup find them all regardless of which DerivedData path they came from.
    private static func siblings(of current: NSRunningApplication) -> [Instance] {
        guard let bundleId = Bundle.main.bundleIdentifier else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != current.processIdentifier }
            .map { Instance(pid: $0.processIdentifier,
                            launchDate: $0.launchDate,
                            bundlePath: $0.bundleURL?.path ?? "unknown") }
    }

    private static func terminate(_ instances: [Instance]) {
        let apps = instances.compactMap { NSRunningApplication(processIdentifier: $0.pid) }
        guard !apps.isEmpty else { return }
        for app in apps { app.terminate() }

        // A polite quit is not guaranteed to land: this app has a known hang mode where a stuck
        // Apple event leaves it unresponsive to everything (see `SpotifyBridgeClient`). A hung
        // copy that ignores the quit is exactly the copy that would sit in the menu bar forever,
        // so escalate rather than trust it. Fires once the main run loop starts pumping.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for app in apps where !app.isTerminated {
                DebugLog.log("instance-guard: pid \(app.processIdentifier) ignored quit; forcing")
                app.forceTerminate()
            }
        }
    }
}
