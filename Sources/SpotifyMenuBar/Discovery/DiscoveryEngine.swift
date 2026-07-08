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
    let sourceName: String?
    let targetName: String?
}

/// Transport that refuses to fire unless playback is confirmed on THIS Mac. The engine
/// still checks locality where the *decision* differs (go idle vs. keep a hold vs. don't
/// advance); this wrapper is defense-in-depth so a forgotten guard on any future transport
/// call degrades to a logged no-op instead of pausing a phone/speaker via Connect.
@MainActor
private struct GuardedTransport {
    let provider: SpotifyProvider
    let isLocal: () -> Bool?

    func pause() { gated("pause") { provider.pause() } }
    func play() { gated("play") { provider.play() } }
    func next() { gated("next") { provider.next() } }
    func previous() { gated("previous") { provider.previous() } }
    func seek(to seconds: Double) { gated("seek") { provider.seek(to: seconds) } }

    private func gated(_ name: String, _ action: () -> Void) {
        guard isLocal() == true else {
            DebugLog.log("discovery: dropped \(name) — playback not confirmed on this Mac")
            return
        }
        action()
    }
}

/// Drives discovery mode off AppModel's existing 1s poll. Owns a single one-shot
/// timer that fires ~`lead` seconds before a track's natural end so we can pause
/// before Spotify auto-advances. See ROADMAP / the plan for the full design.
@MainActor
final class DiscoveryEngine {
    private enum Phase: Equatable {
        case idle
        case watching
        case reclaiming(expectedA: String, attempts: Int)  // pausing + previous()-ing back to A
        case holding(String)   // held URI
        case acting            // advancing via next(); waiting for the new track
        case exhausted
    }

    // Tunables
    // Pause this far before a track's natural end. Must comfortably exceed Apple-event
    // latency + the 1s poll granularity; if our pause lands late, reclaim recovers the track.
    private let lead: TimeInterval = 1.3
    private let manualPauseSlack: TimeInterval = 1.5
    // A watched track that advances with <= this much left ended "naturally" (covers
    // Spotify's 12s max crossfade + slop) and is reclaimed; a far-from-end advance is a
    // deliberate user skip and is left alone.
    private let crossfadeWindow: Double = 13.0
    private let minHoldableDuration: Double = 3.0
    private let maxConsecutiveAutoSkips = 25
    private let maxReclaimAttempts = 2

    // Dependencies
    private let provider: SpotifyProvider
    private let transport: GuardedTransport
    private let settings: Settings
    private let history: ReviewHistory
    private let targetMembership: () -> Set<String>
    private let canAddNow: () -> Bool
    private let targetName: () -> String?
    // Whether playback is on this Mac: true = confirmed local (active Connect device is this Mac,
    // or no remote device and the desktop app is playing here), false = confirmed remote, nil =
    // unknown (not yet confirmed). Discovery issues transport (pause/next/previous) ONLY on a
    // confirmed `true`, so it never reaches a phone/speaker/other computer or an unconfirmed device.
    private let activeDeviceIsLocal: () -> Bool?

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
    private var lastSource: SourceContext = .none
    // Set when the active track was curated from the normal popover: don't reclaim its
    // successor when it ends (the user already made a call on it). Cleared on track change.
    private var suppressReclaimForActive = false
    // One-shot: set when the user drives transport from the app (Next/Previous) so the
    // resulting advance isn't reclaimed. Consumed on the next observed track change.
    private var suppressReclaimOnce = false

    init(provider: SpotifyProvider,
         settings: Settings,
         history: ReviewHistory,
         targetMembership: @escaping () -> Set<String>,
         canAddNow: @escaping () -> Bool,
         targetName: @escaping () -> String?,
         activeDeviceIsLocal: @escaping () -> Bool?) {
        self.provider = provider
        self.transport = GuardedTransport(provider: provider, isLocal: activeDeviceIsLocal)
        self.settings = settings
        self.history = history
        self.targetMembership = targetMembership
        self.canAddNow = canAddNow
        self.targetName = targetName
        self.activeDeviceIsLocal = activeDeviceIsLocal
    }

