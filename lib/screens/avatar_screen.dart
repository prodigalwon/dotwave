import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/avatar_service.dart';
import '../theme.dart';

/// View this account's chat icon and change it (pick → tiny WebP). Reached by
/// tapping the face icon on the home screen or the avatar on the profile tab.
class AvatarScreen extends StatefulWidget {
  final String address;
  const AvatarScreen({super.key, required this.address});

  @override
  State<AvatarScreen> createState() => _AvatarScreenState();
}

class _AvatarScreenState extends State<AvatarScreen> {
  final _svc = AvatarService.instance;
  Uint8List? _avatar;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final a = await _svc.ownAvatar(widget.address);
    if (mounted) setState(() => _avatar = a);
  }

  Future<void> _change() async {
    setState(() => _busy = true);
    try {
      final a = await _svc.pickAndSetOwn(widget.address);
      if (a != null && mounted) setState(() => _avatar = a);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not set icon: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: const Text('Your Icon')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: _busy ? null : _change,
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  Container(
                    width: 160,
                    height: 160,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.pink.withValues(alpha: 0.15),
                      border: Border.all(
                          color: AppTheme.pink.withValues(alpha: 0.4), width: 2),
                    ),
                    child: _avatar != null
                        ? Image.memory(_avatar!,
                            fit: BoxFit.cover, gaplessPlayback: true)
                        : const Icon(Icons.person, color: AppTheme.pink, size: 80),
                  ),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(
                        color: AppTheme.pink, shape: BoxShape.circle),
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.edit, color: Colors.white, size: 18),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text('Tap your icon to change it',
                style: tt.bodyMedium?.copyWith(color: Colors.white60)),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                'Your icon is shared with people you message — it rides inside '
                'the first encrypted message of a conversation. Dead drops never '
                'carry it.',
                textAlign: TextAlign.center,
                style: tt.bodySmall?.copyWith(color: Colors.white38),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
