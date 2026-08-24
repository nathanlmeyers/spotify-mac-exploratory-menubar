package com.nathanlmeyers.spotifycurator.notify

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import com.nathanlmeyers.spotifycurator.R
import com.nathanlmeyers.spotifycurator.curation.CuratorState
import com.nathanlmeyers.spotifycurator.discovery.ReviewState
import com.nathanlmeyers.spotifycurator.state.Settings
import com.nathanlmeyers.spotifycurator.ui.MainActivity

/**
 * The ongoing notification that carries Add / Remove / Skip to the lock screen.
 *
 * Design notes that matter:
 *  - **Custom content view.** Android renders lock-screen notifications collapsed, and a standard
 *    notification's `addAction` buttons only appear when expanded. A custom content view is drawn
 *    as-is, so the buttons live in [R.layout.notification_curator] instead. Standard actions used
 *    to be attached alongside as a fallback for surfaces that ignore custom views; they were
 *    dropped because on every surface that *does* honour them — which is the phone, the only one
 *    this app targets — they drew a second, identical Add/Remove/Skip row under the first.
 *  - **Broadcast PendingIntents.** A broadcast fires without unlocking the device; an activity
 *    PendingIntent would force an unlock first. `setAuthenticationRequired` is deliberately not
 *    set — requiring auth is exactly what we're avoiding.
 *  - **VISIBILITY_PUBLIC.** Otherwise the lock screen replaces the content with a "contents
 *    hidden" placeholder and there are no buttons to press.
 */
object CuratorNotification {

