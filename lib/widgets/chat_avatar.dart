import 'package:flutter/material.dart';

import '../theme.dart';

/// A circular brand-gradient avatar carrying the first glyph of an
/// identity (pubkey hex or label). Shared by the conversation list and
/// the open thread so identity reads consistently across the app.
class ChatAvatar extends StatelessWidget {
  final String seed; // pubkey hex or display label
  final double size;
  const ChatAvatar({super.key, required this.seed, this.size = 44});

  @override
  Widget build(BuildContext context) {
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
