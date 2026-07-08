import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/avatar_service.dart';
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

  List<ChatContact> _contacts = [];
  final Map<String, Uint8List?> _contactAvatars = {}; // pubkey → icon (if any)
  bool _loading = true;
  Timer? _poll;

  // Section collapse state — the caret next to each section header toggles it.
  bool _conversationsExpanded = true;
  bool _deadDropsExpanded = true;

  // STUB: dead-drop inbox gate. The dead-drop receive UX doesn't exist yet, so
  // this stays false and the Dead Drops section is hidden. When a dead drop is
  // received this flips true and [_deadDrops] holds the threads to render.
  final bool _hasDeadDrops = false;
  final List<_DeadDropThread> _deadDrops = const [];

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
    await _load();
    await _loadKeyState();
    if (mounted) setState(() => _loading = false);
    _refresh();
  }

  /// Poll where this account stands in the messaging-setup ceremony (no name /
  /// needs keys / ready) so the banner reflects reality.
  Future<void> _loadKeyState() async {
    final ks = await _store.keyState(widget.address);
    if (!mounted) return;
    setState(() {
      _keyState = ks.state;
      _ownedName = ks.name;
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
    // Load any contact icons (received on a first message) for the list rows.
    for (final c in contacts) {
      _contactAvatars[c.pubkey] =
          await AvatarService.instance.contactAvatar(c.pubkey);
    }
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
  /// the owned name. Streams progress via [ChatStore.registerKeysStream] so the
  /// blade shrinks into the corner badge and tracks in the background.
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
        trackerLabel: 'Register chat keys',
        streamedSubmit: (phrase) =>
            _store.registerKeysStream(widget.address, _ownedName, phrase),
        onSuccess: () async {
          await _store.onKeysConfirmed(widget.address, _ownedName);
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
        ],
      ),
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            RefreshIndicator(
              color: AppTheme.accent,
              backgroundColor: AppTheme.surface2,
              onRefresh: _refresh,
              child: _loading
                  ? Center(
                      child: CircularProgressIndicator(color: AppTheme.accent, strokeWidth: 2))
                  : ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    _KeyStateBanner(
                      state: _keyState,
                      onAction: _onBannerAction,
                    ),
                    const SizedBox(height: 20),
                    if (_contacts.isEmpty && !_hasDeadDrops)
                      _EmptyState(onStart: _showNewMessageSheet)
                    else ...[
                      if (_contacts.isNotEmpty) ...[
                        _SectionHeader(
                          label: 'Conversations',
                          count: _contacts.length,
                          expanded: _conversationsExpanded,
                          onTap: () => setState(() =>
                              _conversationsExpanded = !_conversationsExpanded),
                        ),
                        if (_conversationsExpanded)
                          ..._contacts.map((c) => _ConversationRow(
                                contact: c,
                                last: _store.lastMessage(widget.address, c.pubkey),
                                avatar: _contactAvatars[c.pubkey],
                                onTap: () => _openThread(c),
                              )),
                      ],
                      // Dead Drops — hidden until a drop has been received.
                      if (_hasDeadDrops) ...[
                        const SizedBox(height: 12),
                        _SectionHeader(
                          label: 'Dead Drops',
                          count: _deadDrops.length,
                          expanded: _deadDropsExpanded,
                          onTap: () => setState(() =>
                              _deadDropsExpanded = !_deadDropsExpanded),
                        ),
                        if (_deadDropsExpanded)
                          ..._deadDrops.map((d) => _DeadDropRow(thread: d)),
                      ],
                    ],
                  ],
                ),
            ),
            // New-message pencil — pinned to the bottom of the body (just above
            // HomeShell's nav bar) with a small standard margin, and pulled 20%
            // in from the right edge toward centre via fractional Alignment. No
            // pixel positioning → uniform across screen sizes.
            Align(
              alignment: const Alignment(0.8, 1.0),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: FloatingActionButton.large(
                  heroTag: 'newMessageFab',
                  tooltip: 'New message',
                  backgroundColor: AppTheme.accent,
                  foregroundColor: Colors.white,
                  shape: const CircleBorder(),
                  onPressed: _showNewMessageSheet,
                  child: const Icon(Icons.edit_outlined, size: 34),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── new-message sheet ──────────────────────────────────────────────

  void _showNewMessageSheet() {
    final nameCtrl = TextEditingController();
    final pubkeyCtrl = TextEditingController();
    final contentKeyCtrl = TextEditingController();
    final sealRecordCtrl = TextEditingController();
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
                controller: sealRecordCtrl,
                style: Theme.of(ctx).textTheme.bodyMedium,
                decoration: const InputDecoration(
                  labelText: 'Seal record (hex)',
                  hintText: "recipient's seal record — required to send",
                  prefixIcon: Icon(Icons.enhanced_encryption_outlined, size: 18),
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
                        final sr = sealRecordCtrl.text.trim().replaceFirst(RegExp('^0x'), '');
                        if (sr.isNotEmpty && !RegExp(r'^[0-9a-fA-F]{2496}$').hasMatch(sr)) {
                          setSheet(() => error =
                              'Seal record must be 2496 hex chars (1248 bytes: ek + signature).');
                          return;
                        }
                        final label = labelCtrl.text.trim();
                        final contact = await _store.upsertContact(
                          widget.address, raw.toLowerCase(),
                          label: label.isEmpty ? null : label,
                          contentKeyHex: ck.isEmpty ? null : ck.toLowerCase(),
                          sealRecordHex: sr.isEmpty ? null : sr.toLowerCase(),
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
                    trackerLabel: 'Mint admission cert',
                    streamedSubmit: (phrase) =>
                        _store.mintCertStream(widget.address, phrase),
                    onSuccess: () async {
                      await _store.onCertConfirmed(widget.address);
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
        AppTheme.accent,
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

// ── collapsible section header ───────────────────────────────────────

/// Tappable section label with a caret toggle and a count badge. Drives the
/// collapse state of the Conversations / Dead Drops lists below it.
class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final bool expanded;
  final VoidCallback onTap;
  const _SectionHeader({
    required this.label,
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              Text(label.toUpperCase(), style: tt.labelMedium),
              const SizedBox(width: 4),
              Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 18,
                color: Colors.white54,
              ),
              const SizedBox(width: 6),
              if (count > 0)
                Text('$count', style: tt.labelSmall?.copyWith(color: Colors.white38)),
            ],
          ),
        ),
      ),
    );
  }
}

