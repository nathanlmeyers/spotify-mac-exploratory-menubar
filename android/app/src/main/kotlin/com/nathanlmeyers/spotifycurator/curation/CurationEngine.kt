package com.nathanlmeyers.spotifycurator.curation

import android.content.Context
import com.nathanlmeyers.spotifycurator.api.SpotifyApi
import com.nathanlmeyers.spotifycurator.auth.SpotifyAuth
import com.nathanlmeyers.spotifycurator.discovery.DiscoveryEngine
import com.nathanlmeyers.spotifycurator.discovery.DiscoveryLogic
import com.nathanlmeyers.spotifycurator.discovery.HeldTrack
import com.nathanlmeyers.spotifycurator.discovery.ReviewState
import com.nathanlmeyers.spotifycurator.state.ReviewHistory
import com.nathanlmeyers.spotifycurator.media.MediaMetadataMapping
import com.nathanlmeyers.spotifycurator.media.MediaWatcher
import com.nathanlmeyers.spotifycurator.model.NowPlaying
import com.nathanlmeyers.spotifycurator.model.Playlist
import com.nathanlmeyers.spotifycurator.model.SourceContext
import com.nathanlmeyers.spotifycurator.state.Settings
import com.nathanlmeyers.spotifycurator.support.DebugLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Everything the notification and the UI need to render, in one snapshot. */
data class CuratorState(
    val nowPlaying: NowPlaying? = null,
    val source: SourceContext = SourceContext.NONE,
    /** True when the currently-playing track is already in the target playlist. */
    val inTarget: Boolean = false,
    val status: String? = null,
    val isError: Boolean = false,
    val isBusy: Boolean = false,
    /** Discovery mode's review state; [ReviewState.Held] is what turns the row into a verdict. */
    val review: ReviewState = ReviewState.Inactive,
)

/**
 * The curation core: Add / Remove / Skip against the target and source playlists.
 * Port of the macOS `AppModel`'s curation half plus `SpotifyProvider`.
 */
class CurationEngine private constructor(context: Context) {

    val auth = SpotifyAuth.get(context)
    val api = SpotifyApi(auth)
    val settings = Settings.get(context)
    val watcher = MediaWatcher(context)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Held for the whole of one curation action — see [withActionLock]. */
    private val actionLock = Mutex()

    /** Serializes full membership loads with Add/Remove mutations of the same cache. */
    private val membershipLock = Mutex()

    private val _state = MutableStateFlow(CuratorState())
    val state: StateFlow<CuratorState> = _state.asStateFlow()

    // User-scoped caches — cleared on logout so accounts can't leak into each other.
    private var cachedUserId: String? = null
    private val cachedPlaylistInfo = mutableMapOf<String, Playlist>()

    /** URIs known to be in the target playlist; the duplicate guard for Add. */
    @Volatile private var targetMembership: Set<String> = emptySet()

    val history = ReviewHistory.get(context)

    val discovery = DiscoveryEngine(
        watcher = watcher,
        settings = settings,
        history = history,
        targetMembership = { targetMembership },
        deviceIsLocal = { watcher.isPlaybackLocal() },
    )

    init {
        watcher.onChanged = { onMediaChanged() }
        scope.launch {
            discovery.state.collect { review ->
                _state.update { it.copy(review = review) }
            }
        }
        // Seed the duplicate guard from disk so Add says "Already in <target>" on the very first
        // press after a cold start, before the playlist fetch has come back.
        settings.targetPlaylistId?.let { target ->
            history.cachedMembership(target)?.let { targetMembership = it }
        }
    }

    // MARK: - Media

    private var lastIdentity: String? = null

    /**
     * The playback context the published source was resolved against.
     *
     * Tracked separately from the track identity because the two change independently: starting
     * the *same* song from a different playlist leaves the URI untouched, so keying only off
     * identity kept the previous playlist standing as a confirmed source — and a held Remove
     * would then delete the track out of the playlist the user had just left.
     */
    private var lastContextUri: String? = null
    private var sourceJob: Job? = null

