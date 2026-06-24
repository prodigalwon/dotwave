import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'manage_name_screen.dart';
import 'name_registration_screen.dart';
import 'zkpki_spoof_defense_test_screen.dart';

class ProfileTab extends StatefulWidget {
  final String address;
  const ProfileTab({super.key, required this.address});

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  /// Cached canonical name (bare label, no ".rst"). The chain has no
  /// address→label reverse lookup, so this comes from the same secure-storage
  /// cache the home header uses.
  String? _ownedName;

  String get _address => widget.address;

  String get _truncatedAddress =>
      '${_address.substring(0, 8)}...${_address.substring(_address.length - 6)}';

  String get _storageKey => 'owned_name_$_address';

  @override
  void initState() {
    super.initState();
    _loadOwnedName();
  }

  Future<void> _loadOwnedName() async {
    const storage = FlutterSecureStorage();
    final stored = await storage.read(key: _storageKey);
    if (!mounted) return;
    setState(() => _ownedName = (stored != null && stored.isNotEmpty) ? stored : null);
  }

  /// Owned → manage it; otherwise → register one. Re-read the cache on return so
  /// a fresh registration / release / transfer is reflected here immediately.
  void _openNameScreen() {
    final name = _ownedName;
    final route = name != null
        ? MaterialPageRoute<void>(
            builder: (_) => ManageNameScreen(address: _address, name: name))
        : MaterialPageRoute<void>(
            builder: (_) => NameRegistrationScreen(address: _address));
    Navigator.push(context, route).then((_) => _loadOwnedName());
  }

  @override
  Widget build(BuildContext context) {
    final name = _ownedName;
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
                Text(
                  name != null ? '$name.rst' : 'No name registered',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: _address));
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
            label: name != null ? 'Manage Name' : 'Register a Name',
            subtitle: name != null ? '$name.rst' : 'Claim your .rst name',
            onTap: _openNameScreen,
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

          // Debug-only entry point for the cross-platform spoof defense
          // smoke test. kDebugMode is a Flutter-provided compile-time
          // constant that's `false` in release builds, so this tile is
          // tree-shaken out of anything the user actually installs.
          if (kDebugMode) ...[
            const SizedBox(height: 16),
            _SectionHeader(label: 'Debug'),
            _SettingsTile(
              icon: Icons.shield_outlined,
              label: 'Spoof Defense Test',
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ZkPkiSpoofDefenseTestScreen(),
                  ),
                );
              },
            ),
          ],

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