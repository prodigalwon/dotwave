import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../bridge/bridge_generated.dart/core.dart' as bridge;

/// Parsed Android Verified Boot RootOfTrust — extracted client-side
/// from the chain leaf's AuthorizationList. Matches the shape the
/// pallet's `StrongBoxGenesisFingerprint.root_of_trust` will carry
/// once the on-chain primitives unstub lands.
class ParsedRootOfTrust {
  final Uint8List verifiedBootKey;
  final bool deviceLocked;
  /// 0=Verified(Green), 1=SelfSigned(Yellow), 2=Unverified(Orange),
  /// 3=Failed(Red).
  final int verifiedBootState;
  /// SHA-256 of the boot chain.
  final Uint8List verifiedBootHash;

  ParsedRootOfTrust({
    required this.verifiedBootKey,
    required this.deviceLocked,
    required this.verifiedBootState,
    required this.verifiedBootHash,
  });

  String verifiedBootStateName() => switch (verifiedBootState) {
        0 => 'Verified (Green)',
        1 => 'SelfSigned (Yellow)',
        2 => 'Unverified (Orange)',
        3 => 'Failed (Red)',
        _ => 'Unknown($verifiedBootState)',
      };
}

/// Parsed Android Key Attestation `KeyDescription` — everything the
/// pallet will ever care about from the leaf cert's attestation
/// extension. Captured for both `zkpki_cert_ec` and `zkpki_attest_ec`
/// chain leaves, surfaced separately so divergence between the two
/// is visible.
///
/// Sub-fields are nullable because certain fields (vendor/boot patch
/// level on older OEMs, attestation_application_id on some builds)
/// are legitimately absent on some hardware. Presence/absence per-
/// field is itself capture-worthy data.
class ParsedKeyDescription {
  final int attestationVersion;
  /// 0=Software, 1=TEE (TrustedEnvironment), 2=StrongBox.
  final int attestationSecurityLevel;
  final int keyMintVersion;
  final int keyMintSecurityLevel;
  /// Echo of the attestation challenge baked into this cert at
  /// keygen time. Must equal the ceremony's `attestationChallenge`.
  final Uint8List attestationChallenge;
  final ParsedRootOfTrust? rootOfTrust;
  /// Packed as `YYYYMMDDpp` per Android spec (osVersion is actually
  /// the OS *version code* like 140000 for Android 14.0; keep as int
  /// and interpret downstream).
  final int? osVersion;
  /// YYYYMM (e.g., 202504) — the security patch level.
  final int? osPatchLevel;
  /// DER-encoded `AttestationApplicationId` structure. Contains
  /// `[packages: SEQUENCE OF {packageName, version}, digests: SET OF
  /// OCTET_STRING]`. Surfaced raw here so Dart can decode / inspect
  /// without Kotlin having to parse it twice.
  final Uint8List? attestationApplicationIdRaw;
  /// YYYYMMDD vendor patch level.
  final int? vendorPatchLevel;
  /// YYYYMMDD boot patch level.
  final int? bootPatchLevel;

  ParsedKeyDescription({
    required this.attestationVersion,
    required this.attestationSecurityLevel,
    required this.keyMintVersion,
    required this.keyMintSecurityLevel,
    required this.attestationChallenge,
    required this.rootOfTrust,
    required this.osVersion,
    required this.osPatchLevel,
    required this.attestationApplicationIdRaw,
    required this.vendorPatchLevel,
    required this.bootPatchLevel,
  });

  String attestationSecurityLevelName() => switch (attestationSecurityLevel) {
        0 => 'Software',
        1 => 'TrustedEnvironment',
        2 => 'StrongBox',
        _ => 'Unknown($attestationSecurityLevel)',
      };
}

class ZkPkiCeremonyResult {
  final bool strongboxConfirmed;
  final Uint8List totpSecret;
  final Uint8List publicKeyBytes;
  final List<Uint8List> certEcChainDer;
  final List<Uint8List> attestEcChainDer;

  /// HMAC-SHA256 output over the fixed binding-proof context, computed
  /// inside StrongBox. Used by the pallet to recompute the commitment.
  final Uint8List hmacBindingOutput;

  /// ECDSA-SHA256 signature by `zkpki_attest_ec` over
  /// `blake2b_256(hmacBindingOutput || attestationChallenge)`. Proves the
  /// attest EC key and the HMAC key were co-located in StrongBox at
  /// ceremony time.
  final Uint8List hmacBindingSignature;

  /// The fixed context string the HMAC was computed over — versioned so
  /// the proof construction can be bumped without breaking existing certs.
  final String bindingProofContext;

