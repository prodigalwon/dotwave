import 'package:flutter/material.dart';

import '../theme.dart';

/// Branded confirmation dialog: the Rostro lockup (mark + wordmark) over a
/// question, Cancel / confirm actions. First use: the cert-release flow; any
/// consequential action that deserves the brand treatment can reuse it.
///
/// Returns `true` when the user confirmed, `false`/`null` otherwise.
class RostroConfirmDialog extends StatelessWidget {
  final String message;
  final String confirmLabel;

  /// Destructive actions render the confirm button in the error red.
  final bool destructive;

  const RostroConfirmDialog({
    super.key,
    required this.message,
    this.confirmLabel = 'Confirm',
    this.destructive = false,
  });

  static Future<bool> show(
    BuildContext context, {
    required String message,
    String confirmLabel = 'Confirm',
    bool destructive = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => RostroConfirmDialog(
        message: message,
        confirmLabel: confirmLabel,
        destructive: destructive,
      ),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final confirmColor = destructive ? AppTheme.error : AppTheme.accent;
    return AlertDialog(
      backgroundColor: AppTheme.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppTheme.borderMid),
      ),
      title: Center(
        child: Image.asset(
          'assets/branding/rostro-lockup-white.png',
          height: 34,
          fit: BoxFit.contain,
        ),
      ),
      content: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 15, height: 1.4),
      ),
      actionsAlignment: MainAxisAlignment.spaceEvenly,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel', style: TextStyle(color: AppTheme.textTertiary)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: confirmColor,
            foregroundColor:
                destructive ? Colors.white : AppTheme.onAccent,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
