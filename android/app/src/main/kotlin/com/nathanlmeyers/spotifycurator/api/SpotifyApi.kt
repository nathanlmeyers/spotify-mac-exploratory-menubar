package com.nathanlmeyers.spotifycurator.api

import com.nathanlmeyers.spotifycurator.auth.SpotifyAuth
import com.nathanlmeyers.spotifycurator.curation.UserRemovalIntent
import com.nathanlmeyers.spotifycurator.model.CurrentlyPlaying
import com.nathanlmeyers.spotifycurator.model.PlaybackDevice
import com.nathanlmeyers.spotifycurator.model.Playlist
import com.nathanlmeyers.spotifycurator.support.DebugLog
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.atomic.AtomicLong

/**
 * Thin client for the Spotify Web API endpoints we use. Port of the macOS `SpotifyWebAPI`.
 * Tokens are fetched (and refreshed) via [SpotifyAuth].
 */
class SpotifyApi(private val auth: SpotifyAuth) {

    /**
     * While set and in the future, every request short-circuits without touching the network.
     *
     * Spotify answers a 429 with `Retry-After`, and the macOS app polls `/me/player` about once a
     * second. With no backoff, a throttled session just kept hammering: one debug log held
     * **403,329** consecutive "Too many requests" responses, which is both self-inflicted load and
     * the reason source resolution kept failing (a failed resolve reads as "no playlist").
     * Honouring the header locally turns a storm into a pause.
     *
     * Atomic because on Android the curator service, the UI, and the discovery timer all issue
     * requests from different threads.
     */
    private val rateLimitedUntil = AtomicLong(0)

    sealed class ApiException(message: String) : Exception(message) {
        class Http(val code: Int, val detail: String) :
            ApiException("Spotify API error $code: $detail")

        class RateLimited(val retryAfterMs: Long) :
            ApiException("Spotify is rate limiting us — retrying in ${(retryAfterMs + 999) / 1000}s")
    }

    // MARK: - Public operations

    suspend fun currentUserId(): String {
        @Serializable
        data class Me(val id: String)
        return getJson<Me>(url("/me")).id
    }

    /** All playlists in the user's library (paginated). */
    suspend fun allPlaylists(): List<Playlist> {
        val results = mutableListOf<Playlist>()
        paginate<PlaylistPage>(url("/me/playlists", "limit" to "50")) { page ->
            results += page.items.map { it.toPlaylist() }
        }
        return results
    }

    /**
     * The currently-playing item: its playback context, the full artist list, and the active
     * Connect device.
     *
     * Uses `/me/player` (not `/me/player/currently-playing`) because only that endpoint returns
     * the `device` object — both come back in one call. Returns null when there's no active
     * playback session (HTTP 204).
     */
    suspend fun currentContext(): CurrentlyPlaying? {
        val (body, code) = authorized(url("/me/player"))
        if (code == 204) return null // no active device / nothing playing
        throwIfError("GET /me/player", code, body)
        val r = Http.json.decodeFromString<PlayerResp>(body)
        return CurrentlyPlaying(
            contextUri = r.context?.uri,
            contextType = r.context?.type,
            artistNames = r.item?.artists.orEmpty().mapNotNull { it.name }.filter { it.isNotEmpty() },
            trackUri = r.item?.uri,
            device = r.device?.let {
                PlaybackDevice(it.id, it.name, it.type, it.is_active ?: false)
            },
        )
    }

    suspend fun playlistInfo(id: String): Playlist =
        getJson<PlaylistDto>(url("/playlists/$id", "fields" to "id,name,uri,collaborative,owner(id)"))
            .toPlaylist()

    /**
     * All track URIs in a playlist (paginated) — used for duplicate detection.
     *
     * Uses the Feb-2026 `/items` endpoint; the nested object was renamed `track` -> `item`
     * (we read either to stay robust).
     */
    suspend fun playlistTrackUris(id: String): Set<String> {
        val uris = mutableSetOf<String>()
        paginate<PlaylistItemsPage>(url("/playlists/$id/items", "limit" to "100")) { page ->
            page.items.forEach { entry -> entry.uri()?.let(uris::add) }
        }
        return uris
    }

    suspend fun addTrack(uri: String, playlistId: String) {
        val body = buildJsonObject {
            put("uris", buildJsonArray { add(JsonPrimitive(uri)) })
        }
        send("/playlists/$playlistId/items", "POST", body)
    }

    /** The playlist's current `snapshot_id`, used for optimistic concurrency on edits. */
    suspend fun playlistSnapshotId(id: String): String {
        @Serializable
        data class Resp(val snapshot_id: String)
        return getJson<Resp>(url("/playlists/$id", "fields" to "snapshot_id")).snapshot_id
    }

    /**
     * Removes a track from a playlist.
     *
     * NOTE: identifying the track by URI only (no positions) removes EVERY occurrence of that URI
     * in the playlist — the MediaSession doesn't expose the playing item's index any more than
     * macOS ScriptingBridge does, so single-occurrence removal isn't possible here. We include the
     * current `snapshot_id` so the delete fails cleanly if the playlist changed since we read it,
     * rather than acting on a stale playlist.
     *
     * [intent] is unused here beyond gating the call: it can only be built from the named
     * gesture factories on [UserRemovalIntent], so requiring it keeps an unauthorized deletion
     * from being expressible.
     */
    suspend fun removeTrack(uri: String, playlistId: String, intent: UserRemovalIntent) {
        val snapshotId = playlistSnapshotId(playlistId)
        val body = buildJsonObject {
            put("items", buildJsonArray { add(buildJsonObject { put("uri", JsonPrimitive(uri)) }) })
            put("snapshot_id", JsonPrimitive(snapshotId))
        }
        DebugLog.log("REMOVE $uri from playlist $playlistId — authorized by: ${intent.gesture}")
        send("/playlists/$playlistId/items", "DELETE", body)
    }

