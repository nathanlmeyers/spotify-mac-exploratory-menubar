package com.nathanlmeyers.spotifycurator.auth

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Why a token request failed, and whether retrying it could ever help.
 *
 * @param isPermanent true when no amount of retrying fixes it — the grant or the Client ID is
 *   wrong, not the network. Callers use this to decide whether to flag the session as dead.
 * @param message what to show a human. Never a bare status code.
 */
data class TokenFailure(val isPermanent: Boolean, val message: String)

/**
 * Classifies `POST /api/token` failures.
 *
 * Split out of [SpotifyAuth] so it can be tested without a network or an Android runtime, and
 * because the distinction it draws is the whole point: a refresh that fails *permanently* leaves
 * every Spotify call dead until someone logs in again, and until this existed all three causes —
 * revoked grant, missing Client ID, server hiccup — surfaced as the same `HTTP 400`, which reads
 * like a transient blip and is silently swallowed as one.
 */
object TokenFailures {

    /** Lenient and local: this must not drag [com.nathanlmeyers.spotifycurator.api.Http] into tests. */
    private val json = Json { ignoreUnknownKeys = true }

    @Serializable
    private data class OAuthError(val error: String? = null, val error_description: String? = null)

    /**
     * OAuth error codes that are fatal to the saved login no matter what the status code says.
     * `invalid_grant` is a revoked or rotated-away refresh token; `invalid_client` is this build
     * being wrong about who it is.
     */
    private val FATAL = setOf(
        "invalid_grant",
        "invalid_client",
        "unauthorized_client",
        "invalid_scope",
        "unsupported_grant_type",
    )

    fun classify(httpCode: Int, body: String?): TokenFailure {
        val error = body?.takeIf { it.isNotBlank() }
            ?.let { runCatching { json.decodeFromString<OAuthError>(it) }.getOrNull() }
            ?.error

        // 429 and 5xx are the server asking for patience. Every other 4xx means the request itself
        // was refused, and refreshing again with the same credentials will be refused identically.
        val isPermanent = when {
            error in FATAL -> true
            httpCode == 429 -> false
            httpCode in 500..599 -> false
            else -> httpCode in 400..499
        }

        return TokenFailure(isPermanent = isPermanent, message = message(httpCode, error))
    }

    private fun message(httpCode: Int, error: String?): String = when (error) {
        "invalid_client" ->
            "Spotify rejected this app's Client ID — rebuild with android/local.properties filled in."
        "invalid_grant" ->
            "Spotify rejected the saved login — log in again."
        "unauthorized_client", "invalid_scope", "unsupported_grant_type" ->
            "Spotify refused this app's permissions — log in again."
        null -> "Spotify auth request failed (HTTP $httpCode)."
        else -> "Spotify auth request failed (HTTP $httpCode: $error)."
    }
}
