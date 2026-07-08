import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';

/// About screen — clean, sharp, minimal, in the spirit of the app splash:
/// the brand lockup centred on a plain field, with the version and a single
/// link out to rostro.org.
///
/// Dark-only for now (light mode is stubbed app-wide): white mark on the
/// app's near-black field.
///
/// Copy here is deliberately factual (brand, version, link). Any descriptive
/// tagline is left out pending sign-off, per the consult-before-editing-copy
/// rule.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  /// Keep in sync with `version:` in pubspec.yaml (currently 1.0.0+1).
  static const String _appVersion = '1.0.0';
  static const String _website = 'https://rostro.org';

  Future<void> _open(String url) async {
    // externalApplication hands the URL to the OS, which routes it to the
    // user's DEFAULT browser (whatever they've set — not a hardcoded or
    // in-app Chrome tab). No canLaunchUrl guard: on Android 11+ it can
    // false-negative on package visibility and silently swallow the tap.
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: SafeArea(
        // Fill the full width so the Column can't shrink-wrap and pin itself
        // to the left inset; crossAxisAlignment.center then centres on screen.
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Spacer(flex: 3),
                // Brand lockup (mark + wordmark).
                Image.asset(
                  'assets/branding/rostro-lockup-white.png',
                  width: 190,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 24),
                const Text(
                  'Version $_appVersion · Testnet alpha',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: 13,
                    letterSpacing: 0.2,
                  ),
                ),
                const Spacer(flex: 3),
                // Single, quiet link out.
                TextButton(
                  onPressed: () => _open(_website),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: const Text(
                    'rostro.org',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '© 2026 Rostro',
                  style: TextStyle(color: AppTheme.textDisabled, fontSize: 12),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
