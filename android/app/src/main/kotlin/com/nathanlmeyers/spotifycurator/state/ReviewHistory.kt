package com.nathanlmeyers.spotifycurator.state

import android.content.Context
import com.nathanlmeyers.spotifycurator.api.Http
import com.nathanlmeyers.spotifycurator.support.DebugLog
import kotlinx.serialization.Serializable
import java.io.File

/**
 * Local persistence for:
 *  - the per-source "already reviewed" set of track URIs (discovery auto-skip)
 *  - a cache of target-playlist membership (duplicate prevention)
 *
 * Port of the macOS `ReviewHistory`.
 */
class ReviewHistory private constructor(context: Context) {

    @Serializable
    private data class Store(
        val seenBySource: MutableMap<String, MutableSet<String>> = mutableMapOf(),
        val targetMembership: MutableMap<String, MutableSet<String>> = mutableMapOf(),
    )

    private val file = File(context.filesDir, "history.json")
    private var store = Store()

    init {
        load()
    }

    // MARK: Reviewed set (discovery auto-skip)

    @Synchronized
    fun markReviewed(sourceId: String, uri: String) {
        store.seenBySource.getOrPut(sourceId) { mutableSetOf() }.add(uri)
        save()
    }

    @Synchronized
    fun hasReviewed(sourceId: String, uri: String): Boolean =
        store.seenBySource[sourceId]?.contains(uri) == true

    // MARK: Target membership cache (duplicate prevention)

    @Synchronized
    fun cachedMembership(targetId: String): Set<String>? = store.targetMembership[targetId]?.toSet()

    @Synchronized
    fun setMembership(targetId: String, uris: Set<String>) {
        store.targetMembership[targetId] = uris.toMutableSet()
        save()
    }

    @Synchronized
    fun addToMembership(targetId: String, uri: String) {
        store.targetMembership.getOrPut(targetId) { mutableSetOf() }.add(uri)
        save()
    }

    /**
     * Drop a track just removed from the target.
     *
     * Without this the cache keeps claiming the song is "already in target" until the next full
     * fetch, which is exactly the signal auto-skip reads — so a removed song would go on being
     * skipped as a duplicate.
     */
    @Synchronized
    fun removeFromMembership(targetId: String, uri: String) {
        if (store.targetMembership[targetId]?.contains(uri) != true) return
        store.targetMembership[targetId]?.remove(uri)
        save()
    }

    // MARK: Persistence

    private fun load() {
        // File absent → legitimate first run; start empty.
        if (!file.exists()) return
        val text = runCatching { file.readText() }.getOrNull() ?: return
        runCatching { store = Http.json.decodeFromString<Store>(text) }
            .onFailure { e ->
                // File exists but is unreadable (corrupt / partial write / schema change).
                // Preserve it before any save() overwrites it with the empty default.
                val backup = File(file.parentFile, "${file.name}.corrupt")
                runCatching { file.copyTo(backup, overwrite = true) }
                DebugLog.log("ReviewHistory: could not decode history.json (${e.message}); backed up to ${backup.name}, starting empty")
                store = Store()
            }
    }

    private fun save() {
        runCatching {
            // Write to a temp file and rename, so a kill mid-write can't leave a truncated file
            // where the real history was — the macOS original gets this from atomic NSData writes.
            val tmp = File(file.parentFile, "${file.name}.tmp")
            tmp.writeText(Http.json.encodeToString(store))
            tmp.renameTo(file)
        }.onFailure { DebugLog.log("ReviewHistory: save failed: ${it.message}") }
    }

    companion object {
        @Volatile private var instance: ReviewHistory? = null

        fun get(context: Context): ReviewHistory =
            instance ?: synchronized(this) {
                instance ?: ReviewHistory(context.applicationContext).also { instance = it }
            }
    }
}
