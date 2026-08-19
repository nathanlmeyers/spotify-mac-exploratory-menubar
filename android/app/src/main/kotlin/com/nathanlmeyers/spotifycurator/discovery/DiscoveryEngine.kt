package com.nathanlmeyers.spotifycurator.discovery

import android.os.Handler
import android.os.Looper
import com.nathanlmeyers.spotifycurator.media.MediaWatcher
import com.nathanlmeyers.spotifycurator.model.NowPlaying
import com.nathanlmeyers.spotifycurator.model.SourceContext
import com.nathanlmeyers.spotifycurator.state.ReviewHistory
import com.nathanlmeyers.spotifycurator.state.Settings
import com.nathanlmeyers.spotifycurator.support.DebugLog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A track parked at its end, waiting to be judged. Frozen at the moment of the hold. */
data class HeldTrack(
    val uri: String,
    val name: String,
    val artist: String,
    val source: SourceContext,
)

sealed interface ReviewState {
    /** Discovery off, or nothing curatable playing. */
    data object Inactive : ReviewState

    /** A track is playing; counting down to a hold. */
    data object Watching : ReviewState

    /** Paused at the end of a track; show the judge controls. */
    data class Held(val track: HeldTrack) : ReviewState

    /** Loop protection tripped — everything left is seen or already in the target. */
    data object NothingNew : ReviewState
}

/**
 * Discovery mode: hold playback just before each track's natural end so it can be triaged.
 *
 * Port of the macOS `DiscoveryEngine`, and considerably smaller than it — for two reasons that
 * are worth stating, because they're why this isn't a line-for-line translation:
 *
 *  - **The Mac polls at 1 Hz; this is event-driven.** Most of the Swift engine's machinery
 *    (`acting` tick counting, poll-driven pause, re-arming against drift) exists to cope with a
 *    position reading that can be a whole second stale. Here `PlaybackState` gives exact position
 *    at any instant and every change arrives as a callback, so the timer is armed once and
 *    recomputed on real events instead of on a clock.
 *  - **Pause is a local binder call, not an Apple event.** The Mac needs a 1.3s lead to beat
 *    Apple-event latency. A binder call lands in single-digit milliseconds, so the lead is
 *    [LEAD_MS] — small enough that you hear the song essentially to its end.
 *
 * What is ported exactly is every rule that decides whether something gets skipped or deleted:
 * auto-skip never deletes, loop protection, never re-prompting a judged URI, and holding only on
 * a snapshot whose identity matches the track intended for review.
 */
