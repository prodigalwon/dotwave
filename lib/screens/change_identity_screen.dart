import 'package:flutter/material.dart';

import '../theme.dart';

/// STAGED placeholder for switching the active chat identity (e.g. between
/// multiple owned `.rst` names bound to this account). Reached from Message
/// Options → "Change Chat Identity". Wiring is TODO; this screen exists so the
/// hub button has a real, on-brand destination while the feature is built out.
class ChangeIdentityScreen extends StatelessWidget {
  final String address;
  final String name;
  const ChangeIdentityScreen(
      {super.key, required this.address, required this.name});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: const Text('Change Chat Identity')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.switch_account_outlined,
                  size: 48, color: AppTheme.accent),
              const SizedBox(height: 16),
              Text('Change Chat Identity',
                  style: tt.titleMedium?.copyWith(color: Colors.white)),
              const SizedBox(height: 8),
              Text(
                'Switch the active identity used for messaging. Coming soon.',
                textAlign: TextAlign.center,
                style: tt.bodySmall?.copyWith(color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
