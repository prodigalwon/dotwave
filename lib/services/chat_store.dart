import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../bridge/bridge_generated.dart/chat.dart';
import '../config/rpc_endpoints.dart';

/// One end-to-end-encrypted message in a thread.
///
/// `outbound` messages are authored on this device; `inbound` messages
/// were fetched from a relay, reassembled, unsealed and sender-verified
/// locally (so [verified] reflects the on-device signature check).
class ChatMessage {
  final String id; // message_id_hex (per-message random 32-byte id)
  final String contactPubkey; // the other party's ed25519 chat pubkey (hex)
  final bool outbound;
  final String text;
  final int tsMillis; // local stamp (send-time / first-seen)
  final bool verified;

  const ChatMessage({
    required this.id,
    required this.contactPubkey,
    required this.outbound,
    required this.text,
    required this.tsMillis,
    required this.verified,
  });

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(tsMillis);

  Map<String, dynamic> toJson() => {
        'id': id,
        'c': contactPubkey,
        'o': outbound,
        't': text,
        'ts': tsMillis,
        'v': verified,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        contactPubkey: j['c'] as String,
        outbound: j['o'] as bool,
        text: j['t'] as String,
        tsMillis: j['ts'] as int,
        verified: (j['v'] as bool?) ?? false,
      );
}

/// A correspondent — keyed by their ed25519 chat pubkey, with an
/// optional human label (a `.rst` name once RNS resolution is wired,
/// or a user-set nickname for now).
class ChatContact {
  final String pubkey; // ed25519 chat-identity pubkey (hex)
  final String? label;

  const ChatContact({required this.pubkey, this.label});

  /// Short, human-glanceable handle when no label is set.
  String get shortPubkey =>
      pubkey.length <= 12 ? pubkey : '${pubkey.substring(0, 6)}…${pubkey.substring(pubkey.length - 4)}';

  String get display => (label != null && label!.isNotEmpty) ? label! : shortPubkey;

  Map<String, dynamic> toJson() => {'pk': pubkey, 'l': label};

  factory ChatContact.fromJson(Map<String, dynamic> j) =>
      ChatContact(pubkey: j['pk'] as String, label: j['l'] as String?);
}

/// Device-local chat state: the user's chat identity, contacts, cached
/// threads, and the relay node override. Persists to secure storage,
/// scoped per wallet address so multiple accounts don't collide.
///
/// A [ChangeNotifier] so the conversation list and open thread update
/// the moment a send lands or a refresh pulls new mail.
class ChatStore extends ChangeNotifier {
  ChatStore._();
  static final ChatStore instance = ChatStore._();

  static const _storage = FlutterSecureStorage();

  // In-memory caches (hydrated lazily from storage).
  final Map<String, List<ChatContact>> _contacts = {};
  final Map<String, List<ChatMessage>> _threads = {}; // key: '$address|$pubkey'
  String? _nodeRpcOverride;
  bool _nodeLoaded = false;

  // ── keys ────────────────────────────────────────────────────────
  String _seedKey(String address) => 'chat_seed_$address';
  String _contactsKey(String address) => 'chat_contacts_$address';
  String _threadKey(String address, String pubkey) => 'chat_msgs_${address}_$pubkey';
  static const _nodeKey = 'chat_node_rpc';

  // ── identity ────────────────────────────────────────────────────

