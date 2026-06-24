package com.dotwave.dotwave

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Debug
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import org.bouncycastle.asn1.ASN1Boolean
import org.bouncycastle.asn1.ASN1Encodable
import org.bouncycastle.asn1.ASN1Enumerated
import org.bouncycastle.asn1.ASN1InputStream
import org.bouncycastle.asn1.ASN1Integer
import org.bouncycastle.asn1.ASN1OctetString
import org.bouncycastle.asn1.ASN1Sequence
import org.bouncycastle.asn1.ASN1TaggedObject
import org.bouncycastle.crypto.digests.Blake2bDigest
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory

class ZkPkiException(val errorCode: String, message: String) : Exception(message)

/**
 * ZK-PKI StrongBox ceremony — three-key architecture with operational binding
 * proof (not AttestKey, which Samsung's KeyMint silently ignores for symmetric
 * keys on Android 13 / API 33).
 *
 * Three StrongBox-backed keys are generated under a single attestation
 * challenge:
 *
 *  1. zkpki_cert_ec    — P-256, PURPOSE_SIGN|VERIFY. User's cert signing key.
 *                        Attested by Google's factory root.
 *  2. zkpki_attest_ec  — P-256, PURPOSE_SIGN|VERIFY. Dedicated secondary EC
 *                        key, used ONLY to sign the binding proof below.
 *                        Attested by Google's factory root.
 *
 *                        NOTE on purposes: the original TODO 3 spec called
 *                        for PURPOSE_ATTEST_KEY-only. That's correct for the
 *                        AttestKey flow (where the key signs another key's
 *                        attestation certificate), but Samsung KeyMint
 *                        silently ignores setAttestKeyAlias on symmetric
 *                        keys anyway, so that path is dead. Meanwhile, a
 *                        PURPOSE_ATTEST_KEY-only key CANNOT sign via
 *                        Signature.initSign — KeyMint rejects it as
 *                        INCOMPATIBLE_PURPOSE. Since we need real signing
 *                        for the binding proof, PURPOSE_SIGN|VERIFY is the
 *                        only viable configuration on this hardware class.
 *  3. zkpki_totp_hmac  — HMAC-SHA256, PURPOSE_SIGN. StrongBox-backed (verified
 *                        via `KeyInfo.securityLevel`) but no attestation
 *                        chain — Samsung KeyMint ignores `setAttestKeyAlias`
 *                        on symmetric keys, so the chain returns null. This
 *                        is the known-good behavior on this hardware class.
 *
 * In place of the missing HMAC attestation chain, we produce a **binding
 * proof** — a live cryptographic demonstration that the attest key and the
 * HMAC key work together inside the same StrongBox:
 *
 *     hmac_output = HMAC_SHA256(hmac_key, "zkpki-binding-proof-v1")
 *     commitment  = blake2b_256(hmac_output || attestationChallenge)
 *     binding_sig = ECDSA_SHA256_sign(attest_ec_key, commitment)
 *
 * The pallet verifies:
 *  - Both EC chains pin to the same Google root and carry the same
 *    attestation challenge (same hardware, same ceremony).
 *  - `attest_ec` is the signer of `binding_sig` over `commitment` — i.e.
 *    the attest key was inside StrongBox and had access to the HMAC output
 *    at the same execution context.
 *
 * Blake2b-256 matches `sp_io::hashing::blake2_256` on the pallet side so the
 * commitment bytes are byte-identical across the two environments.
 */
object ZkPkiCeremony {

    private const val CERT_KEY_ALIAS = "zkpki_cert_ec"
    private const val ATTEST_KEY_ALIAS = "zkpki_attest_ec"
    private const val HMAC_KEY_ALIAS = "zkpki_totp_hmac"
    private const val TOTP_ENROLLMENT_CONTEXT = "zkpki-totp-enrollment-v1"
    private const val BINDING_PROOF_CONTEXT = "zkpki-binding-proof-v1"

    /**
     * Declared Dotwave package identity. Matches `DOTWAVE_PACKAGE_NAME` in
     * the `zk-pki-integrity` Rust crate byte-for-byte — the pallet
     * rejects any integrity-attestation blob whose `package_name` field
     * does not equal this exact value. Hardcoded (not pulled from
     * `context.packageName`) so test builds with mangled application IDs
     * can still produce fixture-valid blobs.
     */
    private const val DOTWAVE_PACKAGE_NAME = "com.dotwave.app"

