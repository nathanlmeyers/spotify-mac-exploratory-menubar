package com.nathanlmeyers.spotifycurator.media

import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.service.notification.NotificationListenerService

/**
 * Deliberately empty.
 *
 * We never read anyone's notifications. This service exists only because
 * `MediaSessionManager.getActiveSessions(ComponentName)` requires the caller to name an
 * *enabled* NotificationListenerService — once the user grants notification access to this
 * component, that call works from anywhere in the app, and [CuratorService] is where it
 * actually happens.
 */
class NotificationAccessStub : NotificationListenerService() {

    companion object {
        fun componentName(context: Context) =
            ComponentName(context, NotificationAccessStub::class.java)

        /**
         * True when the user has granted notification access to this app.
         *
         * Read from the `enabled_notification_listeners` secure setting — a colon-separated
         * list of flattened component names — because there is no public API for it. Compare
         * against both flattened forms: the platform has historically stored the short form
         * (`pkg/.Class`) in some versions and the long form (`pkg/pkg.Class`) in others.
         */
        fun isGranted(context: Context): Boolean {
            val enabled = Settings.Secure.getString(
                context.contentResolver, "enabled_notification_listeners"
            ) ?: return false
            val me = componentName(context)
            return enabled.split(':').any {
                val c = ComponentName.unflattenFromString(it) ?: return@any false
                c == me
            }
        }
    }
}