  /// The device's chat-identity seed (hex), created on first use.
  ///
  /// PoC: a fresh 32-byte CSPRNG seed stored in secure storage. (A
  /// later pass derives it deterministically from the wallet key so
  /// the chat identity follows the account, and binds it via a zkpki
  /// cert — see DOTWAVE-BRIDGE-TESTNET.md step 4.)
  Future<String> seedHex(String address) async {
    final existing = await _storage.read(key: _seedKey(address));
    if (existing != null && existing.length == 64) return existing;
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key: _seedKey(address), value: hex);
    return hex;
  }

  /// This device's public chat identity (the pubkey others address, and
  /// the pickup key the relay indexes shares under).
  Future<ChatIdentity> identity(String address) async {
    final seed = await seedHex(address);
    return chatGenIdentity(seedHex: seed);
  }

  // ── node override ───────────────────────────────────────────────

  Future<String> nodeRpc() async {
    if (!_nodeLoaded) {
      _nodeRpcOverride = await _storage.read(key: _nodeKey);
      _nodeLoaded = true;
    }
    final v = _nodeRpcOverride;
    return (v != null && v.isNotEmpty) ? v : RpcEndpoints.chatNode;
  }

  Future<void> setNodeRpc(String? url) async {
    _nodeRpcOverride = (url != null && url.trim().isNotEmpty) ? url.trim() : null;
    _nodeLoaded = true;
    if (_nodeRpcOverride == null) {
      await _storage.delete(key: _nodeKey);
    } else {
      await _storage.write(key: _nodeKey, value: _nodeRpcOverride!);
    }
    notifyListeners();
  }

  // ── contacts ────────────────────────────────────────────────────

  Future<List<ChatContact>> contacts(String address) async {
    if (_contacts.containsKey(address)) return _contacts[address]!;
    final raw = await _storage.read(key: _contactsKey(address));
    final list = <ChatContact>[];
    if (raw != null && raw.isNotEmpty) {
      for (final e in (jsonDecode(raw) as List)) {
        list.add(ChatContact.fromJson(e as Map<String, dynamic>));
      }
    }
    _contacts[address] = list;
    return list;
  }

  Future<ChatContact> upsertContact(String address, String pubkey, {String? label}) async {
    final list = await contacts(address);
    final idx = list.indexWhere((c) => c.pubkey == pubkey);
    final contact = ChatContact(
      pubkey: pubkey,
      label: label ?? (idx >= 0 ? list[idx].label : null),
    );
    if (idx >= 0) {
      list[idx] = contact;
    } else {
      list.add(contact);
    }
    await _persistContacts(address);
    notifyListeners();
    return contact;
  }

  Future<void> _persistContacts(String address) async {
    final list = _contacts[address] ?? [];
    await _storage.write(
      key: _contactsKey(address),
      value: jsonEncode(list.map((c) => c.toJson()).toList()),
    );
  }

  // ── threads ─────────────────────────────────────────────────────

  Future<List<ChatMessage>> messages(String address, String pubkey) async {
    final key = '$address|$pubkey';
    if (_threads.containsKey(key)) return _threads[key]!;
    final raw = await _storage.read(key: _threadKey(address, pubkey));
    final list = <ChatMessage>[];
    if (raw != null && raw.isNotEmpty) {
      for (final e in (jsonDecode(raw) as List)) {
        list.add(ChatMessage.fromJson(e as Map<String, dynamic>));
      }
    }
    list.sort((a, b) => a.tsMillis.compareTo(b.tsMillis));
    _threads[key] = list;
    return list;
  }

  /// Most recent message in a thread, or null if empty.
  ChatMessage? lastMessage(String address, String pubkey) {
    final list = _threads['$address|$pubkey'];
    if (list == null || list.isEmpty) return null;
    return list.last;
  }

  Future<void> _persistThread(String address, String pubkey) async {
    final list = _threads['$address|$pubkey'] ?? [];
    await _storage.write(
      key: _threadKey(address, pubkey),
      value: jsonEncode(list.map((m) => m.toJson()).toList()),
    );
  }

  // ── send / refresh (the RPC-facing surface) ─────────────────────

  /// Seal + sign + dispatch a message to [contactPubkey]. Appends the
  /// outbound message locally on success. Throws on RPC failure.
  Future<ChatMessage> send(String address, String contactPubkey, String text) async {
    final seed = await seedHex(address);
    final node = await nodeRpc();
    final outcome = await chatSend(
      nodeRpc: node,
      senderSeedHex: seed,
      recipientPubkeyHex: contactPubkey,
      message: text,
      totalShares: 5,
      // Cert-auth seam — filled in step 4 (HW-attested device cert).
      authThumbprintHex: null,
      authTimestampSecs: null,
      authSigHex: null,
    );
    final msg = ChatMessage(
      id: outcome.messageIdHex,
      contactPubkey: contactPubkey,
      outbound: true,
      text: text,
      tsMillis: DateTime.now().millisecondsSinceEpoch,
      verified: true, // we authored it
    );
    final list = await messages(address, contactPubkey);
    list.add(msg);
    await _persistThread(address, contactPubkey);
    await upsertContact(address, contactPubkey);
    notifyListeners();
    return msg;
  }

  /// Pull shares from the relay, reassemble + unseal + verify locally,
  /// and merge any new inbound messages into their threads. Returns the
  /// number of newly-seen messages. Unknown senders are auto-added as
  /// contacts so a fresh conversation appears.
  Future<int> refresh(String address) async {
    final seed = await seedHex(address);
    final node = await nodeRpc();
    final recovered = await chatFetch(
      nodeRpc: node,
      recipientSeedHex: seed,
      relayPeer: null,
    );
    var newCount = 0;
    for (final r in recovered) {
      final contactPubkey = r.senderPubkeyHex;
      final list = await messages(address, contactPubkey);
      if (list.any((m) => m.id == r.messageIdHex)) continue; // dedupe
      list.add(ChatMessage(
        id: r.messageIdHex,
        contactPubkey: contactPubkey,
        outbound: false,
        text: r.plaintext,
        tsMillis: DateTime.now().millisecondsSinceEpoch,
        verified: true, // verify_sender already passed on-device
      ));
      list.sort((a, b) => a.tsMillis.compareTo(b.tsMillis));
      await _persistThread(address, contactPubkey);
      await upsertContact(address, contactPubkey);
      newCount++;
    }
    if (newCount > 0) notifyListeners();
    return newCount;
  }
}