class DiscoveryEngine(
    private val watcher: MediaWatcher,
    private val settings: Settings,
    private val history: ReviewHistory,
    /** URIs known to be in the target playlist. */
    private val targetMembership: () -> Set<String>,
    /** Whether playback is on this phone; null when it can't be told. See the locality guard. */
    private val deviceIsLocal: () -> Boolean?,
) {

    private val handler = Handler(Looper.getMainLooper())

    private val _state = MutableStateFlow<ReviewState>(ReviewState.Inactive)
    val state: StateFlow<ReviewState> = _state.asStateFlow()

    private enum class Phase { IDLE, WATCHING, RECLAIMING, HOLDING, ACTING, EXHAUSTED }

    private var phase = Phase.IDLE
    private var activeUri: String? = null
    private var heldTrack: HeldTrack? = null

    /** The last observation of the track under watch, used to classify how it left us. */
    private var lastNp: NowPlaying? = null

    /** The track we're trying to get back to, and how many attempts we've spent. */
    private var reclaimUri: String? = null
    private var reclaimAttempts = 0

    /** Session-wide "never prompt for this again", covering backward scrub and repeat. */
    private val heldOrJudgedUris = mutableSetOf<String>()

    /** URIs auto-skipped in the current sweep; a repeat means we've cycled with nothing new. */
    private val visitedThisSweep = mutableSetOf<String>()
    private var consecutiveAutoSkips = 0

    private var holdRunnable: Runnable? = null

    /** Called when a hold begins, so the UI layer can alert. */
    var onHoldBegan: ((HeldTrack) -> Unit)? = null

    /** Called when a hold resolves, so the UI layer can dismiss its alert. */
    var onHoldResolved: (() -> Unit)? = null

    // MARK: - Input

    /**
     * Called on every media change: new track, play/pause, seek.
     *
     * [source] must be the context resolved for *this* track — an unconfirmed source is what
     * `DiscoveryLogic.autoSkipKind` refuses to act on.
     */
    @Synchronized
    fun onMediaChanged(np: NowPlaying?, source: SourceContext) {
        currentSource = source
        if (!settings.discoveryEnabled || np == null || !np.kind.isCuratable) {
            // Logged because every one of these is a silent "discovery just didn't happen", and
            // without a line here the only symptom is a song that plays past its end.
            if (settings.discoveryEnabled && phase != Phase.IDLE) {
                DebugLog.log("discovery: idle — ${if (np == null) "nothing playing" else "not a track (${np.uri})"}")
            }
            goIdle()
            return
        }
        // Never run discovery on the target playlist itself: every track there is trivially
        // "already in target", so a sweep would skip the entire playlist.
        if (DiscoveryLogic.sourceIsTarget(source.playlistId, settings.targetPlaylistId)) {
            if (phase != Phase.IDLE) DebugLog.log("discovery: idle — listening to the target playlist itself")
            goIdle()
            return
        }

        val prev = lastNp
        lastNp = np

        when (phase) {
            Phase.HOLDING -> {
                // Playback moved while parked — the user picked something else in Spotify.
                // Release rather than fight them.
                if (np.uri != heldTrack?.uri) releaseHold()
            }

            Phase.RECLAIMING -> resolveReclaim(np, source)

            Phase.WATCHING -> when {
                np.uri == activeUri -> updateWatching(np, source)
                // The track we were watching left us. Crossfade and gapless playback both hand
                // over *before* the outgoing track's reported end, so the hold timer can still be
                // pending when the next song starts — and without this the song you actually
                // wanted to judge is silently gone, which is the one thing Discovery exists to
                // prevent. Only reclaim a genuine runoff; a mid-song change is the user choosing.
                shouldReclaim(prev) -> beginReclaim(activeUri!!)
                else -> evaluateCandidate(np, source)
            }

            Phase.EXHAUSTED -> {
                // A URI we haven't auto-skipped this sweep means there's something new again.
                if (np.uri !in visitedThisSweep) {
                    resetSweep()
                    evaluateCandidate(np, source)
                }
            }

            Phase.ACTING -> {
                if (np.uri != activeUri) evaluateCandidate(np, source)
            }

            Phase.IDLE -> if (np.uri != activeUri) evaluateCandidate(np, source)
        }
    }

    // MARK: - Reclaiming a track that slipped past the hold

    /**
     * Whether the departed track ran off its own end rather than being skipped deliberately.
     *
     * Delegates to the tested [DiscoveryLogic.shouldReclaimDeparture]: true only when the last
     * observation showed the expected track itself still *playing* near its end. A parked-paused
     * track that changed, or a change far from the end, is the user picking something else —
     * reclaiming there would fight them.
     */
    private fun shouldReclaim(prev: NowPlaying?): Boolean {
        val expected = activeUri ?: return false
        if (heldOrJudgedUris.contains(expected)) return false
        if (prev == null) return false
        return DiscoveryLogic.shouldReclaimDeparture(
            prevUri = prev.uri,
            // A track that stalled on its last few hundred milliseconds and then handed over is
            // still a runoff. Reading `isPlaying` alone classified it as a deliberate skip and
            // silently dropped the review we were seconds away from offering.
            prevWasPlaying = prev.isAdvancing,
            prevRemainingMs = prev.remainingMs,
            prevDurationMs = prev.durationMs,
            expectedUri = expected,
            crossfadeWindowMs = CROSSFADE_WINDOW_MS,
            minHoldableDurationMs = MIN_HOLDABLE_DURATION_MS,
        )
    }

    private fun beginReclaim(expectedUri: String) {
        cancelTimer()
        if (!transportAllowed("reclaim")) { goIdle(); return }
        reclaimUri = expectedUri
        reclaimAttempts = 0
        DebugLog.log("discovery: reclaiming $expectedUri — it advanced before the hold landed")
        setPhase(Phase.RECLAIMING, ReviewState.Watching)
        watcher.pause()
        // `skipToPrevious` restarts the *current* track when it's more than a few seconds in,
        // rather than going back — so with a long crossfade the first press can be absorbed.
        // That's what the retry below is for, and why it's bounded rather than a single attempt.
        watcher.skipToPrevious()
    }

    /**
     * Each media change while reclaiming: are we back on the wanted track yet?
     *
     * Bounded by [MAX_RECLAIM_ATTEMPTS] so a playlist that won't go backwards (shuffle, a queue
     * boundary, a track Spotify refuses to revisit) can't leave discovery pressing *previous*
     * forever.
     */
    private fun resolveReclaim(np: NowPlaying, source: SourceContext) {
        val wanted = reclaimUri ?: run { evaluateCandidate(np, source); return }

        if (np.uri == wanted) {
            // Back on it. Park it directly at the end rather than replaying the whole song.
            reclaimUri = null
            activeUri = wanted
            val target = (np.durationMs - LEAD_MS).coerceAtLeast(0)
            watcher.seekTo(target)
            watcher.pause()
            val held = HeldTrack(wanted, np.name, np.artist, currentSource)
            heldTrack = held
            setPhase(Phase.HOLDING, ReviewState.Held(held))
            DebugLog.log("discovery: reclaimed and held \"${np.name}\"")
            onHoldBegan?.invoke(held)
            return
        }

        if (++reclaimAttempts > MAX_RECLAIM_ATTEMPTS) {
            DebugLog.log("discovery: giving up reclaiming $wanted after $reclaimAttempts attempts")
            reclaimUri = null
            watcher.play()
            evaluateCandidate(np, source)
            return
        }
        watcher.skipToPrevious()
    }

    // MARK: - Candidate evaluation

    private fun evaluateCandidate(np: NowPlaying, source: SourceContext) {
        cancelTimer()
        activeUri = np.uri

        // Already held/judged this URI: never re-prompt.
        if (heldOrJudgedUris.contains(np.uri)) {
            setPhase(Phase.WATCHING, ReviewState.Watching)
            return
        }
        autoSkipKind(np, source)?.let { if (performAutoSkip(np, source, it)) return }

        setPhase(Phase.WATCHING, ReviewState.Watching)
        armHold(np)
    }

    private fun updateWatching(np: NowPlaying, source: SourceContext) {
        if (heldOrJudgedUris.contains(np.uri)) {
            cancelTimer()
            return
        }
        if (!np.isPlaying) {
            // A stall (BUFFERING/CONNECTING) is not a pause — Spotify reports them mid-track on a
            // weak connection, and disarming there left the hold off for the rest of the song.
            if (np.isStalled) return
            // Manual pause mid-song → cancel the scheduled hold; it re-arms when playback resumes.
            // Only a pause well before the end disarms; near the end, leave it armed.
            if (np.remainingMs > LEAD_MS + MANUAL_PAUSE_SLACK_MS) {
                DebugLog.log("discovery: disarmed \"${np.name}\" — paused with ${np.remainingMs}ms left")
                cancelTimer()
            }
            return
        }
        // The source lags the track change, so `evaluateCandidate` may have seen an unconfirmed
        // context and (correctly) refused to skip. Re-check now that it has confirmed, rather
        // than holding an already-reviewed track for its whole duration.
        autoSkipKind(np, source)?.let { if (performAutoSkip(np, source, it)) return }

        armHold(np) // re-arm against the fresh position: handles seek and resume
    }

    private fun autoSkipKind(np: NowPlaying, source: SourceContext): AutoSkipKind? =
        DiscoveryLogic.autoSkipKind(
            // The source must have been resolved for THIS track. Acting on a stale context
            // auto-skips the wrong songs.
            sourceConfirmed = source.trackUri == np.uri,
            inTarget = targetMembership().contains(np.uri),
            reviewed = source.playlistId?.let { history.hasReviewed(it, np.uri) } ?: false,
            skipIfInTarget = settings.skipIfInTarget,
            skipAlreadyReviewed = settings.skipAlreadyReviewed,
        )

    /**
     * Skip a track the rules say needs no review. Returns false when nothing happened, so the
     * caller falls through to watching it normally.
     *
     * The transport check comes first, and everything else hangs off it. `recordJudgment` used to
     * run unconditionally: on a remote Connect device the skip was suppressed but the URI was
     * persisted as reviewed anyway, so a track the user never saw would be auto-skipped for good
     * once playback came back to this phone.
     */
    private fun performAutoSkip(np: NowPlaying, source: SourceContext, kind: AutoSkipKind): Boolean {
        val uri = np.uri
        if (!transportAllowed("auto-skip")) return false
        // Loop protection: a repeated URI (cycled the sweep) or hitting the ceiling → stop.
        if (DiscoveryLogic.isExhausted(uri, visitedThisSweep, consecutiveAutoSkips, MAX_CONSECUTIVE_AUTO_SKIPS)) {
            goExhausted()
            return true
        }
        visitedThisSweep.add(uri)
        consecutiveAutoSkips++

        // Auto-skip SKIPS. It does not delete. Songs leave a playlist only when the user presses
        // Remove — see UserRemovalIntent, which is the enforcement of that rule. (On the Mac this
        // once also removed from the source under a "move" setting; run against the target
        // playlist it walked the playlist deleting songs. The setting is gone, not re-guarded.)
        recordJudgment(uri, source.playlistId)

        DebugLog.log("discovery: auto-skip (${kind.name.lowercase()}) \"${np.name}\"")
        setPhase(Phase.ACTING, ReviewState.Watching)
        cancelTimer()
        watcher.skipToNext()
        return true
    }

    /**
     * The two judgment stores, always written together: the session-wide never-re-prompt set and
     * the persisted per-source review history.
     */
    private fun recordJudgment(uri: String, sourceId: String?) {
        heldOrJudgedUris.add(uri)
        sourceId?.let { history.markReviewed(it, uri) }
    }

    /** Curating mid-song counts as judging: don't hold this track when it ends. */
    @Synchronized
    fun noteManualReview(uri: String, sourceId: String?) {
        recordJudgment(uri, sourceId)
        if (activeUri == uri) cancelTimer()
    }

    // MARK: - Hold scheduling

    private fun armHold(np: NowPlaying) {
        cancelTimer()
        // Don't trap on short interstitials, or on anything with no known end.
        if (np.durationMs <= MIN_HOLDABLE_DURATION_MS) {
            DebugLog.log("discovery: not arming \"${np.name}\" — duration ${np.durationMs}ms too short/unknown")
            return
        }
        val fireIn = (np.remainingMs - LEAD_MS).coerceAtLeast(0)
        val uri = np.uri
        val runnable = Runnable { fireHold(uri) }
        holdRunnable = runnable
        handler.postDelayed(runnable, fireIn)
        // Only log a *material* change in the target time. Spotify emits position updates
        // frequently and each one re-arms; logging every one would bury everything else.
        if (kotlin.math.abs(fireIn - lastArmedFireIn) > 2_000) {
            DebugLog.log("discovery: armed \"${np.name}\" — hold in ${fireIn}ms (pos=${np.positionMs}/${np.durationMs})")
        }
        lastArmedFireIn = fireIn
    }

    private var lastArmedFireIn = Long.MIN_VALUE

    private fun cancelTimer() {
        holdRunnable?.let(handler::removeCallbacks)
        holdRunnable = null
    }

    @Synchronized
    private fun fireHold(expectedUri: String) {
        if (phase != Phase.WATCHING || activeUri != expectedUri) {
            DebugLog.log("discovery: hold skipped — phase=$phase active=$activeUri expected=$expectedUri")
            return
        }
        if (heldOrJudgedUris.contains(expectedUri)) {
            DebugLog.log("discovery: hold skipped — $expectedUri already judged")
            return
        }
        if (!transportAllowed("hold")) { goIdle(); return }

        // A *fresh* read. This decides which song gets parked, and it must be the track we
        // intended to review — never its successor, which is what a read returns if the pause
        // would land a hair too late and Spotify has already advanced.
        val live = watcher.localSnapshot()
        if (live == null || live.nowPlaying.uri != expectedUri) {
            // The pause would land on the successor. Go back for the track we meant to review
            // rather than parking the wrong song — see beginReclaim.
            DebugLog.log("discovery: hold missed — track already advanced past $expectedUri")
            beginReclaim(expectedUri)
            return
        }

        watcher.pause()
        val held = HeldTrack(
            uri = expectedUri,
            name = live.nowPlaying.name,
            artist = live.nowPlaying.artist,
            source = currentSource,
        )
        heldTrack = held
        setPhase(Phase.HOLDING, ReviewState.Held(held))
        DebugLog.log("discovery: held \"${held.name}\" at ${live.nowPlaying.positionMs}/${live.nowPlaying.durationMs}ms")
        onHoldBegan?.invoke(held)
    }

    /** The source context as of the last media change; frozen into a hold. */
    private var currentSource: SourceContext = SourceContext.NONE

    // MARK: - Resolving a hold

    /**
     * The held track, for a judge action. Returns null when nothing is held.
     *
     * The caller freezes this and acts on it: playback advances first, then the curation action
     * runs against the frozen snapshot, so nothing it observes afterwards can redirect the edit.
     * Same ordering as the macOS `resolveHeld`.
     */
    @Synchronized
    fun heldForJudging(): HeldTrack? = heldTrack.takeIf { phase == Phase.HOLDING }

    /** Records the judgment and advances playback. Call after freezing [heldForJudging]. */
    @Synchronized
    fun finishHold(judgedUri: String, sourceId: String?) {
        recordJudgment(judgedUri, sourceId)
        heldTrack = null
        // A deliberate judgment means the sweep is making progress again.
        consecutiveAutoSkips = 0
        setPhase(Phase.ACTING, ReviewState.Watching)
        onHoldResolved?.invoke()
        if (heldTransportAllowed("resolve hold")) {
            watcher.skipToNext()
            watcher.play()
        }
    }

    /** Let a held track go without judging it — the user moved on in Spotify. */
    private fun releaseHold() {
        heldTrack = null
        setPhase(Phase.WATCHING, ReviewState.Watching)
        onHoldResolved?.invoke()
    }

    // MARK: - Phase plumbing

    private fun setPhase(next: Phase, publish: ReviewState) {
        phase = next
        _state.value = publish
    }

    private fun goIdle() {
        cancelTimer()
        if (phase == Phase.HOLDING) onHoldResolved?.invoke()
        heldTrack = null
        activeUri = null
        reclaimUri = null
        reclaimAttempts = 0
        lastNp = null
        setPhase(Phase.IDLE, ReviewState.Inactive)
    }

    private fun goExhausted() {
        cancelTimer()
        DebugLog.log("discovery: nothing new to review in this playlist")
        setPhase(Phase.EXHAUSTED, ReviewState.NothingNew)
    }

    private fun resetSweep() {
        visitedThisSweep.clear()
        consecutiveAutoSkips = 0
    }

    /** Starting a new sweep (playlist change, discovery re-enabled), or switching discovery off. */
    @Synchronized
    fun reset() {
        cancelTimer()
        // A held track is playback we deliberately stopped. Clearing the phase without resuming
        // would leave Spotify paused a fraction of a second from the end of a song, with the
        // held controls gone and nothing left in the app that could free it — the user's only
        // recourse being to press play in Spotify and wonder what happened.
        if (phase == Phase.HOLDING) {
            onHoldResolved?.invoke()
            if (heldTransportAllowed("resume after reset")) watcher.play()
        }
        resetSweep()
        heldOrJudgedUris.clear()
        heldTrack = null
        activeUri = null
        reclaimUri = null
        reclaimAttempts = 0
        lastNp = null
        setPhase(Phase.IDLE, ReviewState.Inactive)
    }

    /**
     * The locality guard, ported from `SpotifyProvider.resolveLocality` + `GuardedTransport`.
     *
     * Spotify's Android app publishes a MediaSession even when it is only *remote-controlling* a
     * Connect speaker, so a live local session is not proof the audio is here. Issuing a pause
     * against a remote device would stop music in another room. Only a confirmed-local device
     * gets transport; unknown is treated as "don't".
     */
    private fun transportAllowed(what: String): Boolean {
        when (deviceIsLocal()) {
            true -> return true
            false -> {
                DebugLog.log("discovery: suppressed $what — playback is on a remote Connect device")
                return false
            }
            null -> {
                // Unknown. The macOS original has the same fallback and it matters more here: if
                // Spotify simply doesn't populate PlaybackInfo, a strict rule would make discovery
                // silently never fire, which reads as "the feature is broken" rather than "it is
                // being careful". A hand-off to another device shows up as an explicit REMOTE, so
                // its *absence* while a session is actively playing means the audio is here.
                val playing = watcher.nowPlaying.value?.isAdvancing == true
                if (playing) {
                    DebugLog.log("discovery: $what — no playback-type info; local session is playing, treating as local")
                    return true
                }
                DebugLog.log("discovery: suppressed $what — playback location unknown and nothing playing")
                return false
            }
        }
    }

    /**
     * The looser guard for transport that resolves a hold *we* placed on this phone.
     *
     * [transportAllowed]'s "unknown counts as remote unless something is playing" fallback is
     * right for arming and skipping, and wrong here: we just paused this track ourselves, so
     * nothing is playing by construction. Applying the strict rule to a session with no
     * PlaybackInfo meant Add / Remove / Skip moved the phase to ACTING and then issued no
     * transport at all — Spotify sat paused a fraction of a second from the end of a song with
     * no held controls left to free it. Only a *confirmed* remote device blocks; unknown, on a
     * track this engine parked, is local. Same reasoning as the macOS `finishHold`.
     */
    private fun heldTransportAllowed(what: String): Boolean {
        if (deviceIsLocal() == false) {
            DebugLog.log("discovery: suppressed $what — playback is on a remote Connect device")
            return false
        }
        return true
    }

    private companion object {
        /**
         * How far before the natural end to pause.
         *
         * The Mac uses 1300ms to beat Apple-event latency on a 1 Hz poll. A binder
         * `transportControls.pause()` against an exactly-known position needs far less; this is
         * deliberately a little generous to absorb Spotify's own gapless/crossfade handoff.
         */
        const val LEAD_MS = 400L

        /** Below this, a track is an interstitial and holding it would just be a trap. */
        const val MIN_HOLDABLE_DURATION_MS = 3_000L

        /**
         * How far from the end a pause still counts as "near the end" and leaves the hold armed.
         * Ported from the macOS `manualPauseSlack`.
         */
        const val MANUAL_PAUSE_SLACK_MS = 1_500L

        const val MAX_CONSECUTIVE_AUTO_SKIPS = 25

        /**
         * How close to the end still counts as a natural runoff rather than a deliberate skip.
         * Wide enough to cover Spotify's maximum crossfade (12s), so every auto-advance qualifies.
         */
        const val CROSSFADE_WINDOW_MS = 13_000L

        /** Bounded so a playlist that won't rewind can't leave us pressing *previous* forever. */
        const val MAX_RECLAIM_ATTEMPTS = 2
    }
}