    private fun onMediaChanged() {
        val np = watcher.nowPlaying.value
        _state.update { it.copy(nowPlaying = np) }
        val identity = np?.identity
        val contextUri = watcher.localSnapshot()?.contextUri
        if (identity != lastIdentity || contextUri != lastContextUri) {
            lastIdentity = identity
            lastContextUri = contextUri
            // Clear the stale source immediately: rendering "Remove from <previous playlist>"
            // for the new track is exactly the confusion that leads to a wrong deletion.
            _state.update { it.copy(source = SourceContext.NONE, inTarget = false, status = null) }
            // Cancel any in-flight resolve for the previous track: its answer is worthless now,
            // and letting it run just burns an API call against the rate limit.
            sourceJob?.cancel()
            if (identity != null) {
                sourceJob = scope.launch {
                    refreshSource(identity, contextUri)
                    feedDiscovery()
                }
            } else {
                feedDiscovery()
            }
        } else {
            // Same track and same context, but play/pause/seek changed — discovery re-arms its
            // hold off this.
            feedDiscovery()
        }
    }

    /**
     * Push the current state into discovery without waiting for a media event.
     *
     * Needed when discovery is switched on mid-song: nothing changes in Spotify at that moment,
     * so no callback arrives, and without this the song playing right now would never be held —
     * the feature would look broken until the next track.
     */
    fun refreshDiscovery() = feedDiscovery()

    /**
     * The one way to flip Discovery, shared by the settings screen and the notification's toggle.
     *
     * The [DiscoveryEngine.reset] is not optional: switching off mid-hold is the common case (the
     * music stopping is what makes you want it off), and reset is what resumes the track this
     * engine deliberately parked. Without it Spotify sits paused a fraction of a second from the
     * end of a song with no held controls left to free it.
     */
    fun setDiscoveryEnabled(enabled: Boolean) {
        settings.discoveryEnabled = enabled
        discovery.reset()
        // Arm against the song already playing, rather than waiting for the next one.
        refreshDiscovery()
    }

    private fun feedDiscovery() {
        val s = _state.value
        discovery.onMediaChanged(s.nowPlaying, s.source)
    }

    // MARK: - Source resolution

    /**
     * Resolve what the current track is playing *from*.
     *
     * Prefers Spotify's own `CONTEXT_URI` metadata extra, which costs no network call at all;
     * falls back to `GET /me/player` when it's absent. Port of
     * `SpotifyProvider.currentSourceAndArtists`, minus most of the traffic.
     */
    private suspend fun refreshSource(
        forIdentity: String? = _state.value.nowPlaying?.identity,
        forContextUri: String? = watcher.localSnapshot()?.contextUri,
    ) {
        // The track this resolve is for. Everything below is slow enough that the song can change
        // underneath it, and publishing a stale source is not cosmetic: Discovery freezes the
        // source into a hold, and `mayRemoveFromSource` would then refuse the removal (or, if the
        // stale source happened to match, aim it at the wrong playlist).
        resolveFromLocalMetadata()?.let { resolved ->
            publishSource(resolved, forIdentity, forContextUri)
            return
        }

        val resolved = try {
            resolveFromPlayer()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Keep the last-known source rather than blanking it: a failed resolve otherwise
            // reads as "not a playlist", which greys out Remove for no reason. Matches the
            // macOS behaviour of holding the source across a rate-limit.
            DebugLog.log("source resolve failed: ${e.message}")
            return
        }

        publishSource(resolved, forIdentity, forContextUri)
    }

    /** Publish a resolved source, unless the track or its playback context moved on. */
    private fun publishSource(resolved: Resolved, forIdentity: String?, forContextUri: String?) {
        val currentIdentity = _state.value.nowPlaying?.identity
        val currentContextUri = watcher.localSnapshot()?.contextUri
        if (forIdentity != currentIdentity || forContextUri != currentContextUri) {
            DebugLog.log(
                "source resolve discarded — playback changed from " +
                    "$forIdentity / $forContextUri to $currentIdentity / $currentContextUri"
            )
            return
        }
        _state.update {
            it.copy(
                source = resolved.source,
                inTarget = resolved.trackUri != null && targetMembership.contains(resolved.trackUri),
            )
        }
    }

    private data class Resolved(val source: SourceContext, val trackUri: String?)

