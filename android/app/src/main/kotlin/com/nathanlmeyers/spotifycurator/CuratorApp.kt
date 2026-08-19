package com.nathanlmeyers.spotifycurator

import android.app.Application
import com.nathanlmeyers.spotifycurator.support.DebugLog

class CuratorApp : Application() {
    override fun onCreate() {
        super.onCreate()
        DebugLog.install(this)
        DebugLog.log("app start")
        // Deliberately does NOT start CuratorService. The process can be created in the
        // background (after an update, a broadcast, a low-memory kill), and Android 12+ throws
        // ForegroundServiceStartNotAllowedException for a foreground-service start from there —
        // which crashes the app on launch rather than failing quietly. The service is started
        // from MainActivity and from BootReceiver, both of which are allowed start reasons.
    }
}
