// Debug-only screen for validating the cross-platform spoof defense
// (layers 1–3 of `project_dotwave_cross_platform_spoof_defense`).
//
// Exercises both the individual OS-attestation probes (Rust-side) and
// the full ceremony path (Rust + Dart + Kotlin layers stacked). Intended
// to be invoked on real hardware + negative-path environments (Android
// emulator, Linux desktop build) to confirm each layer fires correctly.
//
// Not a shipping-UI surface — gated behind `kDebugMode` in the entry
// point. Safe to leave in the repo; won't reach release builds.

import 'dart:io' show Platform;
import '../theme.dart';
import 'dart:math' as math;
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha1, sha256;
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, MethodChannel;
import 'package:qr_flutter/qr_flutter.dart';

import '../bridge/bridge_generated.dart/core.dart' as bridge;
import '../bridge/bridge_generated.dart/frb_generated.dart' show RustLib;
import '../config/rpc_endpoints.dart';
import '../services/zkpki_ceremony_service.dart';

class ZkPkiSpoofDefenseTestScreen extends StatefulWidget {
  const ZkPkiSpoofDefenseTestScreen({super.key});

  @override
  State<ZkPkiSpoofDefenseTestScreen> createState() =>
      _ZkPkiSpoofDefenseTestScreenState();
}