    /**
     * Source context from Spotify's media metadata alone — no network.
     *
     * Returns null only when the local read can't answer at all (no session, no track URI, or
     * Spotify didn't publish its context extras), which is the signal to fall back to the API. A
     * non-playlist context (album, artist, Liked Songs) is a real answer: [SourceContext.NONE],
     * meaning nothing to remove from.
     *
     * The track URI and the context come from one atomic `MediaMetadata`, so they describe the
     * same instant by construction — the property the macOS app gets from its atomic
     * `playbackSnapshot()`, and the reason this needs no confirming round trip.
     */
    private suspend fun resolveFromLocalMetadata(): Resolved? {
        val local = watcher.localSnapshot() ?: return null
        val trackUri = local.nowPlaying.uri.takeIf { it.isNotEmpty() } ?: return null
        val contextUri = local.contextUri ?: return null

        val playlistId = MediaMetadataMapping.playlistIdFromContextUri(contextUri)
            ?: return Resolved(SourceContext.NONE, trackUri) // album / artist / Liked Songs

        // Editability still needs the Web API (owner + collaborative), but it's cached per
        // playlist and per session, so this costs nothing after the first track from a playlist.
        val info = runCatching { playlistInfo(playlistId) }.getOrElse {
            DebugLog.log("playlist info failed for $playlistId: ${it.message}")
            return null // let the caller fall back rather than guess at editability
        }
        val me = runCatching { currentUserId() }.getOrElse { return null }

        return Resolved(
            SourceContext(
                playlistId = playlistId,
                playlistName = local.contextTitle ?: info.name,
                isEditablePlaylist = info.isEditable(me),
                trackUri = trackUri,
            ),
            trackUri,
        )
    }

    private suspend fun resolveFromPlayer(): Resolved {
        val cp = api.currentContext() ?: return Resolved(SourceContext.NONE, null)
        if (cp.contextType != "playlist" || cp.contextUri == null) {
            // album / artist / liked songs / queue — nothing removable.
            return Resolved(SourceContext.NONE, cp.trackUri)
        }
        val id = cp.contextUri.substringAfterLast(':')
        if (id.isEmpty()) return Resolved(SourceContext.NONE, cp.trackUri)

        val info = playlistInfo(id)
        return Resolved(
            SourceContext(
                playlistId = id,
                playlistName = info.name,
                isEditablePlaylist = info.isEditable(currentUserId()),
                trackUri = cp.trackUri,
            ),
            cp.trackUri,
        )
    }

    /**
     * Playlist metadata, cached per session — the source is re-resolved on every track change,
     * so an uncached read would refetch the same playlist once per song.
     */
    private suspend fun playlistInfo(id: String): Playlist =
        cachedPlaylistInfo[id] ?: api.playlistInfo(id).also { cachedPlaylistInfo[id] = it }

    suspend fun currentUserId(): String =
        cachedUserId ?: api.currentUserId().also {
            cachedUserId = it
            DebugLog.log("me.id = $it")
        }

    suspend fun editablePlaylists(): List<Playlist> {
        val me = currentUserId()
        val all = api.allPlaylists()
        all.forEach { cachedPlaylistInfo[it.id] = it }
        val editable = all.filter { it.isEditable(me) }
        DebugLog.log("playlists: total=${all.size} editable=${editable.size} me=$me")
        return editable
    }

    /**
     * The playlists the target picker offers. Engine-level rather than screen-level so the list
     * survives an Activity restart: on the Mac this is `AppModel.editablePlaylists`, and the panel
     * fills it on open. Android had it in Compose state, so it was empty at every launch and the
     * picker showed nothing to tap — leaving no target set, which is the one thing Add requires.
     */
    private val _playlists = MutableStateFlow<List<Playlist>>(emptyList())
    val playlists: StateFlow<List<Playlist>> = _playlists.asStateFlow()

    /**
     * Fetch the picker's list, at most once per login unless [force]d. Port of the Mac's
     * `AppModel.loadPlaylists`, called on the same trigger the Mac uses (the UI becoming visible
     * while authorized) rather than waiting for a button nobody knows they have to press.
     */
    suspend fun loadPlaylists(force: Boolean = false): Result<Unit> {
        if (!auth.state.value.isAuthorized) return Result.success(Unit)
        if (!force && _playlists.value.isNotEmpty()) return Result.success(Unit)
        return runCatching { editablePlaylists() }
            .onSuccess { _playlists.value = it }
            .onFailure {
                DebugLog.log("playlist load failed: ${it.message}")
                setStatus("Couldn't load playlists: ${it.message}", isError = true)
            }
            .map { }
    }

    /** The target whose membership [targetMembership] describes. */
    private var membershipTargetId: String? = null

    /** Switch the in-memory view to [target] while [membershipLock] is held. */
    private fun selectMembershipTarget(target: String) {
        if (membershipTargetId == target) return
        targetMembership = history.cachedMembership(target).orEmpty()
        membershipTargetId = target
    }