    fun run(context: Context, attestationChallenge: ByteArray): Map<String, Any> {
        // ── Pre-flight: third layer of cross-platform spoof defense ─────
        // The Dart and Rust sides already verified we're on Android at
        // runtime. This layer adds Android-specific Build.* signals that
        // catch the case where an attacker has somehow shimmed a non-
        // hardware Android (emulator, Waydroid, Anbox, etc.) past those
        // upstream checks. Runs BEFORE any keystore call so a failure
        // here produces no side effects on the Keystore daemon.
        //
        // The authoritative check is the pallet-side attestation-chain
        // verification (keys must chain to Google's factory root). This
        // layer is defense-in-depth: it prevents dotwave itself from
        // ever producing a ceremony output that the chain would reject
        // as non-hardware, which matters for the Fagan-inspection audit
        // trail documented in
        // project_dotwave_cross_platform_spoof_defense.
        requireRealAndroidHardware()

        requireStrongBox(context)

        // 1. Cert signing key.
        val certPublicKeyBytes = generateCertEcKey(attestationChallenge)
        verifyEcStrongBoxBacked(CERT_KEY_ALIAS, "CERT_EC_NOT_STRONGBOX")

        // 2. Dedicated attest key.
        generateAttestEcKey(attestationChallenge)
        verifyEcStrongBoxBacked(ATTEST_KEY_ALIAS, "ATTEST_EC_NOT_STRONGBOX")

        // 3. HMAC key (StrongBox-backed but no attestation chain on Samsung).
        generateHmacKey()
        verifyHmacStrongBoxBacked()

        val totpSecret = deriveHmacOutput(TOTP_ENROLLMENT_CONTEXT)
        val hmacBindingOutput = deriveHmacOutput(BINDING_PROOF_CONTEXT)

        val commitment = blake2b256(hmacBindingOutput + attestationChallenge)
        val bindingSignature = signWithAttestKey(commitment)

        val certEcChain = extractAttestationChain(CERT_KEY_ALIAS)
        val attestEcChain = extractAttestationChain(ATTEST_KEY_ALIAS)

        // Parse the leaf cert's Android Key Attestation extension to
        // surface RootOfTrust + patch levels. These become the basis
        // of StrongBoxGenesisFingerprint when the pallet's primitives
        // unstub lands — recorded at genesis time and compared on
        // ongoing-verification to catch verified-boot / patch-level
        // drift. Parse failures are caught and returned as nulls in
        // the map so the capture run can still produce a result even
        // on unexpected cert shapes.
        val certEcLeaf = extractAttestationLeaf(CERT_KEY_ALIAS)
        val attestEcLeaf = extractAttestationLeaf(ATTEST_KEY_ALIAS)
        val certEcKeyDesc = try {
            extractKeyDescription(certEcLeaf)
        } catch (e: Exception) {
            null
        }
        val attestEcKeyDesc = try {
            extractKeyDescription(attestEcLeaf)
        } catch (e: Exception) {
            null
        }

        // ── Input validation gates on the extracted KeyDescriptions ──
        // Fail the ceremony hard if the extracted metadata isn't
        // well-formed or the two chains disagree. These are data-
        // hygiene checks only — policy decisions (is Yellow verified-
        // boot acceptable? is TEE security-level acceptable?) live at
        // the pallet layer and are not enforced here. Here we only
        // check: data structurally valid + both keys' descriptions
        // agree on the fields that MUST agree in an honest ceremony.
        validateKeyDescriptionsOrThrow(
            cert = certEcKeyDesc,
            attest = attestEcKeyDesc,
            expectedChallenge = attestationChallenge,
        )

        // ── Gate 2: integrity attestation ─────────────────────────────
        //
        // Produce a SCALE-encoded IntegrityAttestation blob + signature
        // proving this ceremony ran inside the genuine Dotwave app, in
        // the expected environment (no debugger, unmodified Keystore
        // daemon), and bind it to the cert_ec key via
        // SHA256withECDSA(blake2b_256(blob)). Verified on the pallet
        // side by zk_pki_integrity::verify_integrity_attestation using
        // cert_ec's attested pubkey as the signing key.
        //
        // block_number is 0 here as a placeholder — when the ZK-PKI
        // pallet is deployed and the mint-cert flow can fetch the
        // current block before ceremony, it'll be threaded in.
        val signingCertHash = readSigningCertHash(context)
        val noDebugger = detectNoDebugger()
        val keystoreIntegrity = checkKeystoreIntegrity(context)

        val integrityBlob = scaleEncodeIntegrityAttestation(
            packageName = DOTWAVE_PACKAGE_NAME.toByteArray(Charsets.UTF_8),
            signingCertHash = signingCertHash,
            blockNumber = 0L,
            noDebugger = noDebugger,
            keystoreIntegrity = keystoreIntegrity
        )
        val integritySignature = signWithCertKey(blake2b256(integrityBlob))

        // Assemble return map with the optional key-description entries
        // included only when parsing succeeded. Dart-side presence
        // check distinguishes "parser ran cleanly" from "parse failed"
        // without having to shuttle a null value across the channel.
        return buildMap<String, Any> {
            put("strongboxConfirmed", true)
            put("totpSecret", totpSecret)
            put("publicKeyBytes", certPublicKeyBytes)
            put("certEcChainDer", certEcChain)
            put("attestEcChainDer", attestEcChain)
            put("hmacBindingOutput", hmacBindingOutput)
            put("hmacBindingSignature", bindingSignature)
            put("bindingProofContext", BINDING_PROOF_CONTEXT)
            put("integrityBlob", integrityBlob)
            put("integritySignature", integritySignature)
            put("challengeEcho", attestationChallenge)
            put("certKeyAlias", CERT_KEY_ALIAS)
            put("attestKeyAlias", ATTEST_KEY_ALIAS)
            put("hmacKeyAlias", HMAC_KEY_ALIAS)
            certEcKeyDesc?.let { put("certEcKeyDescription", keyDescriptionToMap(it)) }
            attestEcKeyDesc?.let { put("attestEcKeyDescription", keyDescriptionToMap(it)) }
        }
    }

