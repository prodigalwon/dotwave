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
import 'content_key_service.dart';

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

  // ── in-order delivery: the per-conversation self-hash chain ──────────
  // All three live INSIDE the content seal (see InnerPayload). The relay
  // network is dumb ephemeral transport and never sees them.

  /// This message's chain hash (hex) — what a successor's [prevSelfHash]
  /// references. Outbound: the tip returned by the send. Inbound: surfaced
  /// by `chat_read_content` once decrypted. Empty until known.
  final String selfHash;

  /// The sender's PREVIOUS message in this conversation (hex). Empty =
  /// first message OR a chain reset (no recoverable predecessor: prior
  /// send-state aged out at the ~72h TTL, or the cache was wiped).
  final String prevSelfHash;

  /// Sender wall-clock (unix seconds) at compose time. The hash chain is
  /// authoritative for a single sender's order; this only interleaves the
  /// two directional streams and orders disjoint segments across a gap.
  /// 0 until known.
  final int composedAt;

  // ── transient render markers (computed by _orderThread; NOT persisted,
  //    recomputed each order so a late-arriving message can fill a gap) ──

  /// A referenced predecessor is missing — a message between this and the
  /// prior one didn't arrive (TTL-dropped). Render a "missing" divider.
  final bool gapBefore;

  /// The sender restarted their chain here (their send-state was lost).
  /// Render a soft "resumed" divider, not a gap.
  final bool resumption;

  const ChatMessage({
    required this.id,
    required this.contactPubkey,
    required this.outbound,
    required this.text,
    this.sealedContentHex = '',
    required this.tsMillis,
    required this.verified,
    this.selfHash = '',
    this.prevSelfHash = '',
    this.composedAt = 0,
    this.gapBefore = false,
    this.resumption = false,
  });

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(tsMillis);

  /// Inbound, still-sealed (content not yet read off the silicon key).
  bool get isSealed => !outbound && sealedContentHex.isNotEmpty && text.isEmpty;

  ChatMessage copyWith({
    String? text,
    String? sealedContentHex,
    String? selfHash,
    String? prevSelfHash,
    int? composedAt,
    bool? gapBefore,
    bool? resumption,
  }) =>
      ChatMessage(
        id: id,
        contactPubkey: contactPubkey,
        outbound: outbound,
        text: text ?? this.text,
        sealedContentHex: sealedContentHex ?? this.sealedContentHex,
        tsMillis: tsMillis,
        verified: verified,
        selfHash: selfHash ?? this.selfHash,
        prevSelfHash: prevSelfHash ?? this.prevSelfHash,
        composedAt: composedAt ?? this.composedAt,
        // markers default to false — they are recomputed every reorder,
        // never carried implicitly.
        gapBefore: gapBefore ?? false,
        resumption: resumption ?? false,
      );

  // chain fields persist; render markers do not (they are derived).
  Map<String, dynamic> toJson() => {
        'id': id,
        'c': contactPubkey,
        'o': outbound,
        't': text,
        'sc': sealedContentHex,
        'ts': tsMillis,
        'v': verified,
        if (selfHash.isNotEmpty) 'sh': selfHash,
        if (prevSelfHash.isNotEmpty) 'ph': prevSelfHash,
        if (composedAt != 0) 'ca': composedAt,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        contactPubkey: j['c'] as String,
        outbound: j['o'] as bool,
        text: j['t'] as String,
        sealedContentHex: (j['sc'] as String?) ?? '',
        tsMillis: j['ts'] as int,
        verified: (j['v'] as bool?) ?? false,
        selfHash: (j['sh'] as String?) ?? '',
        prevSelfHash: (j['ph'] as String?) ?? '',
        composedAt: (j['ca'] as int?) ?? 0,
      );
}

// ── read-time ordering (the self-hash chain) ───────────────────────────
//
// Pure functions (top-level so they're unit-testable). Intra-sender order
// is authoritative from the hash chain; `composedAt` only interleaves the
// two directional streams and orders disjoint segments after a reset/gap.
// All ordering data rides INSIDE the content seal — the relay network is
// dumb ephemeral transport and learns nothing of order, recipient, or
// thread shape.

/// Order a thread for display, recomputing the gap/resumption markers.
/// Idempotent — a late-arriving message that fills a gap clears the marker
/// on the next call.
List<ChatMessage> orderThread(List<ChatMessage> msgs) {
  // Inbound is the contact's chain (reconstructed from prev_self_hash).
  // Outbound is locally authored — its order is the local send order,
  // reliable on the authoring device. Then merge by composed_at.
  final inbound = _orderChain(msgs.where((m) => !m.outbound).toList());
  final outbound = msgs.where((m) => m.outbound).toList()..sort(_cmpOrder);
  return _mergeByComposedAt(inbound, outbound);
}

