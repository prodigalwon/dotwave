import 'dart:async';

import 'package:flutter/material.dart';

import '../services/chat_store.dart';
import '../theme.dart';
import '../widgets/chat_avatar.dart';

/// One conversation: the message thread with [contact], plus the
/// compose bar. Polls the relay for new shares while open.
class ChatThreadScreen extends StatefulWidget {
  final String address; // this device's wallet address (identity scope)
  final ChatContact contact;

  const ChatThreadScreen({
    super.key,
    required this.address,
    required this.contact,
  });

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  final _store = ChatStore.instance;

  List<ChatMessage> _messages = [];
  bool _sending = false;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStore);
    _open();
    // Pull new mail every few seconds while the thread is open.
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
  }

  /// Open the thread: render what we have, then batch-decrypt the sealed
  /// messages (one read pass) so the self-hash chain is available and the
  /// thread settles into send-order. On hardware this is the single
  /// biometric→silicon gate for the conversation.
  Future<void> _open() async {
    await _load(scrollToEnd: false);
    try {
      await _store.readThread(widget.address, widget.contact.pubkey);
    } catch (_) {
      // a partial/failed decrypt still renders what opened; don't nag.
    }
    if (mounted) _load(scrollToEnd: true);
  }

  @override
  void dispose() {
    _store.removeListener(_onStore);
    _poll?.cancel();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onStore() {
    if (mounted) _load(scrollToEnd: true);
  }

  Future<void> _load({bool scrollToEnd = true}) async {
    final msgs = await _store.messages(widget.address, widget.contact.pubkey);
    if (!mounted) return;
    setState(() => _messages = List.of(msgs));
    if (scrollToEnd) _jumpToEnd();
  }

  Future<void> _refresh() async {
    try {
      await _store.refresh(widget.address);
    } catch (_) {
      // silent — transient relay/network blips shouldn't nag mid-thread
    }
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await _store.send(widget.address, widget.contact.pubkey, text);
      _composer.clear();
    } catch (e) {
      setState(() => _error = _friendlyError(e.toString()));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _friendlyError(String raw) {
    if (raw.contains('connecting to') || raw.contains('Connect')) {
      return "Couldn't reach the relay node. Check the node address in settings.";
    }
    return 'Send failed. Tap to retry.';
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            ChatAvatar(seed: widget.contact.pubkey, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    widget.contact.display,
                    style: tt.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      const Icon(Icons.lock, size: 11, color: AppTheme.success),
                      const SizedBox(width: 4),
                      Text('End-to-end encrypted', style: tt.labelSmall),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          const _SecurityBanner(),
          Expanded(
            child: _messages.isEmpty
                ? _ThreadEmptyState(name: widget.contact.display)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) {
                      final m = _messages[i];
                      final prev = i > 0 ? _messages[i - 1] : null;
                      final showTime = prev == null ||
                          m.outbound != prev.outbound ||
                          (m.tsMillis - prev.tsMillis) > 5 * 60 * 1000;
                      final bubble = _Bubble(message: m, showTime: showTime);
                      // A break in the sender's self-hash chain: a message
                      // didn't arrive (gap) or the sender restarted their
                      // chain (resumption). Surfaced honestly, never hidden.
                      if (m.gapBefore) {
                        return Column(children: [
                          const _ChainDivider(
                            icon: Icons.link_off,
                            label: 'A message here didn’t arrive',
                          ),
                          bubble,
                        ]);
                      }
                      if (m.resumption) {
                        return Column(children: [
                          const _ChainDivider(
                            icon: Icons.history,
                            label: 'Conversation resumed',
                          ),
                          bubble,
                        ]);
                      }
                      return bubble;
                    },
                  ),
          ),
          if (_error != null)
            GestureDetector(
              onTap: _send,
              child: Container(
                width: double.infinity,
                color: AppTheme.error.withValues(alpha: 0.12),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, size: 16, color: AppTheme.error),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!, style: tt.bodySmall?.copyWith(color: AppTheme.error))),
                  ],
                ),
              ),
            ),
          _Composer(
            controller: _composer,
            sending: _sending,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

// ── security banner ──────────────────────────────────────────────────

class _SecurityBanner extends StatelessWidget {
  const _SecurityBanner();

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      color: AppTheme.surface1,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.shield_outlined, size: 13, color: AppTheme.textTertiary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Sealed & sharded across relays — no node sees the whole message',
              style: tt.labelSmall,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

// ── chain-break divider (gap / resumption) ──────────────────────────
//
// Honesty is a safety feature: where ordering is uncertain — a message
// that never arrived, or a sender who restarted their chain — the thread
// says so rather than silently closing the seam.

class _ChainDivider extends StatelessWidget {
  final IconData icon;
  final String label;

  const _ChainDivider({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const Expanded(child: Divider(color: AppTheme.surface2, height: 1)),
          const SizedBox(width: 8),
          Icon(icon, size: 13, color: AppTheme.textTertiary),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              style: tt.labelSmall?.copyWith(color: AppTheme.textTertiary),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(child: Divider(color: AppTheme.surface2, height: 1)),
        ],
      ),
    );
  }
}

// ── message bubble ───────────────────────────────────────────────────

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final bool showTime;

  const _Bubble({required this.message, required this.showTime});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final out = message.outbound;
    final radius = Radius.circular(18);
    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.74,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        gradient: out ? AppTheme.cardGradient : null,
        color: out ? null : AppTheme.surface2,
        border: out ? null : Border.all(color: AppTheme.borderSubtle),
        borderRadius: BorderRadius.only(
          topLeft: radius,
          topRight: radius,
          bottomLeft: out ? radius : const Radius.circular(4),
          bottomRight: out ? const Radius.circular(4) : radius,
        ),
      ),
      child: Text(
        message.text,
        style: tt.bodyMedium?.copyWith(
          color: Colors.white,
          height: 1.3,
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(top: showTime ? 10 : 3, bottom: 1),
      child: Column(
        crossAxisAlignment: out ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          bubble,
          if (showTime)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!out && message.verified) ...[
                    const Icon(Icons.verified_user, size: 10, color: AppTheme.success),
                    const SizedBox(width: 4),
                  ],
                  Text(_fmtTime(message.time), style: tt.labelSmall),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── composer ─────────────────────────────────────────────────────────

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.bg,
        border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
      ),
      padding: EdgeInsets.fromLTRB(
        12, 10, 12, 10 + MediaQuery.of(context).viewPadding.bottom,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.surface2,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: AppTheme.borderSubtle),
              ),
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                style: Theme.of(context).textTheme.bodyMedium,
                decoration: const InputDecoration(
                  hintText: 'Message',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                ),
                onSubmitted: (_) => onSend(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: sending ? null : onSend,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: AppTheme.cardGradient,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.pink.withValues(alpha: 0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: sending
                  ? const Padding(
                      padding: EdgeInsets.all(13),
                      child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 22),
            ),
          ),
        ],
      ),
    );
  }
}

// ── empty state ──────────────────────────────────────────────────────

class _ThreadEmptyState extends StatelessWidget {
  final String name;
  const _ThreadEmptyState({required this.name});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppTheme.pinkGlow,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.lock_outline, color: AppTheme.pink, size: 30),
            ),
            const SizedBox(height: 18),
            Text('Say hi to $name', style: tt.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Messages are encrypted on your device and sealed so the relays never see who they’re for.',
              style: tt.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

String _fmtTime(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  final ap = t.hour < 12 ? 'AM' : 'PM';
  return '$h:$m $ap';
}
