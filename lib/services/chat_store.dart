import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../bridge/bridge_generated.dart/chat.dart';
import '../bridge/bridge_generated.dart/core.dart'
    show
        chatResolveIdentity,
        chatSetupMessaging,
        ChatSetupOutcome,
        devCertSeedHex,
        chatMintTestCert;
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

  /// Cleartext body. For inbound messages this is empty until the explicit
  /// read step (`chat_read_content`) decrypts [sealedContentHex] — content
  /// arrives SEALED at rest (Phase 3), never as plaintext on fetch. Wiring
  /// the read step is F1 (see docs/DOTWAVE-CHAT-FRONTEND-PLAN.md).
  final String text;

  /// SCALE-encoded `ContentSealed` blob (hex) for inbound at-rest messages,
  /// stored verbatim and decrypted only on demand via the silicon read step.
  /// Empty for outbound messages (authored locally).
  final String sealedContentHex;

  final int tsMillis; // local stamp (send-time / first-seen)
  final bool verified;

  const ChatMessage({
    required this.id,
    required this.contactPubkey,
    required this.outbound,
    required this.text,
    this.sealedContentHex = '',
    required this.tsMillis,
    required this.verified,
  });

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(tsMillis);

  /// Inbound, still-sealed (content not yet read off the silicon key).
  bool get isSealed => !outbound && sealedContentHex.isNotEmpty && text.isEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'c': contactPubkey,
        'o': outbound,
        't': text,
        'sc': sealedContentHex,
        'ts': tsMillis,
        'v': verified,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        contactPubkey: j['c'] as String,
        outbound: j['o'] as bool,
        text: j['t'] as String,
        sealedContentHex: (j['sc'] as String?) ?? '',
        tsMillis: j['ts'] as int,
        verified: (j['v'] as bool?) ?? false,
      );
}

/// A correspondent — keyed by their ed25519 chat pubkey, with an
/// optional human label (a `.rst` name once RNS resolution is wired,
/// or a user-set nickname for now).
class ChatContact {
  final String pubkey; // ed25519 chat-identity pubkey (hex)

  /// The resolved `.rst` name this contact was reached by (F1: conversations
  /// start by name, not pasted hex). Empty for inbound-discovered contacts
  /// until their claimed sender name is forward-resolve-verified.
  final String name;

  /// The contact's published content key (MESSAGE record), hex of the
  /// curve-tagged ContentPublicKey. Cached from resolution so sends can seal
  /// the inner content to it without re-resolving. Empty = dead-drop / unknown.
  final String contentKeyHex;

  final String? label;

  const ChatContact({
    required this.pubkey,
    this.name = '',
    this.contentKeyHex = '',
    this.label,
  });

  /// Short, human-glanceable handle when no name/label is set.
  String get shortPubkey =>
      pubkey.length <= 12 ? pubkey : '${pubkey.substring(0, 6)}…${pubkey.substring(pubkey.length - 4)}';

  String get display => name.isNotEmpty
      ? name
      : (label != null && label!.isNotEmpty)
          ? label!
          : shortPubkey;

  Map<String, dynamic> toJson() => {'pk': pubkey, 'n': name, 'ck': contentKeyHex, 'l': label};

  factory ChatContact.fromJson(Map<String, dynamic> j) => ChatContact(
        pubkey: j['pk'] as String,
        name: (j['n'] as String?) ?? '',
        contentKeyHex: (j['ck'] as String?) ?? '',
        label: j['l'] as String?,
      );
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
  String _contentSeedKey(String address) => 'chat_content_seed_$address';
  String _myNameKey(String address) => 'chat_my_name_$address';
  String _certSeedKey(String address) => 'chat_cert_seed_$address';
  String _certThumbprintKey(String address) => 'chat_cert_thumbprint_$address';
  String _contactsKey(String address) => 'chat_contacts_$address';
  String _threadKey(String address, String pubkey) => 'chat_msgs_${address}_$pubkey';
  static const _nodeKey = 'chat_node_rpc';

  /// Content-key curve for the dev/software path. 0 = P-256 (StrongBox curve);
  /// on hardware the seed is replaced by a non-extractable silicon key.
  static const int _contentCurve = 0;

  /// TTL (in blocks) for the dev admission cert. ~41 days at 6s blocks.
  static const int _certTtlBlocks = 600000;

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