    suspend fun loadTargetMembership() {
        val didLoad = membershipLock.withLock {
            val target = settings.targetPlaylistId ?: run {
                targetMembership = emptySet()
                membershipTargetId = null
                return@withLock false
            }
            // Drop a *different* playlist's membership immediately rather than letting it stand
            // until the fetch returns. Otherwise Add can consult the previous target's contents.
            selectMembershipTarget(target)

            val loaded = try {
                api.playlistTrackUris(target)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                DebugLog.log("target membership load failed: ${e.message}")
                return@withLock false
            }

            // Two loads can be in flight (switch target, switch back) and finish out of order.
            // Holding membershipLock also means an Add or Remove cannot edit the cache between
            // the fetch and this replacement.
            if (settings.targetPlaylistId != target) {
                DebugLog.log("target membership for $target discarded — target changed while loading")
                return@withLock false
            }
            targetMembership = loaded
            membershipTargetId = target
            history.setMembership(target, loaded)
            DebugLog.log("target membership: ${loaded.size} tracks")
            true
        }
        // Source refresh can perform unrelated playlist/user lookups; don't block Add behind it.
        if (didLoad) refreshSource()
    }

    fun logout() {
        auth.logout()
        cachedUserId = null
        cachedPlaylistInfo.clear()
        _playlists.value = emptyList()
        targetMembership = emptySet()
        membershipTargetId = null
        _state.update { CuratorState(nowPlaying = it.nowPlaying) }
    }

    // MARK: - Action target

    /**
     * What Add/Remove should act on, established by one fresh `GET /me/player`.
     *
     * This is the Android replacement for the Mac's cross-check. There, the track URI comes from
     * ScriptingBridge and the playlist context from the Web API, so `sourceTrackURI == actedURI`
     * compares two independent sources. Here Spotify's MediaSession isn't guaranteed to carry a
     * URI at all, so both would come from the same place and that check would be vacuous.
     *
     * Instead: take one fresh `/me/player` read (internally consistent — its `item` and `context`
     * describe the same instant) and cross-check *it* against what the local session says is
     * playing. A mismatch means playback moved, or a Connect device is playing something else,
     * and we refuse rather than act on the wrong track.
     */
    private suspend fun resolveActionTarget(): Result<ActionTarget> {
        // Fast path: Spotify's metadata carries both the track URI and the playback context in
        // one atomic object, so there is nothing to cross-check and nothing to wait for. This is
        // most presses — it turns a ~1.4s Remove into roughly half of that.
        resolveFromLocalMetadata()?.let { resolved ->
            val uri = resolved.trackUri
            if (uri != null && NowPlaying.classify(uri).isCuratable) {
                _state.update { it.copy(source = resolved.source) }
                return Result.success(ActionTarget(uri, resolved.source))
            }
            if (uri != null) {
                return Result.failure(IllegalStateException("Only songs can be added or removed."))
            }
        }

        // Slow path: Spotify didn't publish its context extras (or the playlist lookup failed).
        val local = watcher.snapshot()
        val cp = api.currentContext()
            ?: return Result.failure(IllegalStateException("Nothing is playing right now."))
        val uri = cp.trackUri
            ?: return Result.failure(IllegalStateException("Spotify didn't say what's playing."))

        if (local != null && !confirms(local, uri, cp.artistNames)) {
            DebugLog.log("action refused: local session (${local.uri} ${local.name} / ${local.artist}) != /me/player ($uri, ${cp.artistNames})")
            return Result.failure(IllegalStateException("Couldn't confirm what's playing — try again."))
        }

        if (!NowPlaying.classify(uri).isCuratable) {
            return Result.failure(IllegalStateException("Only songs can be added or removed."))
        }

        val source = if (cp.contextType == "playlist" && cp.contextUri != null) {
            val id = cp.contextUri.substringAfterLast(':')
            if (id.isEmpty()) SourceContext.NONE else {
                val info = playlistInfo(id)
                SourceContext(id, info.name, info.isEditable(currentUserId()), uri)
            }
        } else {
            SourceContext.NONE
        }

        _state.update { it.copy(source = source) }
        return Result.success(ActionTarget(uri, source))
    }

    private data class ActionTarget(val uri: String, val source: SourceContext)

    /**
     * Whether the local session agrees with `/me/player` about what is playing.
     *
     * Exact URIs whenever the local session publishes one — that is the whole cross-check, and
     * anything looser is not a check at all: two songs by the same artist pass an artist compare,
     * so an advance between the local read and `/me/player` would let Add/Remove act on the
     * successor. Artist matching is the fallback for the sessions that carry no URI (Android's
     * `MediaMetadata` is not obliged to), where it is the only signal there is.
     */
    private fun confirms(local: NowPlaying, apiUri: String, apiArtists: List<String>): Boolean {
        if (local.uri.isNotEmpty()) return local.uri == apiUri
        return matches(local, apiArtists)
    }