    // MARK: - Poll entry point (called from AppModel.tick())

    func onTick(np: NowPlaying?, source: SourceContext) {
        defer { lastNP = np }

        guard settings.discoveryEnabled else { goIdle(); return }
        // Only operate when playback is confirmed on THIS Mac. Anything else — a confirmed remote
        // device, or an unconfirmed/unknown one — must not issue transport, or our pause/skip would
        // propagate to it via Connect. Exception: a paused hold issues no transport and is safe to
        // keep across a transient device blip, so don't tear it down here (it resumes when local).
        if activeDeviceIsLocal() != true {
            if case .holding = phase { return }
            goIdle(); return
        }
        // Nothing playing, or non-curatable content (ad/episode/local): never hold.
        guard let np, np.kind == .track else { goIdle(); return }
        // Playing the target playlist itself: nothing to discover, and every track is
        // trivially "in target" — auto-skip-and-remove would delete the playlist. Stay idle.
        if DiscoveryLogic.sourceIsTarget(sourcePlaylistId: source.playlistId,
                                         targetPlaylistId: settings.targetPlaylistId) {
            goIdle(); return
        }
        lastSource = source

        let uri = np.uri
        switch phase {
        case .reclaiming(let expectedA, let attempts):
            resolveReclaim(np, source, expectedA: expectedA, attempts: attempts)

        case .holding(let heldURI):
            if uri != heldURI {
                if !consumeSuppressReclaimOnce(), reclaimableDeparture(expected: heldURI) {
                    // The held song ran off its end (a pause that didn't take, or a re-listen
                    // that reached the end). Recover IT — a hold only resolves through a
                    // judgment or a deliberate user action, never by silently becoming the
                    // successor. A parked-paused hold whose track changed is a deliberate
                    // pick in the Spotify app and is released below instead.
                    beginReclaim(expectedA: heldURI)
                } else {
                    evaluateNewCandidate(np, source)
                }
            } else if np.isPlaying,
                      np.durationSeconds > minHoldableDuration,
                      (np.durationSeconds - np.positionSeconds) <= lead + 1.0 {
                // The held track is playing again (a re-listen, or a pause that didn't take) and is
                // about to run off its end. Re-pause so the hold never slips to the next song —
                // pinned a hair early on purpose; the exact spot doesn't matter on a re-listen.
                transport.pause()
            }
            // else: paused, or re-listening with time to spare — stay held; ignore position drift.

        case .acting:
            if uri != activeURI {
                actingTicks = 0
                evaluateNewCandidate(np, source)
            } else {
                actingTicks += 1
                // Still on the old track. Retry next() only after ~3 ticks: a slow-but-successful
                // first next() would already have landed by then, so we don't double-advance and
                // skip the successor unreviewed. `uri == activeURI` is this tick's fresh read.
                if actingTicks == 3 { provider.next() }
                else if actingTicks >= 6 { actingTicks = 0; goIdle() }
            }

        case .exhausted:
            if !visitedThisSweep.contains(uri) {
                resetLoopProtection()
                evaluateNewCandidate(np, source)
            }

        case .idle, .watching:
            if uri != activeURI {
                let suppressed = consumeSuppressReclaimOnce()
                if !suppressed && shouldReclaim(newURI: uri) {
                    beginReclaim(expectedA: activeURI!)
                } else {
                    evaluateNewCandidate(np, source)
                }
            } else {
                updateWatching(np)
            }
        }
    }

    /// Reads-and-resets the one-shot user-transport flag (set by Next/Previous in the app).
    private func consumeSuppressReclaimOnce() -> Bool {
        defer { suppressReclaimOnce = false }
        return suppressReclaimOnce
    }

