package com.nathanlmeyers.spotifycurator.curation

/**
 * Proof that a deletion was authorized by a physical user gesture.
 *
 * Port of the macOS `UserRemovalIntent`. Every layer that can delete something — the API client,
 * and the curation actions above it — requires one of these, so a code path that deletes without
 * a button press cannot be written.
 *
 * **How this differs from the Swift original.** Swift uses a `fileprivate init`, so only the
 * button handlers sharing that file can mint an intent. Kotlin has no file-private constructor:
 * `private` on a constructor means class-private, and `internal` means the whole module. So
 * instead of restricting *who* can construct one, this restricts *what* can be constructed —
 * the constructor is private and the only ways in are the named factories below, each of which
 * corresponds to a real button. Auto-skip cannot fabricate an intent with an invented reason;
 * adding a new one means adding a named factory here, in the one file whose entire job is to
 * enumerate the gestures that may delete a song.
 *
 * This exists because an auto-skip rule once deleted 15 songs with no button press.
 * See the "no removal without the minus button" rule.
 */
class UserRemovalIntent private constructor(
    /** The gesture that authorized this, logged at the point of deletion. */
    val gesture: String,
) {
    companion object {
        /** The Remove (minus) button on the ongoing/lock-screen notification. */
        fun removeButton() = UserRemovalIntent("Remove button")

        /** The Remove button on the Discovery held-review panel. */
        fun heldPanelRemoveButton() = UserRemovalIntent("held-panel Remove button")

        /**
         * The Add button, when "move on add" is enabled — the press authorizes both halves of
         * the move. Still a button press; still gated by `DiscoveryLogic.mayRemoveFromSource`,
         * which refuses to move-delete out of the target playlist.
         */
        fun addButtonMove() = UserRemovalIntent("Add button (move)")
    }
}
