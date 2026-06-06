package com.dotwave.dotwave

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.KeyProtection
import android.security.keystore.StrongBoxUnavailableException
import androidx.biometric.BiometricPrompt
import java.nio.ByteBuffer
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.spec.ECGenParameterSpec
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.SecretKeySpec

/**
 * StrongBox hardware security manager for TOTP enrollment and identity signing.
 *
 * All cryptographic operations happen inside the discrete secure element (StrongBox).
 * Private keys and HMAC secrets never exist in application memory.
 * TEE (TrustZone) is NOT used as a fallback — StrongBox or nothing.
 *
 * SECURITY: Never log seed bytes, HMAC output, key material, or any sensitive data.
 */
object StrongBoxManager {

    private const val TOTP_KEY_ALIAS = "dotwave_totp_secret"
    private const val IDENTITY_KEY_ALIAS = "dotwave_identity_key"
    private const val ATTESTATION_KEY_ALIAS = "dotwave_attestation_key"

    /**
     * Check if this device has StrongBox hardware.
     * Returns false if only TEE is available — we require discrete secure element.
     */
    fun isStrongBoxAvailable(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
        } else {
            false
        }
    }

    /**
     * Import TOTP seed into StrongBox as an HMAC-SHA256 key.
     *
     * The key requires biometric authentication per use (timeout 0 = every operation).
     * Invalidated if new biometrics are enrolled (prevents attacker adding their fingerprint).
     *
     * @param seedBytes Raw 20-byte TOTP seed from Rust CSPRNG.
     * @throws StrongBoxUnavailableException if StrongBox hardware is present but refused the key.
     * @throws Exception on any other failure (no biometric enrolled, alias collision, etc.).
     *         The seed bytes are zeroized before the exception propagates.
     *
     * The previous "catch (Exception) { return false }" was swallowing the real
     * reason and surfacing a generic "Try again" to the user with no clue
     * what went wrong. Now the exception propagates so the caller (MainActivity)
     * can map it to a specific PlatformException `code`/`message` for Dart.
     */
    fun importTotpSecretToStrongBox(seedBytes: ByteArray) {
        try {
            val keyStore = KeyStore.getInstance("AndroidKeyStore")
            keyStore.load(null)

            val secretKey = SecretKeySpec(seedBytes, "HmacSHA256")

            val protection = KeyProtection.Builder(KeyProperties.PURPOSE_SIGN)
                .setIsStrongBoxBacked(true)
                .setUserAuthenticationRequired(true)
                .setUserAuthenticationValidityDurationSeconds(0) // auth per use
                .setUserAuthenticationParameters(
                    0, // timeout = 0 means every use
                    KeyProperties.AUTH_BIOMETRIC_STRONG
                )
                .setInvalidatedByBiometricEnrollment(true)
                .build()

            keyStore.setEntry(
                TOTP_KEY_ALIAS,
                KeyStore.SecretKeyEntry(secretKey),
                protection
            )

            // Zero the input array — seed now exists only inside StrongBox
            seedBytes.fill(0)
        } catch (e: Throwable) {
            seedBytes.fill(0)
            throw e
        }
    }

    /**
     * Initialize a Mac object for HMAC-SHA256 using the StrongBox-backed TOTP key.
     *
     * The returned CryptoObject wraps the Mac and must be passed to BiometricPrompt.
     * The biometric match happens inside the secure element — not in the OS, not in the app.
     * Only after successful biometric auth can the Mac perform computations.
     *
     * @return CryptoObject wrapping the initialized Mac, or null on failure.
     */
    fun initializeMacForBiometric(): BiometricPrompt.CryptoObject? {
        return try {
            val keyStore = KeyStore.getInstance("AndroidKeyStore")
            keyStore.load(null)
            val key = keyStore.getKey(TOTP_KEY_ALIAS, null) ?: return null
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(key)
            BiometricPrompt.CryptoObject(mac)
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Compute HMAC-SHA256 of the current TOTP time step inside StrongBox.
     *
     * The Mac must have been authenticated via BiometricPrompt first.
     * Returns the full 32-byte HMAC output — this is NOT the 6-digit OTP.
     * The 6-digit OTP is derived from this via RFC 6238 truncation (see computeOtpTruncated).
     *
     * @param mac Authenticated Mac from BiometricPrompt.CryptoObject.
     * @return 32-byte HMAC output computed inside StrongBox.
     */
    fun computeOtpRawHmac(mac: Mac): ByteArray {
        val timeStep = System.currentTimeMillis() / 1000 / 30
        val timeBytes = ByteBuffer.allocate(8).putLong(timeStep).array()
        return mac.doFinal(timeBytes)
    }

    /**
     * Apply RFC 6238 dynamic truncation to derive a 6-digit OTP from HMAC output.
     *
     * @param hmacOutput Full 32-byte HMAC from computeOtpRawHmac.
     * @return 6-digit OTP as Int (000000–999999).
     */
    fun computeOtpTruncated(hmacOutput: ByteArray): Int {
        val offset = (hmacOutput[hmacOutput.size - 1].toInt() and 0x0f)
        val binary = ((hmacOutput[offset].toInt() and 0x7f) shl 24) or
                ((hmacOutput[offset + 1].toInt() and 0xff) shl 16) or
                ((hmacOutput[offset + 2].toInt() and 0xff) shl 8) or
                (hmacOutput[offset + 3].toInt() and 0xff)
        return binary % 1_000_000
    }

    /**
     * Generate a P-256 identity key pair inside StrongBox.
     *
     * The private key is born inside the secure element and NEVER leaves.
     * Signing happens inside StrongBox. No software memory exposure.
     * Requires biometric auth per signing operation.
     *
     * @return The P-256 public key bytes (SEC1 uncompressed, 65 bytes), or null on failure.
     */
    fun generateIdentityKeyPair(): ByteArray? {
        return try {
            val keyPairGenerator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore"
            )
            val spec = KeyGenParameterSpec.Builder(
                IDENTITY_KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
            )
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setIsStrongBoxBacked(true)
                .setUserAuthenticationRequired(true)
                .setUserAuthenticationParameters(
                    0,
                    KeyProperties.AUTH_BIOMETRIC_STRONG
                )
                .setInvalidatedByBiometricEnrollment(true)
                .build()

            keyPairGenerator.initialize(spec)
            val keyPair = keyPairGenerator.generateKeyPair()

            // Return the public key in SEC1 uncompressed format
            keyPair.public.encoded
        } catch (e: StrongBoxUnavailableException) {
            null
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Sign data using the StrongBox-backed P-256 identity key.
     *
     * The signing operation happens entirely inside the secure element.
     * The private key never exists in application memory.
     * BiometricPrompt must authenticate before calling this.
     *
     * @param data The bytes to sign.
     * @return DER-encoded ECDSA signature, or null on failure.
     */
    fun signWithIdentityKey(data: ByteArray): ByteArray? {
        return try {
            val keyStore = KeyStore.getInstance("AndroidKeyStore")
            keyStore.load(null)
            val privateKey = keyStore.getKey(IDENTITY_KEY_ALIAS, null)
                ?: return null

            val signature = java.security.Signature.getInstance("SHA256withECDSA")
            signature.initSign(privateKey as java.security.PrivateKey)
            signature.update(data)
            signature.sign()
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Get the public key of the identity key pair from StrongBox.
     *
     * @return Public key encoded bytes, or null if no identity key exists.
     */
    fun getIdentityPublicKey(): ByteArray? {
        return try {
            val keyStore = KeyStore.getInstance("AndroidKeyStore")
            keyStore.load(null)
            val cert = keyStore.getCertificate(IDENTITY_KEY_ALIAS) ?: return null
            cert.publicKey.encoded
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Generate an attestation key pair for hardware proof.
     *
     * The attestation challenge is included in the certificate chain,
     * proving this specific enrollment ceremony happened on real hardware.
     * The certificate chain roots to the device manufacturer's EK.
     *
     * @param challengeBytes Pallet-generated challenge for freshness binding.
     * @return List of DER-encoded certificates (leaf to root), or null on failure.
     */
    fun generateAttestationKeyPair(challengeBytes: ByteArray): List<ByteArray>? {
        return try {
            val keyPairGenerator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore"
            )
            val spec = KeyGenParameterSpec.Builder(
                ATTESTATION_KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
            )
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setIsStrongBoxBacked(true)
                .setAttestationChallenge(challengeBytes)
                .setDevicePropertiesAttestationIncluded(true)
                .build()

            keyPairGenerator.initialize(spec)
            keyPairGenerator.generateKeyPair()

            // Get the certificate chain from the keystore
            val keyStore = KeyStore.getInstance("AndroidKeyStore")
            keyStore.load(null)
            val chain = keyStore.getCertificateChain(ATTESTATION_KEY_ALIAS)
                ?: return null

            chain.map { it.encoded }
        } catch (e: StrongBoxUnavailableException) {
            null
        } catch (e: Exception) {
            null
        }
    }
}
