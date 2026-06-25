import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme.dart';

/// A circular avatar. When [image] is set it shows that picture (the user's or
/// a contact's tiny WebP icon); otherwise it falls back to the first glyph of
/// the identity ([seed]) on a brand gradient — the long-standing default.
/// Shared by the conversation list and the open thread so identity reads
/// consistently across the app.
class ChatAvatar extends StatelessWidget {
  final String seed; // pubkey hex or display label
  final double size;
  final Uint8List? image; // optional avatar bytes (WebP); null → letter
  const ChatAvatar({super.key, required this.seed, this.size = 44, this.image});

  @override
  Widget build(BuildContext context) {
    if (image != null) {
      return ClipOval(
        child: Image.memory(
          image!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }
    final glyph = seed.isNotEmpty ? seed.substring(0, 1).toUpperCase() : '?';
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        gradient: AppTheme.cardGradient,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        glyph,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.42,
        ),
      ),
    );
  }
}
