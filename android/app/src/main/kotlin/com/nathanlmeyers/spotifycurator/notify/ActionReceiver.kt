package com.nathanlmeyers.spotifycurator.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.nathanlmeyers.spotifycurator.curation.CurationEngine
import com.nathanlmeyers.spotifycurator.support.DebugLog

/**
 * Handles the notification's Add / Remove / Skip presses, and the Discovery toggle.
 *
 * A BroadcastReceiver rather than an Activity because a broadcast PendingIntent fires on a
 * **locked** device without prompting for an unlock — which is the entire point of the feature.
 * The work itself is handed to [CurationEngine], which runs it on its own scope; nothing blocking
 * happens on the receiver's 10-second main-thread budget.
 */
class ActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val engine = CurationEngine.get(context)
        when (intent.action) {
            ACTION_ADD -> {
                DebugLog.log("gesture: Add button (notification)")
                engine.onAddPressed()
            }

            ACTION_REMOVE -> {
                DebugLog.log("gesture: Remove button (notification)")
                engine.onRemovePressed()
            }

            ACTION_SKIP -> {
                DebugLog.log("gesture: Skip button (notification)")
                engine.onSkipPressed()
            }

            ACTION_DISCOVERY -> {
                val next = !engine.settings.discoveryEnabled
                DebugLog.log("gesture: Discovery ${if (next) "on" else "off"} (notification)")
                engine.setDiscoveryEnabled(next)
            }

            else -> return
        }
    }

    companion object {
        const val ACTION_ADD = "com.nathanlmeyers.spotifycurator.ADD"
        const val ACTION_REMOVE = "com.nathanlmeyers.spotifycurator.REMOVE"
        const val ACTION_SKIP = "com.nathanlmeyers.spotifycurator.SKIP"
        const val ACTION_DISCOVERY = "com.nathanlmeyers.spotifycurator.DISCOVERY"
    }
}