    /**
     * Versioned because a channel's importance is fixed once created — the only way to change it
     * is a new id. v1 was IMPORTANCE_LOW, which Android files as "silent" and **hides from the
     * lock screen by default**, taking the buttons with it. That defeats the whole feature.
     */
    const val CHANNEL_ID = "curator_v2"
    private const val RETIRED_CHANNEL_ID = "curator"
    const val NOTIFICATION_ID = 1001

    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.deleteNotificationChannel(RETIRED_CHANNEL_ID)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.channel_curator_name),
            // DEFAULT, not LOW: LOW is filed as "silent" and dropped from the lock screen.
            // DEFAULT still never pops up a heads-up (that needs HIGH), and the sound and
            // vibration are cleared below — so it is silent in practice but still shown.
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = context.getString(R.string.channel_curator_description)
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
            enableLights(false)
            lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    fun build(context: Context, state: CuratorState): android.app.Notification {
        ensureChannel(context)

        val np = state.nowPlaying
        // Neither is drawn: DecoratedCustomViewStyle gives the content area over to the custom
        // views entirely. They're what the surfaces that read a notification rather than draw it
        // get — accessibility services, and the lock screen's "hide sensitive content" mode.
        val title = np?.name?.takeIf { it.isNotBlank() } ?: "Nothing playing"
        val status = state.status ?: sourceLine(state)

        // Both views are buttons only. Setting text on an id that isn't in the layout throws when
        // the system inflates it, which shows up as a notification that silently never appears —
        // so the Discovery row is wired on the expanded view alone, which is the only one that
        // has it.
        val collapsed = RemoteViews(context.packageName, R.layout.notification_curator).apply {
            wireActions(context, this, state, addedLabel = context.getString(R.string.glyph_added))
        }
        val expanded = RemoteViews(context.packageName, R.layout.notification_curator_big).apply {
            wireActions(context, this, state, addedLabel = context.getString(R.string.action_added))
            wireDiscoveryToggle(context, this)
        }

        val openApp = PendingIntent.getActivity(
            context, 0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_curator)
            .setContentTitle(title)
            .setContentText(status)
            .setStyle(NotificationCompat.DecoratedCustomViewStyle())
            .setCustomContentView(collapsed)
            .setCustomBigContentView(expanded)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            // Deliberately NOT setSilent(true): that forces the notification into the system's
            // "silent" group, which the lock screen hides. Silence comes from the channel above.
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    /**
     * Why the buttons look the way they do — or null to stay out of the way, which is the usual
     * answer.
     *
     * Deliberately silent in the ordinary case: Spotify's own media notification sits directly
     * above this one, so a running commentary here would only steal room from the buttons. It
     * speaks up when a button is disabled for a reason you cannot see, because that is the state
     * that reads as "the app is broken" and sends you into settings that cannot fix it. A dead
     * Spotify grant is the sharpest example — it blanks the source, which disables Remove, and
     * every setting in the app is irrelevant to it.
     */
    private fun statusLine(state: CuratorState, canRemove: Boolean): String? {
        val sourceName = state.source.playlistName
        return when {
            state.authBroken -> "Spotify login expired — open the app to log in again"
            state.isError -> state.status
            !canRemove && sourceName != null -> "Can't remove from $sourceName — you can't edit it"
            else -> null
        }
    }

    /**
     * A one-line summary of what Remove would act on.
     *
     * Shown whenever there's no fresher status. Naming the playlist is a safety feature, not a
     * nicety: Remove deletes from whatever you're listening to, and on a lock screen this line is
     * the only chance to notice it says the wrong thing before you press it.
     */
    private fun sourceLine(state: CuratorState): String {
        val review = state.review
        if (review is ReviewState.Held) {
            return "Review: ${review.track.name} — ${review.track.artist}"
        }
        if (review is ReviewState.NothingNew) return "Nothing new to review here"
        val name = state.source.playlistName
        return when {
            state.nowPlaying == null -> "Waiting for Spotify"
            name == null -> "Not playing from a playlist"
            !state.source.isEditablePlaylist -> "$name (can't edit)"
            else -> "From $name"
        }
    }

    /**
     * @param addedLabel what the Add button reads once the song is in the target. The two layouts
     *   carry different text for the same id — a glyph collapsed, a word expanded — and setting
     *   text on an id a layout doesn't have throws at inflate time (see the note in [build]), so
     *   the caller supplies the one that belongs to the view it is wiring.
     */
    private fun wireActions(
        context: Context,
        views: RemoteViews,
        state: CuratorState,
        addedLabel: String,
    ) {
        views.setOnClickPendingIntent(R.id.action_add, actionIntent(context, ActionReceiver.ACTION_ADD))
        views.setOnClickPendingIntent(R.id.action_remove, actionIntent(context, ActionReceiver.ACTION_REMOVE))
        views.setOnClickPendingIntent(R.id.action_skip, actionIntent(context, ActionReceiver.ACTION_SKIP))

        // Grey out rather than hide, so the row never reflows and the buttons stay where your
        // thumb learned they are. Mirrors the macOS popover's disabled states.
        //
        // While a track is held for review the buttons act on the *frozen* held snapshot, so
        // their enabled state has to come from that snapshot too — not from what is playing now,
        // which during a hold is the same track but paused.
        val held = (state.review as? ReviewState.Held)?.track
        val canCurate = when {
            held != null -> true
            else -> state.nowPlaying?.let { it.uri.isEmpty() || it.kind.isCuratable } ?: false
        }
        val canRemove = (held?.source ?: state.source).isEditablePlaylist

        // The song is already where Add would put it: say so and take the press away. This is the
        // only confirmation the lock screen gets — the status line is set as `contentText`, which
        // DecoratedCustomViewStyle never draws (see [build]) — so before this, a successful Add
        // looked identical to nothing happening.
        val added = state.inTarget && canCurate && !state.isBusy
        val addEnabled = canCurate && !state.isBusy && !added
        val removeEnabled = canCurate && !state.isBusy && canRemove

        // Explain a dead button, when there is anything to explain. Both content views carry
        // @id/status_line so this runs identically for either.
        when (val line = statusLine(state, canRemove)) {
            null -> views.setViewVisibility(R.id.status_line, View.GONE)
            else -> {
                views.setTextViewText(R.id.status_line, line)
                views.setViewVisibility(R.id.status_line, View.VISIBLE)
            }
        }

        views.setBoolean(R.id.action_add, "setEnabled", addEnabled)
        views.setBoolean(R.id.action_remove, "setEnabled", removeEnabled)
        // `added` keeps full alpha deliberately — see @drawable/notification_button_added. Its
        // "not pressable" signal is the changed glyph and the changed fill, not a fade, because a
        // faded green tick on a lock screen is a green tick you can't read.
        views.setFloat(R.id.action_add, "setAlpha", if (addEnabled || added) 1f else 0.4f)
        views.setFloat(R.id.action_remove, "setAlpha", if (removeEnabled) 1f else 0.4f)

        if (added) {
            views.setTextViewText(R.id.action_add, addedLabel)
            views.setTextColor(R.id.action_add, context.getColor(R.color.curator_added))
            views.setInt(R.id.action_add, "setBackgroundResource", R.drawable.notification_button_added)
            views.setCharSequence(
                R.id.action_add,
                "setContentDescription",
                context.getString(R.string.action_added_description),
            )
        }
        // No else branch: `build` inflates a fresh RemoteViews every time, so an un-added rebuild
        // already carries the layout's own text, colour and background.
    }

    /**
     * The Discovery switch — expanded view only; the collapsed layout has no such id.
     *
     * Read straight from [Settings] rather than from [CuratorState]: the flag is a setting, not
     * part of the playback snapshot. [com.nathanlmeyers.spotifycurator.service.CuratorService] is
     * what makes the label keep up, by rebuilding on `Settings.revision` as well as on state.
     */
    private fun wireDiscoveryToggle(context: Context, views: RemoteViews) {
        val on = Settings.get(context).discoveryEnabled
        views.setTextViewText(
            R.id.action_discovery,
            context.getString(if (on) R.string.action_discovery_on else R.string.action_discovery_off),
        )
        views.setCharSequence(
            R.id.action_discovery,
            "setContentDescription",
            context.getString(
                if (on) R.string.action_discovery_on_description
                else R.string.action_discovery_off_description,
            ),
        )
        views.setOnClickPendingIntent(
            R.id.action_discovery,
            actionIntent(context, ActionReceiver.ACTION_DISCOVERY),
        )
    }

    private fun actionIntent(context: Context, action: String): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            action.hashCode(),
            Intent(context, ActionReceiver::class.java).setAction(action).setPackage(context.packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
}
