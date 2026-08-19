package com.nathanlmeyers.spotifycurator.auth

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import com.nathanlmeyers.spotifycurator.BuildConfig
import com.nathanlmeyers.spotifycurator.api.Http
import com.nathanlmeyers.spotifycurator.api.await
import com.nathanlmeyers.spotifycurator.support.DebugLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import okhttp3.FormBody
import okhttp3.Request
import java.util.concurrent.atomic.AtomicInteger

/**
 * The persisted OAuth grant. Port of the macOS `TokenBundle`.
 *
 * [grantedScopes] defaults to `""` so bundles written before the field existed still decode —
 * a decode failure here would silently log the user out.
 */
@Serializable
data class TokenBundle(
    val accessToken: String,
    val refreshToken: String,
    /** Epoch millis. */
    val expiresAt: Long,
    /**
     * The scopes Spotify actually granted, space-separated, as reported by the token endpoint.
     *
     * Refreshing a token never *widens* its scopes, so when a scope is added to [SpotifyAuth.SCOPES]
     * everyone already logged in keeps a token that can't reach the new endpoints. Recording what
     * was granted lets the UI say "log out and back in" instead of surfacing a bare 403.
     */
    val grantedScopes: String = "",
) {
    /** Treat as expired 60s early to avoid edge-of-expiry failures. */
    val isExpired: Boolean get() = System.currentTimeMillis() >= expiresAt - 60_000

    fun grants(scope: String): Boolean = grantedScopes.split(' ').any { it == scope }
}

data class AuthState(
    val isAuthorized: Boolean = false,
    val hasLibraryScopes: Boolean = false,
    val lastError: String? = null,
)

/**
 * Owns the OAuth 2.0 Authorization Code + PKCE flow and token lifecycle.
 * Port of the macOS `SpotifyAuth`; same client ID, same redirect URI, same scopes.
 */
class SpotifyAuth private constructor(private val app: Context) {

    private val store = TokenStore(app)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Serialises refreshes so two concurrent callers can't both burn the refresh token. */
    private val refreshLock = Mutex()

    private val _state = MutableStateFlow(AuthState())
    val state: StateFlow<AuthState> = _state.asStateFlow()

    @Volatile private var tokens: TokenBundle? = null

    /**
     * The in-flight PKCE transaction, persisted rather than held in memory.
     *
     * Logging in means handing control to a Custom Tab — a different process, on screen for as
     * long as it takes to type a password. Android is free to kill this app meanwhile, and the
     * redirect then starts a *fresh* process where in-memory fields are null, so a perfectly
     * valid response gets rejected as a state mismatch and login just silently fails.
     *
     * The verifier is a secret only for the duration of the exchange, and app-private storage is
     * where the refresh token already lives, so this doesn't widen the app's exposure.
     */
    private val pending = app.getSharedPreferences("auth-pending", Context.MODE_PRIVATE)

    private var pendingVerifier: String?
        get() = pending.getString(KEY_VERIFIER, null)
        set(v) = pending.edit().apply { if (v == null) remove(KEY_VERIFIER) else putString(KEY_VERIFIER, v) }.apply()

    private var pendingState: String?
        get() = pending.getString(KEY_STATE, null)
        set(v) = pending.edit().apply { if (v == null) remove(KEY_STATE) else putString(KEY_STATE, v) }.apply()

    private val clientId = BuildConfig.SPOTIFY_CLIENT_ID

    init {
        tokens = store.load()?.let { runCatching { Http.json.decodeFromString<TokenBundle>(it) }.getOrNull() }
        publish()
    }

    /** False if the Client ID hasn't been filled into `android/local.properties` yet. */
    val hasClientId: Boolean get() = clientId.isNotEmpty() && !clientId.startsWith("REPLACE")

    val currentTokens: TokenBundle? get() = tokens