class _ZkPkiSpoofDefenseTestScreenState
    extends State<ZkPkiSpoofDefenseTestScreen> {
  final List<_LogEntry> _log = [];
  bool _busy = false;
  /// Retained after a successful ceremony so the post-ceremony
  /// observation panel can render the otpauth URI / QR / OTP verify.
  /// Nulled out explicitly by the Zeroize button (which also fills
  /// the held `totpSecret` buffer with zeros).
  ZkPkiCeremonyResult? _lastCeremony;

  // ── Stage 4c state ─────────────────────────────────────────────
  /// Target Rostro node dev URL. Defaults to the local Rostro lab node
  /// ([RpcEndpoints.chain]); editable for pointing at another lab node.
  final TextEditingController _rpcUrlController =
      TextEditingController(text: RpcEndpoints.chain);
  /// Signer seed phrase for submitting extrinsics. Default is Alice
  /// (dev-mode sudo + funded account).
  final TextEditingController _phraseController =
      TextEditingController(text: '//Alice');
  /// Last nonce used for `verify_and_record`. When `_reuseLastNonce` is
  /// checked, the next sign attempt uses this value instead of
  /// generating a fresh one — drives the on-chain replay-rejection test.
  Uint8List? _lastStage4cNonce;
  bool _reuseLastNonce = false;

  // ── Stage 5e cert lifecycle inputs ─────────────────────────────
  /// `contract_nonce` — 32-byte hex from the issuer's `offerContract`
  /// `ContractOffered` event. Issuer-side admin work happens off-device
  /// (the Stage 5d driver); this field is where the operator pastes the
  /// result.
  final TextEditingController _contractNonceController = TextEditingController();
  /// `offer_created_at_block` — u32 block number of the same offerContract
  /// extrinsic. Decimal, no `0x`.
  final TextEditingController _offerBlockController = TextEditingController();
  /// `cert_thumbprint` — 32-byte hex returned in the `CertMinted` event
  /// after a successful mint_cert. Operator copies it from chain-side
  /// and pastes here to drive the self_discard_cert PoP step.
  final TextEditingController _certThumbprintController = TextEditingController();

  @override
  void dispose() {
    _rpcUrlController.dispose();
    _phraseController.dispose();
    _contractNonceController.dispose();
    _offerBlockController.dispose();
    _certThumbprintController.dispose();
    super.dispose();
  }

  void _append(_LogEntry entry) {
    // Flush to stdout so the flutter run terminal captures it — test
    // results are useless if they only live on the phone screen and
    // can't be copied off. Format is `SPOOFTEST | ` prefix for easy
    // grepping out of the flutter run output stream.
    final tag = entry.ok ? 'OK  ' : 'FAIL';
    debugPrint('SPOOFTEST | [$tag] ${entry.label} '
        '(${entry.elapsed.inMilliseconds}ms) — ${entry.summary}');
    for (final line in entry.detail.split('\n')) {
      debugPrint('SPOOFTEST |     $line');
    }
    debugPrint('SPOOFTEST |');
    setState(() => _log.insert(0, entry));
  }

  Future<void> _probeOs(String expected) async {
    if (_busy) return;
    setState(() => _busy = true);
    final started = DateTime.now();
    try {
      final attestation = await bridge.attestRuntimeOs(expected: expected);
      _append(_LogEntry.success(
        label: 'attest_runtime_os("$expected")',
        summary: 'PASS — runtime_os="${attestation.runtimeOs}", '
            'signals=${attestation.signalsChecked}',
        detail: attestation.evidence,
        elapsed: DateTime.now().difference(started),
      ));
    } catch (e) {
      _append(_LogEntry.failure(
        label: 'attest_runtime_os("$expected")',
        summary: 'REFUSED',
        detail: e.toString(),
        elapsed: DateTime.now().difference(started),
      ));
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _runCeremony() async {
    if (_busy) return;
    setState(() => _busy = true);
    final started = DateTime.now();

    // 32-byte random challenge. The ceremony bakes this into both EC
    // keys' attestation extension so it's what a real mint would use;
    // value doesn't have to be meaningful for a smoke test.
    final rng = Random.secure();
    final challenge = Uint8List.fromList(
      List.generate(32, (_) => rng.nextInt(256)),
    );

    try {
      final service = ZkPkiCeremonyService();
      final result = await service.runCeremony(challenge);
      // Core ceremony fields — same as before
      final detail = <String>[
        'strongboxConfirmed=${result.strongboxConfirmed}',
        'certEcChainDer=${result.certEcChainDer.length} certs',
        'attestEcChainDer=${result.attestEcChainDer.length} certs',
        'publicKeyBytes=${result.publicKeyBytes.length} bytes',
        'hmacBindingOutput=${result.hmacBindingOutput.length} bytes',
        'hmacBindingSignature=${result.hmacBindingSignature.length} bytes',
        'integrityBlob=${result.integrityBlob.length} bytes',
        'integritySignature=${result.integritySignature.length} bytes',
        'bindingProofContext="${result.bindingProofContext}"',
        'certKeyAlias="${result.certKeyAlias}"',
        '',
        '── Raw bytes (hex) for Rostro-runtime mint_cert payload ──',
        'challenge          = 0x${_bytesHex(challenge)}',
        'cert_ec_public     = 0x${_bytesHex(result.publicKeyBytes)}',
        'hmac_binding_out   = 0x${_bytesHex(result.hmacBindingOutput)}',
        'hmac_binding_sig   = 0x${_bytesHex(result.hmacBindingSignature)}',
        'integrity_blob     = 0x${_bytesHex(result.integrityBlob)}',
        'integrity_signature= 0x${_bytesHex(result.integritySignature)}',
        'cert_ec_chain[0]   = 0x${_bytesHex(result.certEcChainDer.first)}',
        'attest_ec_chain[0] = 0x${_bytesHex(result.attestEcChainDer.first)}',
      ];

      // Parsed KeyDescription dump — this is the real payload from
      // the S20 capture run. Include both chain leaves' descriptions
      // so divergence between cert_ec and attest_ec is visible (they
      // SHOULD match on challenge + RootOfTrust + patch levels since
      // they're generated in the same ceremony).
      detail.add('');
      detail.add('── KeyDescription: cert_ec leaf ──');
      detail.addAll(_dumpKeyDescription(result.certEcKeyDescription));
      detail.add('');
      detail.add('── KeyDescription: attest_ec leaf ──');
      detail.addAll(_dumpKeyDescription(result.attestEcKeyDescription));

      _append(_LogEntry.success(
        label: 'runCeremony()',
        summary: 'PASS — StrongBox ceremony completed',
        detail: detail.join('\n'),
        elapsed: DateTime.now().difference(started),
      ));
      // Retain for the post-ceremony observation panel.
      setState(() => _lastCeremony = result);
      debugPrint('SPOOFTEST |     (post-ceremony panel ready — totp_seed '
          'now in state, ${result.totpSecret.length} bytes)');
    } on ZkPkiCeremonyException catch (e) {
      // Differentiate spoof-defense refusal from other ceremony errors.
      // CROSS_PLATFORM_SPOOF = layer 1 or 2 caught it (Dart or Rust).
      // NOT_REAL_ANDROID = layer 3 caught it (Kotlin Build.* check).
      // Anything else = a genuine ceremony / keystore error, not our
      // spoof defense.
      final isSpoofDefense =
          e.errorCode == 'CROSS_PLATFORM_SPOOF' || e.errorCode == 'NOT_REAL_ANDROID';
      _append(_LogEntry.failure(
        label: 'runCeremony()',
        summary: isSpoofDefense
            ? 'REFUSED by spoof defense — ${e.errorCode}'
            : 'FAILED (non-spoof-defense error) — ${e.errorCode}',
        detail: e.message,
        elapsed: DateTime.now().difference(started),
      ));
    } catch (e) {
      _append(_LogEntry.failure(
        label: 'runCeremony()',
        summary: 'UNEXPECTED ERROR',
        detail: e.toString(),
        elapsed: DateTime.now().difference(started),
      ));
    } finally {
      setState(() => _busy = false);
    }
  }

  /// Open the post-ceremony observation panel as a full-height modal
  /// bottom sheet. The panel shows otpauth URI + QR + OTP-verify +
  /// zeroize, with every step instrumented via debugPrint so the
  /// flutter run terminal captures the full lifecycle of the
  /// `totp_seed` from StrongBox to user input and back.
  Future<void> _openPostCeremonyPanel(ZkPkiCeremonyResult ceremony) async {
    debugPrint('SPOOFTEST | [post-ceremony] opening observation panel');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0D0D0D),
      builder: (_) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.92,
          child: _PostCeremonyPanel(
            ceremony: ceremony,
            onZeroize: () {
              // Zero out the retained totp_secret buffer in-place.
              // The Uint8List is reference-shared with the
              // ZkPkiCeremonyResult we stored in _lastCeremony, so
              // filling it here wipes the source bytes. GC behavior
              // on the underlying TypedData backing store is
              // best-effort — Dart/Flutter doesn't guarantee memory
              // is actually cleared from the VM heap, only that
              // this reference's bytes are overwritten.
              final seed = ceremony.totpSecret;
              debugPrint('SPOOFTEST | [zeroize] overwriting seed buffer '
                  '(${seed.length} bytes) with zeros');
              for (var i = 0; i < seed.length; i++) {
                seed[i] = 0;
              }
              debugPrint('SPOOFTEST | [zeroize] seed buffer zeroed '
                  '(GC of object itself is opportunistic — Dart VM '
                  'does not expose explicit free for TypedData)');
              setState(() => _lastCeremony = null);
            },
          ),
        ),
      ),
    );
    debugPrint('SPOOFTEST | [post-ceremony] panel dismissed');
  }

  /// Stage-0 keystone check for the mime-wrap Android design.
  /// Invokes `PcHmacSmokeTest.run()` on the Kotlin side — verifies that
  /// (a) a symmetric HMAC key can be generated with
  /// setUserConfirmationRequired on SM-G986U, (b) Protected Confirmation
  /// is supported on this device, and (c) HMAC operations without auth
  /// are rejected by StrongBox. See
  /// project_zkpki_zero_trust_authorization for why these three claims
  /// are the load-bearing dependencies for the entire Android design.
  ///
  /// If this returns PARTIAL/FAIL, the design needs to be revisited
  /// before any ZK-circuit work starts.
  Future<void> _runPcHmacSmokeTest() async {
    if (_busy) return;
    setState(() => _busy = true);
    final started = DateTime.now();
    const channel = MethodChannel('dotwave/security');
    try {
      final raw =
          await channel.invokeMethod<Map<Object?, Object?>>('pcHmacSmokeTest');
      if (raw == null) {
        throw Exception('pcHmacSmokeTest returned null');
      }
      final map = Map<String, Object?>.from(raw);
      final verdict = map['overallVerdict'] as String? ?? '(no verdict)';
      final ok = verdict.startsWith('PASS');

      final detail = <String>[];
      final keyGen = map['keyGeneration'] as Map<Object?, Object?>?;
      if (keyGen != null) {
        detail.add('── keyGeneration ──');
        detail.add('  attempted=${keyGen['attempted']}');
        detail.add('  succeeded=${keyGen['succeeded']}');
        if (keyGen['errorClass'] != null) {
          detail.add('  errorClass=${keyGen['errorClass']}');
          detail.add('  errorMessage=${keyGen['errorMessage']}');
        }
      }
      final keyInfo = map['keyInfo'] as Map<Object?, Object?>?;
      detail.add('');
      detail.add('── keyInfo ──');
      if (keyInfo == null) {
        detail.add('  (null — key generation did not succeed)');
      } else {
        keyInfo.forEach((k, v) => detail.add('  $k=$v'));
      }
      detail.add('');
      detail.add('── protectedConfirmationSupported ──');
      detail.add('  ${map['protectedConfirmationSupported']}');
      detail.add('');
      detail.add('── hmacWithoutAuth ──');
      final hmacNoAuth = map['hmacWithoutAuth'] as Map<Object?, Object?>?;
      if (hmacNoAuth != null) {
        hmacNoAuth.forEach((k, v) => detail.add('  $k=$v'));
      }

      if (ok) {
        _append(_LogEntry.success(
          label: 'pcHmacSmokeTest (Stage 0 keystone)',
          summary: verdict,
          detail: detail.join('\n'),
          elapsed: DateTime.now().difference(started),
        ));
      } else {
        _append(_LogEntry.failure(
          label: 'pcHmacSmokeTest (Stage 0 keystone)',
          summary: verdict,
          detail: detail.join('\n'),
          elapsed: DateTime.now().difference(started),
        ));
      }
    } catch (e) {
      _append(_LogEntry.failure(
        label: 'pcHmacSmokeTest (Stage 0 keystone)',
        summary: 'INVOCATION FAILED',
        detail: e.toString(),
        elapsed: DateTime.now().difference(started),
      ));
    } finally {
      setState(() => _busy = false);
    }
  }

  /// Stage 2 PoC: ark-circom Groth16 proof-generation benchmark on-device.
  ///
  /// Flow:
  ///   1. Kotlin copies circuit artifacts (wasm + r1cs + zkey, ~70MB
  ///      total) from APK assets to filesDir on first call.
  ///   2. Rust loads zkey, generates random fixture, builds witness
  ///      via the Circom wasm, runs Groth16 prove, serializes the
  ///      proof.
  ///   3. Timings surface back to Dart as milliseconds per phase.
  ///
  /// Pass criteria (from project_zkpki_zero_trust_authorization):
  ///   - < 1.5s total = PASS, design is viable on S20 without
  ///     rapidsnark FFI work
  ///   - 1.5s–3s total = CLOSE, Stage 2b (rapidsnark C++ FFI) can
  ///     close the gap
  ///   - > 3s total = FAIL, design needs fundamental rethink
  Future<void> _runMimeWrapBenchmark() async {
    if (_busy) return;
    setState(() => _busy = true);
    final started = DateTime.now();
    const channel = MethodChannel('dotwave/security');

    try {
      // Step 1: ensure assets are copied to filesDir
      debugPrint('SPOOFTEST | [mime-wrap] ensuring assets in filesDir...');
      final raw = await channel.invokeMethod<Map<Object?, Object?>>(
        'mimeWrapEnsureAssets',
      );
      if (raw == null) {
        throw Exception('mimeWrapEnsureAssets returned null');
      }
      final paths = Map<String, Object?>.from(raw);
      final wasmPath = paths['wasmPath'] as String;
      final r1csPath = paths['r1csPath'] as String;
      final zkeyPath = paths['zkeyPath'] as String;
      debugPrint('SPOOFTEST | [mime-wrap] assets ready');
      debugPrint('SPOOFTEST |     wasm: $wasmPath');
      debugPrint('SPOOFTEST |     r1cs: $r1csPath');
      debugPrint('SPOOFTEST |     zkey: $zkeyPath');

      // Step 2: invoke the Rust benchmark via the bridge
      debugPrint('SPOOFTEST | [mime-wrap] invoking Rust prover...');
      final result = await RustLib.instance.api
          .crateMimeWrapProverBenchmarkMimeWrapProof(
        wasmPath: wasmPath,
        r1CsPath: r1csPath,
        zkeyPath: zkeyPath,
      );

      final detail = <String>[
        'success=${result.success}',
        if (result.errorMessage != null)
          'errorMessage=${result.errorMessage}',
        'zkeyCacheHit=${result.zkeyCacheHit}',
        'zkeyLoadMs=${result.zkeyLoadMs}',
        'witnessGenMs=${result.witnessGenMs}',
        'proofGenMs=${result.proofGenMs}',
        'totalMs=${result.totalMs}',
        'proofBytes=${result.proofBytes.length} bytes',
        'publicInputsCount=${result.publicInputsCount}',
      ];

      // Warm-path latency is what matters — the zkey is loaded once
      // at app startup in production. Measure witness_gen + proof_gen
      // only; ignore the one-time zkey parse cost.
      final warmMs = result.witnessGenMs + result.proofGenMs;
      final verdict = !result.success
          ? 'FAIL(error): ${result.errorMessage}'
          : !result.zkeyCacheHit
              ? 'COLD run (zkey parsed, ${result.zkeyLoadMs}ms) — '
                  'run again for warm timing. Warm estimate: ${warmMs}ms'
              : warmMs < 1500
                  ? 'PASS (warm): ${warmMs}ms < 1500ms target'
                  : warmMs < 3000
                      ? 'CLOSE (warm): ${warmMs}ms in 1.5s–3s range '
                          '(rapidsnark FFI could close gap)'
                      : 'FAIL (warm): ${warmMs}ms > 3000ms '
                          '(design needs rethink)';

      final ok = result.success && (!result.zkeyCacheHit || warmMs < 3000);
      if (ok) {
        _append(_LogEntry.success(
          label: 'mimeWrapBenchmark (Stage 2)',
          summary: verdict,
          detail: detail.join('\n'),
          elapsed: DateTime.now().difference(started),
        ));
      } else {
        _append(_LogEntry.failure(
          label: 'mimeWrapBenchmark (Stage 2)',
          summary: verdict,
          detail: detail.join('\n'),
          elapsed: DateTime.now().difference(started),
        ));
      }
    } catch (e) {
      _append(_LogEntry.failure(
        label: 'mimeWrapBenchmark (Stage 2)',
        summary: 'INVOCATION FAILED',
        detail: e.toString(),
        elapsed: DateTime.now().difference(started),
      ));
    } finally {
      setState(() => _busy = false);
    }
  }

  /// Stage 4c.1: Run the one-time in-Rust trusted setup for the mime-wrap
  /// circuit. Produces a (pk, vk) pair from a deterministic RNG — the pk
  /// is cached in Rust process memory for subsequent proof-gen calls, and
  /// the vk hex is surfaced here to paste into the Stage 5d driver and
  /// submit via `Sudo.sudo(ZkPkiMimeWrap.set_verifying_key(...))` on
  /// the Rostro node.
  ///
  /// First call does the heavy work (30-60s on S20 expected); subsequent
  /// calls hit the cache and return in milliseconds.
  ///
  /// Prerequisite: the mime-wrap circuit artifacts must already be in
  /// filesDir — achieved by tapping the Stage 2 benchmark button once
  /// (which runs `mimeWrapEnsureAssets` under the hood).
  Future<void> _runMimeWrapSetup() async {
    if (_busy) return;
    setState(() => _busy = true);
    final started = DateTime.now();
    const channel = MethodChannel('dotwave/security');

    try {
      debugPrint('SPOOFTEST | [mime-wrap setup] ensuring assets in filesDir...');
      final raw = await channel.invokeMethod<Map<Object?, Object?>>(
        'mimeWrapEnsureAssets',
      );
      if (raw == null) {
        throw Exception('mimeWrapEnsureAssets returned null');
      }
      final paths = Map<String, Object?>.from(raw);
      final wasmPath = paths['wasmPath'] as String;
      final r1csPath = paths['r1csPath'] as String;

      debugPrint('SPOOFTEST | [mime-wrap setup] running circuit_specific_setup '
          '(this takes 30-60s on first run)...');
      final result = await RustLib.instance.api
          .crateMimeWrapClientPrepareMimeWrapSetup(
        wasmPath: wasmPath,
        r1CsPath: r1csPath,
      );

      final detail = <String>[
        'success=${result.success}',
        if (result.errorMessage != null)
          'errorMessage=${result.errorMessage}',
        'freshSetup=${result.freshSetup}',
        'setupMs=${result.setupMs}',
        'vkBytes.length=${result.vkBytesHex.length ~/ 2} bytes',
      ];

      // Stage 5e: auto-submit `zkPki.set_mime_wrap_vk(vk)` if phrase + URL
      // fields are populated. Replaces the Stage 4c.1 "copy hex into
      // the Stage 5d driver" workflow now that the integrated pallet accepts a
      // signed extrinsic (no sudo needed in PoC trust model).
      if (result.success && _phraseController.text.trim().isNotEmpty) {
        try {
          final txHash = await RustLib.instance.api.crateCoreSubmitSetMimeWrapVk(
            vkBytesHex: result.vkBytesHex,
            phrase: _phraseController.text.trim(),
            rpcUrl: _rpcUrlController.text.trim(),
          );
          detail.addAll([
            '',
            '── on-chain submit (zkPki.set_mime_wrap_vk) ──',
            'tx hash = $txHash',
          ]);
        } catch (e) {
          detail.addAll([
            '',
            '── on-chain submit failed (paste VK manually instead) ──',
            'error: $e',
            '',
            '── VK hex for manual install via the Stage 5d driver ──',
            '0x${result.vkBytesHex}',
          ]);
        }
      } else {
        detail.addAll([
          '',
          '── VK hex for manual install (no phrase set, skipped auto-submit) ──',
          '0x${result.vkBytesHex}',
        ]);
      }

      if (result.success) {
        _append(_LogEntry.success(
          label: 'mimeWrapSetup (Stage 4c.1)',
          summary: result.freshSetup
              ? 'PASS: fresh setup in ${result.setupMs}ms'
              : 'PASS: cached setup returned in ${result.setupMs}ms',
          detail: detail.join('\n'),
          elapsed: DateTime.now().difference(started),
        ));
      } else {
        _append(_LogEntry.failure(
          label: 'mimeWrapSetup (Stage 4c.1)',
          summary: 'FAIL — ${result.errorMessage ?? "no message"}',
          detail: detail.join('\n'),
          elapsed: DateTime.now().difference(started),
        ));
      }
    } catch (e) {
      _append(_LogEntry.failure(
        label: 'mimeWrapSetup (Stage 4c.1)',
        summary: 'INVOCATION FAILED',
        detail: e.toString(),
        elapsed: DateTime.now().difference(started),
      ));
    } finally {
      setState(() => _busy = false);
    }
  }

  /// Stage 5e: Submit `zkPki.mint_cert(...)` against the integrated
  /// pallet. Replaces the Stage 4c.2a `register_commitment` flow — the
  /// commitment is now recorded inline at mint time alongside the cert
  /// itself.
  ///
  /// Pre-requirements:
  ///   - Ceremony has been run (provides cert_ec / attest_ec keys + bytes).
  ///   - An issuer has previously called `zkPki.offer_contract(user=…)`
  ///     for the signing account; the resulting `contract_nonce` (32
  ///     hex) and `offer_created_at_block` (u32) are pasted into the
  ///     two fields above the buttons.
  ///   - The signing phrase corresponds to the same `user` the offer
  ///     was made to.
  ///
  /// On success the cert thumbprint is read off the `CertMinted` event
  /// (operator-side via the Stage 5d driver for now) and pasted into the
  /// thumbprint field for the next step.
  Future<void> _runMintCert() async {
    if (_busy) return;
    final ceremony = _lastCeremony;
    if (ceremony == null) {
      _append(_LogEntry.failure(
        label: 'mintCert (Stage 5e)',
        summary: 'no ceremony state — run "Run full ceremony" first',
        detail: 'ZkPkiCeremonyResult is null',
        elapsed: Duration.zero,
      ));
      return;
    }
    final contractNonceText = _contractNonceController.text.trim();
    if (contractNonceText.isEmpty) {
      _append(_LogEntry.failure(
        label: 'mintCert (Stage 5e)',
        summary: 'contract_nonce field is empty',
        detail: 'Paste the 32-byte hex from the issuer\'s ContractOffered event.',
        elapsed: Duration.zero,
      ));
      return;
    }
    final offerBlockText = _offerBlockController.text.trim();
    if (offerBlockText.isEmpty) {
      _append(_LogEntry.failure(
        label: 'mintCert (Stage 5e)',
        summary: 'offer_created_at_block field is empty',
        detail: 'Paste the u32 block number from the same offerContract extrinsic.',
        elapsed: Duration.zero,
      ));
      return;
    }
    final offerBlock = int.tryParse(offerBlockText);
    if (offerBlock == null || offerBlock < 0) {
      _append(_LogEntry.failure(
        label: 'mintCert (Stage 5e)',
        summary: 'offer_created_at_block must be a non-negative integer',
        detail: 'got: $offerBlockText',
        elapsed: Duration.zero,
      ));
      return;
    }

    setState(() => _busy = true);
    final started = DateTime.now();
    try {
      // ── Derive commitment_c + ec_key_pub from ceremony state ──
      final ecKeyPub32 = await RustLib.instance.api
          .crateMimeWrapClientDeriveEcKeyPubFromDer(der: ceremony.publicKeyBytes);
      final commitment = await RustLib.instance.api
          .crateMimeWrapClientComputeCommitment(
        ecKeyPub: ecKeyPub32,
        seed: ceremony.totpSecret,
      );

      // ── Build StrongBoxCeremonyBundle from captured bytes ──
      // cert_ec SEC1: strip the 26-byte SPKI envelope from the 91-byte
      // DER ceremony-emitted publicKeyBytes. attest_ec SEC1: pulled out
      // of the leaf cert via the rust extract_sec1_from_x509_leaf helper.
      if (ceremony.publicKeyBytes.length != 91) {
        throw Exception(
            'cert_ec DER must be 91 bytes (got ${ceremony.publicKeyBytes.length})');
      }
      final certEcSec1 = ceremony.publicKeyBytes.sublist(26);
      if (ceremony.attestEcChainDer.isEmpty) {
        throw Exception('ceremony.attestEcChainDer is empty');
      }
      final attestSec1Vec = await RustLib.instance.api
          .crateCoreExtractSec1FromX509Leaf(
        leafDer: ceremony.attestEcChainDer.first,
      );
      final attestEcSec1 = Uint8List.fromList(attestSec1Vec);

      // ── MockVerdict::Tpm SCALE blob for the testnet NoopBindingProofVerifier ──
      // [variant 0 = Tpm][32 bytes ek_hash dummy][compact-u32(65)][SEC1].
      final mockVerdictBlob = Uint8List.fromList([
        0x00,
        ...List.filled(32, 0x42),
        0x05, 0x01,
        ...certEcSec1,
      ]);

      final bundle = bridge.StrongBoxCeremonyBundle(
        certEcPublicSec1Hex: '0x${_bytesHex(certEcSec1)}',
        attestEcPublicSec1Hex: '0x${_bytesHex(attestEcSec1)}',
        certEcChainLeafHex: '0x${_bytesHex(ceremony.certEcChainDer.first)}',
        attestEcChainLeafHex: '0x${_bytesHex(ceremony.attestEcChainDer.first)}',
        hmacBindingOutputHex: '0x${_bytesHex(ceremony.hmacBindingOutput)}',
        hmacBindingSignatureHex: '0x${_bytesHex(ceremony.hmacBindingSignature)}',
        integrityBlobHex: '0x${_bytesHex(ceremony.integrityBlob)}',
        integritySignatureHex: '0x${_bytesHex(ceremony.integritySignature)}',
        challengeHex: '0x${_bytesHex(ceremony.challengeEcho)}',
      );

      final txHash =
          await RustLib.instance.api.crateCoreSubmitMintCertStrongbox(
        contractNonceHex: contractNonceText,
        offerCreatedAtBlock: offerBlock,
        integrityBlobForMockVerdictHex: '0x${_bytesHex(mockVerdictBlob)}',
        bundle: bundle,
        commitmentCHex: '0x${_bytesHex(commitment)}',
        ecKeyPubClaimedHex: '0x${_bytesHex(ecKeyPub32)}',
        phrase: _phraseController.text.trim(),
        rpcUrl: _rpcUrlController.text.trim(),
      );

      _append(_LogEntry.success(
        label: 'mintCert (Stage 5e)',
        summary: 'PASS — extrinsic accepted',
        detail: [
          'tx hash       = $txHash',
          'ec_key_pub    = 0x${_bytesHex(ecKeyPub32)}',
          'commitment_c  = 0x${_bytesHex(commitment)}',
          'cert_ec SEC1  = 0x${_bytesHex(certEcSec1)}',
          'attest SEC1   = 0x${_bytesHex(attestEcSec1)}',
          '',
          'Read CertMinted event from the chain (System → Events) to',
          'pick up the cert thumbprint, then paste into the field above.',
        ].join('\n'),
        elapsed: DateTime.now().difference(started),
      ));
    } catch (e) {
      _append(_LogEntry.failure(
        label: 'mintCert (Stage 5e)',
        summary: 'FAILED',
        detail: e.toString(),
        elapsed: DateTime.now().difference(started),
      ));
    } finally {
      setState(() => _busy = false);
    }
  }

  /// Stage 4c.2b: Generate a mime-wrap proof for the current time
  /// bucket and submit `ZkPkiMimeWrap.verify_and_record(...)`.
  ///
  /// Flow:
  ///   1. Derive ec_key_pub (= SHA256(ceremony pubkey)) and pick a
  ///      bucket (unix-seconds / 30 — matches TOTP period).
  ///   2. Compute user_otp locally against the same SHA256 formula the
  ///      circuit's C2 constraint uses — so the proof verifies.
  ///   3. Generate a fresh 32-byte nonce (or reuse the previous one if
  ///      `_reuseLastNonce` is set — drives the replay test).
  ///   4. Call `generate_mime_wrap_signing_proof` — uses the PK cached
  ///      at Stage 4c.1 setup time.
  ///   5. Submit `verify_and_record` via the Rust extrinsic helper.
  ///
  /// Expected outcomes:
  ///   - Fresh nonce: PASS, proof verified on-chain, state recorded
  ///   - Reused nonce: FAIL with `ReplayRejected` (the test)
  ///   - Wrong OTP / bad proof: FAIL with `ProofInvalid`
  Future<void> _runSelfDiscardCert() async {
    if (_busy) return;
    final ceremony = _lastCeremony;
    if (ceremony == null) {
      _append(_LogEntry.failure(
        label: 'selfDiscardCert (Stage 5e)',
        summary: 'no ceremony state — run "Run full ceremony" first',
        detail: 'ZkPkiCeremonyResult is null',
        elapsed: Duration.zero,
      ));
      return;
    }
    final thumbprintText = _certThumbprintController.text.trim();
    if (thumbprintText.isEmpty) {
      _append(_LogEntry.failure(
        label: 'selfDiscardCert (Stage 5e)',
        summary: 'cert_thumbprint field is empty',
        detail: 'Paste the 32-byte hex from the CertMinted event of Stage 5e mintCert.',
        elapsed: Duration.zero,
      ));
      return;
    }

    setState(() => _busy = true);
    final started = DateTime.now();
    try {
      // ── Derive ec_key_pub (used by the prover, not part of the assertion) ──
      final ecKeyPub32 = await RustLib.instance.api
          .crateMimeWrapClientDeriveEcKeyPubFromDer(der: ceremony.publicKeyBytes);

      // ── Bucket + user_otp (same derivation the circuit's C2 enforces) ──
      final bucket = DateTime.now().millisecondsSinceEpoch ~/ 30_000;
      final userOtp = _computeUserOtp(ceremony.totpSecret, bucket);

      // ── Mime-wrap nonce (replay-map key) ──
      // Fresh by default; reuse the previous one if the replay-test checkbox
      // is set, in which case the chain should respond `MimeWrapReplayRejected`.
      final Uint8List nonce;
      if (_reuseLastNonce && _lastStage4cNonce != null) {
        nonce = _lastStage4cNonce!;
        debugPrint('SPOOFTEST | [pop] REUSING last nonce — expect MimeWrapReplayRejected');
      } else {
        nonce = _randomBytes32();
      }
      _lastStage4cNonce = nonce;

      // ── Generate proof — file paths from Kotlin side, prover via FRB ──
      const channel = MethodChannel('dotwave/security');
      final raw = await channel.invokeMethod<Map<Object?, Object?>>('mimeWrapEnsureAssets');
      if (raw == null) throw Exception('mimeWrapEnsureAssets returned null');
      final paths = Map<String, Object?>.from(raw);
      final wasmPath = paths['wasmPath'] as String;
      final r1csPath = paths['r1csPath'] as String;
      final proofResult = await RustLib.instance.api
          .crateMimeWrapClientGenerateMimeWrapSigningProof(
        wasmPath: wasmPath,
        r1CsPath: r1csPath,
        ecKeyPub: ecKeyPub32,
        seed: ceremony.totpSecret,
        bucket: BigInt.from(bucket),
        userOtp: userOtp,
      );
      if (!proofResult.success) {
        throw Exception('proof gen failed: ${proofResult.errorMessage ?? "no message"}');
      }
      debugPrint('SPOOFTEST | [pop] proof gen ${proofResult.totalMs}ms '
          '(${proofResult.proofBytesHex.length ~/ 2} bytes)');

      // ── Build StrongBoxCeremonyBundle (must reproduce the bytes pinned
      //    at mint time so the chain's HIP-vs-genesis hash check passes) ──
      if (ceremony.publicKeyBytes.length != 91) {
        throw Exception(
            'cert_ec DER must be 91 bytes (got ${ceremony.publicKeyBytes.length})');
      }
      final certEcSec1 = ceremony.publicKeyBytes.sublist(26);
      if (ceremony.attestEcChainDer.isEmpty) {
        throw Exception('ceremony.attestEcChainDer is empty');
      }
      final attestSec1Vec = await RustLib.instance.api
          .crateCoreExtractSec1FromX509Leaf(leafDer: ceremony.attestEcChainDer.first);
      final attestEcSec1 = Uint8List.fromList(attestSec1Vec);
      final bundle = bridge.StrongBoxCeremonyBundle(
        certEcPublicSec1Hex: '0x${_bytesHex(certEcSec1)}',
        attestEcPublicSec1Hex: '0x${_bytesHex(attestEcSec1)}',
        certEcChainLeafHex: '0x${_bytesHex(ceremony.certEcChainDer.first)}',
        attestEcChainLeafHex: '0x${_bytesHex(ceremony.attestEcChainDer.first)}',
        hmacBindingOutputHex: '0x${_bytesHex(ceremony.hmacBindingOutput)}',
        hmacBindingSignatureHex: '0x${_bytesHex(ceremony.hmacBindingSignature)}',
        integrityBlobHex: '0x${_bytesHex(ceremony.integrityBlob)}',
        integritySignatureHex: '0x${_bytesHex(ceremony.integritySignature)}',
        challengeHex: '0x${_bytesHex(ceremony.challengeEcho)}',
      );

      final txHash = await RustLib.instance.api
          .crateCoreSubmitSelfDiscardCertMimeWrap(
        certThumbprintHex: thumbprintText,
        bucket: BigInt.from(bucket),
        mimeWrapNonceHex: '0x${_bytesHex(nonce)}',
        userOtp: userOtp,
        proofBytesHex: '0x${proofResult.proofBytesHex}',
        bundle: bundle,
        phrase: _phraseController.text.trim(),
        rpcUrl: _rpcUrlController.text.trim(),
      );

      _append(_LogEntry.success(
        label: 'selfDiscardCert (Stage 5e)',
        summary: 'PASS — PoP verified, cert discarded',
        detail: [
          'tx hash    = $txHash',
          'thumbprint = $thumbprintText',
          'bucket     = $bucket',
          'nonce      = 0x${_bytesHex(nonce)}',
          'user_otp   = $userOtp',
          'proof_ms   = ${proofResult.totalMs}',
          'reuseLastNonce = $_reuseLastNonce',
        ].join('\n'),
        elapsed: DateTime.now().difference(started),
      ));
    } catch (e) {
      _append(_LogEntry.failure(
        label: 'selfDiscardCert (Stage 5e)',
        summary: _reuseLastNonce
            ? 'REJECTED (expected — replay test)'
            : 'FAILED',
        detail: e.toString(),
        elapsed: DateTime.now().difference(started),
      ));
    } finally {
      setState(() => _busy = false);
    }
  }

  /// SHA256(seed || bucket_be) → low 24 bits as user_otp.
  /// Matches the circuit's C2 constraint byte-for-byte.
  int _computeUserOtp(Uint8List seed, int bucket) {
    final bytes = Uint8List(8);
    bytes.buffer.asByteData().setUint64(0, bucket, Endian.big);
    final h = sha256.convert([...seed, ...bytes]).bytes;
    // Low 24 bits = bytes[29], bytes[30], bytes[31] packed MSB-first.
    return (h[29] << 16) | (h[30] << 8) | h[31];
  }

  Uint8List _randomBytes32() {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
  }

  String _bytesHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Future<void> _copyLog() async {
    final dump = _log
        .map((e) => '[${e.ok ? 'OK' : 'FAIL'}] ${e.label} (${e.elapsed.inMilliseconds}ms)\n'
            '  ${e.summary}\n'
            '  ${e.detail.replaceAll('\n', '\n  ')}')
        .join('\n\n');
    await Clipboard.setData(ClipboardData(text: dump));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Log copied to clipboard'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        title: const Text(
          'Spoof Defense Test',
          style: TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (_log.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy log',
              onPressed: _copyLog,
            ),
          if (_log.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear_all),
              tooltip: 'Clear log',
              onPressed: () => setState(() => _log.clear()),
            ),
        ],
      ),
      floatingActionButton: _lastCeremony == null
          ? null
          : FloatingActionButton.extended(
              backgroundColor: AppTheme.accent,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('OTP panel'),
              onPressed: () => _openPostCeremonyPanel(_lastCeremony!),
            ),
      body: Column(
        children: [
          _EnvironmentBanner(),
          const Divider(height: 1, color: Color(0xFF333333)),
          _ProbeButtons(
            busy: _busy,
            onProbeOs: _probeOs,
            onRunCeremony: _runCeremony,
            onRunPcHmacSmokeTest: _runPcHmacSmokeTest,
            onRunMimeWrapBenchmark: _runMimeWrapBenchmark,
            onRunMimeWrapSetup: _runMimeWrapSetup,
          ),
          const Divider(height: 1, color: Color(0xFF333333)),
          // Panel + log share one scroll view so the soft keyboard can
          // never bury the Stage 4c URL field or its action buttons —
          // the user can always swipe up past the keyboard inset.
          Expanded(
            child: ListView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              children: [
                _Stage4cPanel(
                  busy: _busy,
                  rpcUrlController: _rpcUrlController,
                  phraseController: _phraseController,
                  contractNonceController: _contractNonceController,
                  offerBlockController: _offerBlockController,
                  certThumbprintController: _certThumbprintController,
                  reuseLastNonce: _reuseLastNonce,
                  onToggleReuseLastNonce: (v) =>
                      setState(() => _reuseLastNonce = v),
                  onMintCert: _runMintCert,
                  onSelfDiscardCert: _runSelfDiscardCert,
                ),
                const Divider(height: 1, color: Color(0xFF333333)),
                if (_log.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(
                      child: Text(
                        'Tap a probe above to begin.',
                        style: TextStyle(color: Color(0xFF888888)),
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        for (int i = 0; i < _log.length; i++) ...[
                          if (i > 0) const SizedBox(height: 8),
                          _LogTile(entry: _log[i]),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Format a `ParsedKeyDescription` into log lines. Returns a list so
/// the caller can splice these into the combined detail block without
/// nested newline wrangling. Hex output for byte arrays uses lowercase
/// (grep-friendly in the flutter run stdout).
List<String> _dumpKeyDescription(ParsedKeyDescription? kd) {
  if (kd == null) {
    return ['  (parser returned null — KeyDescription extension absent or parse failed)'];
  }
  final out = <String>[
    '  attestationVersion        = ${kd.attestationVersion}',
    '  attestationSecurityLevel  = ${kd.attestationSecurityLevel} (${kd.attestationSecurityLevelName()})',
    '  keyMintVersion            = ${kd.keyMintVersion}',
    '  keyMintSecurityLevel      = ${kd.keyMintSecurityLevel}',
    '  attestationChallenge      = ${_hex(kd.attestationChallenge)}',
    '  osVersion                 = ${kd.osVersion ?? "(absent)"}',
    '  osPatchLevel              = ${kd.osPatchLevel ?? "(absent)"}',
    '  vendorPatchLevel          = ${kd.vendorPatchLevel ?? "(absent)"}',
    '  bootPatchLevel            = ${kd.bootPatchLevel ?? "(absent)"}',
    '  attestationApplicationId  = ${kd.attestationApplicationIdRaw == null ? "(absent)" : _hex(kd.attestationApplicationIdRaw!)}',
  ];
  final rot = kd.rootOfTrust;
  if (rot == null) {
    out.add('  rootOfTrust               = (absent)');
  } else {
    out.addAll([
      '  rootOfTrust.verifiedBootState = ${rot.verifiedBootState} (${rot.verifiedBootStateName()})',
      '  rootOfTrust.deviceLocked      = ${rot.deviceLocked}',
      '  rootOfTrust.verifiedBootKey   = ${_hex(rot.verifiedBootKey)}',
      '  rootOfTrust.verifiedBootHash  = ${_hex(rot.verifiedBootHash)}',
    ]);
  }
  return out;
}

/// Lowercase-hex for a Uint8List. Caps display at 128 chars with
/// ellipsis — full-chain leaf certs can be 1-2 KB and would overflow
/// logcat buffers otherwise. Since the test-screen output is for
/// design-time data capture not forensic audit, truncation is fine.
String _hex(Uint8List bytes) {
  final s = bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  if (s.length <= 128) return s;
  return '${s.substring(0, 120)}…(${bytes.length} bytes total)';
}

class _EnvironmentBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: const Color(0xFF1A1A1A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Environment',
            style: TextStyle(
              color: Color(0xFF888888),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Platform.operatingSystem: ${Platform.operatingSystem}\n'
            'Platform.version: ${Platform.version.split(" ").first}\n'
            'kDebugMode: $kDebugMode',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _ProbeButtons extends StatelessWidget {
  final bool busy;
  final Future<void> Function(String expected) onProbeOs;
  final Future<void> Function() onRunCeremony;
  final Future<void> Function() onRunPcHmacSmokeTest;
  final Future<void> Function() onRunMimeWrapBenchmark;
  final Future<void> Function() onRunMimeWrapSetup;

  const _ProbeButtons({
    required this.busy,
    required this.onProbeOs,
    required this.onRunCeremony,
    required this.onRunPcHmacSmokeTest,
    required this.onRunMimeWrapBenchmark,
    required this.onRunMimeWrapSetup,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton.icon(
            onPressed: busy ? null : onRunMimeWrapSetup,
            icon: const Icon(Icons.vpn_key),
            label: const Text('Stage 4c.1: prepare mime-wrap setup (surface VK)'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: busy ? null : onRunMimeWrapBenchmark,
            icon: const Icon(Icons.speed),
            label: const Text('Stage 2: mime-wrap proof benchmark (ark-circom)'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF7C5CE6),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: busy ? null : onRunPcHmacSmokeTest,
            icon: const Icon(Icons.verified_user),
            label: const Text('Stage 0 keystone: PC-on-HMAC smoke test'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4A90E2),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: busy ? null : onRunCeremony,
            icon: const Icon(Icons.lock_clock),
            label: const Text('Run full ceremony'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Individual OS attestations (Rust-side, no keystore):',
            style: TextStyle(color: Color(0xFF888888), fontSize: 12),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final target in const ['android', 'linux', 'windows', 'macos'])
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: OutlinedButton(
                      onPressed: busy ? null : () => onProbeOs(target),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Color(0xFF444444)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      child: Text(target, style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LogEntry {
  final String label;
  final String summary;
  final String detail;
  final bool ok;
  final Duration elapsed;
  final DateTime at;

  _LogEntry._({
    required this.label,
    required this.summary,
    required this.detail,
    required this.ok,
    required this.elapsed,
  }) : at = DateTime.now();

  factory _LogEntry.success({
    required String label,
    required String summary,
    required String detail,
    required Duration elapsed,
  }) =>
      _LogEntry._(
        label: label,
        summary: summary,
        detail: detail,
        ok: true,
        elapsed: elapsed,
      );

  factory _LogEntry.failure({
    required String label,
    required String summary,
    required String detail,
    required Duration elapsed,
  }) =>
      _LogEntry._(
        label: label,
        summary: summary,
        detail: detail,
        ok: false,
        elapsed: elapsed,
      );
}

/// Stage 4c end-to-end panel: RPC URL + signer phrase inputs, plus the
/// register + sign buttons that exercise the Rostro node extrinsics.
///
/// Laid out compactly under the probe-button row so the log area stays
/// visible for reading results as tests run. Not a shipping-UI surface.
class _Stage4cPanel extends StatelessWidget {
  final bool busy;
  final TextEditingController rpcUrlController;
  final TextEditingController phraseController;
  final TextEditingController contractNonceController;
  final TextEditingController offerBlockController;
  final TextEditingController certThumbprintController;
  final bool reuseLastNonce;
  final void Function(bool) onToggleReuseLastNonce;
  final Future<void> Function() onMintCert;
  final Future<void> Function() onSelfDiscardCert;

  const _Stage4cPanel({
    required this.busy,
    required this.rpcUrlController,
    required this.phraseController,
    required this.contractNonceController,
    required this.offerBlockController,
    required this.certThumbprintController,
    required this.reuseLastNonce,
    required this.onToggleReuseLastNonce,
    required this.onMintCert,
    required this.onSelfDiscardCert,
  });

  @override
  Widget build(BuildContext context) {
    const label = TextStyle(color: Color(0xFFAAAAAA), fontSize: 11);
    final inputDecoration = InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(
        borderSide: const BorderSide(color: Color(0xFF444444)),
        borderRadius: BorderRadius.circular(4),
      ),
      enabledBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: Color(0xFF444444)),
        borderRadius: BorderRadius.circular(4),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: Color(0xFF10B981)),
        borderRadius: BorderRadius.circular(4),
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Stage 4c: end-to-end against the Rostro node',
            style: TextStyle(
              color: Color(0xFF10B981),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          const Text('RPC URL', style: label),
          const SizedBox(height: 4),
          TextField(
            controller: rpcUrlController,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            decoration: inputDecoration,
          ),
          const SizedBox(height: 8),
          const Text('Signer phrase (default //Alice for dev)', style: label),
          const SizedBox(height: 4),
          TextField(
            controller: phraseController,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            decoration: inputDecoration,
          ),
          const SizedBox(height: 8),
          const Text(
            'contract_nonce — 32-byte hex from issuer\'s ContractOffered event',
            style: label,
          ),
          const SizedBox(height: 4),
          TextField(
            controller: contractNonceController,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            decoration: inputDecoration,
          ),
          const SizedBox(height: 8),
          const Text('offer_created_at_block — u32 (decimal)', style: label),
          const SizedBox(height: 4),
          TextField(
            controller: offerBlockController,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            decoration: inputDecoration,
          ),
          const SizedBox(height: 8),
          const Text(
            'cert_thumbprint — 32-byte hex from CertMinted (post-mint)',
            style: label,
          ),
          const SizedBox(height: 4),
          TextField(
            controller: certThumbprintController,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            decoration: inputDecoration,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: busy ? null : onMintCert,
                  icon: const Icon(Icons.app_registration, size: 16),
                  label: const Text(
                    'Stage 5e: mint cert',
                    style: TextStyle(fontSize: 12),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: busy ? null : onSelfDiscardCert,
                  icon: const Icon(Icons.send, size: 16),
                  label: const Text(
                    'Stage 5e: self-discard PoP',
                    style: TextStyle(fontSize: 12),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Checkbox(
                value: reuseLastNonce,
                onChanged: busy ? null : (v) => onToggleReuseLastNonce(v ?? false),
                checkColor: Colors.white,
                fillColor: WidgetStateProperty.resolveWith((states) =>
                    states.contains(WidgetState.selected)
                        ? const Color(0xFF10B981)
                        : const Color(0xFF333333)),
              ),
              const Expanded(
                child: Text(
                  'Reuse last nonce (drives ReplayRejected test)',
                  style: TextStyle(color: Color(0xFFAAAAAA), fontSize: 11),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  final _LogEntry entry;

  const _LogTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final color = entry.ok ? const Color(0xFF4CAF50) : const Color(0xFFE53935);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                entry.ok ? Icons.check_circle : Icons.cancel,
                size: 16,
                color: color,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  entry.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              Text(
                '${entry.elapsed.inMilliseconds}ms',
                style: const TextStyle(
                  color: Color(0xFF888888),
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            entry.summary,
            style: TextStyle(color: color, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            entry.detail,
            style: const TextStyle(
              color: Color(0xFFCCCCCC),
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Post-ceremony observation panel
//
// Renders the TOTP enrollment + verification UX so we can observe the
// lifecycle of the extracted `totp_seed` end-to-end on real hardware:
// what enters memory, what touches clipboard, when it's used for
// verification, when it's zeroized. Every stage emits a SPOOFTEST log
// line so the flutter run terminal captures the full sequence.
//
// Scope: diagnostic only. This isn't the production enrollment UX —
// that lives in the mint-flow work (separate session). Here we just
// instrument enough of the flow to verify no unexpected leaks or
// StrongBox side-effects.
// ═══════════════════════════════════════════════════════════════════════════

class _PostCeremonyPanel extends StatefulWidget {
  final ZkPkiCeremonyResult ceremony;
  final VoidCallback onZeroize;

  const _PostCeremonyPanel({
    required this.ceremony,
    required this.onZeroize,
  });

  @override
  State<_PostCeremonyPanel> createState() => _PostCeremonyPanelState();
}

class _PostCeremonyPanelState extends State<_PostCeremonyPanel> {
  final _otpController = TextEditingController();
  String? _verificationResult;
  bool _zeroized = false;
  late final String _otpauthUri;

  @override
  void initState() {
    super.initState();
    final seed = widget.ceremony.totpSecret;
    debugPrint('SPOOFTEST | [panel] init: seed Uint8List '
        'identityHashCode=${identityHashCode(seed)}, length=${seed.length}');
    _otpauthUri = _buildOtpAuthUri(seed);
    debugPrint('SPOOFTEST | [panel] otpauth URI constructed '
        '(length=${_otpauthUri.length}; secret bytes now base32-'
        'encoded inside the URI string — IN-MEMORY EXPOSURE)');
  }

  @override
  void dispose() {
    _otpController.dispose();
    super.dispose();
  }

  /// Build the otpauth:// URI that authenticator apps consume.
  /// Standard format: issuer + label + secret (base32) + algorithm
  /// + digits + period. Uses SHA1 as the OTP hash because that's
  /// what ~all authenticator apps default to; the StrongBox HMAC
  /// key itself is SHA256 but that's a separate concern (it's what
  /// produced the seed, not what's used per-OTP).
  String _buildOtpAuthUri(Uint8List seed) {
    final secret = _base32Encode(seed);
    return 'otpauth://totp/dotwave:ceremony-test'
        '?secret=$secret'
        '&issuer=dotwave'
        '&algorithm=SHA1'
        '&digits=6'
        '&period=30';
  }

  Future<void> _copyUri() async {
    if (_zeroized) return;
    debugPrint('SPOOFTEST | [clipboard] user tapped Copy URI');
    await Clipboard.setData(ClipboardData(text: _otpauthUri));
    debugPrint('SPOOFTEST | [clipboard] write complete — URI now in '
        'system clipboard (readable by any app with clipboard access '
        'until overwritten; Android 10+ restricts background reads '
        'but foreground apps still see it)');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('otpauth URI copied — paste into authenticator app'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _clearClipboard() async {
    debugPrint('SPOOFTEST | [clipboard] wiping system clipboard');
    await Clipboard.setData(const ClipboardData(text: ''));
    debugPrint('SPOOFTEST | [clipboard] wipe complete');
  }

  void _verifyOtp() {
    if (_zeroized) return;
    final entered = _otpController.text.trim();
    debugPrint('SPOOFTEST | [verify] user submitted OTP (${entered.length} digits)');
    if (entered.length != 6 || int.tryParse(entered) == null) {
      debugPrint('SPOOFTEST | [verify] REJECT — malformed OTP input');
      setState(() => _verificationResult = 'REJECT — OTP must be 6 digits');
      return;
    }

    final now = DateTime.now();
    final windowCenter = now.millisecondsSinceEpoch ~/ 1000 ~/ 30;
    debugPrint('SPOOFTEST | [verify] computing TOTP windows '
        '${windowCenter - 1}, $windowCenter, ${windowCenter + 1} '
        '(±1 step tolerance)');

    final seed = widget.ceremony.totpSecret;
    String? match;
    for (var delta = -1; delta <= 1; delta++) {
      final code = _computeTotp(seed, windowCenter + delta);
      if (code == entered) {
        match = 'delta=$delta';
      }
    }

    if (match != null) {
      debugPrint('SPOOFTEST | [verify] MATCH at $match');
      setState(() => _verificationResult = 'MATCH (window $match)');
    } else {
      debugPrint('SPOOFTEST | [verify] MISMATCH — entered code not in '
          'the ±1 time-step window');
      setState(() => _verificationResult =
          'MISMATCH — check authenticator clock, re-enter current code');
    }
  }

  void _zeroize() {
    debugPrint('SPOOFTEST | [zeroize] user tapped Zeroize button');
    _clearClipboard();
    widget.onZeroize();
    setState(() {
      _zeroized = true;
      _otpController.clear();
      _verificationResult = null;
    });
    debugPrint('SPOOFTEST | [zeroize] panel locked, clipboard wiped, '
        'seed buffer overwritten — observation run complete');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.qr_code_2, color: AppTheme.accent),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'TOTP Enrollment Observation',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_zeroized) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check_circle,
                        color: Color(0xFF4CAF50), size: 32),
                    SizedBox(height: 8),
                    Text(
                      'Seed zeroized.',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'In-memory buffer overwritten with zeros. Clipboard '
                      'wiped. Observation run complete — check the flutter '
                      'run terminal for the SPOOFTEST | log.',
                      style: TextStyle(
                          color: Color(0xFFCCCCCC), fontSize: 13),
                    ),
                  ],
                ),
              ),
            ] else ...[
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.white,
                  child: QrImageView(
                    data: _otpauthUri,
                    version: QrVersions.auto,
                    size: 220,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'otpauth URI',
                style: TextStyle(
                    color: Color(0xFF888888),
                    fontSize: 12,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFF333333)),
                ),
                child: SelectableText(
                  _otpauthUri,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.copy),
                label: const Text('Copy URI to clipboard'),
                onPressed: _copyUri,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF444444)),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Enter 6-digit OTP from authenticator',
                style: TextStyle(
                    color: Color(0xFF888888),
                    fontSize: 12,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _otpController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                style: const TextStyle(
                    color: Colors.white, fontSize: 18, letterSpacing: 4),
                decoration: InputDecoration(
                  hintText: '000000',
                  hintStyle: const TextStyle(color: Color(0xFF555555)),
                  counterText: '',
                  filled: true,
                  fillColor: const Color(0xFF1A1A1A),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: Color(0xFF333333)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _verifyOtp,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text('Verify OTP'),
              ),
              if (_verificationResult != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _verificationResult!.startsWith('MATCH')
                        ? const Color(0xFF1B3A1B)
                        : const Color(0xFF3A1B1B),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _verificationResult!,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontFamily: 'monospace'),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_forever),
                label: const Text('Zeroize seed & wipe clipboard'),
                onPressed: _zeroize,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFE53935),
                  side: const BorderSide(color: Color(0xFFE53935)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── TOTP + base32 helpers (RFC 4648 alphabet, RFC 6238 TOTP) ─────────

/// Standard base32 encoding (RFC 4648 alphabet, no padding — matches
/// what most authenticator apps expect in otpauth URIs).
String _base32Encode(Uint8List bytes) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final buf = StringBuffer();
  var bits = 0;
  var value = 0;
  for (final b in bytes) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      buf.write(alphabet[(value >> (bits - 5)) & 0x1f]);
      bits -= 5;
    }
  }
  if (bits > 0) {
    buf.write(alphabet[(value << (5 - bits)) & 0x1f]);
  }
  return buf.toString();
}

/// Compute a 6-digit TOTP for a given secret and time-step counter.
/// Standard HOTP (RFC 4226) as used by TOTP (RFC 6238) with HMAC-SHA1.
String _computeTotp(Uint8List secret, int counter) {
  final counterBytes = Uint8List(8);
  var c = counter;
  for (var i = 7; i >= 0; i--) {
    counterBytes[i] = c & 0xff;
    c = c >> 8;
  }
  final hmac = Hmac(sha1, secret);
  final digest = hmac.convert(counterBytes).bytes;
  final offset = digest.last & 0x0f;
  final code = ((digest[offset] & 0x7f) << 24) |
      ((digest[offset + 1] & 0xff) << 16) |
      ((digest[offset + 2] & 0xff) << 8) |
      (digest[offset + 3] & 0xff);
  final otp = code % math.pow(10, 6).toInt();
  return otp.toString().padLeft(6, '0');
}
