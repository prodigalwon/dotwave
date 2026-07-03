import 'package:flutter/material.dart';

import '../theme.dart';
import 'my_certs_screen.dart';

/// ZK-PKI hub (Explore → ZK-PKI). Entry point for certificate management;
/// future onboarding surfaces (request a cert, pending offers) land here too.
class ZkPkiScreen extends StatelessWidget {
  final String address;
  const ZkPkiScreen({super.key, required this.address});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        title: const Text('ZK-PKI'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surface1,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.borderSubtle),
            ),
            child: const Text(
              'Certificates bind this account to your device’s secure '
              'hardware. An issuer offers you a cert; accepting it mints the '
              'cert on-chain, where services like messaging can verify it '
              'without learning who you are.',
              style: TextStyle(
                  color: AppTheme.textSecondary, fontSize: 13, height: 1.45),
            ),
          ),
          const SizedBox(height: 24),
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              'CERTIFICATES',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _HubTile(
            icon: Icons.badge_outlined,
            title: 'My Certs',
            subtitle: 'Certificates issued to this account',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => MyCertsScreen(address: address),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HubTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _HubTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface1,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.borderSubtle),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppTheme.accentGlow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: AppTheme.accent, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: const TextStyle(
                            color: AppTheme.textTertiary, fontSize: 12)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right,
                  color: AppTheme.textTertiary, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