/// Order one sender's stream by its self-hash chain. Walks each chain
/// segment tip-forward; orders disjoint segments by head `composedAt`;
/// flags a missing predecessor as a gap and a reset head as a resumption.
/// Messages with no chain data yet (still sealed / pre-ordering legacy)
/// fall to the tail by `composedAt`/`tsMillis`.
List<ChatMessage> _orderChain(List<ChatMessage> stream) {
  final withChain = stream.where((m) => m.selfHash.isNotEmpty).toList();
  final withoutChain = stream.where((m) => m.selfHash.isEmpty).toList()
    ..sort(_cmpOrder);
  if (withChain.isEmpty) return withoutChain;

  final bySelf = {for (final m in withChain) m.selfHash: m};
  // prevHash -> the message that follows it (the successor link).
  final next = <String, ChatMessage>{};
  for (final m in withChain) {
    if (m.prevSelfHash.isNotEmpty) next[m.prevSelfHash] = m;
  }
  // A head starts a segment: no prev (first/reset) OR its prev is absent
  // (the linking message was TTL-dropped — a gap).
  final heads = withChain
      .where(
          (m) => m.prevSelfHash.isEmpty || !bySelf.containsKey(m.prevSelfHash))
      .toList()
    ..sort(_cmpOrder);

  final ordered = <ChatMessage>[];
  final seen = <String>{};
  for (final head in heads) {
    ChatMessage? m = head;
    var first = true;
    while (m != null && !seen.contains(m.selfHash)) {
      seen.add(m.selfHash);
      var gap = false;
      var resumed = false;
      if (first) {
        if (m.prevSelfHash.isNotEmpty && !bySelf.containsKey(m.prevSelfHash)) {
          gap = true; // referenced predecessor missing (TTL drop)
        } else if (m.prevSelfHash.isEmpty && ordered.isNotEmpty) {
          resumed = true; // a None head after an earlier segment = reset
        }
      }
      ordered.add(m.copyWith(gapBefore: gap, resumption: resumed));
      first = false;
      m = next[m.selfHash];
    }
  }
  ordered.addAll(withoutChain);
  return ordered;
}

/// Merge two already-ordered streams by `composedAt`, preserving each
/// stream's internal order (so the inbound chain order is never broken).
List<ChatMessage> _mergeByComposedAt(List<ChatMessage> a, List<ChatMessage> b) {
  final out = <ChatMessage>[];
  var i = 0, j = 0;
  while (i < a.length && j < b.length) {
    if (_cmpOrder(a[i], b[j]) <= 0) {
      out.add(a[i++]);
    } else {
      out.add(b[j++]);
    }
  }
  while (i < a.length) {
    out.add(a[i++]);
  }
  while (j < b.length) {
    out.add(b[j++]);
  }
  return out;
}