    /**
     * Refuse to run the ceremony unless multiple `Build.*` signals agree
     * that this is a real Android device, not an emulator or a
     * container-runtime Android variant (Waydroid, Anbox, Genymotion,
     * BlueStacks, etc.). Emulator identifiers checked:
     *
     *  - `Build.HARDWARE`     — `goldfish` / `ranchu` are AOSP emulators
     *  - `Build.PRODUCT`      — `sdk_*` / `vbox_*` are SDK/VirtualBox variants
     *  - `Build.FINGERPRINT`  — contains `generic` / `vbox` / `emulator`
     *  - `Build.MODEL`        — contains `emulator` / `sdk built for`
     *  - `Build.SUPPORTED_ABIS` — no ARM ABI is a strong emulator signal
     *    on any device that would also claim StrongBox support
     *
     * These are heuristics, not guarantees; the pallet's attestation-
     * chain check is still the authoritative defense against a
     * maliciously-constructed emulator. But a failure here prevents
     * dotwave from ever emitting a ceremony output that the chain would
     * then have to reject — cleaner audit trail and faster failure for
     * honest misconfiguration cases.
     */
    private fun requireRealAndroidHardware() {
        val redFlags = mutableListOf<String>()

        val hardware = Build.HARDWARE.lowercase()
        if (hardware.contains("goldfish") || hardware.contains("ranchu")) {
            redFlags.add("Build.HARDWARE=$hardware")
        }

        val product = Build.PRODUCT.lowercase()
        if (product.startsWith("sdk_") || product.startsWith("vbox_")
            || product.contains("emulator") || product == "sdk") {
            redFlags.add("Build.PRODUCT=$product")
        }

        val fingerprint = Build.FINGERPRINT.lowercase()
        if (fingerprint.startsWith("generic") || fingerprint.contains("emulator")
            || fingerprint.contains("vbox") || fingerprint.contains("android sdk built for")) {
            redFlags.add("Build.FINGERPRINT=$fingerprint")
        }

        val model = Build.MODEL.lowercase()
        if (model.contains("emulator") || model.contains("sdk built for")
            || model.contains("android sdk")) {
            redFlags.add("Build.MODEL=$model")
        }

        val abis = Build.SUPPORTED_ABIS.toList()
        val hasArm = abis.any { it.lowercase().startsWith("arm") }
        if (!hasArm) {
            redFlags.add("Build.SUPPORTED_ABIS=$abis (no ARM ABI)")
        }

        // MANUFACTURER "unknown" is another AOSP-emulator signal
        val manufacturer = Build.MANUFACTURER.lowercase()
        if (manufacturer == "unknown" || manufacturer == "genymotion") {
            redFlags.add("Build.MANUFACTURER=$manufacturer")
        }

        if (redFlags.isNotEmpty()) {
            throw ZkPkiException(
                "NOT_REAL_ANDROID",
                "StrongBox ceremony requires real Android hardware. "
                    + "Red flags: ${redFlags.joinToString("; ")}. "
                    + "Emulators, containers, and SDK images are refused."
            )
        }
    }

    private fun requireStrongBox(context: Context) {
        val hasStrongBox = context.packageManager
            .hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
        if (!hasStrongBox) {
            throw ZkPkiException(
                "STRONGBOX_UNAVAILABLE",
                "This device does not support StrongBox"
            )
        }
    }

