import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../bridge/bridge_generated.dart/membership.dart' as membership;
import 'membership_enrollment_service.dart';

/// The anonymous membership session (M4/M5 + CHAT-SESSION-TICKET.md): an
/// on-device Groth16 proof of membership -> `chat_authenticateMembership`
/// -> a software Ed25519 session key that signs each drop. The guard learns
/// the session key and the per-epoch nullifier, never the cert.
///
/// The session is a PORTABLE TICKET: the handshake returns the co-signed
/// witnessed-spend record, which any guard can validate. So the session is
/// persisted per address (secure storage) and survives an app restart or a
/// guard switch WITHOUT a fresh handshake — present the ticket at the new
/// guard instead. One BIOMETRIC_STRONG prompt per 24h epoch (the first
/// handshake of the epoch); reuse within the epoch is silent.
class MembershipSessionService {
  MembershipSessionService._();
  static final MembershipSessionService instance = MembershipSessionService._();

  static const _pkAsset = 'assets/membership_pk.bin';
  static const _storage = FlutterSecureStorage();
  static String _storeKey(String address) => 'membership_session_$address';

  final Map<String, MembershipSession> _sessions = {};

  /// Addresses with no membership enrollment (or a guard with membership
  /// auth off), so sends stop retrying the handshake every message.
  final Set<String> _unavailable = {};

  MembershipSession? liveSession(String address) => _sessions[address];

  /// Drop [address]'s session everywhere (in-memory + persisted). The next
  /// [ensureSession] re-handshakes. Use when a guard rejects a live session
  /// (its ticket verification failed for a reason a re-present won't fix).
  Future<void> invalidate(String address) async {
    _sessions.remove(address);
    await _storage.delete(key: _storeKey(address));
  }

  /// A live session for [address], establishing one if needed. Returns null
  /// when membership auth isn't available (unenrolled / guard not activated
  /// / biometric declined) — callers fall back to cert auth.
  ///
  /// Order of preference, cheapest first:
  ///   1. in-memory session for this run;
  ///   2. persisted session still in the current epoch — present its ticket
  ///      at [guardRpc] (idempotent, no biometric) and reuse;
  ///   3. a fresh handshake (one biometric), persisted for next time.
  Future<MembershipSession?> ensureSession(
    String address, {
    required String chainRpc,
    required String guardRpc,
  }) async {
    final existing = _sessions[address];
    if (existing != null) return existing;
    if (_unavailable.contains(address)) return null;

    // Current epoch (cheap, no biometric) gates persisted-session reuse.
    int? currentEpoch;
    try {
      currentEpoch =
          (await membership.membershipCurrentEpoch(chainRpc: chainRpc)).toInt();
    } catch (e) {
      debugPrint('membership: current epoch unavailable: $e');
    }

    // 2. Reuse a persisted, still-valid session by presenting its ticket.
    if (currentEpoch != null) {
      final persisted = await _loadPersisted(address);
      if (persisted != null && persisted.expiresEpoch.toInt() == currentEpoch) {
        try {
          await membership.membershipPresentTicket(
            guardRpc: guardRpc,
            ticketHex: persisted.ticketHex,
          );
          _sessions[address] = persisted;
          debugPrint('membership: reused persisted session via ticket');
          return persisted;
        } catch (e) {
          // The guard refused the ticket (e.g. epoch just rolled). Fall
          // through to a fresh handshake; don't discard yet — the handshake
          // will overwrite on success.
          debugPrint('membership: ticket present failed, re-handshaking: $e');
        }
      }
    }

    // 3. Fresh handshake.
    try {
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
      final sharedHex = await MembershipEnrollmentService().sharedSecretHex();
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
        ticketHex: outcome.ticketHex,
      );
      _sessions[address] = session;
      await _persist(address, session);
      return session;
    } on MembershipEnrollmentException catch (e) {
      debugPrint('membership: handshake aborted: $e');
      return null;
    } catch (e) {
      final msg = e.toString();
      debugPrint('membership: handshake failed: $msg');
      // Permanent-for-this-run: no enrolled leaf, guard vk off, or the
      // nullifier is already spent with no reusable ticket (a fresh
      // handshake can't succeed until the epoch rolls). Transient RPC
      // failures stay retryable.
      if (msg.contains('no membership witness') ||
          msg.contains('not activated') ||
          msg.contains('already spent')) {
        _unavailable.add(address);
      }
      return null;
    }
  }

  Future<void> _persist(String address, MembershipSession s) async {
    await _storage.write(key: _storeKey(address), value: jsonEncode(s.toJson()));
  }

  Future<MembershipSession?> _loadPersisted(String address) async {
    try {
      final raw = await _storage.read(key: _storeKey(address));
      if (raw == null) return null;
      return MembershipSession.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('membership: persisted session unreadable: $e');
      return null;
    }
  }
}

class MembershipSession {
  final String pubkeyHex;
  final String seedHex;
  final BigInt expiresEpoch;
  final String guardNodeIdHex;

  /// The portable witnessed-spend ticket (SCALE hex) — presented to admit
  /// this session at any guard within [expiresEpoch].
  final String ticketHex;

  MembershipSession({
    required this.pubkeyHex,
    required this.seedHex,
    required this.expiresEpoch,
    required this.guardNodeIdHex,
    required this.ticketHex,
  });

  Map<String, dynamic> toJson() => {
        'pubkey': pubkeyHex,
        'seed': seedHex,
        'epoch': expiresEpoch.toString(),
        'guard': guardNodeIdHex,
        'ticket': ticketHex,
      };

  factory MembershipSession.fromJson(Map<String, dynamic> j) => MembershipSession(
        pubkeyHex: j['pubkey'] as String,
        seedHex: j['seed'] as String,
        expiresEpoch: BigInt.parse(j['epoch'] as String),
        guardNodeIdHex: j['guard'] as String,
        ticketHex: j['ticket'] as String,
      );
}
