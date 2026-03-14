package com.dotwave.dotwave

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.Cipher

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.dotwave/keystore"
    private val KEY_ALIAS = "dotwave_master_key"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "generateKey" -> {
                    try {
                        generateKeystoreKey()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("KEYSTORE_ERROR", e.message, null)
                    }
                }
                "encrypt" -> {
                    val data = call.argument<ByteArray>("data")
                    if (data == null) {
                        result.error("INVALID_ARGS", "data required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val encrypted = encryptWithKeystore(data)
                        result.success(encrypted)
                    } catch (e: Exception) {
                        result.error("ENCRYPT_ERROR", e.message, null)
                    }
                }
                "decrypt" -> {
                    val data = call.argument<ByteArray>("data")
                    if (data == null) {
                        result.error("INVALID_ARGS", "data required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val decrypted = decryptWithKeystore(data)
                        result.success(decrypted)
                    } catch (e: Exception) {
                        result.error("DECRYPT_ERROR", e.message, null)
                    }
                }
                "keyExists" -> {
                    result.success(keystoreKeyExists())
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun generateKeystoreKey() {
        if (keystoreKeyExists()) return
        val keyGenerator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore"
        )
        keyGenerator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setUserAuthenticationRequired(false)
                .build()
        )
        keyGenerator.generateKey()
    }

    private fun keystoreKeyExists(): Boolean {
        val keyStore = KeyStore.getInstance("AndroidKeyStore")
        keyStore.load(null)
        return keyStore.containsAlias(KEY_ALIAS)
    }

    private fun getKeystoreKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore")
        keyStore.load(null)
        return (keyStore.getEntry(KEY_ALIAS, null) as KeyStore.SecretKeyEntry).secretKey
    }

    private fun encryptWithKeystore(data: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getKeystoreKey())
        val iv = cipher.iv
        val encrypted = cipher.doFinal(data)
        return iv + encrypted
    }

    private fun decryptWithKeystore(data: ByteArray): ByteArray {
        val iv = data.slice(0..11).toByteArray()
        val ciphertext = data.slice(12 until data.size).toByteArray()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val spec = GCMParameterSpec(128, iv)
        cipher.init(Cipher.DECRYPT_MODE, getKeystoreKey(), spec)
        return cipher.doFinal(ciphertext)
    }
}
