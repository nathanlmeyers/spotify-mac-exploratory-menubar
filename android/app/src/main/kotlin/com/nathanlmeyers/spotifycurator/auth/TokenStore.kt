package com.nathanlmeyers.spotifycurator.auth

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.nathanlmeyers.spotifycurator.support.DebugLog
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Android analogue of the macOS `KeychainStore`: persists the OAuth token bundle encrypted at
 * rest under a hardware-backed Android Keystore key.
 *
 * We roll this rather than use `androidx.security:security-crypto` (EncryptedSharedPreferences),
 * which is deprecated. It is ~40 lines either way.
 *
 * The key is **not** `setUserAuthenticationRequired`, which is the equivalent of the Mac's
 * `kSecAttrAccessibleAfterFirstUnlock`: the curator service has to be able to refresh a token
 * and act on an Add while the screen is locked, which is the entire point of the app.
 */
class TokenStore(context: Context) {

    private val file = File(context.filesDir, "spotify-oauth.bin")

    fun load(): String? {
        if (!file.exists()) return null
        return runCatching {
            val blob = file.readBytes()
            // Layout: [1 byte iv length][iv][ciphertext]
            val ivLen = blob[0].toInt()
            val iv = blob.copyOfRange(1, 1 + ivLen)
            val cipherText = blob.copyOfRange(1 + ivLen, blob.size)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, iv))
            String(cipher.doFinal(cipherText), Charsets.UTF_8)
        }.onFailure {
            // A wiped/rotated Keystore key makes the blob permanently undecryptable. Drop it so
            // the user just sees "logged out" instead of an app that fails every request.
            DebugLog.log("token store unreadable (${it.javaClass.simpleName}) — clearing")
            delete()
        }.getOrNull()
    }

    fun save(json: String) {
        runCatching {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, key())
            val cipherText = cipher.doFinal(json.toByteArray(Charsets.UTF_8))
            val iv = cipher.iv
            file.writeBytes(byteArrayOf(iv.size.toByte()) + iv + cipherText)
        }.onFailure { DebugLog.log("token store write failed: $it") }
    }

    fun delete() {
        file.delete()
    }

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        gen.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return gen.generateKey()
    }

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val ALIAS = "com.nathanlmeyers.spotifycurator.tokens"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val TAG_BITS = 128
    }
}
