import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

import '../bridge/bridge_generated.dart/membership.dart' as membership;
import 'membership_enrollment_service.dart';

/// The anonymous membership session (M4/M5 of
/// DOTWAVE-MEMBERSHIP-AUTH-CLIENT-PLAN): on-device Groth16 proof of
/// membership -> `chat_authenticateMembership` -> a software Ed25519
/// session key that signs each drop. The guard learns the session key and
/// the per-epoch nullifier, never the cert.
///
/// Cost model: the handshake is one BIOMETRIC_STRONG prompt (the in-chip
/// ECDH that re-derives the member secret `s`) plus ~1s of proving, once
/// per 24h epoch. Drops within the session are silent. Sessions are held
/// in memory only — an app restart re-handshakes, which is one biometric.
class MembershipSessionService {
  MembershipSessionService._();
  static final MembershipSessionService instance = MembershipSessionService._();

  static const _pkAsset = 'assets/membership_pk.bin';

  final Map<String, MembershipSession> _sessions = {};

  /// Addresses whose cert has no membership enrollment (or whose guard has
  /// membership auth deactivated), so sends stop re-attempting the
  /// handshake every message this run.
  final Set<String> _unavailable = {};

  /// A live session for [address], or null without side effects.
  MembershipSession? liveSession(String address) => _sessions[address];

  /// Drop [address]'s session (the guard rejected it: epoch rolled or the
  /// node restarted). The next [ensureSession] re-handshakes.
  void invalidate(String address) => _sessions.remove(address);

  /// A live session for [address], establishing one if needed. Returns
  /// null when membership auth isn't available for this identity (not
  /// enrolled / guard not activated) — callers fall back to cert auth.
  ///
  /// [address] is the account SS58; the ENROLLED cert's thumbprint is
  /// discovered from chain state (the send path's admission cert is not
  /// necessarily the enrolled one — the dev cert isn't). The discovery
  /// runs BEFORE the biometric so an unenrolled account never prompts.
  Future<MembershipSession?> ensureSession(
    String address, {
    required String chainRpc,
    required String guardRpc,
  }) async {
    final existing = _sessions[address];
    if (existing != null) return existing;
    if (_unavailable.contains(address)) return null;

    try {
      // No biometric yet: find the chat-enrolled cert on chain.
      final thumbprintHex = await membership.membershipEnrolledThumbprint(
        chainRpc: chainRpc,
        accountSs58: address,
      );
      if (thumbprintHex == null) {
        debugPrint('membership: no enrolled cert for $address — cert fallback');
        _unavailable.add(address);
        return null;
      }

      // One biometric: in-chip ECDH re-derives the member secret.
      final sharedHex =
          await MembershipEnrollmentService().sharedSecretHex();
      final pk = await rootBundle.load(_pkAsset);
      final outcome = await membership.membershipAuthenticate(
        chainRpc: chainRpc,
        guardRpc: guardRpc,
        thumbprintHex: thumbprintHex,
        sharedSecretHex: sharedHex,
        pkBytes: pk.buffer.asUint8List(),
      );
      final session = MembershipSession(
        pubkeyHex: outcome.sessionPubkeyHex,
        seedHex: outcome.sessionSeedHex,
        expiresEpoch: outcome.expiresEpoch,
        guardNodeIdHex: outcome.guardNodeIdHex,
      );
      _sessions[address] = session;
      return session;
    } on MembershipEnrollmentException catch (e) {
      // Biometric cancel / no W key: not fatal, just no session this time.
      debugPrint('membership: handshake aborted: $e');
      return null;
    } catch (e) {
      final msg = e.toString();
      debugPrint('membership: handshake failed: $msg');
      // Permanent-for-this-run conditions: no enrolled leaf, the guard has
      // no membership vk pinned, or the per-epoch nullifier is already
      // spent (a fresh handshake CANNOT succeed anywhere until the 24h
      // epoch rolls — retrying would just burn a biometric per send; an
      // app restart after rollover re-enables). Transient RPC failures
      // stay retryable.
      if (msg.contains('no membership witness') ||
          msg.contains('not activated') ||
          msg.contains('already spent')) {
        _unavailable.add(address);
      }
      return null;
    }
  }
}

class MembershipSession {
  final String pubkeyHex;
  final String seedHex;
  final BigInt expiresEpoch;
  final String guardNodeIdHex;

  MembershipSession({
    required this.pubkeyHex,
    required this.seedHex,
    required this.expiresEpoch,
    required this.guardNodeIdHex,
  });
}