    /// Whether the track we were watching/reviewing departed via a natural runoff (reclaim)
    /// rather than a deliberate user action (release). See DiscoveryLogic.shouldReclaimDeparture.
    private func reclaimableDeparture(expected: String) -> Bool {
        guard let prev = lastNP else { return false }
        return DiscoveryLogic.shouldReclaimDeparture(
            prevURI: prev.uri, prevWasPlaying: prev.isPlaying,
            prevRemaining: prev.durationSeconds - prev.positionSeconds,
            prevDuration: prev.durationSeconds,
            expectedURI: expected,
            crossfadeWindow: crossfadeWindow,
            minHoldableDuration: minHoldableDuration)
    }

    /// Whether a watched, unjudged track just auto-advanced (so we should reclaim it rather
    /// than accept the skip). False for deliberate mid-song skips, judged tracks, and a
    /// parked-paused track the user switched away from.
    private func shouldReclaim(newURI: String) -> Bool {
        guard case .watching = phase, let a = activeURI, newURI != a,
              !heldOrJudgedURIs.contains(a), !suppressReclaimForActive else { return false }
        return reclaimableDeparture(expected: a)
    }

    // MARK: - Reclaim (recover a track that auto-advanced before we could hold it)

    /// Pause whatever's playing and step back toward the track that just auto-advanced.
    /// Resolution happens on the next tick (previousTrack is an async Apple event);
    /// retries re-enter here with `attempts` bumped.
    private func beginReclaim(expectedA: String, attempts: Int = 0) {
        invalidateTimer()
        if attempts == 0 {
            DebugLog.log("discovery: RECLAIM — \"\(expectedA)\" auto-advanced; pausing and stepping back")
        }
        transport.pause()
        transport.previous()
        // Reclaiming is invisible to the UI: keep the last published state (e.g. a live
        // held panel during an escaped-hold recovery) rather than flashing it closed and
        // re-presenting (with its alert sound) 1-2s later when the re-hold lands.
        setPhase(.reclaiming(expectedA: expectedA, attempts: attempts), publish: lastPublished)
    }

    private func resolveReclaim(_ np: NowPlaying, _ source: SourceContext, expectedA: String, attempts: Int) {
        if np.uri == expectedA {
            // Landed back on the track to review. Pause it and hold (or auto-skip if it qualifies).
            transport.pause()
            activeURI = expectedA
            if let kind = autoSkipKind(np, source) { performAutoSkip(np, source, kind: kind) }
            else {
                // previous() restarted the track near 0:00; seek to its end so the held panel
                // reflects a song that just finished, then hold the post-seek paused snapshot
                // (enterHolding does its own fresh read; np is only the pre-seek fallback).
                if np.durationSeconds > minHoldableDuration {
                    transport.seek(to: max(0, np.durationSeconds - lead))
                }
                enterHolding(expectedURI: expectedA, fallback: np)
            }
            return
        }
        if attempts < maxReclaimAttempts {
            // Still on the successor — previousTrack restarts the current track when it's
            // >~3s in, so it's now near 0:00; another previous() should land on A.
            beginReclaim(expectedA: expectedA, attempts: attempts + 1)
            return
        }
        // Gave up reclaiming A: Spotify won't step back to it. HARD RULE — never hold whatever
        // is playing now as if it were the track under review; that is exactly how the *next*
        // song ends up in the judge panel. Let A go and evaluate the current track as a fresh
        // candidate, so it's held at ITS own end (or auto-skipped) — never mid-song under the
        // wrong identity. The judge panel only ever shows the song discovery set out to review.
        DebugLog.log("discovery: RECLAIM failed for \"\(expectedA)\"; not holding successor \"\(np.uri)\" — evaluating it fresh")
        // Reclaim parked the successor near 0:00. Un-pause before letting it go, so a failed
        // reclaim never mimics a hold (music stopped + next song displayed, no judge panel)
        // and an immediate auto-skip's next() can't strand a paused player either.
        transport.play()
        evaluateNewCandidate(np, source)
    }

    // MARK: - Candidate evaluation

