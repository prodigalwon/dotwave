import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ProfileTab extends StatelessWidget {
  final String address;
  const ProfileTab({super.key, required this.address});

  String get _truncatedAddress =>
      '${address.substring(0, 8)}...${address.substring(address.length - 6)}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        title: const Text('Profile'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Column(
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFE6007A).withOpacity(0.15),
                    border: Border.all(
                      color: const Color(0xFFE6007A).withOpacity(0.4),
                      width: 2,
                    ),
                  ),
                  child: const Icon(
                    Icons.person,
                    color: Color(0xFFE6007A),
                    size: 40,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'No name registered',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: address));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Address copied')),
                    );
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _truncatedAddress,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.copy,
                        size: 14,
                        color: Colors.white38,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          _SectionHeader(label: 'Identity'),
          _SettingsTile(
            icon: Icons.badge_outlined,
            label: 'Register a Name',
            subtitle: 'Claim your .dot name',
            onTap: () {},
          ),

          const SizedBox(height: 16),
          _SectionHeader(label: 'Security'),
          _SettingsTile(
            icon: Icons.cloud_upload_outlined,
            label: 'Backup Account',
            subtitle: 'Update your encrypted backup',
            onTap: () {},
          ),
          _SettingsTile(
            icon: Icons.key_outlined,
            label: 'Show Recovery Phrase',
            subtitle: 'View your seed phrase',
            onTap: () {},
            destructive: true,
          ),

          const SizedBox(height: 16),
          _SectionHeader(label: 'App'),
          _SettingsTile(
            icon: Icons.notifications_outlined,
            label: 'Notifications',
            onTap: () {},
          ),
          _SettingsTile(
            icon: Icons.info_outline,
            label: 'About Dotwave',
            onTap: () {},
          ),

          const SizedBox(height: 16),
          _SettingsTile(
            icon: Icons.logout,
            label: 'Sign Out',
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Sign Out'),
                  content: const Text(
                    'Make sure your backup is up to date before signing out.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Sign Out'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                const storage = FlutterSecureStorage();
                await storage.deleteAll();
                if (!context.mounted) return;
                Navigator.of(context).pushNamedAndRemoveUntil('/', (_) => false);
              }
            },
            destructive: true,
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  final bool destructive;

  const _SettingsTile({
    required this.icon,
    required this.label,
    this.subtitle,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? Colors.red : Colors.white;
    final iconColor = destructive ? Colors.red : const Color(0xFFE6007A);

    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Icon(icon, color: iconColor, size: 22),
        title: Text(label, style: TextStyle(color: color, fontSize: 15)),
        subtitle: subtitle != null
            ? Text(
                subtitle!,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              )
            : null,
        trailing: const Icon(Icons.chevron_right, color: Colors.white24, size: 18),
        onTap: onTap,
      ),
    );
  }
}