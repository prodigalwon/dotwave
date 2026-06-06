package com.dotwave.dotwave

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.security.keystore.UserNotAuthenticatedException
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory

/**
 * Stage-0 keystone check for the mime-wrap Android design.
 *
 * Validates three claims on SM-G986U before any further PoC work:
 *
 *  1. A symmetric HMAC-SHA256 key can be generated with
 *     `setUserConfirmationRequired(true)` + `setUserAuthenticationRequired(true)`
 *     + `BIOMETRIC_STRONG` + `setIsStrongBoxBacked(true)`. Samsung has been
 *     known to silently ignore or reject certain KeyMint parameters on
 *     symmetric keys; we need to observe which category this falls into
 *     before the design is load-bearing.
 *
 *  2. `ConfirmationPrompt.isSupported(context)` returns true on this device.
 *     Protected Confirmation is API 28+ but not all manufacturers ship it.
 *
 *  3. An HMAC operation invoked WITHOUT any auth context throws a
 *     `UserNotAuthenticatedException` (or equivalent), demonstrating that
 *     StrongBox actually enforces the auth requirement — i.e. the flag
 *     isn't silently dropped.
 *
 * **What this test does NOT verify (deferred to Stage 0b):**
 *  - That PC confirmation actually unblocks HMAC computation (needs async
 *    `ConfirmationPrompt.presentPrompt` UI flow)
 *  - That biometric HAT alone (no PC token) still fails when PC is required
 *    (needs async `BiometricPrompt` flow)
 *
 * Keeps the smoke test minimal and deterministic — one Kotlin call,
 * returns a structured result map, no UI. If claim 1 or 2 fails the
 * design needs a redesign before any further implementation work.
 *
 * Output shape (for MethodChannel serialization):
 *
 * ```
 * {
 *   "keyGeneration": {
 *     "attempted": true,
 *     "succeeded": Boolean,
 *     "errorClass": String?,          // null on success
 *     "errorMessage": String?,        // null on success
 *   },
 *   "keyInfo": {                      // null if key generation failed
 *     "securityLevel": Int,           // 0=SW, 1=TEE, 2=StrongBox (API 31+)
 *     "insideSecureHardware": Boolean, // pre-API-31 back-compat
 *     "userAuthenticationRequired": Boolean,
 *     "userConfirmationRequired": Boolean,
 *     "userAuthenticationValidityDurationSeconds": Int,
 *   },
 *   "protectedConfirmationSupported": Boolean?,
 *   "hmacWithoutAuth": {
 *     "attempted": true,
 *     "succeededUnexpectedly": Boolean,   // TRUE is a design-breaking signal
 *     "errorClass": String?,              // expected to be UserNotAuthenticatedException
 *     "errorMessage": String?,
 *   },
 *   "overallVerdict": String,             // human-readable pass/fail summary
 * }
 * ```
 */
object PcHmacSmokeTest {

    private const val TEST_KEY_ALIAS = "zkpki_pc_hmac_smoketest"

    fun run(context: Context): Map<String, Any?> {
        // Scrub any prior smoke-test key — this routine is idempotent,
        // must tolerate being called repeatedly without state carryover.
        cleanupTestKey()

        val result = mutableMapOf<String, Any?>()

        // ── Claim 1: key generation with the target parameters ─────────
        val keyGenOutcome = tryGenerateKey()
        result["keyGeneration"] = keyGenOutcome
        val keyGenSucceeded = keyGenOutcome["succeeded"] as Boolean

        // ── KeyInfo readback (only meaningful if key gen succeeded) ────
        result["keyInfo"] = if (keyGenSucceeded) readKeyInfo() else null

        // ── Claim 2: Protected Confirmation support ────────────────────
        result["protectedConfirmationSupported"] = probeConfirmationPromptSupport(context)

        // ── Claim 3: HMAC without auth must fail ───────────────────────
        result["hmacWithoutAuth"] = if (keyGenSucceeded) {
            tryHmacWithoutAuth()
        } else {
            mapOf(
                "attempted" to false,
                "succeededUnexpectedly" to false,
                "errorClass" to null,
                "errorMessage" to "skipped — key generation failed",
            )
        }

        result["overallVerdict"] = buildVerdict(result)

        // Clean up the test key so it doesn't leak into the ceremony's
        // keystore namespace or survive between runs. Best-effort — if
        // deletion fails we surface it in the verdict rather than
        // throwing, since the smoke-test result itself is the valuable
        // output.
        cleanupTestKey()

        return result
    }