/// Coarse order key: sender wall-clock when known, else the local stamp;
/// deterministic id tiebreak. Never overrides a chain link — it only
/// orders messages the chain leaves unordered (across segments/streams).
int _cmpOrder(ChatMessage a, ChatMessage b) {
  final ca = a.composedAt, cb = b.composedAt;
  if (ca > 0 && cb > 0 && ca != cb) return ca.compareTo(cb);
  if (a.tsMillis != b.tsMillis) return a.tsMillis.compareTo(b.tsMillis);
  return a.id.compareTo(b.id);
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

  // StrongBox content (decrypt) key seam — null-degrades to the software seed
  // on devices without StrongBox (dev box / emulator).
  final ContentKeyService _contentKeys = ContentKeyService();

  // In-memory caches (hydrated lazily from storage).
  final Map<String, List<ChatContact>> _contacts = {};
  final Map<String, List<ChatMessage>> _threads = {}; // key: '$address|$pubkey'
  String? _nodeRpcOverride;
  bool _nodeLoaded = false;
  String? _relay2RpcOverride;
  bool _relay2Loaded = false;

  // ── keys ────────────────────────────────────────────────────────
  String _seedKey(String address) => 'chat_seed_$address';
  String _contentSeedKey(String address) => 'chat_content_seed_$address';
  // Presence (non-empty) marks HARDWARE content mode; the value is this
  // device's published MESSAGE record (curve-tagged ContentPublicKey hex) for
  // the StrongBox content key. Absent => software-seed content path.
  String _contentHwKey(String address) => 'chat_content_hw_$address';
  String _myNameKey(String address) => 'chat_my_name_$address';
  String _certSeedKey(String address) => 'chat_cert_seed_$address';
  String _certThumbprintKey(String address) => 'chat_cert_thumbprint_$address';
  String _contactsKey(String address) => 'chat_contacts_$address';
  String _threadKey(String address, String pubkey) => 'chat_msgs_${address}_$pubkey';
  // The sender's last self-hash chain tip per conversation, stored as
  // 'tipHex:atUnixSecs' so a stale tip (past the relay TTL) resets the chain.
  String _chainTipKey(String address, String pubkey) => 'chat_tip_${address}_$pubkey';
  static const _nodeKey = 'chat_node_rpc';
  static const _relay2Key = 'chat_relay2_rpc';

  /// Content-key curve for the dev/software path. 0 = P-256 (StrongBox curve);
  /// on hardware the seed is replaced by a non-extractable silicon key.
  static const int _contentCurve = 0;
  // A chain tip older than the relay message TTL is dead: the recipient's
  // copy of that predecessor has aged out, so chaining to it would render a
  // perpetual gap. Past this, the next send starts a fresh chain (reset).
  static const int _chainTtlSecs = 72 * 3600;

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
  ///
  /// Hardware-first: if StrongBox can host a non-extractable P-256 content key
  /// it publishes that (the Phase-3 silicon path); otherwise it falls back to
  /// the software seed (the dev stand-in). The choice is recorded under
  /// [_contentHwKey] so the read path knows which seam to use.
  Future<String> contentKey(String address) async {
    final hw = await _ensureHardwareContentKey(address);
    if (hw != null) return hw;
    final seed = await contentSeedHex(address);
    return chatGenContentKey(curve: _contentCurve, contentSeedHex: seed);
  }

  /// Resolve (and cache) this device's HARDWARE content key as a published
  /// MESSAGE value, or null when StrongBox/API-31 is unavailable. Reuses an
  /// existing StrongBox key if present, else generates one. The private scalar
  /// stays in the secure element — only its public SEC1 ever surfaces here.
  Future<String?> _ensureHardwareContentKey(String address) async {
    final cached = await _storage.read(key: _contentHwKey(address));
    if (cached != null && cached.isNotEmpty) return cached;
    var sec1 = await _contentKeys.publicKeyHex();
    sec1 ??= await _contentKeys.generateHex();
    if (sec1 == null || sec1.isEmpty) return null; // no StrongBox → software path
    final ck = await chatContentPubkeyFromSec1(curve: _contentCurve, sec1Hex: sec1);
    await _storage.write(key: _contentHwKey(address), value: ck);
    return ck;
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

  /// The relay-2 node RPC for the 2-hop onion drop. The guard (`nodeRpc`)
  /// peels and forwards the inner packet to relay-2, which delivers — so a
  /// single relay never sees sender AND recipient. MUST be a *different*
  /// chat-capable (non-validator) node than the guard; returns '' if unset,
  /// in which case [send] throws asking the operator to configure one.
  Future<String> relay2Rpc() async {
    if (!_relay2Loaded) {
      _relay2RpcOverride = await _storage.read(key: _relay2Key);
      _relay2Loaded = true;
    }
    return _relay2RpcOverride ?? '';
  }

  Future<void> setRelay2Rpc(String? url) async {
    _relay2RpcOverride = (url != null && url.trim().isNotEmpty) ? url.trim() : null;
    _relay2Loaded = true;
    if (_relay2RpcOverride == null) {
      await _storage.delete(key: _relay2Key);
    } else {
      await _storage.write(key: _relay2Key, value: _relay2RpcOverride!);
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
    _threads[key] = list;
    _reorder(address, pubkey);
    return _threads[key]!;
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

  // ── the sender's self-hash chain tip (per conversation) ──────────────

  /// The sender's last chain tip for this conversation, or null if there
  /// is none yet or it has gone stale past the relay TTL — in which case
  /// the next message starts a fresh chain (a reset, rendered as a soft
  /// "resumed" boundary on the recipient rather than a perpetual gap).
  Future<String?> _liveChainTip(String address, String pubkey) async {
    final raw = await _storage.read(key: _chainTipKey(address, pubkey));
    if (raw == null || raw.isEmpty) return null;
    final i = raw.lastIndexOf(':');
    if (i <= 0) return null;
    final tip = raw.substring(0, i);
    final atSecs = int.tryParse(raw.substring(i + 1)) ?? 0;
    final nowSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (tip.isEmpty || nowSecs - atSecs > _chainTtlSecs) return null;
    return tip;
  }

  Future<void> _setChainTip(String address, String pubkey, String tip) async {
    final nowSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _storage.write(
      key: _chainTipKey(address, pubkey),
      value: '$tip:$nowSecs',
    );
  }

  // ── read-time ordering (the self-hash chain) ─────────────────────────
  //
  // Intra-sender order is authoritative from the hash chain; `composedAt`
  // only interleaves the two directional streams and orders disjoint
  // segments after a reset/gap. All ordering data rides inside the content
  // seal — the relay network learns nothing of order, recipient, or shape.

  /// Reorder a cached thread in place into display order, recomputing the
  /// gap/resumption markers. Idempotent — a late-arriving message that
  /// fills a gap clears the marker on the next call.
  void _reorder(String address, String pubkey) {
    final key = '$address|$pubkey';
    final list = _threads[key];
    if (list == null || list.length < 2) return;
    final ordered = orderThread(list);
    list
      ..clear()
      ..addAll(ordered);
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

  // ── send / refresh (the RPC-facing surface) ─────────────────────

  /// Seal + sign + dispatch a message to [contactPubkey] through the
  /// **2-hop onion** (the locked drop transport). Appends the outbound
  /// message locally on success. Throws on RPC failure.
  ///
  /// Transport: `chat_send_onion_2hop` carries `Plain` content (no Double
  /// Ratchet) — the recipient reads it via `chat_read_content`'s Plain
  /// branch. The guard (pinned `nodeRpc`) peels and FORWARDS the inner
  /// packet to relay-2 (`relay2Rpc`), which delivers + stripes — so a
  /// single relay never sees sender AND recipient. The node rejects a
  /// 1-hop onion (guard must never be the final hop) and rejects an
  /// unauthenticated drop, so both relay-2 and the admission cert are
  /// required.
  ///
  /// Auth: cert-auth. The drop is signed with the device's admission cert
  /// (`certAuth` → thumbprint + cert seed); rust derives the
  /// `blake2_256(domain ‖ packet ‖ ts)` ECDSA signature the node verifies
  /// against the Active on-chain cert. Mint the cert first ([ensureCert]).
  ///
  /// The forward-secret upgrade (F2) swaps the `Plain` body for a
  /// `Ratcheted` one + threads the DR session here; the onion wrap and
  /// auth are unchanged. The session-key drop auth (auth ceremony) is the
  /// cheaper alternative to cert-auth, layered on next.
  Future<ChatMessage> send(String address, String contactPubkey, String text) async {
    final seed = await seedHex(address);
    final node = await nodeRpc();
    final relay2 = await relay2Rpc();
    if (relay2.isEmpty) {
      throw StateError(
          'no relay-2 configured — the 2-hop onion needs a second chat node '
          '(Settings → Relay-2 node)');
    }
    final auth = await certAuth(address);
    if (auth == null) {
      throw StateError(
          'no admission cert — mint your device cert first (Settings → Mint cert)');
    }
    final guard = await chatNodeInfo(nodeRpc: node); // pinned node = guard
    final relay2Pubkey = await chatNodeInfo(nodeRpc: relay2);

    // Chain this message to my previous one in this conversation. A null
    // tip (none yet, or stale past the TTL) starts a fresh chain — the
    // recipient renders that as the first message / a resumption.
    final prevTip = await _liveChainTip(address, contactPubkey);
    final composedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final outcome = await chatSendOnion2Hop(
      nodeRpc: node,
      guardPubkeyHex: guard,
      relay2PubkeyHex: relay2Pubkey,
      senderSeedHex: seed,
      recipientPubkeyHex: contactPubkey,
      recipientContentKeyHex: await _recipientContentKey(address, contactPubkey),
      message: text,
      senderName: await myName(address), // claimed inner name; empty ok for Plain
      totalShares: 5,
      authCertThumbprintHex: auth.thumbprint,
      authCertSeedHex: auth.certSeedHex,
      prevSelfHashHex: prevTip,
      composedAtSecs: BigInt.from(composedAt),
    );

    // Persist the new tip BEFORE appending locally: a crash after the send
    // but before this would otherwise re-chain the next message to the old
    // tip and orphan this one on the recipient.
    await _setChainTip(address, contactPubkey, outcome.newSelfHashHex);

    final msg = ChatMessage(
      id: outcome.messageIdHex,
      contactPubkey: contactPubkey,
      outbound: true,
      text: text,
      tsMillis: DateTime.now().millisecondsSinceEpoch,
      verified: true, // we authored it
      selfHash: outcome.newSelfHashHex,
      prevSelfHash: prevTip ?? '',
      composedAt: composedAt,
    );
    final list = await messages(address, contactPubkey);
    list.add(msg);
    _reorder(address, contactPubkey);
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
      // Still sealed → no chain data yet; ordering settles when the thread
      // is opened and batch-decrypted (readThread). Until then, arrival order.
      _reorder(address, contactPubkey);
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

    final (updated, verifiedName) = await _readOne(address, contactPubkey, m);
    list[idx] = updated;
    _reorder(address, contactPubkey);
    await _persistThread(address, contactPubkey);
    if (verifiedName.isNotEmpty) {
      await upsertContact(address, contactPubkey, name: verifiedName);
    }
    notifyListeners();
    return updated;
  }

  /// Batch-on-open: decrypt EVERY still-sealed inbound message in this
  /// conversation under one read pass (on hardware, one biometric→silicon
  /// gate), then order the thread by the now-available self-hash chain.
  /// This is what makes a freshly-opened thread render in send-order: the
  /// ordering metadata lives inside the seal, so it isn't known until the
  /// messages are decrypted. Returns the number newly decrypted.
  Future<int> readThread(String address, String contactPubkey) async {
    final list = await messages(address, contactPubkey);
    final sealed = list.where((m) => m.isSealed).toList();
    if (sealed.isEmpty) return 0;
    var decrypted = 0;
    var lastName = '';
    for (final m in sealed) {
      final idx = list.indexWhere((x) => x.id == m.id);
      if (idx < 0) continue;
      try {
        final (updated, verifiedName) = await _readOne(address, contactPubkey, m);
        list[idx] = updated;
        decrypted++;
        if (verifiedName.isNotEmpty) lastName = verifiedName;
      } catch (_) {
        // one undecryptable message (e.g. a gap predecessor we can't open)
        // must not abort the batch — leave it sealed, order around it.
      }
    }
    _reorder(address, contactPubkey);
    await _persistThread(address, contactPubkey);
    if (lastName.isNotEmpty) {
      await upsertContact(address, contactPubkey, name: lastName);
    }
    if (decrypted > 0) notifyListeners();
    return decrypted;
  }

  /// Decrypt + sender-verify a single sealed inbound message. Pure — no
  /// thread mutation / persist / notify (the callers batch those). Returns
  /// the decrypted message (carrying the self-hash chain fields) and the
  /// forward-resolve-verified sender name ('' if unverified).
  Future<(ChatMessage, String)> _readOne(
      String address, String contactPubkey, ChatMessage m) async {
    final hwCk = await _storage.read(key: _contentHwKey(address));
    final ReadMessage read;
    if (hwCk != null && hwCk.isNotEmpty) {
      // Hardware path: the content scalar lives in StrongBox. Hand the chip the
      // sender's ephemeral, get the shared secret back from an in-chip ECDH
      // (biometric-gated), and finish HKDF+AEAD in Rust. The scalar never
      // enters app memory.
      final ephemeral =
          await chatContentEphemeralOf(sealedContentHex: m.sealedContentHex);
      final shared = await _contentKeys.ecdhHex(ephemeral);
      if (shared == null || shared.isEmpty) {
        throw StateError('content ECDH failed (biometric declined or no chip key)');
      }
      read = await chatReadContentHw(
        sealedContentHex: m.sealedContentHex,
        recipientContentKeyHex: hwCk,
        sharedSecretHex: shared,
        drSessionStateHex: null, // F2: Ratcheted content threads the DR session here
        identitySeedHex: await seedHex(address),
        opkSecrets: const [],
      );
    } else {
      read = await chatReadContent(
        sealedContentHex: m.sealedContentHex,
        curve: _contentCurve,
        contentSeedHex: await contentSeedHex(address),
        drSessionStateHex: null, // F2: Ratcheted content threads the DR session here
        identitySeedHex: await seedHex(address),
        opkSecrets: const [],
      );
    }

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
      // the in-seal ordering chain, now decrypted:
      selfHash: read.selfHashHex,
      prevSelfHash: read.prevSelfHashHex,
      composedAt: read.composedAt.toInt(),
    );
    return (updated, verifiedName);
  }
}