    // MARK: - Request plumbing

    private fun url(path: String, vararg query: Pair<String, String>): HttpUrl =
        BASE.newBuilder().apply {
            path.trim('/').split('/').forEach { addPathSegment(it) }
            query.forEach { (k, v) -> addQueryParameter(k, v) }
        }.build()

    /**
     * One authorized request: token + Bearer header + optional JSON body.
     * No status check — callers that need special-case statuses (204) inspect the code themselves.
     */
    private suspend fun authorized(
        url: HttpUrl,
        method: String = "GET",
        json: JsonObject? = null,
    ): Pair<String, Int> {
        // Refuse locally while a 429 backoff is live — no token fetch, no network.
        val until = rateLimitedUntil.get()
        if (until > 0) {
            val remaining = until - System.currentTimeMillis()
            if (remaining > 0) throw ApiException.RateLimited(remaining)
            rateLimitedUntil.compareAndSet(until, 0)
        }

        val token = auth.validAccessToken()
        val body = json?.toString()?.toRequestBody(JSON_MEDIA)
        val req = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $token")
            // OkHttp requires a body for DELETE only when one is supplied; method() takes both.
            .method(method, body ?: if (method == "GET" || method == "DELETE") null else EMPTY_BODY)
            .build()

        Http.client.newCall(req).await().use { resp ->
            if (resp.code == 429) beginBackoff(resp.header("Retry-After"))
            return (resp.body?.string().orEmpty()) to resp.code
        }
    }

    /** Start honouring a 429. See [RateLimit.backoffMs] for how the header is interpreted. */
    private fun beginBackoff(header: String?) {
        val waitMs = RateLimit.backoffMs(header)
        val until = System.currentTimeMillis() + waitMs
        // Only ever extend the window, so overlapping in-flight 429s can't shorten it.
        while (true) {
            val current = rateLimitedUntil.get()
            if (until <= current) return
            if (rateLimitedUntil.compareAndSet(current, until)) {
                DebugLog.log(
                    "rate limited: pausing API calls for ${waitMs / 1000}s " +
                        "(Retry-After: ${header ?: "absent"})"
                )
                return
            }
        }
    }

    private suspend inline fun <reified T> getJson(url: HttpUrl): T {
        val (body, code) = authorized(url)
        throwIfError("GET ${url.encodedPath}", code, body)
        return Http.json.decodeFromString<T>(body)
    }

    private suspend fun send(path: String, method: String, json: JsonObject) {
        val (body, code) = authorized(url(path), method, json)
        throwIfError("$method $path", code, body)
    }

    /** Follow a paginated endpoint from [start], feeding each decoded page to [consume]. */
    private suspend inline fun <reified P : Paged> paginate(start: HttpUrl, consume: (P) -> Unit) {
        var next: HttpUrl? = start
        while (next != null) {
            val page: P = getJson(next)
            consume(page)
            next = page.next?.toHttpUrlOrNull()
        }
    }

    private fun throwIfError(label: String, code: Int, body: String) {
        if (code in 200..299) return
        DebugLog.log("API $label -> HTTP $code: $body")
        throw ApiException.Http(code, messageFrom(body))
    }

    /** Pull Spotify's `error.message` out of the JSON body for a readable status line. */
    private fun messageFrom(body: String): String {
        runCatching {
            val message = Http.json.parseToJsonElement(body)
                .jsonObject["error"]?.jsonObject?.get("message")?.jsonPrimitive?.content
            if (message != null) return message
        }
        return body.ifEmpty { "(no details)" }
    }

    // MARK: - Wire types

    /** Anything paginated exposes `next`; lets [paginate] be generic. */
    interface Paged {
        val next: String?
    }

    @Serializable
    private data class PlaylistDto(
        val id: String,
        val name: String,
        val uri: String,
        val collaborative: Boolean = false,
        val owner: Owner = Owner(),
    ) {
        @Serializable
        data class Owner(val id: String = "")

        fun toPlaylist() = Playlist(id, name, uri, owner.id, collaborative)
    }

    @Serializable
    private data class PlaylistPage(
        val items: List<PlaylistDto> = emptyList(),
        override val next: String? = null,
    ) : Paged

    @Serializable
    private data class PlaylistItemsPage(
        val items: List<Entry> = emptyList(),
        override val next: String? = null,
    ) : Paged {
        @Serializable
        data class Entry(val item: Inner? = null, val track: Inner? = null) {
            @Serializable
            data class Inner(val uri: String? = null)

            /** Feb-2026 renamed `track` -> `item`; read either. */
            fun uri(): String? = item?.uri ?: track?.uri
        }
    }

    @Serializable
    private data class PlayerResp(
        val device: Device? = null,
        val context: Context? = null,
        val item: Item? = null,
    ) {
        @Serializable
        data class Device(
            val id: String? = null,
            val name: String? = null,
            val type: String? = null,
            val is_active: Boolean? = null,
        )

        @Serializable
        data class Context(val uri: String? = null, val type: String? = null)

        @Serializable
        data class Item(val uri: String? = null, val artists: List<Artist>? = null) {
            @Serializable
            data class Artist(val name: String? = null)
        }
    }

    private companion object {
        val BASE: HttpUrl = "https://api.spotify.com/v1".toHttpUrl()
        val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()
        val EMPTY_BODY = ByteArray(0).toRequestBody(null)
    }
}
