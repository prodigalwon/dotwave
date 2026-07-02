package com.dotwave.dotwave

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.Cipher

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.dotwave/keystore"
    private val SECURITY_CHANNEL = "dotwave/security"
    private val KEY_ALIAS = "dotwave_master_key"

    // Holds the CryptoObject between initMacForBiometric and computeOtpRawHmac
    private var pendingCryptoObject: androidx.biometric.BiometricPrompt.CryptoObject? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Existing keystore channel (unchanged) ──
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

        // ── StrongBox security channel (TOTP + identity + attestation) ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SECURITY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isStrongBoxAvailable" -> {
                    result.success(StrongBoxManager.isStrongBoxAvailable(this))
                }
                "importTotpSecret" -> {
                    val seedBytes = call.argument<ByteArray>("seedBytes")
                    if (seedBytes == null) {
                        result.error("INVALID_ARGS", "seedBytes required", null)
                        return@setMethodCallHandler
                    }
                    // Pre-check: StrongBox HMAC keys with
                    // setUserAuthenticationRequired(true) + BIOMETRIC_STRONG
                    // will throw at creation if the device has no enrolled
                    // biometric. On a freshly-reset phone (Tony's SM-G986U
                    // scenario) this is the single most common failure.
                    // Catching it here gives the user an actionable message
                    // instead of a silent "Try again".
                    val biometricStatus = BiometricManager.from(this)
                        .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                    when (biometricStatus) {
                        BiometricManager.BIOMETRIC_SUCCESS -> { /* proceed */ }
                        BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> {
                            result.error(
                                "BIOMETRIC_NONE_ENROLLED",
                                "No biometric is enrolled on this device. " +
                                    "Open Android Settings → Biometrics " +
                                    "and enroll a fingerprint or face, then try again.",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE,
                        BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> {
                            result.error(
                                "BIOMETRIC_HARDWARE_UNAVAILABLE",
                                "Biometric hardware is not available on this device. " +
                                    "dotwave requires a StrongBox-capable Android device.",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        else -> {
                            result.error(
                                "BIOMETRIC_UNAVAILABLE",
                                "Biometric auth unavailable (status=$biometricStatus). " +
                                    "Check Android Settings and try again.",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                    }
                    try {
                        StrongBoxManager.importTotpSecretToStrongBox(seedBytes)
                        result.success(true)
                    } catch (e: android.security.keystore.StrongBoxUnavailableException) {
                        result.error(
                            "STRONGBOX_UNAVAILABLE",
                            "StrongBox rejected the key: ${e.message ?: "no detail"}",
                            null,
                        )
                    } catch (e: Throwable) {
                        result.error(
                            "TOTP_IMPORT_FAILED",
                            e.message ?: e.javaClass.simpleName,
                            null,
                        )
                    }
                }
                "initMacForBiometric" -> {
                    val crypto = StrongBoxManager.initializeMacForBiometric()
                    pendingCryptoObject = crypto
                    result.success(crypto != null)
                }
                "computeOtpRawHmac" -> {
                    val crypto = pendingCryptoObject
                    if (crypto == null) {
                        result.error("NO_MAC", "Call initMacForBiometric first", null)
                        return@setMethodCallHandler
                    }
                    // BiometricPrompt authenticates the CryptoObject inside StrongBox.
                    // Only after biometric match can the Mac compute the HMAC.
                    val executor = ContextCompat.getMainExecutor(this)
                    val prompt = BiometricPrompt(this, executor,
                        object : BiometricPrompt.AuthenticationCallback() {
                            override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult) {
                                try {
                                    val authedMac = authResult.cryptoObject?.mac
                                    if (authedMac == null) {
                                        result.error("AUTH_ERROR", "No Mac after auth", null)
                                        return
                                    }
                                    val hmac = StrongBoxManager.computeOtpRawHmac(authedMac)
                                    result.success(hmac)
                                } catch (e: Exception) {
                                    result.error("HMAC_ERROR", e.message, null)
                                }
                            }
                            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                                result.error("BIOMETRIC_ERROR", errString.toString(), null)
                            }
                            override fun onAuthenticationFailed() {
                                // Don't error yet — the OS may allow retry
                            }
                        }
                    )
                    val promptInfo = BiometricPrompt.PromptInfo.Builder()
                        .setTitle("Authenticate")
                        .setSubtitle("Verify your identity")
                        .setNegativeButtonText("Cancel")
                        .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                        .build()
                    prompt.authenticate(promptInfo, crypto)
                }
                "computeOtpTruncated" -> {
                    val hmacOutput = call.argument<ByteArray>("hmacOutput")
                    if (hmacOutput == null) {
                        result.error("INVALID_ARGS", "hmacOutput required", null)
                        return@setMethodCallHandler
                    }
                    result.success(StrongBoxManager.computeOtpTruncated(hmacOutput))
                }
                "generateIdentityKeyPair" -> {
                    val pubkey = StrongBoxManager.generateIdentityKeyPair()
                    if (pubkey != null) {
                        result.success(pubkey)
                    } else {
                        result.error("STRONGBOX_ERROR", "Failed to generate identity key", null)
                    }
                }
                "getIdentityPublicKey" -> {
                    result.success(StrongBoxManager.getIdentityPublicKey())
                }
                "signWithIdentityKey" -> {
                    val data = call.argument<ByteArray>("data")
                    if (data == null) {
                        result.error("INVALID_ARGS", "data required", null)
                        return@setMethodCallHandler
                    }
                    // StrongBox requires biometric auth before signing.
                    // Present BiometricPrompt, then sign on success.
                    val executor = ContextCompat.getMainExecutor(this)
                    val prompt = BiometricPrompt(this, executor,
                        object : BiometricPrompt.AuthenticationCallback() {
                            override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult) {
                                val sig = StrongBoxManager.signWithIdentityKey(data)
                                if (sig != null) {
                                    result.success(sig)
                                } else {
                                    result.error("SIGN_ERROR", "Signing failed after auth", null)
                                }
                            }
                            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                                result.error("BIOMETRIC_ERROR", errString.toString(), null)
                            }
                            override fun onAuthenticationFailed() {
                                // OS may allow retry
                            }
                        }
                    )
                    val promptInfo = BiometricPrompt.PromptInfo.Builder()
                        .setTitle("Sign Transaction")
                        .setSubtitle("Biometric required for signing")
                        .setNegativeButtonText("Cancel")
                        .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                        .build()
                    prompt.authenticate(promptInfo)
                }
                "generateContentKeyPair" -> {
                    val pubkey = StrongBoxManager.generateContentKeyPair()
                    if (pubkey != null) {
                        result.success(pubkey)
                    } else {
                        result.error("CONTENT_KEY_ERROR", "Failed to generate content key (StrongBox/API-31 required)", null)
                    }
                }
                "getContentPublicKey" -> {
                    result.success(StrongBoxManager.getContentPublicKey())
                }
                "contentEcdh" -> {
                    val ephemeral = call.argument<ByteArray>("ephemeralSec1")
                    if (ephemeral == null) {
                        result.error("INVALID_ARGS", "ephemeralSec1 required", null)
                        return@setMethodCallHandler
                    }
                    // Biometric gate: one STRONG prompt authorizes the in-chip
                    // ECDH for the content key's auth window, then we run the
                    // key agreement inside StrongBox.
                    val executor = ContextCompat.getMainExecutor(this)
                    val prompt = BiometricPrompt(this, executor,
                        object : BiometricPrompt.AuthenticationCallback() {
                            override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult) {
                                val shared = StrongBoxManager.computeContentEcdh(ephemeral)
                                if (shared != null) {
                                    result.success(shared)
                                } else {
                                    result.error("ECDH_ERROR", "In-chip ECDH failed after auth", null)
                                }
                            }
                            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                                result.error("BIOMETRIC_ERROR", errString.toString(), null)
                            }
                            override fun onAuthenticationFailed() {
                                // OS may allow retry
                            }
                        }
                    )
                    val promptInfo = BiometricPrompt.PromptInfo.Builder()
                        .setTitle("Decrypt Message")
                        .setSubtitle("Biometric required to read")
                        .setNegativeButtonText("Cancel")
                        .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                        .build()
                    prompt.authenticate(promptInfo)
                }
                "membershipEnsureWKey" -> {
                    // Idempotent: returns the existing W pubkey if the key
                    // exists (never rotates — see StrongBoxManager docs).
                    // Key GENERATION needs no biometric; only the ECDH does.
                    val pubkey = StrongBoxManager.ensureMembershipWKey()
                    if (pubkey != null) {
                        result.success(pubkey)
                    } else {
                        result.error("MEMBERSHIP_W_ERROR", "Failed to ensure membership W key (StrongBox/API-31 required)", null)
                    }
                }
                "membershipEcdh" -> {
                    val pFixed = call.argument<ByteArray>("pFixedSec1")
                    if (pFixed == null) {
                        result.error("INVALID_ARGS", "pFixedSec1 required", null)
                        return@setMethodCallHandler
                    }
                    // Biometric gate: one STRONG prompt authorizes the
                    // in-chip ECDH(W, P_FIXED) for the auth window. Same
                    // windowed model as contentEcdh.
                    val executor = ContextCompat.getMainExecutor(this)
                    val prompt = BiometricPrompt(this, executor,
                        object : BiometricPrompt.AuthenticationCallback() {
                            override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult) {
                                val shared = StrongBoxManager.computeMembershipEcdh(pFixed)
                                if (shared != null) {
                                    result.success(shared)
                                } else {
                                    result.error("ECDH_ERROR", "In-chip membership ECDH failed after auth", null)
                                }
                            }
                            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                                result.error("BIOMETRIC_ERROR", errString.toString(), null)
                            }
                            override fun onAuthenticationFailed() {
                                // OS may allow retry
                            }
                        }
                    )
                    val promptInfo = BiometricPrompt.PromptInfo.Builder()
                        .setTitle("Prove Membership")
                        .setSubtitle("Biometric required to authenticate")
                        .setNegativeButtonText("Cancel")
                        .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                        .build()
                    prompt.authenticate(promptInfo)
                }
                "zkpkiSignIdBinding" -> {
                    val bindingMsg = call.argument<ByteArray>("bindingMsg")
                    if (bindingMsg == null || bindingMsg.size != 32) {
                        result.error("INVALID_ARGS", "bindingMsg (32 bytes) required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(ZkPkiCeremony.signIdBinding(bindingMsg))
                    } catch (e: Exception) {
                        result.error(
                            "ID_BINDING_ERROR",
                            e.message ?: "attest_ec id-binding signature failed",
                            mapOf("errorClass" to e.javaClass.name)
                        )
                    }
                }
                "getAttestationCertChain" -> {
                    val challengeBytes = call.argument<ByteArray>("challengeBytes")
                    if (challengeBytes == null) {
                        result.error("INVALID_ARGS", "challengeBytes required", null)
                        return@setMethodCallHandler
                    }
                    val chain = StrongBoxManager.generateAttestationKeyPair(challengeBytes)
                    if (chain != null) {
                        result.success(chain)
                    } else {
                        result.error("ATTESTATION_ERROR", "Failed to generate attestation", null)
                    }
                }
                "mimeWrapEnsureAssets" -> {
                    // Stage 2 PoC: copy Groth16 circuit artifacts
                    // (wasm + r1cs + zkey) from APK assets to filesDir
                    // and return the absolute paths so the Rust-side
                    // benchmark can open them. Idempotent — first
                    // call on a fresh install copies ~70MB; subsequent
                    // calls short-circuit on file existence.
                    try {
                        val paths = MimeWrapAssets.ensure(this)
                        result.success(
                            mapOf(
                                "wasmPath" to paths.wasmPath,
                                "r1csPath" to paths.r1csPath,
                                "zkeyPath" to paths.zkeyPath,
                            )
                        )
                    } catch (e: Exception) {
                        result.error(
                            "ASSET_COPY_ERROR",
                            e.message ?: "Unknown asset-copy failure",
                            mapOf("errorClass" to e.javaClass.name)
                        )
                    }
                }
                "pcHmacSmokeTest" -> {
                    // Stage 0 keystone check for the mime-wrap Android
                    // design — verifies that symmetric HMAC keys can be
                    // generated with setUserConfirmationRequired and that
                    // the auth requirement is enforced by StrongBox.
                    // Synchronous; creates and deletes a throwaway test
                    // key inside run(). No side effects on ceremony keys.
                    try {
                        val out = PcHmacSmokeTest.run(this)
                        result.success(out)
                    } catch (e: Exception) {
                        result.error(
                            "SMOKETEST_ERROR",
                            e.message ?: "Unknown smoke-test failure",
                            mapOf("errorClass" to e.javaClass.name)
                        )
                    }
                }
                "zkpkiCeremony" -> {
                    val attestationChallenge = call.argument<ByteArray>("attestationChallenge")
                    if (attestationChallenge == null) {
                        result.error(
                            "ZKPKI_ERROR",
                            "attestationChallenge required",
                            mapOf("errorCode" to "INVALID_ARGS")
                        )
                        return@setMethodCallHandler
                    }
                    try {
                        val out = ZkPkiCeremony.run(this, attestationChallenge)
                        result.success(out)
                    } catch (e: ZkPkiException) {
                        result.error(
                            "ZKPKI_ERROR",
                            e.message,
                            mapOf("errorCode" to e.errorCode)
                        )
                    } catch (e: android.security.keystore.StrongBoxUnavailableException) {
                        result.error(
                            "ZKPKI_ERROR",
                            e.message ?: "StrongBox unavailable",
                            mapOf("errorCode" to "STRONGBOX_UNAVAILABLE")
                        )
                    } catch (e: java.security.InvalidAlgorithmParameterException) {
                        result.error(
                            "ZKPKI_ERROR",
                            e.message ?: "Invalid key parameters",
                            mapOf("errorCode" to "INVALID_KEY_PARAMS")
                        )
                    } catch (e: java.security.KeyStoreException) {
                        result.error(
                            "ZKPKI_ERROR",
                            e.message ?: "KeyStore failure",
                            mapOf("errorCode" to "KEYSTORE_ERROR")
                        )
                    } catch (e: Exception) {
                        result.error(
                            "ZKPKI_ERROR",
                            e.message ?: "Unknown ceremony failure",
                            mapOf("errorCode" to "UNKNOWN")
                        )
                    }
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
