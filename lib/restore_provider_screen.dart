import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'cloud_backup.dart';
import 'providers/google_drive_provider.dart';
import 'providers/onedrive_provider.dart';
import 'providers/webdav_provider.dart';
import 'providers/local_backup_provider.dart';

class RestoreProviderScreen extends StatefulWidget {
  final Function(Uint8List blob) onBlobDownloaded;

  const RestoreProviderScreen({super.key, required this.onBlobDownloaded});

  @override
  State<RestoreProviderScreen> createState() => _RestoreProviderScreenState();
}

class _RestoreProviderScreenState extends State<RestoreProviderScreen> {
  bool _loading = false;

  Future<void> _restore(CloudBackupProvider provider) async {
    setState(() => _loading = true);
    try {
      final signedIn = await provider.signIn();
      if (!signedIn) throw Exception('Sign in failed or cancelled');
      final blob = await provider.download(kBackupFilename);
      if (blob == null) throw Exception('No backup found in ${provider.name}');
      widget.onBlobDownloaded(blob);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Restore failed: $e')),
      );
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Restore Account')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Where is your backup?',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Select where you stored your encrypted backup file.',
                      style: TextStyle(color: Colors.white60),
                    ),
                    const SizedBox(height: 32),
                    _ProviderTile(
                      name: 'Google Drive',
                      subtitle: 'Restore from Google Drive',
                      icon: Icons.add_to_drive,
                      onTap: () => _restore(GoogleDriveProvider()),
                    ),
                    const SizedBox(height: 12),
                    _ProviderTile(
                      name: 'OneDrive',
                      subtitle: 'Restore from OneDrive',
                      icon: Icons.cloud,
                      onTap: () => _restore(OneDriveProvider()),
                    ),
                    const SizedBox(height: 12),
                    _ProviderTile(
                      name: 'WebDAV',
                      subtitle: 'Proton Drive, Nextcloud, iCloud and more',
                      icon: Icons.storage,
                      onTap: () => _showWebDavDialog(),
                    ),
                    const SizedBox(height: 12),
                    _ProviderTile(
                      name: 'From Device',
                      subtitle: 'Pick a backup file from your device',
                      icon: Icons.folder_open,
                      onTap: () => _restore(LocalBackupProvider()),
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
              _restore(WebDavProvider(
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
