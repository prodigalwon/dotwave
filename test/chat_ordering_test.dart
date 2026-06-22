// Unit tests for the read-time self-hash chain ordering (in-order chat
// delivery). The relay network is a dumb dead-drop: messages arrive in
// arbitrary order, possibly with gaps (TTL-dropped) or a reset (sender lost
// send-state). All ordering metadata lives inside the content seal; these
// tests exercise the pure `orderThread` reconstruction over `ChatMessage`s.

import 'package:flutter_test/flutter_test.dart';
import 'package:dotwave/services/chat_store.dart';

// Build an inbound (from-contact) message with explicit chain fields.
ChatMessage inbound(
  String id, {
  String self = '',
  String prev = '',
  int composedAt = 0,
  int ts = 0,
}) =>
    ChatMessage(
      id: id,
      contactPubkey: 'CONTACT',
      outbound: false,
      text: id, // body == id for easy order assertions
      tsMillis: ts,
      verified: true,
      selfHash: self,
      prevSelfHash: prev,
      composedAt: composedAt,
    );

ChatMessage outbound(String id, {int composedAt = 0, int ts = 0}) =>
    ChatMessage(
      id: id,
      contactPubkey: 'CONTACT',
      outbound: true,
      text: id,
      tsMillis: ts,
      verified: true,
      selfHash: 'out-$id',
      composedAt: composedAt,
    );

List<String> bodies(List<ChatMessage> ms) => ms.map((m) => m.text).toList();

void main() {
  group('self-hash chain ordering', () {
    test('a shuffled single-sender chain reconstructs send order', () {
      // a -> b -> c -> d, delivered out of order.
      final shuffled = [
        inbound('c', self: 'h3', prev: 'h2', composedAt: 30),
        inbound('a', self: 'h1', prev: '', composedAt: 10),
        inbound('d', self: 'h4', prev: 'h3', composedAt: 40),
        inbound('b', self: 'h2', prev: 'h1', composedAt: 20),
      ];
      final ordered = orderThread(shuffled);
      expect(bodies(ordered), ['a', 'b', 'c', 'd']);
      // No breaks: first message has no prev (not a resumption), none missing.
      expect(ordered.any((m) => m.gapBefore), isFalse);
      expect(ordered.any((m) => m.resumption), isFalse);
    });

    test('chain order wins even when composed_at is rolled back', () {
      // The sender's clock went backwards between b and c, but the chain
      // is authoritative — order must still be a,b,c.
      final msgs = [
        inbound('a', self: 'h1', prev: '', composedAt: 100),
        inbound('b', self: 'h2', prev: 'h1', composedAt: 200),
        inbound('c', self: 'h3', prev: 'h2', composedAt: 150),
      ];
      expect(bodies(orderThread(msgs)), ['a', 'b', 'c']);
    });

    test('a missing predecessor is flagged as a gap', () {
      // We hold a, then d (prev=h3) but never received b/c. d heads a new
      // segment whose referenced predecessor is absent -> gapBefore.
      final msgs = [
        inbound('a', self: 'h1', prev: '', composedAt: 10),
        inbound('d', self: 'h4', prev: 'h3', composedAt: 40),
      ];
      final ordered = orderThread(msgs);
      expect(bodies(ordered), ['a', 'd']);
      final d = ordered.firstWhere((m) => m.text == 'd');
      expect(d.gapBefore, isTrue);
      expect(d.resumption, isFalse);
    });

    test('a None head after an earlier segment is a resumption (reset)', () {
      // a,b then a reset: c has no prev (sender lost send-state) but earlier
      // messages exist -> resumption, ordered after by composed_at.
      final msgs = [
        inbound('a', self: 'h1', prev: '', composedAt: 10),
        inbound('b', self: 'h2', prev: 'h1', composedAt: 20),
        inbound('c', self: 'h9', prev: '', composedAt: 90),
      ];
      final ordered = orderThread(msgs);
      expect(bodies(ordered), ['a', 'b', 'c']);
      final c = ordered.firstWhere((m) => m.text == 'c');
      expect(c.resumption, isTrue);
      expect(c.gapBefore, isFalse);
      // The genuine first message is never a resumption.
      expect(ordered.first.resumption, isFalse);
    });

    test('two streams interleave by composed_at, each chain intact', () {
      // Inbound chain i1->i2; outbound o1,o2. Compose times interleave them.
      final msgs = [
        inbound('i2', self: 'hi2', prev: 'hi1', composedAt: 30),
        outbound('o1', composedAt: 20),
        inbound('i1', self: 'hi1', prev: '', composedAt: 10),
        outbound('o2', composedAt: 40),
      ];
      final ordered = orderThread(msgs);
      expect(bodies(ordered), ['i1', 'o1', 'i2', 'o2']);
      // Inbound chain order preserved regardless of the interleave.
      final inboundOnly =
          ordered.where((m) => !m.outbound).map((m) => m.text).toList();
      expect(inboundOnly, ['i1', 'i2']);
    });

    test('markers are recomputed: a late predecessor clears the gap', () {
      final withGap = [
        inbound('a', self: 'h1', prev: '', composedAt: 10),
        inbound('c', self: 'h3', prev: 'h2', composedAt: 30),
      ];
      expect(orderThread(withGap).firstWhere((m) => m.text == 'c').gapBefore,
          isTrue);
      // b arrives late, filling the hole -> no gap on the next order.
      final filled = [
        ...withGap,
        inbound('b', self: 'h2', prev: 'h1', composedAt: 20),
      ];
      final ordered = orderThread(filled);
      expect(bodies(ordered), ['a', 'b', 'c']);
      expect(ordered.any((m) => m.gapBefore), isFalse);
    });

    test('still-sealed (no chain data) messages fall to the tail', () {
      final msgs = [
        inbound('sealed', self: '', prev: '', ts: 5), // unread: no chain yet
        inbound('a', self: 'h1', prev: '', composedAt: 10),
        inbound('b', self: 'h2', prev: 'h1', composedAt: 20),
      ];
      // Chained messages order first; the chain-less one trails.
      expect(bodies(orderThread(msgs)), ['a', 'b', 'sealed']);
    });
  });
}
