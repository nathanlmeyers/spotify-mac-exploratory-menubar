import Foundation

/// The outcome of one bridge call. `unavailable` (the deadline was missed) is kept distinct from
/// `value(nil)` ("Spotify answered: nothing is playing") because the two must be handled very
/// differently: the first means our knowledge is stale, the second means it's accurate.
enum BridgeResult<T> {
    case value(T?)
    case unavailable
}

/// Serialized, deadline-bounded access to `SpotifyBridge` — the app's only path to Spotify's
/// ScriptingBridge interface.
///
/// Why this exists: every ScriptingBridge accessor is a blocking `AESendMessage`. When Spotify
/// acknowledges an event and then never sends a reply, that call blocks **forever** — the 60s
/// `kAEDefaultTimeout` does not fire for a dropped reply. This app used to issue those calls on
/// the main thread, so one such event permanently froze everything, the status item included:
/// the icon sat in the menu bar, clicks did nothing, and relaunching did nothing either
/// (re-opening an `LSUIElement` app that is already running just re-activates the hung process).
///
/// So: all Apple events run on a private serial queue, every call carries a deadline that *we*
/// enforce rather than trusting AE to, and a connection that blows its deadline is abandoned and
/// rebuilt. The main thread never waits on Spotify.
@MainActor
final class SpotifyBridgeClient {

    // MARK: Tunables

    /// Reads run once a second, so they must expire well inside a poll. Writes get longer:
    /// a transport command that is merely slow is still worth landing.
    private let readDeadline: TimeInterval = 2.0
    private let writeDeadline: TimeInterval = 3.0
    /// Only report unresponsive after this many consecutive misses — one slow read (a track
    /// load, a Spotify GC pause) is normal and shouldn't flap the UI.
    private let unresponsiveThreshold = 2
    /// Don't churn connections; a wedged event may still be about to drain.
    private let rebuildCooldown: TimeInterval = 10
    /// Ceiling on simultaneously-wedged connections. Each one pins a thread until its Apple
    /// event returns, which may be never — past this we stop rebuilding and stay degraded.
    private let maxWedgedConnections = 4
    /// Never pile more than this many blocks onto one connection; if it's stuck, extra work
    /// would only queue behind it and burn a full deadline each time.
    private let maxQueueDepth = 3

    // MARK: Connection

    /// One Apple-event connection plus the serial queue that owns it. Deliberately immutable so
    /// it can be captured by its own queue safely; all mutable bookkeeping is main-actor state
    /// below, keyed by `id`.
    ///
    /// `@unchecked Sendable` is sound by construction: every stored property is a `let`, and the
    /// one piece of non-thread-safe state — `bridge`, which owns the `SBApplication` — is only
    /// ever touched from inside `queue`, this connection's own serial queue.
    private final class Connection: @unchecked Sendable {
        let id: Int
        let queue: DispatchQueue
        let bridge = SpotifyBridge()

        init(id: Int) {
            self.id = id
            self.queue = DispatchQueue(label: "SpotifyMenuBar.spotify-bridge.\(id)", qos: .userInitiated)
        }
    }

    private var connection = Connection(id: 0)
    private var nextConnectionID = 1
    private var inFlight: [Int: Int] = [:]      // connection id → outstanding blocks
    private var wedged: Set<Int> = []           // abandoned connections that haven't drained
    private var lastRebuildAt: Date?
    private var consecutiveTimeouts = 0

    /// False once reads have missed their deadline repeatedly. Callers use this to degrade
    /// honestly in the UI and — more importantly — to stop *acting* on playback state we can't
    /// currently trust. Never skip, pause, or remove on a stale read.
    private(set) var isResponsive = true

    // MARK: API

    /// Run a read with the read deadline.
    func read<T>(_ label: String, _ work: @escaping (SpotifyBridge) -> T?) async -> BridgeResult<T> {
        await run(label: label, deadline: readDeadline, work)
    }

