import 'package:flutter/material.dart';

import '../services/chat_store.dart';
import '../theme.dart';
import 'callsigns_screen.dart';

/// Dead-drop hub. Explains the feature and routes to the two halves: composing
/// a drop (sending) and managing callsigns (receiving). Reached from Message
/// Options. See docs/DOTWAVE-CHAT-DEAD-DROPS.md.
class DeadDropsScreen extends StatelessWidget {
  final String address;
  const DeadDropsScreen({super.key, required this.address});

  /// Compose + send a dead drop to a recipient's callsign (sealed to their
  /// out-of-band keys). The sender is this canonically-named account.
  Future<void> _compose(BuildContext context) async {
    final csCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final msgCtrl = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface2,
        title: const Text('Send a dead drop'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: csCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Callsign',
                      helperText: 'the label they poll')),
              TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Recipient name',
                      hintText: 'e.g. ferdie',
                      suffixText: '.rst')),
              TextField(
                  controller: msgCtrl,
                  decoration: const InputDecoration(labelText: 'Message')),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Send')),
        ],
      ),
    );
    if (go != true) return;
    final cs = csCtrl.text.trim();
    final name = nameCtrl.text.trim().replaceFirst(RegExp(r'\.rst$'), '');
    try {
      await ChatStore.instance.sendDeaddrop(address, cs, name, msgCtrl.text);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Dead drop sent to '$cs' (→ $name.rst)")),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Send failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: const Text('Dead Drops')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Text(
            'Receive messages addressed to a callsign instead of your '
            'identity. A callsign is shared offline; the conversation then '
            'walks rotating, unlinkable return addresses, so nothing on the '
            'wire ties the messages to you.',
            style: tt.bodySmall,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.pink),
            icon: const Icon(Icons.send, size: 18),
            label: const Text('Send drop'),
            onPressed: () => _compose(context),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.vpn_key_outlined, size: 18),
            label: const Text('Callsigns'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CallsignsScreen(address: address),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
