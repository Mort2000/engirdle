package com.engirdle.native_services

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Android Keystore-backed secret store for the mobile translation module
 * (lightweight-readpack design §10.1).
 *
 * Secrets are encrypted with a single non-exportable AES-256/GCM key held by
 * AndroidKeyStore; the ciphertext blobs live in the no-backup files dir so
 * they are excluded from cloud backups. The key is deliberately NOT
 * per-use-authenticating: background translation must run unattended.
 *
 * Blob layout: 12-byte IV followed by the GCM ciphertext+tag.
 */
class SecretStore(private val context: Context) {
    private val keyAlias = "engirdle.secrets.aes"

    fun read(alias: String): String? {
        val file = blobFile(alias)
        if (!file.exists()) return null
        val blob = file.readBytes()
        if (blob.size <= IV_LENGTH) return null
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, blob, 0, IV_LENGTH))
        val plain = cipher.doFinal(blob, IV_LENGTH, blob.size - IV_LENGTH)
        return String(plain, Charsets.UTF_8)
    }

    fun write(alias: String, secret: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val cipherText = cipher.doFinal(secret.toByteArray(Charsets.UTF_8))
        val blob = cipher.iv + cipherText
        val dir = File(context.noBackupFilesDir, "secrets").apply { mkdirs() }
        val file = blobFile(alias)
        val tmp = File(dir, file.name + ".tmp")
        tmp.writeBytes(blob)
        if (!tmp.renameTo(file)) {
            tmp.delete()
            throw IllegalStateException("could not persist secret for $alias")
        }
    }

    fun delete(alias: String) {
        blobFile(alias).delete()
    }

    private fun blobFile(alias: String): File =
        File(File(context.noBackupFilesDir, "secrets"), aliasToFileName(alias))

    private fun aliasToFileName(alias: String): String =
        alias.toByteArray(Charsets.UTF_8).joinToString("") { "%02x".format(it) } + ".bin"

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(keyAlias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(KEY_BITS)
                .build(),
        )
        return generator.generateKey()
    }

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val IV_LENGTH = 12
        private const val TAG_BITS = 128
        private const val KEY_BITS = 256
    }
}
