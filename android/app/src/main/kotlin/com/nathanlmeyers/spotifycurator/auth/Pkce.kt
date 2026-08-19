package com.nathanlmeyers.spotifycurator.auth

import android.util.Base64
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * PKCE (Proof Key for Code Exchange) helpers for the OAuth Authorization Code flow.
 * Port of the macOS app's `PKCE.swift`.
 */
object Pkce {
    private val random = SecureRandom()

    /** A high-entropy code verifier (base64url, ~86 chars — within the 43..128 spec range). */
    fun makeVerifier(): String = randomBase64Url(64)

    /** S256 challenge = base64url(SHA256(verifier)). */
    fun challenge(verifier: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.UTF_8))
        return base64Url(digest)
    }

    /** Opaque anti-CSRF state value. */
    fun randomState(): String = randomBase64Url(16)

    private fun randomBase64Url(byteCount: Int): String =
        base64Url(ByteArray(byteCount).also { random.nextBytes(it) })

    private fun base64Url(bytes: ByteArray): String =
        Base64.encodeToString(bytes, Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE)
}
