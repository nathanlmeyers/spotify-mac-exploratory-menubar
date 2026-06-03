import Foundation

/// What the UI/AppDelegate observe for discovery mode.
enum ReviewState: Equatable {
    case inactive        // discovery off, or nothing curatable playing
    case watching        // a track is playing; counting down to a hold
    case held(HeldTrack) // paused at the end of a track; show judge controls
    case nothingNew      // loop protection tripped — everything left is seen/in-target
}

struct HeldTrack: Equatable {
    let snapshot: NowPlaying
    let canAdd: Bool
    let canRemoveFromSource: Bool
    let sourceName: String?
    let targetName: String?
}

/// Drives discovery mode off AppModel's existing 1s poll. Owns a single one-shot
/// timer that fires ~`lead` seconds before a track's natural end so we can pause
/// before Spotify auto-advances. See ROADMAP / the plan for the full design.
@MainActor
final class DiscoveryEngine {
    private enum Phase: Equatable {
        case idle
        case watching
        case holding(String)   // held URI
        case acting            // advancing via next(); waiting for the new track
        case exhausted
    }

    // Tunables
    // Pause this far before a track's natural end. Must comfortably exceed Apple-event
    // latency + the 1s poll granularity, otherwise Spotify auto-advances before our pause
    // lands and we end up holding the *next* track. 0.8s is the reliable floor in practice.
    private let lead: TimeInterval = 0.8
    private let manualPauseSlack: TimeInterval = 1.5
    private let slipWindow: TimeInterval = 2.0
    private let minHoldableDuration: Double = 3.0
    private let maxConsecutiveAutoSkips = 25

    // Dependencies
    private let provider: SpotifyProvider
    private let settings: Settings
    private let history: ReviewHistory
    private let targetMembership: () -> Set<String>
    private let canAddNow: () -> Bool
    private let canRemoveNow: () -> Bool
    private let sourceName: () -> String?
    private let targetName: () -> String?

    /// Published to AppModel (deduped — only fires on genuine state changes).
    var onStateChange: ((ReviewState) -> Void)?

    // State
    private var phase: Phase = .idle
    private var activeURI: String?
    private var lastNP: NowPlaying?
    private var precisePauseTimer: Timer?
    private var heldOrJudgedURIs = Set<String>()
    private var visitedThisSweep = Set<String>()
    private var consecutiveAutoSkips = 0
    private var actingTicks = 0
    private var lastPublished: ReviewState = .inactive

    init(provider: SpotifyProvider,
         settings: Settings,
         history: ReviewHistory,
         targetMembership: @escaping () -> Set<String>,
         canAddNow: @escaping () -> Bool,
         canRemoveNow: @escaping () -> Bool,
         sourceName: @escaping () -> String?,
         targetName: @escaping () -> String?) {
        self.provider = provider
        self.settings = settings
        self.history = history
        self.targetMembership = targetMembership
        self.canAddNow = canAddNow
        self.canRemoveNow = canRemoveNow
        self.sourceName = sourceName
        self.targetName = targetName
    }

    // MARK: - Poll entry point (called from AppModel.tick())

    func onTick(np: NowPlaying?, source: SourceContext) {
        defer { lastNP = np }

        guard settings.discoveryEnabled else { goIdle(); return }
        // Nothing playing, or non-curatable content (ad/episode/local): never hold.
        guard let np, np.kind == .track else { goIdle(); return }

        let uri = np.uri
        switch phase {
        case .holding(let heldURI):
            if uri != heldURI { evaluateNewCandidate(np, source, slip: false) }
            // else: stay held; ignore position drift.

        case .acting:
            if uri != activeURI {
                actingTicks = 0
                evaluateNewCandidate(np, source, slip: false)
            } else {
                actingTicks += 1
                if actingTicks == 2 { provider.next() }          // advance didn't take — retry once
                else if actingTicks >= 4 { actingTicks = 0; goIdle() }
            }

        case .exhausted:
            if !visitedThisSweep.contains(uri) {
                resetLoopProtection()
                evaluateNewCandidate(np, source, slip: false)
            }

        case .idle, .watching:
            if uri != activeURI {
                evaluateNewCandidate(np, source, slip: wasWatchingNearEnd())
            } else {
                updateWatching(np)
            }
        }
    }

    /// Whether the track we were watching was about to end when the URI changed —
    /// i.e. Spotify auto-advanced (crossfade/gapless) before our pre-emptive pause landed.
    private func wasWatchingNearEnd() -> Bool {
        guard case .watching = phase, let prev = lastNP, prev.durationSeconds > minHoldableDuration else { return false }
        return (prev.durationSeconds - prev.positionSeconds) <= (lead + slipWindow)
    }

    // MARK: - Candidate evaluation

    private func evaluateNewCandidate(_ np: NowPlaying, _ source: SourceContext, slip: Bool) {
        invalidateTimer()
        activeURI = np.uri

        // Already held/judged this URI: never re-prompt (guards backward-scrub / repeat).
        if heldOrJudgedURIs.contains(np.uri) {
            setPhase(.watching, publish: .watching)
            return
        }
        // Auto-skip rules (need source/target data — effectively login-gated).
        if let kind = autoSkipKind(np, source) {
            performAutoSkip(np, source, kind: kind)
            return
        }
        if slip {
            // We missed the previous track's end; pause this new track at ~0:00 and judge it.
            DebugLog.log("discovery: SLIP — prev track ended before pause landed; holding new track")
            provider.pause()
            enterHolding(provider.nowPlaying() ?? np)
            return
        }
        setPhase(.watching, publish: .watching)
        armPrecisePause(np)
    }