    /// Enqueue a write and return immediately. A transport command must never make the main
    /// thread wait on Spotify, and there's nothing useful to do with the result — but it still
    /// flows through the same deadline/health machinery so a wedge is noticed and recovered.
    func write(_ label: String, _ work: @escaping (SpotifyBridge) -> Void) {
        Task {
            _ = await run(label: label, deadline: writeDeadline) { bridge -> Bool? in
                work(bridge)
                return true
            }
        }
    }

    // MARK: Execution

    /// Resumes its continuation exactly once — the work block and the deadline race to it.
    private final class ResumeOnce<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<BridgeResult<T>, Never>?

        init(_ continuation: CheckedContinuation<BridgeResult<T>, Never>) {
            self.continuation = continuation
        }

        func resume(_ outcome: BridgeResult<T>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: outcome)
        }
    }

    private func run<T>(label: String,
                        deadline: TimeInterval,
                        _ work: @escaping (SpotifyBridge) -> T?) async -> BridgeResult<T> {
        let conn = connection
        // A stuck connection would only make extra work queue behind it and burn a full
        // deadline apiece, so refuse rather than pile on.
        guard (inFlight[conn.id] ?? 0) < maxQueueDepth else { return .unavailable }
        inFlight[conn.id, default: 0] += 1

        let outcome: BridgeResult<T> = await withCheckedContinuation { continuation in
            let box = ResumeOnce<T>(continuation)
            conn.queue.async {
                let value = work(conn.bridge)
                box.resume(.value(value))
                Task { @MainActor [weak self] in self?.noteDrained(conn.id) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {
                box.resume(.unavailable)
            }
        }

        switch outcome {
        case .value:
            noteSuccess()
        case .unavailable:
            noteTimeout(label: label, conn)
        }
        return outcome
    }

    // MARK: Health

    private func noteSuccess() {
        consecutiveTimeouts = 0
        if !isResponsive {
            isResponsive = true
            DebugLog.log("spotify bridge: responsive again (connection \(connection.id))")
        }
    }

    private func noteTimeout(label: String, _ conn: Connection) {
        consecutiveTimeouts += 1
        DebugLog.log("spotify bridge: \(label) missed its deadline (\(consecutiveTimeouts) in a row)")
        if consecutiveTimeouts >= unresponsiveThreshold, isResponsive {
            isResponsive = false
            DebugLog.log("spotify bridge: UNRESPONSIVE — Spotify isn't answering Apple events")
        }
        rebuild(abandoning: conn)
    }

    /// Abandon a wedged connection and build a fresh one, so the next event goes out over a new
    /// `SBAppContext` instead of queueing behind a send that may never return. The old queue is
    /// left to finish whenever its event finally comes back; its result is discarded.
    private func rebuild(abandoning conn: Connection) {
        guard conn.id == connection.id else { return }   // already replaced by an earlier timeout
        guard inFlight[conn.id] != nil else { return }   // completed just after the deadline — healthy
        if let last = lastRebuildAt, Date().timeIntervalSince(last) < rebuildCooldown { return }
        guard wedged.count < maxWedgedConnections else {
            DebugLog.log("spotify bridge: \(wedged.count) connections still wedged — not rebuilding")
            return
        }

        wedged.insert(conn.id)
        lastRebuildAt = Date()
        connection = Connection(id: nextConnectionID)
        nextConnectionID += 1
        DebugLog.log("spotify bridge: abandoned wedged connection \(conn.id), rebuilt as \(connection.id)")
    }

    private func noteDrained(_ id: Int) {
        let remaining = (inFlight[id] ?? 1) - 1
        if remaining > 0 {
            inFlight[id] = remaining
            return
        }
        inFlight[id] = nil
        if wedged.remove(id) != nil {
            DebugLog.log("spotify bridge: wedged connection \(id) finally drained")
        }
    }
}