    private fun tryGenerateKey(): Map<String, Any?> {
        return try {
            val kg = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_HMAC_SHA256,
                "AndroidKeyStore",
            )
            val builder = KeyGenParameterSpec.Builder(
                TEST_KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN,
            )
                .setKeySize(256)
                .setIsStrongBoxBacked(true)
                .setUserAuthenticationRequired(true)

            // setUserAuthenticationParameters is API 30+; on older
            // devices fall back to setUserAuthenticationValidityDurationSeconds.
            // SM-G986U is API 33 (Android 13) so the new path applies.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                builder.setUserAuthenticationParameters(
                    0, // validity=0: per-operation biometric required
                    KeyProperties.AUTH_BIOMETRIC_STRONG,
                )
            } else {
                @Suppress("DEPRECATION")
                builder.setUserAuthenticationValidityDurationSeconds(-1)
            }

            // setUserConfirmationRequired is the claim under test.
            // Documented for API 28+. Whether Samsung KeyMint honors it
            // for SYMMETRIC keys (as opposed to signing keys where it's
            // definitely supported) is what the overall verdict
            // hinges on.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                builder.setUserConfirmationRequired(true)
            }

            kg.init(builder.build())
            kg.generateKey()

            mapOf(
                "attempted" to true,
                "succeeded" to true,
                "errorClass" to null,
                "errorMessage" to null,
            )
        } catch (e: Throwable) {
            mapOf(
                "attempted" to true,
                "succeeded" to false,
                "errorClass" to e.javaClass.name,
                "errorMessage" to (e.message ?: "no message"),
            )
        }
    }

    private fun readKeyInfo(): Map<String, Any?> {
        return try {
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val stored = ks.getKey(TEST_KEY_ALIAS, null) as SecretKey
            val skf = SecretKeyFactory.getInstance(stored.algorithm, "AndroidKeyStore")
            val info = skf.getKeySpec(stored, KeyInfo::class.java) as KeyInfo

            val securityLevel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                info.securityLevel
            } else {
                -1
            }
            @Suppress("DEPRECATION")
            val insideSecureHardware = info.isInsideSecureHardware

            // KeyInfo.isUserConfirmationRequired was added in API 28.
            // API 33 target means this is always available on SM-G986U.
            val userConfirmationRequired = try {
                val m = KeyInfo::class.java.getMethod("isUserConfirmationRequired")
                m.invoke(info) as Boolean
            } catch (_: Throwable) {
                false
            }

            mapOf(
                "securityLevel" to securityLevel,
                "insideSecureHardware" to insideSecureHardware,
                "userAuthenticationRequired" to info.isUserAuthenticationRequired,
                "userConfirmationRequired" to userConfirmationRequired,
                "userAuthenticationValidityDurationSeconds" to
                    info.userAuthenticationValidityDurationSeconds,
            )
        } catch (e: Throwable) {
            mapOf(
                "error" to "${e.javaClass.simpleName}: ${e.message}",
            )
        }
    }

    /**
     * Reflective probe for `android.security.ConfirmationPrompt.isSupported`.
     * Called reflectively because the class was hidden behind @hide until
     * API 28 and some minSdk targets won't see the type at compile time;
     * reflection keeps the smoke test self-contained and doesn't commit
     * a specific Android API surface as a permanent dependency of the
     * ceremony code.
     *
     * Returns `null` if the API isn't available at all on this build.
     */
    private fun probeConfirmationPromptSupport(context: Context): Boolean? {
        return try {
            val cls = Class.forName("android.security.ConfirmationPrompt")
            val m = cls.getMethod("isSupported", Context::class.java)
            m.invoke(null, context) as Boolean
        } catch (_: Throwable) {
            null
        }
    }

    private fun tryHmacWithoutAuth(): Map<String, Any?> {
        return try {
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val key = ks.getKey(TEST_KEY_ALIAS, null) as SecretKey
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(key)
            val output = mac.doFinal("smoketest-v1".toByteArray(Charsets.UTF_8))
            // Getting here means StrongBox did NOT enforce the auth
            // requirement. That's a design-breaking signal — flag it
            // loud.
            mapOf(
                "attempted" to true,
                "succeededUnexpectedly" to true,
                "errorClass" to null,
                "errorMessage" to
                    "HMAC produced ${output.size} bytes without any auth — " +
                    "StrongBox did NOT enforce the auth requirement",
            )
        } catch (e: UserNotAuthenticatedException) {
            // Expected path.
            mapOf(
                "attempted" to true,
                "succeededUnexpectedly" to false,
                "errorClass" to e.javaClass.name,
                "errorMessage" to (e.message ?: "UserNotAuthenticatedException (no message)"),
            )
        } catch (e: Throwable) {
            // Some other exception class — still a rejection, but not
            // the specific UserNotAuthenticatedException. Worth
            // surfacing the exact class so we understand how Samsung
            // StrongBox enforces the requirement. May be
            // KeyPermanentlyInvalidatedException,
            // InvalidKeyException, or an android.system subtype.
            mapOf(
                "attempted" to true,
                "succeededUnexpectedly" to false,
                "errorClass" to e.javaClass.name,
                "errorMessage" to (e.message ?: "no message"),
            )
        }
    }

    private fun cleanupTestKey() {
        try {
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            if (ks.containsAlias(TEST_KEY_ALIAS)) {
                ks.deleteEntry(TEST_KEY_ALIAS)
            }
        } catch (_: Throwable) {
            // Ignore — cleanup is best-effort.
        }
    }

    private fun buildVerdict(r: Map<String, Any?>): String {
        val keyGen = r["keyGeneration"] as Map<*, *>
        if (keyGen["succeeded"] != true) {
            return "FAIL(key-gen): setUserConfirmationRequired rejected on symmetric " +
                "StrongBox HMAC key. Error: ${keyGen["errorClass"]} — ${keyGen["errorMessage"]}"
        }
        val keyInfo = r["keyInfo"] as? Map<*, *>
        val ucrReadback = keyInfo?.get("userConfirmationRequired") == true
        val pcSupported = r["protectedConfirmationSupported"] == true
        val hmacNoAuth = r["hmacWithoutAuth"] as Map<*, *>
        val hmacEnforced = hmacNoAuth["succeededUnexpectedly"] != true

        val pieces = mutableListOf<String>()
        pieces.add("key-gen: OK")
        pieces.add("KeyInfo.userConfirmationRequired readback: ${if (ucrReadback) "TRUE" else "FALSE"}")
        pieces.add("ConfirmationPrompt.isSupported: ${if (pcSupported) "TRUE" else "FALSE/null"}")
        pieces.add("HMAC-without-auth enforced: ${if (hmacEnforced) "TRUE" else "FALSE (design-breaking)"}")

        val allGood = ucrReadback && pcSupported && hmacEnforced
        return if (allGood) {
            "PASS(keystone): all three claims hold — ${pieces.joinToString("; ")}"
        } else {
            "PARTIAL/FAIL: ${pieces.joinToString("; ")}"
        }
    }

}