    private func autoSkipKind(_ np: NowPlaying, _ source: SourceContext) -> AutoSkipKind? {
        let inTarget = targetMembership().contains(np.uri)
        let reviewed = source.playlistId.map { history.hasReviewed(sourceId: $0, uri: np.uri) } ?? false
        return DiscoveryLogic.autoSkipKind(
            inTarget: inTarget,
            reviewed: reviewed,
            skipIfInTarget: settings.skipIfInTarget,
            skipAlreadyReviewed: settings.skipAlreadyReviewed
        )
    }

    private func performAutoSkip(_ np: NowPlaying, _ source: SourceContext, kind: AutoSkipKind) {
        let uri = np.uri
        // Loop protection: a repeated URI (cycled the sweep) or hitting the ceiling → stop.
        if DiscoveryLogic.isExhausted(uri: uri, visited: visitedThisSweep,
                                      consecutiveSoFar: consecutiveAutoSkips,
                                      ceiling: maxConsecutiveAutoSkips) {
            goExhausted(); return
        }
        visitedThisSweep.insert(uri)
        consecutiveAutoSkips += 1

        // "Skip if in target" with the move option also removes from the source.
        if kind == .inTarget, settings.skipInTargetAlsoRemove,
           source.isEditablePlaylist, let src = source.playlistId {
            Task { try? await provider.removeTrack(uri: uri, fromPlaylist: src) }
        }
        if let sid = source.playlistId { history.markReviewed(sourceId: sid, uri: uri) }
        heldOrJudgedURIs.insert(uri)

        actingTicks = 0
        setPhase(.acting, publish: .watching)
        provider.next()
    }

    // MARK: - Precise pause scheduling

    private func updateWatching(_ np: NowPlaying) {
        if heldOrJudgedURIs.contains(np.uri) { invalidateTimer(); return }
        if !np.isPlaying {
            // Manual pause mid-song → cancel the scheduled hold; re-arm when playback resumes.
            let remaining = np.durationSeconds - np.positionSeconds
            if remaining > lead + manualPauseSlack { invalidateTimer() }
            return
        }
        armPrecisePause(np)   // re-arm against fresh polled position (handles seek + drift)
    }

    private func armPrecisePause(_ np: NowPlaying) {
        invalidateTimer()
        guard np.durationSeconds > minHoldableDuration else { return }  // don't trap on short interstitials
        let remaining = max(0, np.durationSeconds - np.positionSeconds)
        let fireIn = max(0, remaining - lead)
        precisePauseTimer = Timer.scheduledTimer(withTimeInterval: fireIn, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.firePreciseHold() }
        }
        precisePauseTimer?.tolerance = 0.05
    }

    private func firePreciseHold() {
        guard case .watching = phase, let uri = activeURI, !heldOrJudgedURIs.contains(uri) else { return }
        guard let live = provider.nowPlaying() else { return }
        if live.uri == uri {
            DebugLog.log("discovery: precise hold (timer) on \"\(live.name)\" pos=\(Int(live.positionSeconds))/\(Int(live.durationSeconds))s")
            provider.pause()
            enterHolding(provider.nowPlaying() ?? live)
        } else if live.kind == .track, !heldOrJudgedURIs.contains(live.uri) {
            // Missed the pre-emptive pause (latency/crossfade) and the track already advanced.
            // Pause the now-current track immediately rather than waiting for the next poll.
            DebugLog.log("discovery: MISSED pre-empt; already advanced to \"\(live.name)\" — holding it")
            provider.pause()
            enterHolding(provider.nowPlaying() ?? live)
        }
    }

    private func enterHolding(_ np: NowPlaying) {
        invalidateTimer()
        activeURI = np.uri
        DebugLog.log("discovery: HELD \"\(np.name)\" [\(np.uri)]")
        heldOrJudgedURIs.insert(np.uri)
        resetLoopProtection()                  // we found something worth reviewing
        setPhase(.holding(np.uri), publish: .held(HeldTrack(
            snapshot: np,
            canAdd: canAddNow(),
            canRemoveFromSource: canRemoveNow(),
            sourceName: sourceName(),
            targetName: targetName()
        )))
    }

    // MARK: - Held resolution (called by AppModel after curating)

    /// Mark the held track reviewed, advance, and resume the cycle. AppModel performs
    /// any add/remove with the explicit URI before/after calling this.
    func finishHold(judgedURI: String, sourceId: String?) {
        invalidateTimer()
        heldOrJudgedURIs.insert(judgedURI)
        if let sid = sourceId { history.markReviewed(sourceId: sid, uri: judgedURI) }
        resetLoopProtection()
        activeURI = judgedURI
        actingTicks = 0
        setPhase(.acting, publish: .watching)
        provider.next()
    }

    /// Full reset (logout, discovery disabled, source change).
    func reset() {
        invalidateTimer()
        heldOrJudgedURIs.removeAll()
        resetLoopProtection()
        activeURI = nil
        goIdle()
    }

    // MARK: - Helpers

    private func goIdle() {
        invalidateTimer()
        activeURI = nil
        actingTicks = 0
        setPhase(.idle, publish: .inactive)
    }

    private func goExhausted() {
        invalidateTimer()
        setPhase(.exhausted, publish: .nothingNew)
    }

    private func resetLoopProtection() {
        visitedThisSweep.removeAll()
        consecutiveAutoSkips = 0
    }

    private func invalidateTimer() {
        precisePauseTimer?.invalidate()
        precisePauseTimer = nil
    }

    private func setPhase(_ newPhase: Phase, publish state: ReviewState) {
        phase = newPhase
        if state != lastPublished {
            lastPublished = state
            onStateChange?(state)
        }
    }
}