  /// SCALE-encoded `zk_pki_integrity::IntegrityAttestation` — Gate 2
  /// blob. Contains declared package name, APK signing cert SHA-256,
  /// ceremony block number (placeholder 0 until the mint-cert flow
  /// threads a real block in), debugger check, and Keystore daemon
  /// integrity check. Verified on the pallet side via
  /// `verify_integrity_attestation(&integrityBlob, &integritySignature,
  /// &cert_ec_pubkey, …)`.
  final Uint8List integrityBlob;

  /// ECDSA-SHA256 signature by `zkpki_cert_ec` over
  /// `blake2b_256(integrityBlob)`. Binds the integrity declaration to
  /// the same key the cert_ec attestation chain certifies — no separate
  /// trust anchor.
  final Uint8List integritySignature;

  /// Echo of the `attestationChallenge` parameter the caller passed in.
  /// Surfaced alongside the ceremony outputs so fixture captures can
  /// record exactly what challenge was baked into the KeyDescription
  /// extension on both EC keys without needing to trust the caller to
  /// remember.
  final Uint8List challengeEcho;

  final String certKeyAlias;
  final String attestKeyAlias;
  final String hmacKeyAlias;

  /// Parsed `KeyDescription` extension from the cert_ec chain leaf.
  /// `null` if the Kotlin-side ASN.1 parser failed (unusual on real
  /// StrongBox hardware — absence is a capture-worthy finding).
  final ParsedKeyDescription? certEcKeyDescription;

  /// Parsed `KeyDescription` from the attest_ec chain leaf. Should
  /// carry the same attestation challenge and RootOfTrust as
  /// `certEcKeyDescription` (both keys generated in the same
  /// ceremony execution context); divergence is itself a finding.
  final ParsedKeyDescription? attestEcKeyDescription;

  ZkPkiCeremonyResult({
    required this.strongboxConfirmed,
    required this.totpSecret,
    required this.publicKeyBytes,
    required this.certEcChainDer,
    required this.attestEcChainDer,
    required this.hmacBindingOutput,
    required this.hmacBindingSignature,
    required this.bindingProofContext,
    required this.integrityBlob,
    required this.integritySignature,
    required this.challengeEcho,
    required this.certKeyAlias,
    required this.attestKeyAlias,
    required this.hmacKeyAlias,
    required this.certEcKeyDescription,
    required this.attestEcKeyDescription,
  });
}

class ZkPkiCeremonyException implements Exception {
  final String errorCode;
  final String message;

  ZkPkiCeremonyException(this.errorCode, this.message);

  @override
  String toString() => 'ZkPkiCeremonyException($errorCode): $message';
}

class ZkPkiCeremonyService {
  static const MethodChannel _channel = MethodChannel('dotwave/security');

  /// The StrongBox ceremony is Android-only. This service refuses to
  /// invoke it on any other platform — see
  /// `project_dotwave_cross_platform_spoof_defense` for the full
  /// threat model. Every ceremony call pre-flights **two** independent
  /// OS signals that must agree:
  ///
  /// 1. Dart-side `Platform.isAndroid` (dart:io, reflects OS of the
  ///    running VM at runtime)
  /// 2. Rust-side `attest_runtime_os("android")` via the FRB bridge —
  ///    checks `std::env::consts::OS` (compile-time target) plus
  ///    filesystem signals (`/system/build.prop`, `/system/bin/linker`,
  ///    `/apex`) that the binary is actually running on Android
  ///
  /// Disagreement between the two → refuse, surface a
  /// `CROSS_PLATFORM_SPOOF` exception. The Kotlin side performs a third
  /// cross-check (Build.HARDWARE / Build.MANUFACTURER / SUPPORTED_ABIS)
  /// before any StrongBox key generation starts; together the three
  /// layers form the "dotwave itself refuses to produce cross-platform
  /// proofs" guarantee that is required for Fagan-inspection audit.
  Future<ZkPkiCeremonyResult> runCeremony(Uint8List attestationChallenge) async {
    // ── Pre-flight layer 1: Dart runtime OS check ───────────────────────
    if (!Platform.isAndroid) {
      throw ZkPkiCeremonyException(
        'CROSS_PLATFORM_SPOOF',
        'StrongBox ceremony is Android-only; Platform.operatingSystem is '
        '"${Platform.operatingSystem}". Refusing to invoke.',
      );
    }

    // ── Pre-flight layer 2: Rust-side multi-signal OS attestation ───────
    // Cross-checks std::env::consts::OS against filesystem markers. Throws
    // at this layer if the binary was compiled for a non-Android target
    // or if Android filesystem signals are absent (emulator, chroot, etc).
    try {
      final attestation = await bridge.attestRuntimeOs(expected: 'android');
      if (attestation.runtimeOs != 'android') {
        throw ZkPkiCeremonyException(
          'CROSS_PLATFORM_SPOOF',
          'Rust-side OS attestation returned runtimeOs='
          '"${attestation.runtimeOs}" but Dart reports Android. '
          'Binary/runtime mismatch.',
        );
      }
    } on ZkPkiCeremonyException {
      rethrow;
    } catch (e) {
      throw ZkPkiCeremonyException(
        'CROSS_PLATFORM_SPOOF',
        'Rust-side OS attestation failed: $e',
      );
    }

    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'zkpkiCeremony',
        {'attestationChallenge': attestationChallenge},
      );
      if (raw == null) {
        throw ZkPkiCeremonyException('NULL_RESULT', 'Ceremony returned null');
      }
      final map = Map<String, Object?>.from(raw);