// ── dead-drop stub ───────────────────────────────────────────────────

/// STUB model for a received dead-drop thread. The receive UX doesn't exist
/// yet; this is the shape the Dead Drops section will render once it lands.
class _DeadDropThread {
  final String label;
  final String preview;
  const _DeadDropThread({required this.label, required this.preview});
}

class _DeadDropRow extends StatelessWidget {
  final _DeadDropThread thread;
  const _DeadDropRow({required this.thread});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {}, // STUB: no dead-drop thread screen yet
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Row(
              children: [
                ChatAvatar(seed: thread.label, size: 48),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(thread.label,
                          style: tt.titleMedium,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(thread.preview,
                          style: tt.bodySmall,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                const Icon(Icons.markunread_mailbox_outlined,
                    size: 16, color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── conversation row ─────────────────────────────────────────────────

class _ConversationRow extends StatelessWidget {
  final ChatContact contact;
  final ChatMessage? last;
  final Uint8List? avatar; // contact's icon (from their first message), if any
  final VoidCallback onTap;
  const _ConversationRow(
      {required this.contact, required this.last, this.avatar, required this.onTap});

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
                ChatAvatar(seed: contact.display, size: 48, image: avatar),
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
            decoration: BoxDecoration(
              color: AppTheme.accentGlow,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.shield_outlined, color: AppTheme.accent, size: 36),
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
