package com.nathanlmeyers.spotifycurator

import com.nathanlmeyers.spotifycurator.auth.TokenFailures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The distinction that matters: a *permanent* failure means every Spotify call stays dead until
 * someone logs in again, so it has to be surfaced rather than swallowed as a blip.
 */
class TokenFailureTest {

    @Test
    fun `a revoked grant is permanent`() {
        val f = TokenFailures.classify(400, """{"error":"invalid_grant","error_description":"Refresh token revoked"}""")
        assertTrue(f.isPermanent)
        assertEquals("Spotify rejected the saved login — log in again.", f.message)
    }

    @Test
    fun `a wrong client id is permanent and says so`() {
        val f = TokenFailures.classify(400, """{"error":"invalid_client"}""")
        assertTrue(f.isPermanent)
        // The message has to name local.properties: this is the failure a build with no Client ID
        // produces, and "HTTP 400" alone sent a real debugging session down the wrong path.
        assertTrue(f.message.contains("android/local.properties"))
    }

    @Test
    fun `rate limiting is not permanent`() {
        assertFalse(TokenFailures.classify(429, null).isPermanent)
    }

    @Test
    fun `server errors are not permanent`() {
        assertFalse(TokenFailures.classify(500, null).isPermanent)
        assertFalse(TokenFailures.classify(503, """{"error":"server_error"}""").isPermanent)
    }

    @Test
    fun `an unexplained 4xx is still permanent`() {
        // No body, or one we can't read: a 4xx on the token endpoint means the request was refused,
        // and repeating it with the same credentials gets refused identically.
        val f = TokenFailures.classify(401, null)
        assertTrue(f.isPermanent)
        assertEquals("Spotify auth request failed (HTTP 401).", f.message)
    }

    @Test
    fun `a malformed body does not throw`() {
        val f = TokenFailures.classify(400, "<html>gateway trouble</html>")
        assertTrue(f.isPermanent)
        assertEquals("Spotify auth request failed (HTTP 400).", f.message)
    }

    @Test
    fun `an unrecognised oauth error keeps the code and the name`() {
        val f = TokenFailures.classify(400, """{"error":"invalid_request"}""")
        assertTrue(f.isPermanent)
        assertEquals("Spotify auth request failed (HTTP 400: invalid_request).", f.message)
    }
}
