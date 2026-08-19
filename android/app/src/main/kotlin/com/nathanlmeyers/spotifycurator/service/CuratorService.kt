package com.nathanlmeyers.spotifycurator.service

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.core.app.ServiceCompat
import com.nathanlmeyers.spotifycurator.curation.CurationEngine
import com.nathanlmeyers.spotifycurator.notify.CuratorNotification
import com.nathanlmeyers.spotifycurator.state.Settings
import com.nathanlmeyers.spotifycurator.support.DebugLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * The always-on half of the app: holds the ongoing notification for as long as the curator is
 * switched on, so Add / Remove / Skip are reachable mid-song from the lock screen rather than
 * only at track boundaries.
 *
 * A foreground service, not just a posted notification, because the process has to survive being
 * backgrounded for hours while you listen. `specialUse` is the honest foreground-service type:
 * this isn't playing media, it's watching someone else play it.
 */
class CuratorService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var engine: CurationEngine

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        engine = CurationEngine.get(this)
        DebugLog.log("curator service starting")

        // Post immediately: Android kills a foreground service that doesn't call startForeground
        // within a few seconds of being started.
        startForegroundWith(engine.state.value)

        engine.watcher.start()

        // Settings as well as state: the notification's Discovery toggle names the *current*
        // setting, and a settings write doesn't necessarily move `engine.state` — so on its own,
        // state would leave the label reading "Discovery on" after you'd just turned it off.
        // Also keeps the target playlist's name current when it's changed in the app.
        scope.launch {
            combine(engine.state, engine.settings.revision) { state, _ -> state }.collectLatest { state ->
                notificationManager().notify(
                    CuratorNotification.NOTIFICATION_ID,
                    CuratorNotification.build(this@CuratorService, state),
                )
            }
        }

        // The membership cache is what makes Add say "Already in <target>" instead of silently
        // adding a duplicate, so load it once at start rather than on the first press.
        scope.launch { engine.loadTargetMembership() }

        // Discovery's hold is silent by design — the music stopping is itself the signal. The
        // optional alert is for when the phone is in a pocket and that cue is easy to miss.
        engine.discovery.onHoldBegan = { held ->
            DebugLog.log("discovery: alerting for held \"${held.name}\"")
            if (engine.settings.alertSound) {
                val vibrator = getSystemService(Vibrator::class.java)
                vibrator?.vibrate(VibrationEffect.createOneShot(120, VibrationEffect.DEFAULT_AMPLITUDE))
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundWith(engine.state.value)
        // The session can be recreated by Spotify while we were away; re-read it.
        engine.watcher.refresh()
        return START_STICKY
    }

    override fun onDestroy() {
        DebugLog.log("curator service stopping")
        // Resume a track Discovery deliberately parked while the controller is still attached.
        engine.discovery.reset()
        engine.watcher.stop()
        scope.cancel()
        super.onDestroy()
    }

    private fun startForegroundWith(state: com.nathanlmeyers.spotifycurator.curation.CuratorState) {
        ServiceCompat.startForeground(
            this,
            CuratorNotification.NOTIFICATION_ID,
            CuratorNotification.build(this, state),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
        )
    }

    private fun notificationManager() =
        getSystemService(android.app.NotificationManager::class.java)

    companion object {
        /**
         * Starts or stops the service to match [Settings.curatorEnabled].
         *
         * Safe to call from anywhere: a foreground-service start is only permitted from a
         * foreground context (or an allowed reason like BOOT_COMPLETED), and Android throws
         * rather than declining. Swallow that — a curator that can't start right now is a
         * notification that doesn't appear, not a reason to take the app down.
         */
        fun sync(context: Context) {
            val intent = Intent(context, CuratorService::class.java)
            if (Settings.get(context).curatorEnabled) {
                runCatching { context.startForegroundService(intent) }
                    .onFailure { DebugLog.log("curator service start refused: ${it.message}") }
            } else {
                runCatching { context.stopService(intent) }
            }
        }
    }
}
