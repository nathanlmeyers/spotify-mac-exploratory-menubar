package com.nathanlmeyers.spotifycurator.media

import android.content.Context
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.nathanlmeyers.spotifycurator.model.NowPlaying
import com.nathanlmeyers.spotifycurator.support.DebugLog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Watches Spotify's MediaSession — the Android analogue of the macOS app's ScriptingBridge
 * connection to Spotify.app.
 *
 * Two things make this better than the Mac's 1 Hz Apple-event poll:
 *  - position arrives as a *sample* (`position` + `lastPositionUpdateTime` + `speed`), so exact
 *    position is computable at any instant with no polling at all;
 *  - `transportControls` is a local binder call, so pause/skip land in single-digit milliseconds
 *    rather than the tens-to-hundreds an Apple event takes.
 *
 * Requires notification access — see [NotificationAccessStub].
 */
class MediaWatcher(private val context: Context) {

    private val handler = Handler(Looper.getMainLooper())
    private val sessionManager: MediaSessionManager? =
        context.getSystemService(MediaSessionManager::class.java)

    private val _nowPlaying = MutableStateFlow<NowPlaying?>(null)
    val nowPlaying: StateFlow<NowPlaying?> = _nowPlaying.asStateFlow()

    /** True when we hold a live Spotify session. False means "we can see nothing", not "paused". */
    private val _isConnected = MutableStateFlow(false)
    val isConnected: StateFlow<Boolean> = _isConnected.asStateFlow()

    @Volatile private var controller: MediaController? = null
    private var lastLoggedIdentity: String? = null

    /**
     * Whether [sessionsListener] is actually registered.
     *
     * Registration throws when notification access hasn't been granted, and the grant is made in
     * *system* Settings — nothing calls back into this process. Without this flag the failed
     * registration was never retried, so a curator started before the grant could go the whole
     * session without ever learning that a Spotify session had appeared.
     */
    private var listenerRegistered = false

    /** Fired whenever metadata or playback state changes, so Discovery can recompute its timer. */
    var onChanged: (() -> Unit)? = null