  /// The device's content-key seed (hex), created on first use. The hardware
  /// content key (MESSAGE record) is derived from it. PoC: a software seed in
  /// secure storage; on real silicon this is a StrongBox/TPM key handle.
  Future<String> contentSeedHex(String address) async {
    final existing = await _storage.read(key: _contentSeedKey(address));
    if (existing != null && existing.length == 64) return existing;
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key: _contentSeedKey(address), value: hex);
    return hex;
  }

  /// This device's published content key (MESSAGE record value), hex of the
  /// curve-tagged ContentPublicKey. Senders seal inner content to it.
  Future<String> contentKey(String address) async {
    final seed = await contentSeedHex(address);
    return chatGenContentKey(curve: _contentCurve, contentSeedHex: seed);
  }

  /// This account's own `.rst` chat name (claimed in the signed inner so the
  /// recipient can forward-resolve-verify it). Set at onboarding; the chain has
  /// no reverse name lookup, so the user's name is held locally.
  Future<String> myName(String address) async =>
      (await _storage.read(key: _myNameKey(address))) ?? '';

  Future<void> _setMyName(String address, String name) async {
    await _storage.write(key: _myNameKey(address), value: name);
  }

  // ── Step 1: admission cert (authenticate to the node) ───────────
  //
  // The drop is admitted by the node only if it's signed by an Active
  // HW-attested cert (anti-abuse: "a real secure element / human is
  // sending" — NOT identity). On the dev box the cert is a software P-256
  // key derived deterministically from the account; on real hardware it's a
  // StrongBox/TPM key behind the same digest + wire format. The onion drop
  // (Step 2) signs blake2_256(domain ‖ packet ‖ ts) with the cert key; this
  // layer makes sure the cert exists and hands the drop its (thumbprint,
  // cert seed). Minting is a chain op (register_root) — needs a
  // block-producing chain, so it's live-exercised once the lab is up.

  /// The account's cert seed (hex), deterministic from the signing phrase so
  /// the idempotent mint and the signing key stay in lockstep. Cached after
  /// first derivation. On hardware this is a non-extractable silicon key.
  Future<String> certSeedHex(String address, String phrase) async {
    final cached = await _storage.read(key: _certSeedKey(address));
    if (cached != null && cached.isNotEmpty) return cached;
    final seed = await devCertSeedHex(phrase: phrase);
    await _storage.write(key: _certSeedKey(address), value: seed);
    return seed;
  }

  /// Ensure the account holds an Active admission cert; returns its
  /// thumbprint (hex). Idempotent — the mint is a no-op on chain if the
  /// account already has a root cert. Caches the thumbprint so repeat sends
  /// don't re-query the chain. Requires the signing phrase (mint is a chain
  /// extrinsic); call from onboarding where the phrase is in hand.
  Future<String> ensureCert(String address, String phrase) async {
    final cached = await _storage.read(key: _certThumbprintKey(address));
    if (cached != null && cached.isNotEmpty) return cached;
    final seed = await certSeedHex(address, phrase);
    final node = await nodeRpc();
    final thumbprint = await chatMintTestCert(
      rpcUrl: node,
      phrase: phrase,
      certSeedHex: seed,
      ttlBlocks: _certTtlBlocks,
    );
    await _storage.write(key: _certThumbprintKey(address), value: thumbprint);
    return thumbprint;
  }

  /// The cached (thumbprint, cert seed) the onion drop authenticates with.
  /// Null if no cert has been minted yet (call [ensureCert] first, from
  /// onboarding). Keeps Step 2's send free of the signing phrase.
  Future<({String thumbprint, String certSeedHex})?> certAuth(String address) async {
    final tp = await _storage.read(key: _certThumbprintKey(address));
    final seed = await _storage.read(key: _certSeedKey(address));
    if (tp == null || tp.isEmpty || seed == null || seed.isEmpty) return null;
    return (thumbprint: tp, certSeedHex: seed);
  }

  // ── onboarding + resolution (F1) ────────────────────────────────

  /// One-step "set up messaging": register `name` and publish this device's
  /// typed CHAT (Ed25519 address) + MESSAGE (content key) records under it.
  /// `phrase` is the account's signing secret. Persists the name locally so it
  /// can be claimed as the sender name on outbound messages.
  Future<ChatSetupOutcome> setupMessaging(String address, String name, String phrase) async {
    final seed = await seedHex(address);
    final ck = await contentKey(address);
    final node = await nodeRpc();
    final outcome = await chatSetupMessaging(
      name: name,
      phrase: phrase,
      rpcUrl: node,
      identitySeedHex: seed,
      innerContentKeyHex: ck,
    );
    if (outcome.published) {
      await _setMyName(address, name);
      // Step 1: ensure the account can also AUTHENTICATE to drop (admission
      // cert). Minted here while the phrase is in hand; idempotent. Tolerated
      // if it fails (e.g. chain not producing) — onboarding's addressability
      // (CHAT/MESSAGE) still stands and the cert can be minted later.
      try {
        await ensureCert(address, phrase);
      } catch (_) {/* cert mint deferred; ensureCert is idempotent on retry */}
      notifyListeners();
    }
    return outcome;
  }

  /// Start (or refresh) a conversation by `.rst` name: resolve the name's
  /// typed CHAT + MESSAGE records, cache the contact's ed25519 pubkey + content
  /// key, and return it. Throws if the name has no chat identity published.
  Future<ChatContact> resolveContactByName(String address, String name) async {
    final node = await nodeRpc();
    final r = await chatResolveIdentity(name: name, rpcUrl: node);
    if (!r.found) {
      throw StateError("'$name' has no published chat identity (no CHAT record)");
    }
    return upsertContact(
      address,
      r.ed25519PubkeyHex,
      name: name,
      contentKeyHex: r.innerContentKeyHex,
    );
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

  Future<ChatContact> upsertContact(
    String address,
    String pubkey, {
    String? name,
    String? contentKeyHex,
    String? label,
  }) async {
    final list = await contacts(address);
    final idx = list.indexWhere((c) => c.pubkey == pubkey);
    final prev = idx >= 0 ? list[idx] : null;
    final contact = ChatContact(
      pubkey: pubkey,
      // Keep previously-resolved values when this call doesn't supply them
      // (e.g. an inbound message upsert shouldn't clobber a resolved name).
      name: (name != null && name.isNotEmpty) ? name : (prev?.name ?? ''),
      contentKeyHex: (contentKeyHex != null && contentKeyHex.isNotEmpty)
          ? contentKeyHex
          : (prev?.contentKeyHex ?? ''),
      label: label ?? prev?.label,
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

  /// Look up a cached contact by ed25519 pubkey, or null.
  Future<ChatContact?> contactByPubkey(String address, String pubkey) async {
    final list = await contacts(address);
    final idx = list.indexWhere((c) => c.pubkey == pubkey);
    return idx >= 0 ? list[idx] : null;
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

  // ── send-path inputs (F1 wired; DR session is the last F2 gate) ──

  /// The recipient's published content key (MESSAGE record), from the cached
  /// contact resolved by name. The inner payload is sealed to it — there is no
  /// plaintext-inner path, so a contact reached only by raw pubkey (no resolved
  /// MESSAGE key) can't be sent to until it's resolved by name.
  Future<String> _recipientContentKey(String address, String contactPubkey) async {
    final c = await contactByPubkey(address, contactPubkey);
    final ck = c?.contentKeyHex ?? '';
    if (ck.isEmpty) {
      throw StateError(
          'no content key for this contact — start the conversation by .rst name '
          'so its MESSAGE record resolves');
    }
    return ck;
  }

  /// This device's sender `.rst` name (claimed in the signed inner; the
  /// recipient forward-resolves it and checks the published key matches).
  Future<String> _senderName(String address) async {
    final name = await myName(address);
    if (name.isEmpty) {
      throw StateError('set up messaging first (no .rst name published for this account)');
    }
    return name;
  }

  /// F2: per-conversation Double Ratchet session state (hex), persisted
  /// encrypted and advanced on every send/read. Empty bootstraps X3DH. The
  /// last remaining plug point — forward-secret send needs the recipient SPK,
  /// whose typed-records home is F2's open decision.
  Future<String> _drSessionState(String address, String contactPubkey) async =>
      throw UnimplementedError('F2: load/persist DR session state (needs recipient SPK)');

  // ── send / refresh (the RPC-facing surface) ─────────────────────

  /// Seal + sign + dispatch a message to [contactPubkey]. Appends the
  /// outbound message locally on success. Throws on RPC failure.
  ///
  /// F0: wired to the re-baselined v1.0 `chat_send` binding; the content
  /// key + sender name (F1) and DR session state (F2) come from the plug
  /// points above, which throw until their phase lands.
  Future<ChatMessage> send(String address, String contactPubkey, String text) async {
    final seed = await seedHex(address);
    final node = await nodeRpc();
    final outcome = await chatSend(
      nodeRpc: node,
      senderSeedHex: seed,
      recipientPubkeyHex: contactPubkey,
      recipientContentKeyHex: await _recipientContentKey(address, contactPubkey), // F1
      message: text,
      senderName: await _senderName(address), // F1
      totalShares: 5,
      drSessionStateHex: await _drSessionState(address, contactPubkey), // F2
      x3DhInitHex: null, // F2: carried on the first message of a conversation
      authCertThumbprintHex: null, // F1/P2: HW-attested device cert seam
      authCertSeedHex: null,
    );
    // F2: outcome.newSessionStateHex MUST be persisted (encrypted) before
    // the send is considered done — losing it breaks the ratchet.
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

  /// Pull shares from the relay, reassemble + outer-unseal + sender-verify
  /// on-device, and merge any new inbound messages into their threads as
  /// SEALED-at-rest blobs. Content stays encrypted (Phase 3); decrypting it
  /// is the explicit read step (`chat_read_content`), wired in F1. Returns
  /// the number of newly-seen messages. Unknown senders are auto-added as
  /// contacts so a fresh conversation appears.
  Future<int> refresh(String address) async {
    final seed = await seedHex(address);
    final node = await nodeRpc();
    final fetched = await chatFetch(
      nodeRpc: node,
      recipientSeedHex: seed,
      relayPeer: null,
    );
    var newCount = 0;
    for (final m in fetched) {
      final contactPubkey = m.senderPubkeyHex;
      final list = await messages(address, contactPubkey);
      if (list.any((x) => x.id == m.messageIdHex)) continue; // dedupe
      list.add(ChatMessage(
        id: m.messageIdHex,
        contactPubkey: contactPubkey,
        outbound: false,
        text: '', // content is sealed at rest; decrypt is the F1 read step
        sealedContentHex: m.sealedContentHex,
        tsMillis: DateTime.now().millisecondsSinceEpoch,
        verified: true, // outer-layer sender signature already checked on-device
      ));
      list.sort((a, b) => a.tsMillis.compareTo(b.tsMillis));
      await _persistThread(address, contactPubkey);
      await upsertContact(address, contactPubkey);
      newCount++;
    }
    if (newCount > 0) notifyListeners();
    return newCount;
  }

  /// THE read step: decrypt a sealed inbound message's content (Phase 3 — on
  /// hardware this is the biometric→silicon gate) and surface the plaintext +
  /// the forward-resolve-verified sender name. Replaces the sealed blob with
  /// the decrypted text in the thread.
  ///
  /// F1 handles `Plain` content (no DR session). `Ratcheted` content needs the
  /// per-conversation DR session (F2). Device-seizure / amnesiac-at-rest
  /// behaviour (don't persist plaintext) is F3.
  Future<ChatMessage> readMessage(String address, String contactPubkey, String messageId) async {
    final list = await messages(address, contactPubkey);
    final idx = list.indexWhere((m) => m.id == messageId);
    if (idx < 0) throw StateError('message not found');
    final m = list[idx];
    if (!m.isSealed) return m; // already read, or nothing sealed

    final read = await chatReadContent(
      sealedContentHex: m.sealedContentHex,
      curve: _contentCurve,
      contentSeedHex: await contentSeedHex(address),
      drSessionStateHex: null, // F2: Ratcheted content threads the DR session here
      identitySeedHex: await seedHex(address),
      opkSecrets: const [],
    );

    // Forward-resolve-and-verify the claimed sender name (impersonation-
    // resistant): the claimed name must resolve to THIS exact ed25519 sender
    // key. A name that doesn't match is dropped, not displayed.
    var verifiedName = '';
    if (read.claimedSenderName.isNotEmpty) {
      try {
        final r = await chatResolveIdentity(name: read.claimedSenderName, rpcUrl: await nodeRpc());
        if (r.found && r.ed25519PubkeyHex == contactPubkey) {
          verifiedName = read.claimedSenderName;
        }
      } catch (_) {
        // resolution failure → leave the name unverified (blank), never spoofable
      }
    }

    final updated = ChatMessage(
      id: m.id,
      contactPubkey: contactPubkey,
      outbound: false,
      text: read.plaintext,
      sealedContentHex: '', // consumed
      tsMillis: m.tsMillis,
      verified: true,
    );
    list[idx] = updated;
    await _persistThread(address, contactPubkey);
    if (verifiedName.isNotEmpty) {
      await upsertContact(address, contactPubkey, name: verifiedName);
    }
    notifyListeners();
    return updated;
  }
}
