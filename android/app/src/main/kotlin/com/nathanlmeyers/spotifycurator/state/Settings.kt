package com.nathanlmeyers.spotifycurator.state

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * User preferences. Port of the macOS `Settings.swift`.
 *
 * Backed by SharedPreferences rather than DataStore: it is the direct analogue of UserDefaults,
 * and — unlike DataStore — it reads synchronously, which matters because the notification's
 * Add/Remove buttons are handled in a BroadcastReceiver that has to decide what to do
 * immediately, on a locked phone, before it can start any coroutine.
 */
class Settings private constructor(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("curator", Context.MODE_PRIVATE)

    // MARK: Curation

    var targetPlaylistId: String?
        get() = prefs.getString(K.TARGET_ID, null)
        set(v) = put { putString(K.TARGET_ID, v) }

    var targetPlaylistName: String?
        get() = prefs.getString(K.TARGET_NAME, null)
        set(v) = put { putString(K.TARGET_NAME, v) }

    var removeFromSourceOnAdd: Boolean
        get() = prefs.getBoolean(K.MOVE_ON_ADD, false)
        set(v) = put { putBoolean(K.MOVE_ON_ADD, v) }

    var skipToNextAfterRemove: Boolean
        get() = prefs.getBoolean(K.SKIP_AFTER_REMOVE, true)
        set(v) = put { putBoolean(K.SKIP_AFTER_REMOVE, v) }

    var skipToNextAfterAdd: Boolean
        get() = prefs.getBoolean(K.SKIP_AFTER_ADD, false)
        set(v) = put { putBoolean(K.SKIP_AFTER_ADD, v) }

    // MARK: Curator service

    /**
     * The master switch. Android-only: on the Mac the menu-bar icon is always there, but here
     * the app has to hold a foreground service and a notification to stay reachable from the
     * lock screen, so that has to be something you can turn off.
     */
    var curatorEnabled: Boolean
        get() = prefs.getBoolean(K.CURATOR_ENABLED, false)
        set(v) = put { putBoolean(K.CURATOR_ENABLED, v) }

    // MARK: Discovery

    var discoveryEnabled: Boolean
        get() = prefs.getBoolean(K.DISCOVERY, false)
        set(v) = put { putBoolean(K.DISCOVERY, v) }

    var alertSound: Boolean
        get() = prefs.getBoolean(K.ALERT_SOUND, false)
        set(v) = put { putBoolean(K.ALERT_SOUND, v) }

    var skipIfInTarget: Boolean
        get() = prefs.getBoolean(K.SKIP_IN_TARGET, false)
        set(v) = put { putBoolean(K.SKIP_IN_TARGET, v) }

    var skipAlreadyReviewed: Boolean
        get() = prefs.getBoolean(K.SKIP_REVIEWED, false)
        set(v) = put { putBoolean(K.SKIP_REVIEWED, v) }

    /** Bumped on every write so Compose can recompose off a single flow. */
    private val _revision = MutableStateFlow(0L)
    val revision: StateFlow<Long> = _revision.asStateFlow()

    private inline fun put(block: SharedPreferences.Editor.() -> Unit) {
        prefs.edit().apply(block).apply()
        _revision.value = _revision.value + 1
    }

    init {
        // Clear retired behavior flags. In particular, a value restored from a device backup
        // must never revive auto-delete or the unreliable background activity launch.
        val retired = setOf(K.RETIRED_ALERT_PANEL, K.RETIRED_SKIP_IN_TARGET_REMOVE)
        if (retired.any(prefs::contains)) {
            prefs.edit().apply { retired.forEach(::remove) }.apply()
        }
    }

    private object K {
        const val TARGET_ID = "targetPlaylistId"
        const val TARGET_NAME = "targetPlaylistName"
        const val MOVE_ON_ADD = "removeFromSourceOnAdd"
        const val SKIP_AFTER_REMOVE = "skipToNextAfterRemove"
        const val SKIP_AFTER_ADD = "skipToNextAfterAdd"
        const val CURATOR_ENABLED = "curatorEnabled"
        const val DISCOVERY = "discoveryEnabled"
        const val ALERT_SOUND = "alertSound"
        const val SKIP_IN_TARGET = "skipIfInTarget"
        const val SKIP_REVIEWED = "skipAlreadyReviewed"

        /** Retired auto-delete flag; kept only so init can clear it. Never read. */
        const val RETIRED_SKIP_IN_TARGET_REMOVE = "skipInTargetAlsoRemove"

        /** Background activity launches are unreliable and inappropriate for a playback hold. */
        const val RETIRED_ALERT_PANEL = "alertAutoOpenPanel"
    }

    companion object {
        @Volatile private var instance: Settings? = null

        fun get(context: Context): Settings =
            instance ?: synchronized(this) {
                instance ?: Settings(context.applicationContext).also { instance = it }
            }
    }
}