    private val sessionsListener = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
        bind(controllers.orEmpty())
    }

    private val controllerCallback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) {
            if (metadata != null) logMetadata(metadata)
            publish()
        }

        override fun onPlaybackStateChanged(state: PlaybackState?) = publish()

        override fun onSessionDestroyed() {
            DebugLog.log("media: Spotify session destroyed")
            detach()
            // The session usually comes straight back (Spotify recreates it on the next track);
            // OnActiveSessionsChangedListener will re-bind us when it does.
            refresh()
        }
    }

    /** Idempotent: safe to call again after a failed start, which is what [refresh] does. */
    fun start() {
        val msm = sessionManager ?: return
        try {
            if (!listenerRegistered) {
                msm.addOnActiveSessionsChangedListener(
                    sessionsListener, NotificationAccessStub.componentName(context), handler
                )
                listenerRegistered = true
            }
            bind(msm.getActiveSessions(NotificationAccessStub.componentName(context)))
        } catch (e: SecurityException) {
            // Notification access not granted (or revoked while running).
            DebugLog.log("media: no notification access — ${e.message}")
            _isConnected.value = false
        }
    }

    fun stop() {
        if (listenerRegistered) {
            sessionManager?.removeOnActiveSessionsChangedListener(sessionsListener)
            listenerRegistered = false
        }
        detach()
    }

    /**
     * Re-reads the active session list; used after a session is destroyed and recreated, and
     * when the service is re-commanded after a trip to system Settings.
     *
     * Retries the listener registration when it isn't in place. Only re-reading sessions would
     * be a one-shot look: if notification access was granted while Spotify happened to have no
     * active session, nothing would ever tell us when one appeared.
     */
    fun refresh() {
        if (!listenerRegistered) {
            start()
            return
        }
        val msm = sessionManager ?: return
        runCatching { bind(msm.getActiveSessions(NotificationAccessStub.componentName(context))) }
    }

    // MARK: - Transport (local, instant)

    fun pause() = controller?.transportControls?.pause()
    fun play() = controller?.transportControls?.play()
    fun skipToNext() = controller?.transportControls?.skipToNext()
    fun skipToPrevious() = controller?.transportControls?.skipToPrevious()
    fun seekTo(positionMs: Long) = controller?.transportControls?.seekTo(positionMs)

    // MARK: - Internals

    private fun bind(controllers: List<MediaController>) {
        val spotify = controllers.firstOrNull { it.packageName == SPOTIFY_PACKAGE }
        if (spotify == null) {
            if (controller != null) DebugLog.log("media: Spotify session went away")
            detach()
            return
        }
        if (spotify.sessionToken == controller?.sessionToken) return

        // No announcement for this one: the new controller publishes a moment later, and a null
        // in between would make discovery go idle and drop an armed hold on every re-bind.
        detach(announce = false)
        controller = spotify.also { it.registerCallback(controllerCallback, handler) }
        _isConnected.value = true
        // Log the playback type: it's what discovery's locality guard rests on, and if Spotify
        // doesn't populate it we want that visible here rather than inferred from a hold that
        // never fires.
        DebugLog.log("media: bound to Spotify session (playbackLocal=${isPlaybackLocal()})")
        spotify.metadata?.let(::logMetadata)
        publish()
    }

    /**
     * Drop the current session.
     *
     * [announce] fires [onChanged]. It has to, for anything but the re-bind above: `CurationEngine`
     * mirrors now-playing off that callback rather than collecting [nowPlaying], so a silent clear
     * left the app and the ongoing notification showing the track that stopped playing — and the
     * source underneath it — for as long as Spotify stayed away.
     */
    private fun detach(announce: Boolean = true) {
        val hadSession = controller != null
        controller?.unregisterCallback(controllerCallback)
        controller = null
        _isConnected.value = false
        _nowPlaying.value = null
        if (announce && hadSession) onChanged?.invoke()
    }

    private fun publish() {
        _nowPlaying.value = snapshot()
        onChanged?.invoke()
    }

    /**
     * An atomic reading of what Spotify is playing *and* what it's playing from.
     *
     * Both halves come out of a single `MediaMetadata` object, so they cannot disagree — this is
     * the direct equivalent of the macOS app's atomic `playbackSnapshot()` Apple event, and it is
     * what makes a Remove safe without a confirming API round trip. [contextUri] is Spotify's own
     * undocumented extra; it is absent on some playback types, hence nullable.
     */
    data class LocalSnapshot(
        val nowPlaying: NowPlaying,
        val contextUri: String?,
        val contextTitle: String?,
    )

    /**
     * The current track plus its playback context, read from one metadata object.
     *
     * Returns null when there's no session at all. A non-null result with a null [LocalSnapshot.contextUri]
     * means Spotify didn't publish a context — callers fall back to `GET /me/player`.
     */
    fun localSnapshot(): LocalSnapshot? {
        val c = controller ?: return null
        // Read the reference exactly once: re-reading c.metadata could straddle a track change
        // and pair one song's URI with the next song's context.
        val md = c.metadata ?: return null
        val np = snapshot(md, c.playbackState) ?: return null
        return LocalSnapshot(
            nowPlaying = np,
            contextUri = md.getString(EXTRA_CONTEXT_URI)?.takeIf { it.isNotBlank() },
            contextTitle = md.getString(EXTRA_CONTEXT_TITLE)?.takeIf { it.isNotBlank() },
        )
    }

    /**
     * A fresh [NowPlaying] with the position extrapolated to *now*.
     *
     * Call this rather than reading [nowPlaying] when the exact position matters (the hold
     * timer): the stored value's position is only accurate as of the last state change.
     */
    fun snapshot(): NowPlaying? {
        val c = controller ?: return null
        return snapshot(c.metadata ?: return null, c.playbackState)
    }

    private fun snapshot(md: MediaMetadata, state: PlaybackState?): NowPlaying? {

        val durationMs = MediaMetadataMapping.normalizeDurationMs(
            md.getLong(MediaMetadata.METADATA_KEY_DURATION)
        )
        val isPlaying = state?.state == PlaybackState.STATE_PLAYING
        // Spotify emits these mid-track (a stall on a weak connection, a Connect handover). They
        // are not a pause, and discovery must not disarm on them — see NowPlaying.isStalled.
        val isStalled = state?.state == PlaybackState.STATE_BUFFERING ||
            state?.state == PlaybackState.STATE_CONNECTING
        val positionMs = MediaMetadataMapping.extrapolatePositionMs(
            basePositionMs = state?.position ?: 0L,
            lastUpdateTimeMs = state?.lastPositionUpdateTime ?: 0L,
            speed = state?.playbackSpeed ?: 0f,
            isPlaying = isPlaying,
            nowElapsedRealtimeMs = SystemClock.elapsedRealtime(),
            durationMs = durationMs,
        )

        return NowPlaying(
            uri = MediaMetadataMapping.spotifyUriFrom(md.getString(MediaMetadata.METADATA_KEY_MEDIA_ID)),
            name = md.getString(MediaMetadata.METADATA_KEY_TITLE).orEmpty(),
            artist = md.getString(MediaMetadata.METADATA_KEY_ARTIST).orEmpty(),
            album = md.getString(MediaMetadata.METADATA_KEY_ALBUM).orEmpty(),
            artworkUri = md.getString(MediaMetadata.METADATA_KEY_ALBUM_ART_URI),
            durationMs = durationMs,
            positionMs = positionMs,
            isPlaying = isPlaying,
            isStalled = isStalled,
        )
    }

    /**
     * Whether the audio is coming out of *this phone*, or null when it can't be told.
     *
     * The Android answer to `SpotifyProvider.resolveLocality`. Spotify's app keeps a MediaSession
     * alive even when it is only remote-controlling a Connect speaker, so the session's existence
     * proves nothing — but its `PlaybackInfo` distinguishes local output from remote, with no API
     * call. Discovery uses this before issuing a pause, so it can't silence another room.
     *
     * Some apps report LOCAL sloppily while casting. The consequence here is a pause sent to the
     * wrong device — recoverable, and never a playlist edit.
     */
    fun isPlaybackLocal(): Boolean? = when (controller?.playbackInfo?.playbackType) {
        MediaController.PlaybackInfo.PLAYBACK_TYPE_LOCAL -> true
        MediaController.PlaybackInfo.PLAYBACK_TYPE_REMOTE -> false
        else -> null
    }

    /** The album art Spotify attached to the session, if any. Used for the notification. */
    fun artworkBitmap() = controller?.metadata?.let {
        it.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: it.getBitmap(MediaMetadata.METADATA_KEY_ART)
    }

    /**
     * Dumps every key Spotify puts in its metadata, once per track.
     *
     * This is how we learn whether `METADATA_KEY_MEDIA_ID` carries a `spotify:track:…` URI —
     * which decides whether Add can act instantly or has to wait on `GET /me/player`. Spotify
     * has changed this between releases, so it stays logged rather than being a one-off spike.
     */
    private fun logMetadata(md: MediaMetadata) {
        val identity = md.getString(MediaMetadata.METADATA_KEY_TITLE).orEmpty() +
            "/" + md.getString(MediaMetadata.METADATA_KEY_ARTIST).orEmpty()
        if (identity == lastLoggedIdentity) return
        lastLoggedIdentity = identity

        val pairs = md.keySet().sorted().mapNotNull { key ->
            val value = md.getString(key)
                ?: md.getLong(key).takeIf { it != 0L }?.toString()
                ?: md.getBitmap(key)?.let { "<bitmap ${it.width}x${it.height}>" }
            value?.let { "$key=$it" }
        }
        DebugLog.log("media metadata: ${pairs.joinToString(" | ")}")
    }

    companion object {
        const val SPOTIFY_PACKAGE = "com.spotify.music"

        /**
         * Spotify's own metadata extras carrying the playback context.
         *
         * Undocumented and vendor-specific, so every read is treated as optional and falls back
         * to `GET /me/player` — but when present they remove an API round trip from every track
         * change and every curation action.
         */
        const val EXTRA_CONTEXT_URI = "com.spotify.music.extra.CONTEXT_URI"
        const val EXTRA_CONTEXT_TITLE = "com.spotify.music.extra.CONTEXT_TITLE"
    }
}
