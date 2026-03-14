import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'cloud_backup.dart';
import 'providers/google_drive_provider.dart';
import 'providers/onedrive_provider.dart';
import 'providers/webdav_provider.dart';
import 'providers/local_backup_provider.dart';

class BackupProviderScreen extends StatefulWidget {
  final Uint8List encryptedBlob;
  final String address;
  final VoidCallback onComplete;

  const BackupProviderScreen({
    super.key,
    required this.encryptedBlob,
    required this.address,
    required this.onComplete,
  });

  @override
  State<BackupProviderScreen> createState() => _BackupProviderScreenState();
}

class _BackupProviderScreenState extends State<BackupProviderScreen> {
  bool _loading = false;

  Future<void> _backup(CloudBackupProvider provider) async {
    setState(() => _loading = true);
    try {
      final signedIn = await provider.signIn();
      if (!signedIn) throw Exception('Sign in failed or cancelled');
      await provider.upload(kBackupFilename, widget.encryptedBlob);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Backup saved to ${provider.name}')),
      );
      widget.onComplete();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Backup failed: $e')),
      );
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _localBackupWithWarning() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Advanced Option'),
        content: const Text(
          'This will save your encrypted backup file to your device. '
          'Do not leave this file on your phone — copy it immediately to '
          'your chosen storage location. If you lose this file, you lose '
          'access to your account. There is no recovery option.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('I understand, continue'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _backup(LocalBackupProvider());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Back Up Your Account')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Choose where to store your backup',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Your backup is encrypted. Only you can decrypt it with your recovery passphrase.',
                      style: TextStyle(color: Colors.white60),
                    ),
                    const SizedBox(height: 32),
                    _ProviderTile(
                      name: 'Google Drive',
                      subtitle: 'Recommended for most users',
                      icon: Icons.add_to_drive,
                      onTap: () => _backup(GoogleDriveProvider()),
                    ),
                    const SizedBox(height: 12),
                    _ProviderTile(
                      name: 'OneDrive',
                      subtitle: 'Microsoft accounts',
                      icon: Icons.cloud,
                      onTap: () => _backup(OneDriveProvider()),
                    ),
                    const SizedBox(height: 12),
                    _ProviderTile(
                      name: 'WebDAV',
                      subtitle: 'Proton Drive, Nextcloud, iCloud and more',
                      icon: Icons.storage,
                      onTap: () => _showWebDavDialog(),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _localBackupWithWarning,
                      child: const Text(
                        'Advanced: save to device',
                        style: TextStyle(color: Colors.white38),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  void _showWebDavDialog() {
    final urlController = TextEditingController();
    final userController = TextEditingController();
    final passController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('WebDAV Connection'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Works with Proton Drive, Nextcloud, iCloud and any WebDAV provider.',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'https://your-server.com/dav',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: userController,
              decoration: const InputDecoration(
                labelText: 'Username',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password / App password',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _backup(WebDavProvider(
                serverUrl: urlController.text,
                username: userController.text,
                password: passController.text,
              ));
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }
}

class _ProviderTile extends StatelessWidget {
  final String name;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  const _ProviderTile({
    required this.name,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: const Color(0xFFE6007A)),
        title: Text(name),
        subtitle: Text(subtitle, style: const TextStyle(color: Colors.white60)),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
