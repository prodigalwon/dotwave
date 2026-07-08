import 'package:flutter/material.dart';

import '../theme.dart';
import 'change_identity_screen.dart';
import 'chat_keys_screen.dart';
import 'dead_drops_screen.dart';

/// Shown when messaging is fully set up (name owned + CHAT/MESSAGE live). A hub
/// routing to the two messaging-settings areas: **Chat Keys** (identity + key
/// material + rotate) and **Dead Drops** (callsign-addressed messaging).
/// Reached from the messages screen's "Message Options" button.
class MessageOptionsScreen extends StatelessWidget {
  final String address;
  final String name;
  const MessageOptionsScreen({super.key, required this.address, required this.name});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: const Text('Message Options')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Text('CHAT KEYS', style: tt.labelMedium),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.vpn_key_outlined, size: 18),
            label: const Text('Chat Keys'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ChatKeysScreen(address: address, name: name),
              ),
            ),
          ),
          const SizedBox(height: 28),
          Text('DEAD DROPS', style: tt.labelMedium),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.markunread_mailbox_outlined, size: 18),
            label: const Text('Dead Drops'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DeadDropsScreen(address: address),
              ),
            ),
          ),
          const SizedBox(height: 28),
          Text('CHAT IDENTITY', style: tt.labelMedium),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.switch_account_outlined, size: 18),
            label: const Text('Change Chat Identity'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    ChangeIdentityScreen(address: address, name: name),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