      List<Uint8List> decodeChain(String key) {
        final raw = map[key] as List<Object?>;
        return raw
            .map((e) => Uint8List.fromList((e as List<Object?>).cast<int>()))
            .toList();
      }

      Uint8List decodeBytes(String key) =>
          Uint8List.fromList((map[key] as List<Object?>).cast<int>());

      ParsedRootOfTrust? decodeRootOfTrust(Map<String, Object?> m) {
        return ParsedRootOfTrust(
          verifiedBootKey: Uint8List.fromList(
            (m['verifiedBootKey'] as List<Object?>).cast<int>(),
          ),
          deviceLocked: m['deviceLocked'] as bool,
          verifiedBootState: m['verifiedBootState'] as int,
          verifiedBootHash: Uint8List.fromList(
            (m['verifiedBootHash'] as List<Object?>).cast<int>(),
          ),
        );
      }

      ParsedKeyDescription? decodeKeyDescription(String key) {
        final raw = map[key];
        if (raw == null) return null;
        final kd = Map<String, Object?>.from(raw as Map<Object?, Object?>);
        final rotRaw = kd['rootOfTrust'];
        final rot = rotRaw == null
            ? null
            : decodeRootOfTrust(
                Map<String, Object?>.from(rotRaw as Map<Object?, Object?>),
              );
        Uint8List? optBytes(String k) {
          final v = kd[k];
          return v == null
              ? null
              : Uint8List.fromList((v as List<Object?>).cast<int>());
        }
        return ParsedKeyDescription(
          attestationVersion: kd['attestationVersion'] as int,
          attestationSecurityLevel: kd['attestationSecurityLevel'] as int,
          keyMintVersion: kd['keyMintVersion'] as int,
          keyMintSecurityLevel: kd['keyMintSecurityLevel'] as int,
          attestationChallenge: Uint8List.fromList(
            (kd['attestationChallenge'] as List<Object?>).cast<int>(),
          ),
          rootOfTrust: rot,
          osVersion: kd['osVersion'] as int?,
          osPatchLevel: kd['osPatchLevel'] as int?,
          attestationApplicationIdRaw: optBytes('attestationApplicationIdRaw'),
          vendorPatchLevel: kd['vendorPatchLevel'] as int?,
          bootPatchLevel: kd['bootPatchLevel'] as int?,
        );
      }

      return ZkPkiCeremonyResult(
        strongboxConfirmed: map['strongboxConfirmed'] as bool,
        totpSecret: decodeBytes('totpSecret'),
        publicKeyBytes: decodeBytes('publicKeyBytes'),
        certEcChainDer: decodeChain('certEcChainDer'),
        attestEcChainDer: decodeChain('attestEcChainDer'),
        hmacBindingOutput: decodeBytes('hmacBindingOutput'),
        hmacBindingSignature: decodeBytes('hmacBindingSignature'),
        bindingProofContext: map['bindingProofContext'] as String,
        integrityBlob: decodeBytes('integrityBlob'),
        integritySignature: decodeBytes('integritySignature'),
        challengeEcho: decodeBytes('challengeEcho'),
        certKeyAlias: map['certKeyAlias'] as String,
        attestKeyAlias: map['attestKeyAlias'] as String,
        hmacKeyAlias: map['hmacKeyAlias'] as String,
        certEcKeyDescription: decodeKeyDescription('certEcKeyDescription'),
        attestEcKeyDescription: decodeKeyDescription('attestEcKeyDescription'),
      );
    } on PlatformException catch (e) {
      final code = (e.details is Map)
          ? (e.details as Map)['errorCode']?.toString() ?? 'UNKNOWN'
          : 'UNKNOWN';
      throw ZkPkiCeremonyException(code, e.message ?? 'PlatformException');
    }
  }
}
