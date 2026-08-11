import AppKit

/// Swift-facing wrapper over the Objective-C `SpotifyBridge` (ScriptingBridge).
/// All playback reads/controls are local and require no Premium / no login.
///
/// Every Apple event goes through `SpotifyBridgeClient`: off the main thread, under a deadline.
/// Synchronous callers read `lastKnown` — the cache the 1s poll refreshes — so drawing the menu
/// bar never waits on Spotify. See `SpotifyBridgeClient` for why that matters.
@MainActor
final class LocalSpotifyController {
    private static let spotifyBundleID = "com.spotify.client"

    private let client = SpotifyBridgeClient()
    private var didLogSnapshotKeys = false

    /// The most recent successful read. Deliberately retained through an outage: the panel keeps
    /// showing the last known track and labels it via `isResponsive`, rather than blanking out.
    private(set) var lastKnown: NowPlaying?

    /// Whether Spotify is currently answering Apple events.
    var isResponsive: Bool { client.isResponsive }

    /// A Launch Services lookup, not an Apple event — safe and instant on the main thread.
    var isAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.spotifyBundleID).isEmpty
    }

    /// Cached "actively playing here" probe for the per-second device-locality refresh. Reads
    /// the poll's snapshot rather than spending an extra Apple event every single second.
    var isPlaying: Bool { lastKnown?.isPlaying ?? false }

    /// Re-read playback and update the cache. One queue hop and one deadline per poll:
    /// `playbackSnapshot` gathers state + track identity + position + shuffle in a single trip.
    ///
    /// Returns nil when nothing is playing **and** when the read missed its deadline — in the
    /// latter case `lastKnown` is left intact for display, but nil is returned so that callers
    /// which *act* on playback never act on a reading we failed to take. Check `isResponsive`
    /// to tell the two apart.
    @discardableResult
    func refresh() async -> NowPlaying? {
        guard isAppRunning else { lastKnown = nil; return nil }

        switch await client.read("nowPlaying", { $0.playbackSnapshot() }) {
        case .value(let snapshot):
            guard let snapshot else { lastKnown = nil; return nil }   // stopped / nothing playing
            logSnapshotKeysOnce(snapshot)
            lastKnown = NowPlayingMapping.makeNowPlaying(fromPlaybackSnapshot: snapshot)
            return lastKnown
        case .unavailable:
            return nil
        }
    }

    /// A guaranteed-fresh read, for the moments where discovery must confirm track identity
    /// before parking on or advancing past a song. A cached snapshot can be a full poll stale,
    /// and committing to the wrong identity is the failure this app works hardest to avoid.
    func freshNowPlaying() async -> NowPlaying? {
        await refresh()
    }

    /// One-time diagnostic: which fields the snapshot actually populated (especially artwork
    /// + duration), so a wrong `-properties` key spelling is visible on-device without a
    /// rebuild loop. See `SpotifyBridge.currentTrackSnapshot`'s artwork-key fallback chain.
    private func logSnapshotKeysOnce(_ snapshot: [String: Any]) {
        guard !didLogSnapshotKeys else { return }
        didLogSnapshotKeys = true
        DebugLog.log("nowPlaying snapshot keys: \(snapshot.keys.sorted())")
    }

    // MARK: Transport
    //
    // Fire-and-forget: these enqueue onto the bridge queue and return immediately, so a button
    // press can't block the main thread either. Nothing useful comes back from a transport
    // command, and the next poll reports the result anyway.

    func playPause() { client.write("playpause") { $0.playpause() } }
    func play() { client.write("play") { $0.play() } }
    func pause() { client.write("pause") { $0.pause() } }
    func next() { client.write("next") { $0.nextTrack() } }
    func previous() { client.write("previous") { $0.previousTrack() } }
    func seek(to seconds: Double) { client.write("seek") { $0.seek(to: seconds) } }
    func setShuffle(_ on: Bool) { client.write("shuffle") { $0.shuffling = on } }

    /// Deliberately NOT routed through the bridge queue: this is a Launch Services call rather
    /// than an Apple event, and "Open Spotify" has to keep working precisely when the bridge is
    /// wedged — that's the moment the user most wants it.
    func activateSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.spotifyBundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: NSWorkspace.OpenConfiguration(),
                                           completionHandler: nil)
    }
}
