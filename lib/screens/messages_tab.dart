import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/bridge_generated.dart/chat.dart';
import '../services/chat_store.dart';
import '../theme.dart';
import '../widgets/chat_avatar.dart';
import '../widgets/transaction_blade.dart';
import 'chat_thread_screen.dart';
import 'message_options_screen.dart';
import 'name_registration_screen.dart';

class MessagesTab extends StatefulWidget {
  final String address;
  const MessagesTab({super.key, required this.address});

  @override
  State<MessagesTab> createState() => _MessagesTabState();
}

class _MessagesTabState extends State<MessagesTab> {
  final _store = ChatStore.instance;

  ChatIdentity? _identity;
  String? _contentKey; // this account's published content key (hex), for sharing
  List<ChatContact> _contacts = [];
  bool _loading = true;
  Timer? _poll;

  // Messaging-setup ceremony state — drives the top banner/button.
  ChatKeyState _keyState = ChatKeyState.noName;
  String _ownedName = '';

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStore);
    _bootstrap();
    _poll = Timer.periodic(const Duration(seconds: 6), (_) => _refresh());
  }

  @override
  void dispose() {
    _store.removeListener(_onStore);
    _poll?.cancel();
    super.dispose();
  }

  void _onStore() {
    if (mounted) _load();
  }

  Future<void> _bootstrap() async {
    final id = await _store.identity(widget.address);
    final ck = await _store.contentKey(widget.address);
    if (!mounted) return;
    setState(() {
      _identity = id;
      _contentKey = ck;
    });
    await _load();
    await _loadKeyState();
    if (mounted) setState(() => _loading = false);
    _refresh();
  }

  /// Poll where this account stands in the messaging-setup ceremony (no name /
  /// needs keys / ready) so the banner reflects reality. Also refreshes the
  /// displayed content key once keys are live.
  Future<void> _loadKeyState() async {
    final ks = await _store.keyState(widget.address);
    final ck = await _store.contentKey(widget.address);
    if (!mounted) return;
    setState(() {
      _keyState = ks.state;
      _ownedName = ks.name;
      _contentKey = ck;
    });
  }

  Future<void> _load() async {
    final contacts = await _store.contacts(widget.address);
    // Hydrate each thread so previews + ordering are available.
    for (final c in contacts) {
      await _store.messages(widget.address, c.pubkey);
    }
    contacts.sort((a, b) {
      final la = _store.lastMessage(widget.address, a.pubkey)?.tsMillis ?? 0;
      final lb = _store.lastMessage(widget.address, b.pubkey)?.tsMillis ?? 0;
      return lb.compareTo(la);
    });
    if (mounted) setState(() => _contacts = List.of(contacts));
  }

  Future<void> _refresh() async {
    try {
      await _store.refresh(widget.address);
    } catch (_) {
      // silent
    }
    // Keep watching the setup ceremony until it's ready (then stop re-polling
    // it — the records won't un-publish themselves).
    if (_keyState != ChatKeyState.ready) await _loadKeyState();
  }

  void _copy(String value, String label) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied')),
    );
  }

  void _openThread(ChatContact c) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen(address: widget.address, contact: c),
      ),
    );
  }

  /// Banner CTA dispatch by ceremony state:
  /// • noName    → register a `.rst` name first (the prerequisite)
  /// • needsKeys → mint + publish CHAT/MESSAGE in a paid blade
  /// • ready     → open Message Options (rotate keys)
  Future<void> _onBannerAction() async {
    switch (_keyState) {
      case ChatKeyState.noName:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => NameRegistrationScreen(address: widget.address),
          ),
        );
        await _loadKeyState(); // a name may have been registered
        break;
      case ChatKeyState.needsKeys:
        await _openRegisterKeys();
        break;
      case ChatKeyState.ready:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                MessageOptionsScreen(address: widget.address, name: _ownedName),
          ),
        );
        await _loadKeyState(); // keys may have been rotated
        break;
    }
  }

  /// The paid "Register Keys" action: mint a content keypair in secure silicon
  /// (public → MESSAGE) and publish the software chat address (→ CHAT) under
  /// the owned name. The mint happens inside [ChatStore.registerOrRotateKeys]
  /// when the user authorizes payment.
  Future<void> _openRegisterKeys() async {
    final rpc = await _store.nodeRpc();
    if (!mounted) return;
    TransactionBlade.show(
      context,
      TransactionBlade(
        transactionType: 'Register Chat Keys',
        rpcUrl: rpc,
        rows: [
          TxRow('Name', '$_ownedName.rst'),
          const TxRow('MESSAGE', 'silicon content key (StrongBox P-256)'),
          const TxRow('CHAT', 'software chat address (Ed25519)'),
        ],
        costLabel: 'Network Fee',
        onConfirm: (phrase) =>
            _store.registerOrRotateKeys(widget.address, _ownedName, phrase),
        onSuccess: () async {
          await _loadKeyState();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Chat keys registered')),
            );
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: const Text('Messages'),
        actions: [
          IconButton(
            tooltip: 'Relay node',
            icon: const Icon(Icons.dns_outlined),
            onPressed: _showNodeSheet,
          ),
          IconButton(
            tooltip: 'New message',
            icon: const Icon(Icons.edit_outlined, color: AppTheme.pink),
            onPressed: _showNewMessageSheet,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          color: AppTheme.pink,
          backgroundColor: AppTheme.surface2,
          onRefresh: _refresh,
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: AppTheme.pink, strokeWidth: 2))
              : ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    _KeyStateBanner(
                      state: _keyState,
                      onAction: _onBannerAction,
                    ),
                    if (_keyState != ChatKeyState.noName)
                      const SizedBox(height: 16),
                    _IdentityCard(
                      identity: _identity,
                      contentKey: _contentKey,
                      onCopy: () {
                        if (_identity != null) {
                          _copy(_identity!.ed25519PubkeyHex, 'Your chat address');
                        }
                      },
                      onCopyContentKey: () {
                        if (_contentKey != null) {
                          _copy(_contentKey!, 'Your content key');
                        }
                      },
                    ),
                    const SizedBox(height: 24),
                    if (_contacts.isEmpty)
                      _EmptyState(onStart: _showNewMessageSheet)
                    else ...[
                      Padding(
                        padding: const EdgeInsets.only(left: 4, bottom: 8),
                        child: Text('CONVERSATIONS', style: tt.labelMedium),
                      ),
                      ..._contacts.map((c) => _ConversationRow(
                            contact: c,
                            last: _store.lastMessage(widget.address, c.pubkey),
                            onTap: () => _openThread(c),
                          )),
                    ],
                  ],
                ),
        ),
      ),
    );
  }

  // ── new-message sheet ──────────────────────────────────────────────

  void _showNewMessageSheet() {
    final nameCtrl = TextEditingController();
    final pubkeyCtrl = TextEditingController();
    final contentKeyCtrl = TextEditingController();
    final labelCtrl = TextEditingController();
    String? error;
    bool resolving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: 20 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SheetGrabber(),
              Text('New conversation',
                  style: Theme.of(ctx).textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(
                "Start by .rst name (resolved on-chain), or paste the recipient's "
                "chat address + content key manually.",
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                style: Theme.of(ctx).textTheme.bodyMedium,
                decoration: InputDecoration(
                  labelText: 'Recipient .rst name',
                  hintText: 'e.g. ferdie',
                  errorText: error,
                  prefixIcon: const Icon(Icons.alternate_email, size: 18),
                ),
              ),
              const SizedBox(height: 16),
              Text('— or enter manually —', style: Theme.of(ctx).textTheme.labelSmall),
              const SizedBox(height: 8),
              TextField(
                controller: pubkeyCtrl,
                style: Theme.of(ctx).textTheme.bodyMedium,
                decoration: const InputDecoration(
                  labelText: 'Chat address (hex)',
                  hintText: '0x… / 64 hex chars',
                  prefixIcon: Icon(Icons.key_outlined, size: 18),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentKeyCtrl,
                style: Theme.of(ctx).textTheme.bodyMedium,
                decoration: const InputDecoration(
                  labelText: 'Content key (hex)',
                  hintText: "recipient's content key — required to send",
                  prefixIcon: Icon(Icons.vpn_key_outlined, size: 18),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: labelCtrl,
                style: Theme.of(ctx).textTheme.bodyMedium,
                decoration: const InputDecoration(
                  labelText: 'Name (optional)',
                  hintText: 'e.g. Alice',
                  prefixIcon: Icon(Icons.badge_outlined, size: 18),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: resolving
                    ? null
                    : () async {
                        final name = nameCtrl.text.trim().replaceFirst(RegExp(r'\.rst$'), '');
                        // Path 1: resolve by .rst name (hits the node).
                        if (name.isNotEmpty) {
                          setSheet(() {
                            resolving = true;
                            error = null;
                          });
                          try {
                            final contact =
                                await _store.resolveContactByName(widget.address, name);
                            if (ctx.mounted) Navigator.pop(ctx);
                            _openThread(contact);
                          } catch (e) {
                            setSheet(() {
                              resolving = false;
                              error = '$e'.replaceFirst('StateError: ', '');
                            });
                          }
                          return;
                        }
                        // Path 2: manual address + content key.
                        final raw = pubkeyCtrl.text.trim().replaceFirst(RegExp('^0x'), '');
                        if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(raw)) {
                          setSheet(() => error =
                              'Enter a .rst name above, or a 64-hex chat address.');
                          return;
                        }
                        final ck = contentKeyCtrl.text.trim().replaceFirst(RegExp('^0x'), '');
                        if (ck.isNotEmpty && !RegExp(r'^([0-9a-fA-F]{2})+$').hasMatch(ck)) {
                          setSheet(() => error = 'Content key must be hex (even length).');
                          return;
                        }
                        final label = labelCtrl.text.trim();
                        final contact = await _store.upsertContact(
                          widget.address, raw.toLowerCase(),
                          label: label.isEmpty ? null : label,
                          contentKeyHex: ck.isEmpty ? null : ck.toLowerCase(),
                        );
                        if (ctx.mounted) Navigator.pop(ctx);
                        _openThread(contact);
                      },
                child: Text(resolving ? 'Resolving…' : 'Start chat'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── node-settings sheet ────────────────────────────────────────────

  void _showNodeSheet() async {
    final current = await _store.nodeRpc();
    final currentRelay2 = await _store.relay2Rpc();
    if (!mounted) return;
    final ctrl = TextEditingController(text: current);
    final relay2Ctrl = TextEditingController(text: currentRelay2);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20, right: 20, top: 20,
          bottom: 20 + MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SheetGrabber(),
            Text('Relay nodes', style: Theme.of(ctx).textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(
              'The guard is the node this device sends through and pulls messages from. '
              'The 2-hop onion forwards through a second chat node (relay-2) so no single '
              'relay sees both you and the recipient. In the lab, point these at two '
              'different non-validator nodes on your network.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: ctrl,
              style: Theme.of(ctx).textTheme.bodyMedium,
              decoration: const InputDecoration(
                labelText: 'Guard RPC URL',
                hintText: 'ws://192.168.1.x:9944',
                prefixIcon: Icon(Icons.dns_outlined, size: 18),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: relay2Ctrl,
              style: Theme.of(ctx).textTheme.bodyMedium,
              decoration: const InputDecoration(
                labelText: 'Relay-2 RPC URL',
                hintText: 'ws://192.168.1.y:9945 (different node)',
                prefixIcon: Icon(Icons.alt_route_outlined, size: 18),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      await _store.setNodeRpc(null); // reset to default
                      await _store.setRelay2Rpc(null);
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Reset'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      await _store.setNodeRpc(ctrl.text);
                      await _store.setRelay2Rpc(relay2Ctrl.text);
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
            const Divider(height: 32),
            Text('Admission cert', style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Every onion drop is signed by an Active device cert. Mint one once '
              '(a chain extrinsic — needs a block-producing chain) before sending.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.verified_user_outlined, size: 18),
              label: const Text('Mint admission cert'),
              onPressed: () async {
                // Persist the guard URL first so the mint RPC targets it.
                await _store.setNodeRpc(ctrl.text);
                await _store.setRelay2Rpc(relay2Ctrl.text);
                if (!mounted) return;
                if (ctx.mounted) Navigator.pop(ctx);
                if (!mounted) return;
                TransactionBlade.show(
                  context,
                  TransactionBlade(
                    transactionType: 'Mint Admission Cert',
                    rpcUrl: ctrl.text,
                    rows: [
                      TxRow('Account',
                          '${widget.address.substring(0, 6)}…${widget.address.substring(widget.address.length - 4)}'),
                      const TxRow('Cert', 'dev admission (P-256)'),
                    ],
                    onConfirm: (phrase) => _store.ensureCert(widget.address, phrase),
                    onSuccess: () {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Admission cert minted')),
                        );
                      }
                    },
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── setup-ceremony banner ────────────────────────────────────────────

/// Top-of-screen CTA reflecting messaging-setup state: register a name, then
/// register keys, then (once live) message options. Tapping runs the action
/// for the current state.
class _KeyStateBanner extends StatelessWidget {
  final ChatKeyState state;
  final Future<void> Function() onAction;
  const _KeyStateBanner({required this.state, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final (IconData icon, String title, String subtitle, Color color, bool primary) =
        switch (state) {
      ChatKeyState.noName => (
        Icons.badge_outlined,
        'No Name Registered',
        'Register a .rst name to start messaging',
        Colors.orangeAccent,
        true,
      ),
      ChatKeyState.needsKeys => (
        Icons.vpn_key_outlined,
        'Register Keys',
        'Publish your CHAT + MESSAGE keys so others can reach you',
        AppTheme.pink,
        true,
      ),
      ChatKeyState.ready => (
        Icons.tune,
        'Message Options',
        'Manage or rotate your chat keys',
        Colors.white54,
        false,
      ),
    };
    return Material(
      color: primary ? color.withValues(alpha: 0.12) : AppTheme.surface2,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onAction,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: tt.titleSmall?.copyWith(
                            color: primary ? color : Colors.white,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: tt.bodySmall?.copyWith(color: Colors.white54)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white24, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// ── identity card ────────────────────────────────────────────────────

class _IdentityCard extends StatelessWidget {
  final ChatIdentity? identity;
  final String? contentKey;
  final VoidCallback onCopy;
  final VoidCallback onCopyContentKey;
  const _IdentityCard({
    required this.identity,
    required this.contentKey,
    required this.onCopy,
    required this.onCopyContentKey,
  });

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final pk = identity?.ed25519PubkeyHex ?? '';
    final short = pk.length <= 14 ? pk : '${pk.substring(0, 8)}…${pk.substring(pk.length - 6)}';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: AppTheme.subtleGradient,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.borderMid),
      ),
      child: Row(
        children: [
          ChatAvatar(seed: pk.isEmpty ? '?' : pk, size: 46),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('YOUR CHAT ADDRESS', style: tt.labelMedium),
                    const SizedBox(width: 6),
                    const Icon(Icons.lock, size: 11, color: AppTheme.success),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  identity == null ? '…' : short,
                  style: tt.titleMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 2),
                Text('Share your address + content key so others can message you',
                    style: tt.bodySmall),
              ],
            ),
          ),
          Column(
            children: [
              IconButton(
                onPressed: identity == null ? null : onCopy,
                tooltip: 'Copy chat address',
                icon: const Icon(Icons.copy_rounded, size: 18, color: AppTheme.pink),
              ),
              IconButton(
                onPressed: contentKey == null ? null : onCopyContentKey,
                tooltip: 'Copy content key',
                icon: const Icon(Icons.vpn_key_outlined, size: 18, color: AppTheme.pink),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── conversation row ─────────────────────────────────────────────────

class _ConversationRow extends StatelessWidget {
  final ChatContact contact;
  final ChatMessage? last;
  final VoidCallback onTap;
  const _ConversationRow({required this.contact, required this.last, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final preview = last == null
        ? 'Tap to start chatting'
        : '${last!.outbound ? 'You: ' : ''}${last!.text}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Row(
              children: [
                ChatAvatar(seed: contact.display, size: 48),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(contact.display,
                          style: tt.titleMedium,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(preview,
                          style: tt.bodySmall,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                if (last != null) ...[
                  const SizedBox(width: 8),
                  Text(_fmtRelative(last!.time), style: tt.labelSmall),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── empty state ──────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onStart;
  const _EmptyState({required this.onStart});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: Column(
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: const BoxDecoration(
              color: AppTheme.pinkGlow,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.shield_outlined, color: AppTheme.pink, size: 36),
          ),
          const SizedBox(height: 20),
          Text('Private messaging', style: tt.headlineSmall),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Your conversations are end-to-end encrypted and sharded across relays — no node ever sees who you’re talking to.',
              style: tt.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: 220,
            child: FilledButton.icon(
              onPressed: onStart,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('New message'),
            ),
          ),
        ],
      ),
    );
  }
}

// ── bits ─────────────────────────────────────────────────────────────

class _SheetGrabber extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: AppTheme.borderMid,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

String _fmtRelative(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  return '${t.month}/${t.day}';
}
