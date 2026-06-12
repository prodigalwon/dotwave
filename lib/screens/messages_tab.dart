import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/bridge_generated.dart/chat.dart';
import '../services/chat_store.dart';
import '../theme.dart';
import '../widgets/chat_avatar.dart';
import 'chat_thread_screen.dart';

class MessagesTab extends StatefulWidget {
  final String address;
  const MessagesTab({super.key, required this.address});

  @override
  State<MessagesTab> createState() => _MessagesTabState();
}

class _MessagesTabState extends State<MessagesTab> {
  final _store = ChatStore.instance;

  ChatIdentity? _identity;
  List<ChatContact> _contacts = [];
  bool _loading = true;
  Timer? _poll;

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
    if (!mounted) return;
    setState(() => _identity = id);
    await _load();
    if (mounted) setState(() => _loading = false);
    _refresh();
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
                    _IdentityCard(
                      identity: _identity,
                      onCopy: () {
                        if (_identity != null) {
                          _copy(_identity!.ed25519PubkeyHex, 'Your chat address');
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
    final pubkeyCtrl = TextEditingController();
    final labelCtrl = TextEditingController();
    String? error;

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
                "Paste the recipient's chat address (their 64-character public key).",
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: pubkeyCtrl,
                autofocus: true,
                style: Theme.of(ctx).textTheme.bodyMedium,
                decoration: InputDecoration(
                  labelText: 'Chat address (hex)',
                  hintText: '0x… / 64 hex chars',
                  errorText: error,
                  prefixIcon: const Icon(Icons.key_outlined, size: 18),
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
                onPressed: () async {
                  final raw = pubkeyCtrl.text.trim().replaceFirst(RegExp('^0x'), '');
                  if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(raw)) {
                    setSheet(() => error = 'Must be 64 hexadecimal characters.');
                    return;
                  }
                  final label = labelCtrl.text.trim();
                  final contact = await _store.upsertContact(
                    widget.address, raw.toLowerCase(),
                    label: label.isEmpty ? null : label,
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                  _openThread(contact);
                },
                child: const Text('Start chat'),
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
    if (!mounted) return;
    final ctrl = TextEditingController(text: current);

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
            Text('Relay node', style: Theme.of(ctx).textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(
              'The gemini-node this device sends through and pulls messages from. In the lab, point it at a node laptop on your network.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: ctrl,
              style: Theme.of(ctx).textTheme.bodyMedium,
              decoration: const InputDecoration(
                labelText: 'Node RPC URL',
                hintText: 'ws://192.168.1.x:9944',
                prefixIcon: Icon(Icons.dns_outlined, size: 18),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      await _store.setNodeRpc(null); // reset to default
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
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── identity card ────────────────────────────────────────────────────

class _IdentityCard extends StatelessWidget {
  final ChatIdentity? identity;
  final VoidCallback onCopy;
  const _IdentityCard({required this.identity, required this.onCopy});

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
                Text('Share this so others can message you', style: tt.bodySmall),
              ],
            ),
          ),
          IconButton(
            onPressed: identity == null ? null : onCopy,
            icon: const Icon(Icons.copy_rounded, size: 18, color: AppTheme.pink),
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
