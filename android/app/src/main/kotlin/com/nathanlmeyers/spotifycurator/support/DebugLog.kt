package com.nathanlmeyers.spotifycurator.support

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Appends timestamped diagnostics to `filesDir/debug.log`, mirroring the macOS `DebugLog`.
 *
 * File-based rather than logcat-only because logcat is a ring buffer: by the time you notice
 * a track went missing, the line naming the URI that was deleted is long gone. On the Mac
 * this file is the only record of what a Remove took out, and the same is true here.
 */
object DebugLog {
    const val TAG = "SpotifyCurator"

    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "SpotifyCurator.debuglog") }
    private val stamp = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    @Volatile private var file: File? = null

    fun install(context: Context) {
        file = File(context.filesDir, "debug.log")
    }

    fun log(message: String) {
        Log.i(TAG, message)
        val target = file ?: return
        val line = "${stamp.format(Date())} $message\n"
        io.execute {
            runCatching {
                // Trim before appending so a long-running service can't grow this without
                // bound; 512 KB keeps several days of curation history.
                if (target.length() > 512 * 1024) {
                    val keep = target.readLines().takeLast(2000)
                    target.writeText(keep.joinToString("\n", postfix = "\n"))
                }
                target.appendText(line)
            }
        }
    }
}
