package com.nathanlmeyers.spotifycurator.curation

/**
 * A Remove that is waiting on a second, explicit press because the track sits in the source
 * playlist more than once.
 *
 * Spotify's delete takes a URI and no positions, so one press takes every copy — the MediaSession
 * never exposes the playing row's index, so there is no narrower call to make. The count can't be
 * prevented, only shown: this makes it part of the decision instead of something you discover
 * afterwards in a playlist that is short by four songs.
 *
 * **Why a second press rather than a dialog.** The Mac swaps the popover's buttons for a
 * Cancel / Remove-all pair. There is no equivalent here: the whole point of the notification is
 * that it works on a *locked* phone, where nothing can be shown but the one status line and the
 * buttons already in the layout. So the prompt goes in the status line and the Remove button
 * itself becomes the confirmation — but only for [WINDOW_MS], and only for the exact track and
 * playlist it was armed for. A press outside either bound arms a fresh prompt instead of
 * deleting, so a stale confirmation can never be answered by accident.
 */
data class PendingDuplicateRemoval(
    val uri: String,
    val trackName: String?,
    val playlistId: String,
    val playlistName: String,
    /** Rows this removal will take. Always > 1; a single-row removal never prompts. */
    val count: Int,
    /** `System.currentTimeMillis()` when the prompt was armed. */
    val armedAtMs: Long,
) {
    /** True when a Remove press should be treated as confirming *this* prompt. */
    fun isConfirmedBy(uri: String, playlistId: String, nowMs: Long): Boolean =
        this.uri == uri &&
            this.playlistId == playlistId &&
            nowMs >= armedAtMs &&
            nowMs - armedAtMs <= WINDOW_MS

    /** The line the notification shows while this is armed. */
    fun prompt(): String {
        val subject = trackName?.let { "“$it”" } ?: "This track"
        return "$subject is in $playlistName $count times — press Remove again to delete all $count."
    }

    companion object {
        /**
         * How long the arming press stays answerable. Long enough to read the line on a lock
         * screen and decide; short enough that a phone put back in a pocket doesn't stay armed.
         */
        const val WINDOW_MS = 30_000L
    }
}
