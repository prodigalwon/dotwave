import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One discovered chat guard — a community node dotwave has learned about via
/// the authenticated `chat_guards` discovery call (see
/// docs/CHAT-GUARD-DISCOVERY.md).
class ChatGuard {
  /// Opaque dialable address / PeerID (encoding is the node contract's). Used
  /// both to dial the guard for drops and to RNS-resolve its owner (accounta-
  /// bility) — nothing else about the guard is trusted from the response.
  final String address;

  /// Node-reported last sighting of this member in the chat channel (epoch ms).
  final int nodeSeenMillis;

  /// This device's last successful contact with the guard (epoch ms; 0 = never).
  final int myContactMillis;

  const ChatGuard({
    required this.address,
    required this.nodeSeenMillis,
    this.myContactMillis = 0,
  });

  ChatGuard copyWith({int? nodeSeenMillis, int? myContactMillis}) => ChatGuard(
        address: address,
        nodeSeenMillis: nodeSeenMillis ?? this.nodeSeenMillis,
        myContactMillis: myContactMillis ?? this.myContactMillis,
      );

  Map<String, dynamic> toJson() =>
      {'a': address, 's': nodeSeenMillis, 'c': myContactMillis};

  factory ChatGuard.fromJson(Map<String, dynamic> j) => ChatGuard(
        address: j['a'] as String,
        nodeSeenMillis: (j['s'] as num).toInt(),
        myContactMillis: (j['c'] as num?)?.toInt() ?? 0,
      );
}

/// A freshly-fetched entry from the node's signed discovery response.
class GuardEntry {
  final String address;
  final int lastSeenSecs; // node's last sighting, epoch seconds
  const GuardEntry({required this.address, required this.lastSeenSecs});
}

/// Client-side guard cache + random-spread selection for dead-drops.
///
/// Learns live guards from the connected node's authenticated `chat_guards`
/// response, caches them with timestamps ("node last saw it" / "I last reached
/// it"), prunes by staleness, and hands the send path a random distinct
/// (guard, relay-2) pair — so no single guard sees a user's whole traffic.
///
/// Falls back to hand-configured guard/relay-2 whenever the cache can't supply
/// two distinct fresh guards, so behavior is unchanged until discovery is
/// populated (the node-side `chat_guards` RPC + the `chatDiscoverGuards` bridge
/// fn are TODO in a separate thread).
class GuardDiscovery {
  GuardDiscovery._();
  static final GuardDiscovery instance = GuardDiscovery._();

  static const _storage = FlutterSecureStorage();
  static const _cacheKey = 'chat_guard_cache';

  /// A guard is usable if seen (by the node OR by us) within this window.
  static const _staleness = Duration(minutes: 30);

  /// Don't re-hit the discovery endpoint more often than this.
  static const _refreshInterval = Duration(minutes: 5);

  final _rng = Random.secure();
  List<ChatGuard>? _cache; // lazily loaded
  DateTime? _lastRefresh;

  int get _now => DateTime.now().millisecondsSinceEpoch;
  int get _cutoff => _now - _staleness.inMilliseconds;

  Future<List<ChatGuard>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final raw = await _storage.read(key: _cacheKey);
    if (raw == null || raw.isEmpty) return _cache = [];
    try {
      return _cache = (jsonDecode(raw) as List)
          .map((e) => ChatGuard.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return _cache = [];
    }
  }

  Future<void> _save() async => _storage.write(
      key: _cacheKey,
      value: jsonEncode((_cache ?? []).map((g) => g.toJson()).toList()));

  bool _isFresh(ChatGuard g) =>
      g.nodeSeenMillis >= _cutoff || g.myContactMillis >= _cutoff;

  /// Current cached guards (may include stale entries).
  Future<List<ChatGuard>> guards() async => List.of(await _load());

  /// Merge a freshly-fetched batch: bump node-seen times, keep our own
  /// last-contact, and prune anything neither clock has seen within the window.
  Future<void> ingest(List<GuardEntry> fetched) async {
    final byAddr = {for (final g in await _load()) g.address: g};
    for (final e in fetched) {
      final seenMs = e.lastSeenSecs * 1000;
      final prev = byAddr[e.address];
      byAddr[e.address] = prev == null
          ? ChatGuard(address: e.address, nodeSeenMillis: seenMs)
          : prev.copyWith(
              nodeSeenMillis:
                  seenMs > prev.nodeSeenMillis ? seenMs : prev.nodeSeenMillis);
    }
    _cache = byAddr.values.where(_isFresh).toList();
    await _save();
  }

  /// Record a successful contact so the guard stays fresh via our own clock.
  Future<void> markContacted(String address) async {
    final cache = await _load();
    final i = cache.indexWhere((g) => g.address == address);
    if (i < 0) return; // fallback (hand-configured) address not in cache — no-op
    cache[i] = cache[i].copyWith(myContactMillis: _now);
    await _save();
  }

  /// Pick a random distinct (guard, relay-2) pair from the fresh set. Falls back
  /// to the supplied hand-configured values when fewer than two fresh guards are
  /// known — preserving today's behavior until discovery is populated.
  Future<({String guard, String relay2})> pickGuardAndRelay({
    required String fallbackGuard,
    required String fallbackRelay2,
  }) async {
    final fresh = (await _load()).where(_isFresh).map((g) => g.address).toList();
    if (fresh.length < 2) {
      return (guard: fallbackGuard, relay2: fallbackRelay2);
    }
    final i = _rng.nextInt(fresh.length);
    var j = _rng.nextInt(fresh.length - 1);
    if (j >= i) j++; // fold into a distinct second index
    return (guard: fresh[i], relay2: fresh[j]);
  }

  /// Authenticate-gate + throttle + fetch + ingest. Honors the auth gate on the
  /// client too (don't touch the endpoint pre-auth). No-op until the rust_core
  /// bridge fn lands — the fetch is isolated in [_fetch] so the cache/selection
  /// above is real and exercised today.
  Future<void> refreshGuards(
      {required bool authenticated, required String nodeRpc}) async {
    if (!authenticated) return;
    final last = _lastRefresh;
    final now = DateTime.now();
    if (last != null && now.difference(last) < _refreshInterval) return;
    _lastRefresh = now;
    final fetched = await _fetch(nodeRpc);
    if (fetched.isNotEmpty) await ingest(fetched);
  }

  /// SEAM: the signed `chat_guards` fetch via rust_core. Returns [] until the
  /// bridge fn `chatDiscoverGuards` exists (docs/CHAT-GUARD-DISCOVERY.md §8).
  Future<List<GuardEntry>> _fetch(String nodeRpc) async {
    // TODO(node-thread): wire the signed, session-authenticated fetch:
    //   final r = await chatDiscoverGuards(rpcUrl: nodeRpc, certThumbprintHex:.., certSeedHex:..);
    //   return r.map((e) => GuardEntry(address: e.address, lastSeenSecs: e.lastSeenSecs)).toList();
    return const [];
  }
}
