import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../bridge/bridge_generated.dart/chat.dart';

/// Standing-callsign pool + dead-drop rotation persistence (Phase 4).
///
/// The ping-pong rotation logic lives in Rust core
/// (`dead_drop::DeadDropThread`, bridged as [DeadDropThreadDto] + the
/// `deaddrop*` fns); this service owns only the app-side state — the
/// ≤[maxCallsigns] standing callsigns a user polls, and the per-thread
/// rotation DTO — persisted in the secure store. See
/// docs/DOTWAVE-CHAT-DEAD-DROPS.md.
class DeadDropService extends ChangeNotifier {
  DeadDropService._();
  static final DeadDropService instance = DeadDropService._();

  static const _storage = FlutterSecureStorage();

  /// Mirrors `dead_drop::MAX_CALLSIGNS` (the core enforces it too).
  static const int maxCallsigns = 10;

  String _callsignsKey(String address) => 'deaddrop_callsigns_$address';
  String _threadKey(String address, String threadId) =>
      'deaddrop_thread_${address}_$threadId';

  // ── Standing callsigns ──────────────────────────────────────────────

  /// The user's standing callsigns (front-door labels they poll).
  Future<List<String>> callsigns(String address) async {
    final raw = await _storage.read(key: _callsignsKey(address));
    if (raw == null || raw.isEmpty) return [];
    return (jsonDecode(raw) as List).cast<String>();
  }

  /// Add a callsign. Idempotent; throws at the cap (a hard cutover, never a
  /// silent drop).
  Future<void> addCallsign(String address, String label) async {
    final list = await callsigns(address);
    if (list.contains(label)) return;
    if (list.length >= maxCallsigns) {
      throw 'Callsign list is full ($maxCallsigns max) — remove one first.';
    }
    list.add(label);
    await _storage.write(key: _callsignsKey(address), value: jsonEncode(list));
    notifyListeners();
  }

  Future<void> removeCallsign(String address, String label) async {
    final list = await callsigns(address);
    list.remove(label);
    await _storage.write(key: _callsignsKey(address), value: jsonEncode(list));
    notifyListeners();
  }

  /// Generate a random ed25519-shaped (32-byte) label — opaque, so the drop
  /// blends into the field of N other drops rather than advertising a human
  /// name. Same shape the engine mints return addresses in.
  Future<String> generateRandomLabel() => chatMintReturnPickup();

  /// The pickup bucket a callsign routes to (`for_deaddrop(label)`). Both
  /// the sender's opener target and the recipient's poll bucket.
  Future<String> bucketFor(String label) => chatDeaddropPickup(label: label);

  // ── Per-thread ping-pong rotation state ─────────────────────────────

  /// Persist a thread's rotation DTO (the core owns the transitions; this
  /// only serialises the state the app holds between turns).
  Future<void> saveThread(
      String address, String threadId, DeadDropThreadDto dto) async {
    final json = jsonEncode({
      'out': dto.outboundTargetHex,
      'in': dto.inboundCurrentHex,
      'grace': dto.grace
          .map((g) => {'p': g.pickupHex, 'r': g.roundsLeft})
          .toList(),
    });
    await _storage.write(key: _threadKey(address, threadId), value: json);
  }

  /// Load a thread's rotation DTO, or `null` if none persisted.
  Future<DeadDropThreadDto?> loadThread(String address, String threadId) async {
    final raw = await _storage.read(key: _threadKey(address, threadId));
    if (raw == null) return null;
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return DeadDropThreadDto(
      outboundTargetHex: m['out'] as String,
      inboundCurrentHex: m['in'] as String,
      grace: (m['grace'] as List)
          .map((g) => DeadDropGraceEntry(
                pickupHex: g['p'] as String,
                roundsLeft: g['r'] as int,
              ))
          .toList(),
    );
  }
}