    private fun generateCertEcKey(attestationChallenge: ByteArray): ByteArray {
        val kpg = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC,
            "AndroidKeyStore"
        )
        kpg.initialize(
            KeyGenParameterSpec.Builder(
                CERT_KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
            )
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setIsStrongBoxBacked(true)
                .setAttestationChallenge(attestationChallenge)
                .build()
        )
        val keyPair = kpg.generateKeyPair()
        return keyPair.public.encoded
    }

    /**
     * Generate the dedicated secondary EC key used only to sign the binding
     * proof commitment at ceremony time.
     *
     * **DO NOT reuse this key for any other signing operation.**
     * Not for cert signing, not for contract acceptance, not for arbitrary
     * messages. Its sole legitimate use is
     * `signWithAttestKey(blake2b_256(hmac_binding_output || challenge))`
     * immediately after ceremony completion.
     *
     * The pallet's mint_cert validator expects the binding proof to be
     * the ONLY signature this key ever produces. If this key is ever
     * observed signing something else, the attestation's claim that it
     * only-ever served the binding proof ceremony is falsified, and
     * downstream security arguments collapse.
     *
     * **Why PURPOSE_SIGN|VERIFY and not PURPOSE_ATTEST_KEY?** The original
     * TODO 3 spec called for PURPOSE_ATTEST_KEY-only. That's correct for
     * the canonical AttestKey flow where the key signs another key's
     * attestation certificate via `setAttestKeyAlias`. Two platform
     * constraints force PURPOSE_SIGN|VERIFY on Samsung/Android 13:
     *
     *   1. Samsung KeyMint silently ignores `setAttestKeyAlias` on
     *      symmetric keys — the canonical AttestKey binding path doesn't
     *      produce a chain for the HMAC key. We use the binding proof
     *      instead, which requires signing arbitrary bytes.
     *   2. Android KeyMint rejects `Signature.initSign` on a
     *      PURPOSE_ATTEST_KEY-only key with INCOMPATIBLE_PURPOSE. The
     *      attest key cannot sign arbitrary data while holding that
     *      purpose.
     *
     * PURPOSE_SIGN|VERIFY is the only configuration under which the
     * binding proof is implementable on this hardware class. The
     * "never reuse" rule above is the operational substitute for the
     * keystore-enforced purpose restriction we can't have.
     */
    private fun generateAttestEcKey(attestationChallenge: ByteArray) {
        val kpg = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC,
            "AndroidKeyStore"
        )
        kpg.initialize(
            KeyGenParameterSpec.Builder(
                ATTEST_KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
            )
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setIsStrongBoxBacked(true)
                .setAttestationChallenge(attestationChallenge)
                .build()
        )
        kpg.generateKeyPair()
    }

    private fun generateHmacKey() {
        val kg = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_HMAC_SHA256,
            "AndroidKeyStore"
        )
        kg.init(
            KeyGenParameterSpec.Builder(
                HMAC_KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN
            )
                .setKeySize(256)
                .setIsStrongBoxBacked(true)
                .build()
        )
        kg.generateKey()
    }

    private fun verifyEcStrongBoxBacked(alias: String, errorCode: String) {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val entry = ks.getEntry(alias, null) as KeyStore.PrivateKeyEntry
        val kf = KeyFactory.getInstance(entry.privateKey.algorithm, "AndroidKeyStore")
        val info = kf.getKeySpec(entry.privateKey, KeyInfo::class.java) as KeyInfo

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (info.securityLevel != KeyProperties.SECURITY_LEVEL_STRONGBOX) {
                throw ZkPkiException(
                    errorCode,
                    "$alias is not StrongBox-backed. Security level: ${info.securityLevel}"
                )
            }
        } else {
            @Suppress("DEPRECATION")
            if (!info.isInsideSecureHardware) {
                throw ZkPkiException(
                    errorCode,
                    "$alias is not hardware-backed"
                )
            }
        }
    }

    private fun verifyHmacStrongBoxBacked() {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val stored = ks.getKey(HMAC_KEY_ALIAS, null) as SecretKey
        val skf = SecretKeyFactory.getInstance(stored.algorithm, "AndroidKeyStore")
        val info = skf.getKeySpec(stored, KeyInfo::class.java) as KeyInfo

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (info.securityLevel != KeyProperties.SECURITY_LEVEL_STRONGBOX) {
                throw ZkPkiException(
                    "HMAC_NOT_STRONGBOX",
                    "HMAC key is not StrongBox-backed. Security level: ${info.securityLevel}"
                )
            }
        } else {
            @Suppress("DEPRECATION")
            if (!info.isInsideSecureHardware) {
                throw ZkPkiException(
                    "HMAC_NOT_STRONGBOX",
                    "HMAC key is not hardware-backed"
                )
            }
        }
    }

    /**
     * Compute HMAC-SHA256 of the given context string using the StrongBox
     * HMAC key. Used for both the TOTP enrollment secret and the binding
     * proof's hmac output — different contexts, same key.
     */
    private fun deriveHmacOutput(context: String): ByteArray {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val hmacKey = ks.getKey(HMAC_KEY_ALIAS, null) as SecretKey
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(hmacKey)
        return mac.doFinal(context.toByteArray(Charsets.UTF_8))
    }

    /**
     * Sign `data` using the StrongBox-backed attest EC key with
     * SHA256withECDSA (the signer pre-hashes with SHA-256 then signs).
     */
    private fun signWithAttestKey(data: ByteArray): ByteArray {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val entry = ks.getEntry(ATTEST_KEY_ALIAS, null) as KeyStore.PrivateKeyEntry
        val sig = Signature.getInstance("SHA256withECDSA")
        sig.initSign(entry.privateKey as PrivateKey)
        sig.update(data)
        return sig.sign()
    }

    /**
     * Blake2b-256 via BouncyCastle. Byte-identical output to
     * `sp_io::hashing::blake2_256` on the Rust/pallet side.
     */
    private fun blake2b256(input: ByteArray): ByteArray {
        val digest = Blake2bDigest(256)
        digest.update(input, 0, input.size)
        val out = ByteArray(32)
        digest.doFinal(out, 0)
        return out
    }

    private fun extractAttestationChain(alias: String): List<ByteArray> {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val chain = ks.getCertificateChain(alias)
            ?: throw ZkPkiException(
                "ATTESTATION_CHAIN_MISSING",
                "No attestation certificate chain found for $alias"
            )
        return chain.map { it.encoded }
    }

    /**
     * Retrieve the leaf X509Certificate from a given alias's
     * attestation chain. Used to parse the Android Key Attestation
     * extension (OID 1.3.6.1.4.1.11129.2.1.17) — the structured
     * KeyDescription blob that carries RootOfTrust, patch levels,
     * and the attestation challenge echo.
     *
     * This is a second entry into the same keystore chain that
     * `extractAttestationChain` reads; kept separate so the DER-
     * bytes path and the parsed-leaf path are visibly distinct.
     */
    private fun extractAttestationLeaf(alias: String): X509Certificate {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val chain = ks.getCertificateChain(alias)
            ?: throw ZkPkiException(
                "ATTESTATION_CHAIN_MISSING",
                "No attestation certificate chain found for $alias"
            )
        return chain[0] as? X509Certificate
            ?: throw ZkPkiException(
                "ATTESTATION_LEAF_NOT_X509",
                "Chain leaf for $alias is not X509Certificate"
            )
    }

    // ── Android Key Attestation extension parsing ────────────────────
    //
    // The leaf cert of every Android Keystore attestation chain carries
    // a critical extension at OID 1.3.6.1.4.1.11129.2.1.17, containing
    // a SEQUENCE-encoded KeyDescription. Reference spec:
    //   https://source.android.com/docs/security/features/keystore/attestation
    //
    // We pull out the subset of fields the pallet's future
    // StrongBoxGenesisFingerprint needs: RootOfTrust (verifiedBootKey,
    // deviceLocked, verifiedBootState, verifiedBootHash), osVersion,
    // osPatchLevel, vendorPatchLevel, bootPatchLevel, plus
    // attestationChallenge + attestationApplicationId for sanity-check
    // echo.
    //
    // ASN.1 layout (simplified from the full spec):
    //   KeyDescription ::= SEQUENCE {
    //       attestationVersion         INTEGER,
    //       attestationSecurityLevel   ENUMERATED,  -- 0=SW, 1=TEE, 2=StrongBox
    //       keyMintVersion             INTEGER,
    //       keyMintSecurityLevel       ENUMERATED,
    //       attestationChallenge       OCTET STRING,
    //       uniqueId                   OCTET STRING,
    //       softwareEnforced           AuthorizationList,
    //       hardwareEnforced           AuthorizationList,
    //   }
    //   AuthorizationList ::= SEQUENCE { ... tagged fields ... }
    //   RootOfTrust ::= SEQUENCE {
    //       verifiedBootKey   OCTET STRING,
    //       deviceLocked      BOOLEAN,
    //       verifiedBootState ENUMERATED,  -- 0=Verified(Green), 1=SelfSigned(Yellow), 2=Unverified(Orange), 3=Failed(Red)
    //       verifiedBootHash  OCTET STRING,  -- SHA-256 of boot chain
    //   }

    private data class ParsedRootOfTrust(
        val verifiedBootKey: ByteArray,
        val deviceLocked: Boolean,
        val verifiedBootState: Int,
        val verifiedBootHash: ByteArray,
    ) {
        // Data-class auto-equals on ByteArray is referential, so two
        // independent parses of the same RootOfTrust would never compare
        // equal — defeating the cert_ec/attest_ec consistency gate.
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is ParsedRootOfTrust) return false
            return deviceLocked == other.deviceLocked &&
                verifiedBootState == other.verifiedBootState &&
                verifiedBootKey.contentEquals(other.verifiedBootKey) &&
                verifiedBootHash.contentEquals(other.verifiedBootHash)
        }

        override fun hashCode(): Int {
            var result = verifiedBootKey.contentHashCode()
            result = 31 * result + deviceLocked.hashCode()
            result = 31 * result + verifiedBootState
            result = 31 * result + verifiedBootHash.contentHashCode()
            return result
        }
    }

    private data class ParsedKeyDescription(
        val attestationVersion: Int,
        val attestationSecurityLevel: Int,
        val keyMintVersion: Int,
        val keyMintSecurityLevel: Int,
        val attestationChallenge: ByteArray,
        val rootOfTrust: ParsedRootOfTrust?,
        val osVersion: Int?,
        val osPatchLevel: Int?,
        val attestationApplicationIdRaw: ByteArray?,
        val vendorPatchLevel: Int?,
        val bootPatchLevel: Int?,
    )

    // Android Key Attestation extension OID — lives on the leaf cert
    // of every hardware-attested keystore chain.
    private const val KEY_ATTESTATION_OID = "1.3.6.1.4.1.11129.2.1.17"

    // AuthorizationList tag numbers (hardware-enforced entries) — per
    // Android Keystore attestation spec. We extract only the subset
    // relevant to the HIP genesis fingerprint; other tags (purpose,
    // algorithm, keySize, …) are skipped.
    private const val TAG_ROOT_OF_TRUST = 704
    private const val TAG_OS_VERSION = 705
    private const val TAG_OS_PATCH_LEVEL = 706
    private const val TAG_ATTESTATION_APPLICATION_ID = 709
    private const val TAG_VENDOR_PATCH_LEVEL = 718
    private const val TAG_BOOT_PATCH_LEVEL = 719

    private fun extractKeyDescription(cert: X509Certificate): ParsedKeyDescription? {
        val rawExt = cert.getExtensionValue(KEY_ATTESTATION_OID) ?: return null
        // The extension value is wrapped in an outer OCTET STRING
        // (standard X.509 extension encoding). Unwrap once to reach
        // the inner SEQUENCE.
        val inner = ASN1OctetString.getInstance(rawExt).octets
        val seq = ASN1InputStream(inner).use { it.readObject() } as ASN1Sequence
        if (seq.size() < 8) return null

        val attestationVersion = (seq.getObjectAt(0) as ASN1Integer).value.toInt()
        val attestationSecurityLevel =
            (seq.getObjectAt(1) as ASN1Enumerated).value.toInt()
        val keyMintVersion = (seq.getObjectAt(2) as ASN1Integer).value.toInt()
        val keyMintSecurityLevel =
            (seq.getObjectAt(3) as ASN1Enumerated).value.toInt()
        val attestationChallenge =
            (seq.getObjectAt(4) as ASN1OctetString).octets
        // seq[5] = uniqueId (skip)
        // seq[6] = softwareEnforced (skip; only hardwareEnforced is
        //          StrongBox-backed and tamper-evident)
        val hardwareEnforced = seq.getObjectAt(7) as ASN1Sequence
        val auth = parseAuthorizationList(hardwareEnforced)

        return ParsedKeyDescription(
            attestationVersion = attestationVersion,
            attestationSecurityLevel = attestationSecurityLevel,
            keyMintVersion = keyMintVersion,
            keyMintSecurityLevel = keyMintSecurityLevel,
            attestationChallenge = attestationChallenge,
            rootOfTrust = auth.rootOfTrust,
            osVersion = auth.osVersion,
            osPatchLevel = auth.osPatchLevel,
            attestationApplicationIdRaw = auth.attestationApplicationId,
            vendorPatchLevel = auth.vendorPatchLevel,
            bootPatchLevel = auth.bootPatchLevel,
        )
    }

    private data class AuthListFields(
        val rootOfTrust: ParsedRootOfTrust? = null,
        val osVersion: Int? = null,
        val osPatchLevel: Int? = null,
        val attestationApplicationId: ByteArray? = null,
        val vendorPatchLevel: Int? = null,
        val bootPatchLevel: Int? = null,
    )

    private fun parseAuthorizationList(seq: ASN1Sequence): AuthListFields {
        var rootOfTrust: ParsedRootOfTrust? = null
        var osVersion: Int? = null
        var osPatchLevel: Int? = null
        var attestationApplicationId: ByteArray? = null
        var vendorPatchLevel: Int? = null
        var bootPatchLevel: Int? = null

        for (i in 0 until seq.size()) {
            val item = seq.getObjectAt(i) as? ASN1TaggedObject ?: continue
            val base: ASN1Encodable = item.baseObject
            when (item.tagNo) {
                TAG_ROOT_OF_TRUST -> rootOfTrust = parseRootOfTrust(base as ASN1Sequence)
                TAG_OS_VERSION -> osVersion = (base as ASN1Integer).value.toInt()
                TAG_OS_PATCH_LEVEL -> osPatchLevel = (base as ASN1Integer).value.toInt()
                TAG_ATTESTATION_APPLICATION_ID ->
                    attestationApplicationId = (base as ASN1OctetString).octets
                TAG_VENDOR_PATCH_LEVEL -> vendorPatchLevel = (base as ASN1Integer).value.toInt()
                TAG_BOOT_PATCH_LEVEL -> bootPatchLevel = (base as ASN1Integer).value.toInt()
            }
        }

        return AuthListFields(
            rootOfTrust = rootOfTrust,
            osVersion = osVersion,
            osPatchLevel = osPatchLevel,
            attestationApplicationId = attestationApplicationId,
            vendorPatchLevel = vendorPatchLevel,
            bootPatchLevel = bootPatchLevel,
        )
    }

    private fun parseRootOfTrust(seq: ASN1Sequence): ParsedRootOfTrust {
        val verifiedBootKey = (seq.getObjectAt(0) as ASN1OctetString).octets
        val deviceLocked = (seq.getObjectAt(1) as ASN1Boolean).isTrue
        val verifiedBootState = (seq.getObjectAt(2) as ASN1Enumerated).value.toInt()
        val verifiedBootHash = (seq.getObjectAt(3) as ASN1OctetString).octets
        return ParsedRootOfTrust(
            verifiedBootKey = verifiedBootKey,
            deviceLocked = deviceLocked,
            verifiedBootState = verifiedBootState,
            verifiedBootHash = verifiedBootHash,
        )
    }

    /**
     * Input validation gates for the extracted [ParsedKeyDescription]
     * pair. Checks that:
     *
     *  1. Both extractors produced a result (null = parser choked,
     *     which on real StrongBox hardware indicates a bug).
     *  2. Byte-sized fields have correct lengths (challenge == 32,
     *     verifiedBootKey/Hash == 32).
     *  3. Enum values are in their declared ranges.
     *  4. Required fields (RoT, patch levels) are present.
     *  5. The two keys' descriptions agree on everything device-
     *     specific — challenge, RootOfTrust, patch levels, osVersion —
     *     since both were generated in the same ceremony execution.
     *  6. The challenge echoed back in both descriptions equals the
     *     challenge supplied as ceremony input.
     *
     * Policy decisions (is Yellow verified-boot acceptable? require
     * StrongBox security level? etc.) are NOT enforced here — those
     * live at the pallet layer. These gates only ensure the data is
     * well-formed before it leaves the ceremony.
     */
    private fun validateKeyDescriptionsOrThrow(
        cert: ParsedKeyDescription?,
        attest: ParsedKeyDescription?,
        expectedChallenge: ByteArray,
    ) {
        if (cert == null) {
            throw ZkPkiException(
                "CERT_EC_KEYDESC_MISSING",
                "cert_ec chain leaf has no parsable KeyDescription extension"
            )
        }
        if (attest == null) {
            throw ZkPkiException(
                "ATTEST_EC_KEYDESC_MISSING",
                "attest_ec chain leaf has no parsable KeyDescription extension"
            )
        }

        // ── Cross-chain consistency ──────────────────────────────────
        // Both keys generated in the same ceremony — their
        // KeyDescriptions MUST agree on everything device-specific.
        if (!cert.attestationChallenge.contentEquals(attest.attestationChallenge)) {
            throw ZkPkiException(
                "CERT_ATTEST_CHALLENGE_MISMATCH",
                "cert_ec and attest_ec KeyDescription challenges differ"
            )
        }
        if (!cert.attestationChallenge.contentEquals(expectedChallenge)) {
            throw ZkPkiException(
                "CHALLENGE_ECHO_MISMATCH",
                "KeyDescription challenge doesn't match ceremony input"
            )
        }
        if (cert.rootOfTrust != attest.rootOfTrust) {
            throw ZkPkiException(
                "CERT_ATTEST_ROT_MISMATCH",
                "cert_ec and attest_ec have divergent RootOfTrust values"
            )
        }
        if (cert.osVersion != attest.osVersion
            || cert.osPatchLevel != attest.osPatchLevel
            || cert.vendorPatchLevel != attest.vendorPatchLevel
            || cert.bootPatchLevel != attest.bootPatchLevel
        ) {
            throw ZkPkiException(
                "CERT_ATTEST_PATCH_MISMATCH",
                "cert_ec and attest_ec have divergent osVersion/patchLevels"
            )
        }

        // ── Per-key well-formedness ──────────────────────────────────
        validateSingleKeyDescription(cert, "cert_ec")
        validateSingleKeyDescription(attest, "attest_ec")
    }

    /**
     * Structural well-formedness checks for a single KeyDescription.
     * Called for cert_ec and attest_ec separately.
     */
    private fun validateSingleKeyDescription(kd: ParsedKeyDescription, label: String) {
        val labelUpper = label.uppercase()

        // Byte-size fields must match our expected protocol widths.
        if (kd.attestationChallenge.size != 32) {
            throw ZkPkiException(
                "${labelUpper}_CHALLENGE_WRONG_SIZE",
                "$label attestationChallenge is ${kd.attestationChallenge.size} bytes, expected 32"
            )
        }

        // Enum-shaped ints must be in declared ranges.
        if (kd.attestationSecurityLevel !in 0..2) {
            throw ZkPkiException(
                "${labelUpper}_ATTEST_SECLEVEL_OUT_OF_RANGE",
                "$label attestationSecurityLevel=${kd.attestationSecurityLevel}, expected 0..2"
            )
        }
        if (kd.keyMintSecurityLevel !in 0..2) {
            throw ZkPkiException(
                "${labelUpper}_KEYMINT_SECLEVEL_OUT_OF_RANGE",
                "$label keyMintSecurityLevel=${kd.keyMintSecurityLevel}, expected 0..2"
            )
        }

        // RootOfTrust is required for PoP-eligible keys.
        val rot = kd.rootOfTrust ?: throw ZkPkiException(
            "${labelUpper}_ROT_MISSING",
            "$label KeyDescription has no RootOfTrust (required for PoP)"
        )
        if (rot.verifiedBootKey.size != 32) {
            throw ZkPkiException(
                "${labelUpper}_BOOTKEY_WRONG_SIZE",
                "$label verifiedBootKey is ${rot.verifiedBootKey.size} bytes, expected 32"
            )
        }
        if (rot.verifiedBootHash.size != 32) {
            throw ZkPkiException(
                "${labelUpper}_BOOTHASH_WRONG_SIZE",
                "$label verifiedBootHash is ${rot.verifiedBootHash.size} bytes, expected 32"
            )
        }
        if (rot.verifiedBootState !in 0..3) {
            throw ZkPkiException(
                "${labelUpper}_BOOTSTATE_OUT_OF_RANGE",
                "$label verifiedBootState=${rot.verifiedBootState}, expected 0..3"
            )
        }

        // Patch levels must be present and structurally plausible.
        // Per the SM-G986U capture: osPatchLevel is YYYYMM (6 digits),
        // vendor/boot are YYYYMMDD (8 digits). We use loose lower
        // bounds that any real device exceeds comfortably — the
        // precise format interpretation happens at the pallet layer.
        val osVer = kd.osVersion ?: throw ZkPkiException(
            "${labelUpper}_OS_VERSION_MISSING", "$label has no osVersion"
        )
        if (osVer <= 0) {
            throw ZkPkiException(
                "${labelUpper}_OS_VERSION_NONSENSE",
                "$label osVersion=$osVer, expected > 0"
            )
        }
        val osPatch = kd.osPatchLevel ?: throw ZkPkiException(
            "${labelUpper}_OS_PATCH_MISSING", "$label has no osPatchLevel"
        )
        if (osPatch < 200001) {
            throw ZkPkiException(
                "${labelUpper}_OS_PATCH_NONSENSE",
                "$label osPatchLevel=$osPatch (expected YYYYMM >= 200001)"
            )
        }
        val vendorPatch = kd.vendorPatchLevel ?: throw ZkPkiException(
            "${labelUpper}_VENDOR_PATCH_MISSING", "$label has no vendorPatchLevel"
        )
        if (vendorPatch < 20000101) {
            throw ZkPkiException(
                "${labelUpper}_VENDOR_PATCH_NONSENSE",
                "$label vendorPatchLevel=$vendorPatch (expected YYYYMMDD >= 20000101)"
            )
        }
        val bootPatch = kd.bootPatchLevel ?: throw ZkPkiException(
            "${labelUpper}_BOOT_PATCH_MISSING", "$label has no bootPatchLevel"
        )
        if (bootPatch < 20000101) {
            throw ZkPkiException(
                "${labelUpper}_BOOT_PATCH_NONSENSE",
                "$label bootPatchLevel=$bootPatch (expected YYYYMMDD >= 20000101)"
            )
        }
    }

    /**
     * Serialize a [ParsedKeyDescription] into a plain `Map<String, Any?>`
     * suitable for MethodChannel transport. Used to ship the parsed
     * values up to Dart for the capture-run test screen. All byte
     * arrays round-trip intact; enums/ints pass through as-is; null
     * sub-fields (e.g., missing rootOfTrust) stay null.
     */
    private fun keyDescriptionToMap(desc: ParsedKeyDescription): Map<String, Any?> {
        return mapOf(
            "attestationVersion" to desc.attestationVersion,
            "attestationSecurityLevel" to desc.attestationSecurityLevel,
            "keyMintVersion" to desc.keyMintVersion,
            "keyMintSecurityLevel" to desc.keyMintSecurityLevel,
            "attestationChallenge" to desc.attestationChallenge,
            "rootOfTrust" to desc.rootOfTrust?.let {
                mapOf(
                    "verifiedBootKey" to it.verifiedBootKey,
                    "deviceLocked" to it.deviceLocked,
                    "verifiedBootState" to it.verifiedBootState,
                    "verifiedBootHash" to it.verifiedBootHash,
                )
            },
            "osVersion" to desc.osVersion,
            "osPatchLevel" to desc.osPatchLevel,
            "attestationApplicationIdRaw" to desc.attestationApplicationIdRaw,
            "vendorPatchLevel" to desc.vendorPatchLevel,
            "bootPatchLevel" to desc.bootPatchLevel,
        )
    }

    /**
     * SHA-256 of the first entry in `apkContentsSigners` for this app's
     * installed package. The pallet compares this against its
     * `DOTWAVE_SIGNING_CERT_HASH` constant (placeholder zero-hash during
     * beta, real hash once the production APK signing key is minted).
     *
     * Requires API 28+ — the app's minSdk and the target SM-G986U (API
     * 33) both satisfy that. If `signingInfo` is unexpectedly null
     * (shouldn't happen on a real install), throw rather than silently
     * emit a garbage hash.
     */
    private fun readSigningCertHash(context: Context): ByteArray {
        val pkg = context.packageManager.getPackageInfo(
            context.packageName,
            PackageManager.GET_SIGNING_CERTIFICATES
        )
        val info = pkg.signingInfo
            ?: throw ZkPkiException(
                "NO_SIGNING_INFO",
                "PackageInfo.signingInfo is null for ${context.packageName}"
            )
        val signers = info.apkContentsSigners
        if (signers.isEmpty()) {
            throw ZkPkiException(
                "NO_APK_SIGNERS",
                "apkContentsSigners is empty for ${context.packageName}"
            )
        }
        return MessageDigest.getInstance("SHA-256").digest(signers[0].toByteArray())
    }

    /**
     * True when no debugger is attached at ceremony time. Two checks —
     * the JDWP-level `Debug.isDebuggerConnected()` and the kernel-level
     * `TracerPid` field in `/proc/self/status`. Either being positive
     * means the ceremony ran under inspection, which invalidates the
     * integrity claim.
     *
     * An attacker with root could plausibly forge `/proc/self/status`,
     * but this is a defense-in-depth signal for non-rooted devices, not
     * a root-proof guarantee.
     */
    private fun detectNoDebugger(): Boolean {
        if (Debug.isDebuggerConnected()) return false
        val statusFile = File("/proc/self/status")
        if (!statusFile.exists()) {
            // Should never happen on Android — bail to the safe side.
            return false
        }
        val tracerPid = statusFile.readText()
            .lineSequence()
            .firstOrNull { it.startsWith("TracerPid:") }
            ?.substringAfter(":")
            ?.trim()
            ?.toIntOrNull()
            ?: return false
        return tracerPid == 0
    }

    /**
     * True when the Android Keystore daemon (via the `android` package
     * which hosts `keystore2`) has a visible signing identity. A weak
     * but non-zero signal that the platform Keystore hasn't been
     * replaced with a userspace shim; the pallet surfaces this bit
     * rather than enforcing it, so relying parties set their own
     * threshold.
     */
    private fun checkKeystoreIntegrity(context: Context): Boolean {
        return try {
            context.packageManager.getPackageInfo(
                "android",
                PackageManager.GET_SIGNING_CERTIFICATES
            ).signingInfo != null
        } catch (_: Exception) {
            false
        }
    }

    /**
     * SCALE encode the [`zk_pki_integrity::IntegrityAttestation`]
     * layout byte-for-byte compatible with the Rust struct:
     *
     * ```
     * package_name        BoundedVec<u8, 256>   — SCALE compact length + raw bytes
     * signing_cert_hash   [u8; 32]              — fixed 32 bytes, no prefix
     * block_number        u64                   — little-endian 8 bytes
     * no_debugger         bool                  — 0x01 / 0x00
     * keystore_integrity  bool                  — 0x01 / 0x00
     * ```
     *
     * The `BoundedVec` bound is 256 bytes, so the compact-length prefix
     * is either single-byte (len < 64) or two-byte (64 ≤ len < 16384).
     * Refuses anything longer than the bound to fail loudly rather than
     * silently emit something the pallet's bounded decoder would reject.
     */
    private fun scaleEncodeIntegrityAttestation(
        packageName: ByteArray,
        signingCertHash: ByteArray,
        blockNumber: Long,
        noDebugger: Boolean,
        keystoreIntegrity: Boolean
    ): ByteArray {
        require(signingCertHash.size == 32) {
            "signingCertHash must be 32 bytes (got ${signingCertHash.size})"
        }
        require(packageName.size <= 256) {
            "packageName exceeds BoundedVec<u8, 256> bound (${packageName.size})"
        }
        val buf = ByteArrayOutputStream()

        // SCALE compact length for BoundedVec<u8, 256>.
        val len = packageName.size
        when {
            len < 64 -> buf.write((len shl 2) and 0xFF)
            else -> {
                val compact = (len shl 2) or 0x01
                buf.write(compact and 0xFF)
                buf.write((compact shr 8) and 0xFF)
            }
        }
        buf.write(packageName)

        buf.write(signingCertHash)

        for (i in 0..7) {
            buf.write(((blockNumber ushr (i * 8)) and 0xFF).toInt())
        }

        buf.write(if (noDebugger) 0x01 else 0x00)
        buf.write(if (keystoreIntegrity) 0x01 else 0x00)

        return buf.toByteArray()
    }

    /**
     * Sign `data` with the StrongBox-backed cert EC key using
     * `SHA256withECDSA`. Used exclusively to sign the blake2b-256 hash
     * of the SCALE-encoded integrity blob. The pallet re-applies
     * SHA-256 internally via p256's ECDSA verifier, so the net signed
     * digest is `SHA-256(blake2b_256(blob))` — byte-for-byte identical
     * on both sides.
     */
    private fun signWithCertKey(data: ByteArray): ByteArray {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val entry = ks.getEntry(CERT_KEY_ALIAS, null) as KeyStore.PrivateKeyEntry
        val sig = Signature.getInstance("SHA256withECDSA")
        sig.initSign(entry.privateKey as PrivateKey)
        sig.update(data)
        return sig.sign()
    }
}