    /**
     * Loose match between the local session and the Web API's view, for a session with no URI.
     *
     * Only the artist is compared: Spotify's MediaSession title and the Web API track name agree
     * for plain tracks but diverge on remasters and "- Live" suffixes across markets, and a false
     * refusal is a broken button. The artist list is the stable half.
     */
    private fun matches(local: NowPlaying, apiArtists: List<String>): Boolean {
        if (apiArtists.isEmpty() || local.artist.isBlank()) return true // nothing to compare
        val localArtists = local.artist.split(",", "&", " and ").map { it.trim().lowercase() }
            .filter { it.isNotEmpty() }
        val remote = apiArtists.map { it.trim().lowercase() }
        return localArtists.any { l -> remote.any { r -> r == l || r.contains(l) || l.contains(r) } }
    }

    // MARK: - Curation actions (the only callers that may construct a UserRemovalIntent)

    /**
     * Run one curation action, or nothing at all if one is already running.
     *
     * Deliberately **drops** the second press rather than queueing it, which is what
     * `Mutex.withLock` did. With "skip to next after Remove" on — the default — the first press
     * removes the song and advances; the queued press then woke up, resolved the track that was
     * now playing, and removed that one too. One double-tap, two songs gone. A stale lock-screen
     * notification makes it easy to do by accident, and the rule this app is built around is that
     * nothing leaves a playlist without a press meant for it (see [UserRemovalIntent]).
     */
    private suspend fun withActionLock(what: String, block: suspend () -> Unit) {
        if (!actionLock.tryLock()) {
            DebugLog.log("gesture: dropped $what — a curation action is still running")
            return
        }
        try {
            block()
        } finally {
            actionLock.unlock()
        }
    }

    fun onAddPressed() = scope.launch {
        withActionLock("Add") {
            if (resolveHeld { uri, src -> performAdd(uri, src) } != null) return@withActionLock
            curate { target ->
                // Curating mid-song counts as judging this track: don't let discovery hold it when
                // it ends — let playback advance naturally.
                discovery.noteManualReview(target.uri, target.source.playlistId)
                val ok = performAdd(target.uri, target.source)
                if (ok && settings.skipToNextAfterAdd) watcher.skipToNext()
            }
        }
    }

    fun onRemovePressed() = scope.launch {
        withActionLock("Remove") {
            val held = resolveHeld { uri, src ->
                performRemoveFromSource(uri, src, UserRemovalIntent.heldPanelRemoveButton())
            }
            if (held != null) return@withActionLock

            curate { target ->
                discovery.noteManualReview(target.uri, target.source.playlistId)
                val ok = performRemoveFromSource(target.uri, target.source, UserRemovalIntent.removeButton())
                if (ok && settings.skipToNextAfterRemove) watcher.skipToNext()
            }
        }
    }

    /**
     * Resolve what to act on, run [action] against it, and clear the busy flag whatever happens.
     *
     * The `finally` is the point. `resolveActionTarget` can *throw* as well as return a failure —
     * `api.currentContext()` and the playlist lookups raise on HTTP errors, a local rate-limit
     * refusal, or a dropped connection — and a throw used to escape past `busy(false)`. `isBusy`
     * then stayed true forever, and that flag is what `CuratorNotification` greys `+` and `−` on:
     * one failed press and the buttons went dead until the process restarted.
     */
    private suspend fun curate(action: suspend (ActionTarget) -> Unit) {
        busy(true)
        try {
            val target = runCatching { resolveActionTarget().getOrThrow() }
                .getOrElse { setStatus(it.message, isError = true); return }
            action(target)
        } finally {
            busy(false)
        }
    }

    fun onSkipPressed() = scope.launch {
        withActionLock("Skip") {
            // A skip while held is a verdict of "neither" — record it so the track isn't re-offered.
            discovery.heldForJudging()?.let { held ->
                discovery.finishHold(held.uri, held.source.playlistId)
                setStatus("Skipped")
                return@withActionLock
            }
            watcher.skipToNext()
        }
    }

