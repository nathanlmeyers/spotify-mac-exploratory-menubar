package com.nathanlmeyers.spotifycurator.auth

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Receives the `spotifymenubar://callback?code=…&state=…` redirect from the Custom Tab.
 *
 * Finishes immediately and hands the URI to [SpotifyAuth]; `noHistory` in the manifest keeps
 * the authorization code out of Recents.
 */
class AuthCallbackActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        intent?.data?.let { SpotifyAuth.get(this).handleCallback(it) }
        finish()
    }
}