    fun beginLogin(context: Context) {
        if (!hasClientId) {
            _state.value = _state.value.copy(
                lastError = "No Spotify Client ID configured (see android/local.properties)."
            )
            return
        }
        val verifier = Pkce.makeVerifier()
        val state = Pkce.randomState()
        pendingVerifier = verifier
        pendingState = state

        val url = Uri.parse("https://accounts.spotify.com/authorize").buildUpon()
            .appendQueryParameter("client_id", clientId)
            .appendQueryParameter("response_type", "code")
            .appendQueryParameter("redirect_uri", REDIRECT_URI)
            .appendQueryParameter("code_challenge_method", "S256")
            .appendQueryParameter("code_challenge", Pkce.challenge(verifier))
            .appendQueryParameter("scope", SCOPES)
            .appendQueryParameter("state", state)
            .build()

        val tab = CustomTabsIntent.Builder().setShowTitle(true).build()
        tab.intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { tab.launchUrl(context, url) }.onFailure {
            // No browser that supports Custom Tabs — fall back to a plain VIEW intent.
            context.startActivity(Intent(Intent.ACTION_VIEW, url).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    /** Invoked by [AuthCallbackActivity] when `spotifymenubar://callback?...` arrives. */
    fun handleCallback(uri: Uri) {
        uri.getQueryParameter("error")?.let {
            _state.value = _state.value.copy(lastError = "Spotify login canceled: $it")
            return
        }
        val code = uri.getQueryParameter("code") ?: return
        val verifier = pendingVerifier
        val expectedState = pendingState
        // Compare against a non-null expectation: if both sides were null, a response carrying no
        // state at all would compare equal and pass the CSRF check.
        if (expectedState == null || uri.getQueryParameter("state") != expectedState || verifier == null) {
            _state.value = _state.value.copy(
                lastError = "Login response did not match the request (possible CSRF)."
            )
            return
        }
        scope.launch {
            runCatching {
                persist(
                    tokenRequest(
                        mapOf(
                            "grant_type" to "authorization_code",
                            "code" to code,
                            "redirect_uri" to REDIRECT_URI,
                            "client_id" to clientId,
                            "code_verifier" to verifier,
                        )
                    )
                )
            }.onSuccess {
                _state.value = _state.value.copy(lastError = null)
            }.onFailure {
                _state.value = _state.value.copy(lastError = it.message ?: "Login failed.")
            }
            pendingVerifier = null
            pendingState = null
        }
    }

    /**
     * Bumped by [logout], so a refresh that was already in flight can tell that it lost.
     *
     * The refresh holds [refreshLock] for the whole network round trip, and logout deliberately
     * doesn't wait on it (it has to take effect the instant the button is pressed, and it can be
     * called from the main thread). Without this counter the refresh would come back afterwards
     * and `persist()` the credentials logout had just deleted — logging the user silently back in.
     */
    private val logoutGeneration = AtomicInteger(0)

    /** Returns a valid access token, refreshing if necessary. */
    suspend fun validAccessToken(): String = refreshLock.withLock {
        val current = tokens ?: throw AuthException("Not logged in to Spotify.")
        if (!current.isExpired) return@withLock current.accessToken
        val generation = logoutGeneration.get()
        val refreshed = refresh(current)
        if (generation != logoutGeneration.get()) {
            DebugLog.log("token refresh discarded — logged out while it was in flight")
            throw AuthException("Not logged in to Spotify.")
        }
        persist(refreshed)
        refreshed.accessToken
    }

    fun logout() {
        logoutGeneration.incrementAndGet()
        tokens = null
        store.delete()
        publish()
    }

    // MARK: - Token requests

    private suspend fun refresh(existing: TokenBundle): TokenBundle {
        val refreshed = tokenRequest(
            mapOf(
                "grant_type" to "refresh_token",
                "refresh_token" to existing.refreshToken,
                "client_id" to clientId,
            )
        )
        return refreshed.copy(
            // Spotify often omits a new refresh token — keep the existing one.
            refreshToken = refreshed.refreshToken.ifEmpty { existing.refreshToken },
            // Likewise for `scope`: when the refresh response omits it the grant is unchanged, so
            // carry the old value rather than reading the token as having lost every scope.
            grantedScopes = refreshed.grantedScopes.ifEmpty { existing.grantedScopes },
        )
    }

    private suspend fun tokenRequest(body: Map<String, String>): TokenBundle {
        val form = FormBody.Builder().apply { body.forEach { (k, v) -> add(k, v) } }.build()
        val req = Request.Builder().url("https://accounts.spotify.com/api/token").post(form).build()

        Http.client.newCall(req).await().use { resp ->
            if (!resp.isSuccessful) {
                throw AuthException("Spotify auth request failed (HTTP ${resp.code}).")
            }
            @Serializable
            data class TokenResponse(
                val access_token: String,
                val refresh_token: String? = null,
                val expires_in: Double,
                val scope: String? = null,
            )

            val r = Http.json.decodeFromString<TokenResponse>(resp.body?.string().orEmpty())
            DebugLog.log("token granted scopes: ${r.scope ?: "<none>"}")
            return TokenBundle(
                accessToken = r.access_token,
                refreshToken = r.refresh_token.orEmpty(),
                expiresAt = System.currentTimeMillis() + (r.expires_in * 1000).toLong(),
                grantedScopes = r.scope.orEmpty(),
            )
        }
    }

    private fun persist(bundle: TokenBundle) {
        tokens = bundle
        store.save(Http.json.encodeToString(bundle))
        publish()
    }

    private fun publish() {
        val t = tokens
        _state.value = _state.value.copy(
            isAuthorized = t != null,
            hasLibraryScopes = LIBRARY_SCOPES.all { t?.grants(it) == true },
        )
    }

    class AuthException(message: String) : Exception(message)

    companion object {
        private const val KEY_VERIFIER = "pkce_verifier"
        private const val KEY_STATE = "oauth_state"

        val REDIRECT_URI: String = BuildConfig.REDIRECT_URI

        /**
         * Reading and emptying "Your Episodes" (the saved-podcast-episodes library, not a
         * playlist) needs the library scopes: `GET /me/episodes` requires read,
         * `DELETE /me/library` modify.
         */
        val LIBRARY_SCOPES = listOf("user-library-read", "user-library-modify")

        /** Kept identical to the macOS app's list so one login works for both. */
        val SCOPES = (
            listOf(
                "playlist-read-private",
                "playlist-read-collaborative",
                "playlist-modify-public",
                "playlist-modify-private",
                "user-read-playback-state",
                "user-read-currently-playing",
            ) + LIBRARY_SCOPES
            ).joinToString(" ")

        @Volatile private var instance: SpotifyAuth? = null

        fun get(context: Context): SpotifyAuth =
            instance ?: synchronized(this) {
                instance ?: SpotifyAuth(context.applicationContext).also { instance = it }
            }
    }
}