    /**
     * If a track is parked by discovery, judge it and run [action] against the **frozen** snapshot.
     *
     * Ordering matters and is taken from the macOS `resolveHeld`: playback advances first, then
     * the curation action runs against the URI and source captured at the moment of the hold. So
     * nothing observed after the advance — a new track, a new context — can redirect the edit.
     *
     * Returns null when nothing is held, so callers fall through to the normal path.
     */
    private suspend fun resolveHeld(action: suspend (String, SourceContext) -> Boolean): Unit? {
        val held: HeldTrack = discovery.heldForJudging() ?: return null
        busy(true)
        try {
            discovery.finishHold(held.uri, held.source.playlistId)
            action(held.uri, held.source)
        } finally {
            busy(false)
        }
        return Unit
    }

    /** Returns true when the track ended up in (or was already in) the target. */
    private suspend fun performAdd(uri: String, sourceCtx: SourceContext): Boolean {
        val target = settings.targetPlaylistId ?: run {
            setStatus("No target playlist set — pick one in the app.", isError = true)
            return false
        }
        val targetName = settings.targetPlaylistName ?: "target"
        return try {
            membershipLock.withLock {
                // A target selection and this coroutine can race. Never consult the previous
                // target's set while the new target's full load is still waiting to start.
                selectMembershipTarget(target)
                if (targetMembership.contains(uri)) {
                    setStatus("Already in $targetName")
                } else {
                    api.addTrack(uri, target)
                    targetMembership = targetMembership + uri
                    history.addToMembership(target, uri)
                    _state.update { it.copy(inTarget = true) }
                    setStatus("Added to $targetName")
                }
            }
            // Move semantics: also remove from source when enabled & editable — but never delete
            // from the target itself, and only when the source was resolved for THIS track (a
            // stale source must not delete the wrong track from the wrong playlist).
            val src = sourceCtx.playlistId
            if (settings.removeFromSourceOnAdd && sourceCtx.isEditablePlaylist && src != null &&
                DiscoveryLogic.mayRemoveFromSource(
                    sourcePlaylistId = src,
                    targetPlaylistId = settings.targetPlaylistId,
                    sourceTrackUri = sourceCtx.trackUri,
                    actedUri = uri,
                    isMove = true,
                )
            ) {
                api.removeTrack(uri, src, UserRemovalIntent.addButtonMove())
                setStatus("Moved to $targetName")
            }
            true
        } catch (e: Exception) {
            setStatus("Add failed: ${e.message}", isError = true)
            false
        }
    }

    /**
     * Returns true when the track was removed from the source playlist.
     * [intent] is the user gesture that authorized this — see [UserRemovalIntent].
     */
    private suspend fun performRemoveFromSource(
        uri: String,
        sourceCtx: SourceContext,
        intent: UserRemovalIntent,
    ): Boolean {
        val src = sourceCtx.playlistId
        if (!sourceCtx.isEditablePlaylist || src == null) {
            setStatus("This isn't playing from a playlist you can edit.", isError = true)
            return false
        }
        // Only remove when the source context was resolved for THIS exact track. If the source
        // is stale, refuse rather than delete the wrong track from the wrong playlist.
        if (!DiscoveryLogic.mayRemoveFromSource(
                sourcePlaylistId = src,
                targetPlaylistId = settings.targetPlaylistId,
                sourceTrackUri = sourceCtx.trackUri,
                actedUri = uri,
                isMove = false,
            )
        ) {
            setStatus("Couldn't confirm this track's playlist — try again.", isError = true)
            return false
        }
        val name = sourceCtx.playlistName ?: "playlist"
        return try {
            if (src == settings.targetPlaylistId) {
                membershipLock.withLock {
                    selectMembershipTarget(src)
                    api.removeTrack(uri, src, intent)
                    targetMembership = targetMembership - uri
                    history.removeFromMembership(src, uri)
                    _state.update { it.copy(inTarget = false) }
                }
            } else {
                api.removeTrack(uri, src, intent)
            }
            DebugLog.log("REMOVE ok $uri")
            setStatus("Removed from $name")
            true
        } catch (e: Exception) {
            DebugLog.log("REMOVE FAILED $uri: ${e.message}")
            setStatus("Remove failed: ${e.message}", isError = true)
            false
        }
    }

    private fun setStatus(message: String?, isError: Boolean = false) {
        DebugLog.log("status: $message")
        _state.update { it.copy(status = message, isError = isError) }
    }

    private fun busy(value: Boolean) {
        _state.update { it.copy(isBusy = value) }
    }

    companion object {
        @Volatile private var instance: CurationEngine? = null

        fun get(context: Context): CurationEngine =
            instance ?: synchronized(this) {
                instance ?: CurationEngine(context.applicationContext).also { instance = it }
            }
    }
}
