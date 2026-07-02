import 'package:flutter/services.dart';

import '../bridge/bridge_generated.dart/membership.dart' as membership;

/// Chat anonymous-membership enrollment (M1 of
/// DOTWAVE-MEMBERSHIP-AUTH-CLIENT-PLAN): produce the `ChatEnrollment`
/// pair that `mint_cert` carries as its 7th argument.
///
/// The member secret `s` is derived in-chip (anon-membership D1): a
/// dedicated StrongBox AGREE_KEY `W` runs ECDH against the fixed
/// nothing-up-my-sleeve point `P_FIXED` behind one BIOMETRIC_STRONG
/// prompt; rust_core reduces the shared secret to `s`, computes
/// `id_commitment = Poseidon(s)`, and zeroizes. `attest_ec` (the mint
/// ceremony's attested key) then signs the domain-separated binding
/// message, tying the commitment to the same silicon the attestation
/// proved (D2). The chain verifies via `verify_chat_enrollment` before
/// inserting the membership leaf.
///
/// The same in-chip ECDH re-derives `s` at every 24h-epoch membership
/// handshake (M4); this service owns only the mint-time enrollment.
class MembershipEnrollmentService {
  static const _channel = MethodChannel('dotwave/security');

  /// The enrollment pair for `submit_mint_cert_strongbox`.
  ///
  /// [challengeHex] MUST be the offer nonce (`contract_nonce`) — the
  /// same bytes the ceremony used as its attestation challenge and the
  /// chain passes to `verify_chat_enrollment`.
  ///
  /// Throws [MembershipEnrollmentException] on any failure (including
  /// biometric cancel); enrollment is all-or-nothing by design.
  Future<MembershipEnrollment> enroll(String challengeHex) async {
    // 1. Ensure W exists (idempotent, never rotates; no biometric).
    final wPub = await _invoke<Uint8List>('membershipEnsureWKey', null,
        'membership W key unavailable (StrongBox/API-31 required)');

    // 2. In-chip ECDH(W, P_FIXED) behind one biometric prompt.
    final pFixed = await membership.membershipPFixedSec1();
    final shared = await _invoke<Uint8List>('membershipEcdh',
        {'pFixedSec1': pFixed}, 'in-chip membership ECDH failed');

    // 3. s = hash_to_field(shared); id_commitment = Poseidon(s). The
    //    shared secret is reduced and zeroized inside rust_core.
    final idCommitmentHex =
        await membership.membershipIdCommitment(sharedSecretHex: _toHex(shared));

    // 4. attest_ec signs blake2_256(CTX || id_commitment || challenge).
    final msgHex = await membership.membershipIdBindingMsg(
      idCommitmentHex: idCommitmentHex,
      challengeHex: challengeHex,
    );
    final sig = await _invoke<Uint8List>('zkpkiSignIdBinding',
        {'bindingMsg': _fromHex(msgHex)}, 'attest_ec id-binding signature failed');

    return MembershipEnrollment(
      idCommitmentHex: idCommitmentHex,
      idBindingSignatureHex: _toHex(sig),
      wPublicKeyHex: _toHex(wPub),
    );
  }

  /// The in-chip ECDH(W, P_FIXED) shared secret (hex), behind one
  /// BIOMETRIC_STRONG prompt. The membership handshake re-derives the
  /// member secret `s` from this every epoch; rust_core zeroizes it after
  /// the reduction. Requires the W key ([enroll] created it at mint).
  Future<String> sharedSecretHex() async {
    final pFixed = await membership.membershipPFixedSec1();
    final shared = await _invoke<Uint8List>('membershipEcdh',
        {'pFixedSec1': pFixed}, 'in-chip membership ECDH failed');
    return _toHex(shared);
  }

  Future<T> _invoke<T>(
      String method, Map<String, dynamic>? args, String failure) async {
    try {
      final out = await _channel.invokeMethod<T>(method, args);
      if (out == null) throw MembershipEnrollmentException(method, failure);
      return out;
    } on PlatformException catch (e) {
      throw MembershipEnrollmentException(
          method, '${e.code}: ${e.message ?? failure}');
    }
  }

  static String _toHex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _fromHex(String hex) {
    final s = hex.startsWith('0x') ? hex.substring(2) : hex;
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

/// The two fields of the chain's `ChatEnrollment`, plus the W pubkey for
/// diagnostics (the chain never sees W).
class MembershipEnrollment {
  final String idCommitmentHex;
  final String idBindingSignatureHex;
  final String wPublicKeyHex;

  MembershipEnrollment({
    required this.idCommitmentHex,
    required this.idBindingSignatureHex,
    required this.wPublicKeyHex,
  });
}

class MembershipEnrollmentException implements Exception {
  final String step;
  final String message;

  MembershipEnrollmentException(this.step, this.message);

  @override
  String toString() => 'MembershipEnrollmentException($step): $message';
}