    private func evaluateNewCandidate(_ np: NowPlaying, _ source: SourceContext) {
        invalidateTimer()
        activeURI = np.uri
        suppressReclaimForActive = false   // the reclaim decision for this transition is already made

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
        setPhase(.watching, publish: .watching)
        armPrecisePause(np)
    }

    private func autoSkipKind(_ np: NowPlaying, _ source: SourceContext) -> AutoSkipKind? {
        let inTarget = targetMembership().contains(np.uri)
        let reviewed = source.playlistId.map { history.hasReviewed(sourceId: $0, uri: np.uri) } ?? false
        return DiscoveryLogic.autoSkipKind(
            sourceConfirmed: source.trackURI == np.uri,
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
        // Defense-in-depth: never let a *move* delete from the target itself (the onTick
        // source==target guard already prevents reaching here in that case).
        if kind == .inTarget, settings.skipInTargetAlsoRemove,
           source.isEditablePlaylist, let src = source.playlistId,
           DiscoveryLogic.mayRemoveFromSource(sourcePlaylistId: src,
                                              targetPlaylistId: settings.targetPlaylistId,
                                              sourceTrackURI: source.trackURI, actedURI: uri, isMove: true) {
            Task { try? await provider.removeTrack(uri: uri, fromPlaylist: src) }
        }
        recordJudgment(uri: uri, sourceId: source.playlistId)

        actingTicks = 0
        setPhase(.acting, publish: .watching)
        transport.next()
    }

    /// The two judgment stores, always written together: the session-wide never-re-prompt
    /// set and the persisted per-source review history.
    private func recordJudgment(uri: String, sourceId: String?) {
        heldOrJudgedURIs.insert(uri)
        if let sid = sourceId { history.markReviewed(sourceId: sid, uri: uri) }
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
        // Auto-skip couldn't be evaluated when this track first appeared — its SourceContext lags
        // the track change by a tick, so `evaluateNewCandidate` saw an unconfirmed source and (
        // correctly) refused to skip. Re-check now that the source has confirmed, so an already-in-
        // target / already-reviewed track is skipped instead of held for its whole duration.
        if let kind = autoSkipKind(np, lastSource) { performAutoSkip(np, lastSource, kind: kind); return }
        // Poll-driven pause: if this fresh poll already shows we're within the lead window,
        // hold now rather than trusting the scheduled timer to fire on time.
        if np.durationSeconds > minHoldableDuration,
           (np.durationSeconds - np.positionSeconds) <= lead {
            invalidateTimer()
            transport.pause()
            enterHolding(expectedURI: np.uri, fallback: np)
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
        // The timer is armed up to a whole song earlier and fires independently of the poll
        // loop: re-check here so a hand-off to the phone since arming can't pause the phone.
        guard activeDeviceIsLocal() == true else { goIdle(); return }
        guard let live = provider.nowPlaying() else { return }
        if live.uri == uri {
            DebugLog.log("discovery: precise hold (timer) on \"\(live.name)\" pos=\(Int(live.positionSeconds))/\(Int(live.durationSeconds))s")
            transport.pause()
            enterHolding(expectedURI: uri, fallback: live)
        } else {
            // Missed the pre-emptive pause (latency/crossfade) and the track already advanced.
            // Reclaim the track we were watching rather than holding/skipping its successor.
            beginReclaim(expectedA: uri)
        }
    }

    /// Commit a hold, but only on a snapshot whose identity matches the track we intend to
    /// review. The held snapshot drives both the panel display and the Add/Remove/Skip URI, so
    /// it must never be the *successor* — which is what a now-playing read returns when our pause
    /// landed a hair too late and Spotify already advanced. In that case we paused the wrong track,
    /// so we recover the intended one (reclaim) instead of ever displaying/judging the wrong song.
    private func enterHolding(expectedURI: String, fallback: NowPlaying) {
        // Fresh read failed → conservative pre-pause snapshot (identity already verified).
        guard let fresh = provider.nowPlaying() else { commitHold(fallback); return }
        guard fresh.uri == expectedURI else {
            // We paused the successor, not the track we were reviewing. Step back to recover it.
            DebugLog.log("discovery: hold aborted — expected [\(expectedURI)] but now on \"\(fresh.name)\" [\(fresh.uri)]; reclaiming")
            beginReclaim(expectedA: expectedURI)
            return
        }
        // If the pause hasn't taken yet (still playing the expected track), re-issue it before
        // holding so we never commit a hold over live, still-advancing playback; the .holding
        // re-pin keeps it parked thereafter.
        if fresh.isPlaying { transport.pause() }
        commitHold(fresh)
    }

    private func commitHold(_ np: NowPlaying) {
        invalidateTimer()
        activeURI = np.uri
        DebugLog.log("discovery: HELD \"\(np.name)\" [\(np.uri)]")
        heldOrJudgedURIs.insert(np.uri)
        resetLoopProtection()                  // we found something worth reviewing
        setPhase(.holding(np.uri), publish: .held(HeldTrack(
            snapshot: np,
            canAdd: canAddNow(),
            // Freeze the provenance from the source confirmed FOR THIS track (nil if the source is
            // mid-resolution, e.g. just after a reclaim) so the panel never shows another playlist.
            sourceName: lastSource.trackURI == np.uri ? lastSource.playlistName : nil,
            targetName: targetName()
        )))
    }

    // MARK: - Held resolution (called by AppModel after curating)

    /// Mark the held track reviewed, advance, and resume the cycle. AppModel performs
    /// any add/remove with the explicit URI before/after calling this.
    func finishHold(judgedURI: String, sourceId: String?) {
        invalidateTimer()
        recordJudgment(uri: judgedURI, sourceId: sourceId)
        resetLoopProtection()
        activeURI = judgedURI
        actingTicks = 0
        // Judging is a user action on a track WE parked on this Mac, so advance unless playback
        // is CONFIRMED remote. A hand-off to a phone shows it as an active remote device →
        // locality reads `false` (blocked). A held song that's simply sat paused a while reads
        // `nil` (Spotify drops the active-device report; the "app is playing" fallback is false
        // while paused) — that's still local, so an aged-out flag must not strand playback.
        // Use provider.* directly: GuardedTransport gates on a confirmed-true flag and would
        // wrongly drop these on `nil`; the explicit `confirmedRemote` check is the guard here.
        let live = provider.nowPlaying()
        let confirmedRemote = activeDeviceIsLocal() == false
        if !confirmedRemote, live == nil || live?.uri == judgedURI {
            setPhase(.acting, publish: .watching)
            provider.next()
        } else if let live, live.uri != judgedURI {
            // A reclaim in flight may have parked the successor paused; judging resolves the
            // hold, so resume before evaluating it fresh — never leave a silent fake stop.
            if !confirmedRemote, !live.isPlaying { provider.play() }
            evaluateNewCandidate(live, lastSource)
        } else {
            setPhase(.watching, publish: .watching)   // confirmed remote: don't issue transport
        }
    }

    /// The user curated the *currently playing* track from the normal popover (not the held
    /// panel). Mark it judged so discovery neither holds it at its natural end nor reclaims
    /// the track that plays next — playback just advances on its own.
    func noteManualReview(uri: String, sourceId: String?) {
        guard settings.discoveryEnabled else { return }
        recordJudgment(uri: uri, sourceId: sourceId)
        if activeURI == uri {
            invalidateTimer()                // cancel any armed precise-pause for this track
            suppressReclaimForActive = true  // and don't reclaim whatever plays next
        }
    }

    /// The user drove transport from the app (Next/Previous). Don't reclaim the resulting
    /// advance — it's deliberate. Consumed on the next observed track change.
    func noteUserTransport() {
        suppressReclaimOnce = true
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
        suppressReclaimForActive = false
        suppressReclaimOnce = false
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
