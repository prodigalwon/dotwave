import 'package:flutter/foundation.dart';

import '../models/feed_item.dart';

/// Holds the Home "Recent Activity" feed.
///
/// Source-agnostic aggregator: chain history, chat events, and identity/cert
/// events (including upcoming expiries) all [add] their [FeedItem]s here, and
/// the Home feed renders whatever is present, newest-first. This is the
/// structure a real feed slots into — wire ingestion from those sources and
/// drop [_seedPlaceholders].
class FeedService extends ChangeNotifier {
  FeedService._() {
    // No live sources are wired yet. Seed a few representative entries so the
    // feed layout is visible on-device. Replace this with real ingestion.
    _seedPlaceholders();
  }
  static final FeedService instance = FeedService._();

  final List<FeedItem> _items = [];

  /// Items newest-first.
  List<FeedItem> get items {
    final copy = [..._items]..sort((a, b) => b.time.compareTo(a.time));
    return List.unmodifiable(copy);
  }

  bool get isEmpty => _items.isEmpty;

  /// Add (or replace, by id) a single item.
  void add(FeedItem item) {
    _items.removeWhere((i) => i.id == item.id);
    _items.add(item);
    notifyListeners();
  }

  /// Add (or replace, by id) many items at once.
  void addAll(Iterable<FeedItem> items) {
    for (final i in items) {
      _items.removeWhere((e) => e.id == i.id);
      _items.add(i);
    }
    notifyListeners();
  }

  /// Remove an item (a swipe-to-dismiss on the feed).
  void remove(String id) {
    _items.removeWhere((i) => i.id == id);
    notifyListeners();
  }

  void clear() {
    _items.clear();
    notifyListeners();
  }

  // ── Placeholder content (remove once real sources are wired) ────────────
  void _seedPlaceholders() {
    final now = DateTime.now();
    _items.addAll([
      FeedItem(
        id: 'sample-recv-1',
        kind: FeedKind.received,
        time: now.subtract(const Duration(minutes: 6)),
        title: 'Received from ferdie',
        amount: '+12.5 RST',
        avatarSeed: 'ferdie',
        details: {
          'From': 'ferdie.rst',
          'Status': 'Confirmed',
          'Reference': '0x9a3f…c21b',
        },
      ),
      // Messages NEVER carry plaintext in the feed — only that one arrived.
      FeedItem(
        id: 'sample-msg-1',
        kind: FeedKind.message,
        time: now.subtract(const Duration(hours: 4)),
        title: 'New message from ferdie',
        avatarSeed: 'ferdie',
      ),
      FeedItem(
        id: 'sample-sent-1',
        kind: FeedKind.sent,
        time: now.subtract(const Duration(days: 1)),
        title: 'Sent to alice',
        amount: '-4 RST',
        avatarSeed: 'alice',
        details: {
          'To': 'alice.rst',
          'Status': 'Confirmed',
          'Reference': '0x41d0…8e7a',
        },
      ),
      FeedItem(
        id: 'sample-name-expiry-1',
        kind: FeedKind.nameExpiring,
        time: now.subtract(const Duration(hours: 20)),
        title: 'anthony.rst expires soon',
        subtitle: 'Renew within 9 days to keep your name.',
        details: {
          'Name': 'anthony.rst',
          'Expires': 'in 9 days',
        },
      ),
      FeedItem(
        id: 'sample-cert-expiry-1',
        kind: FeedKind.certExpiring,
        time: now.subtract(const Duration(days: 2)),
        title: 'Admission cert expiring',
        subtitle: 'Re-mint within 5 days to keep sending messages.',
        details: {
          'Cert': 'Device admission (P-256)',
          'Expires': 'in 5 days',
        },
      ),
    ]);
  }
}
