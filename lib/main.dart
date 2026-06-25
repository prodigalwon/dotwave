import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_fonts/google_fonts.dart';
import 'bridge/bridge_generated.dart/frb_generated.dart';
import 'package:no_screenshot/no_screenshot.dart';
import 'dart:typed_data';
import 'package:local_auth/local_auth.dart';
import 'backup_provider_screen.dart';
import 'restore_provider_screen.dart';
import 'home_shell.dart';
import 'services/theme_controller.dart';
import 'widgets/tx_badge_overlay.dart';
import 'theme.dart';
import 'screens/name_registration_screen.dart';
import 'screens/seed_phrase_quiz_screen.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('>>> Starting RustLib.init()');
  await RustLib.init();
  await ThemeController.instance.load(); // apply the persisted brand colour
  debugPrint('>>> RustLib done, starting app');
  runApp(const DotWaveApp());
}

class DotWaveApp extends StatelessWidget {
  const DotWaveApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Rebuild the whole app (new ThemeData) whenever the brand accent changes.
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) => MaterialApp(
        title: 'Rostro',
        navigatorKey: rootNavigatorKey,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        home: const SplashScreen(),
        builder: (context, child) {
        // Pin the transaction tracker badge above every route.
        return Stack(
          children: [
            if (child != null) child,
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 12,
              child: const TxBadgeOverlay(),
            ),
          ],
        );
        },
      ),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final _storage = const FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _checkExistingAccount();
  }

Future<void> _checkExistingAccount() async {
  // Single source of truth for "is this device onboarded": the
  // passphrase-encrypted seed phrase. If it's on the device, the
  // user has a recoverable wallet. If it's not, the user needs to
  // onboard fresh regardless of what other keys are lying around.
  final encryptedPhrase = await _storage.read(key: 'encrypted_phrase');
  if (!mounted) return;

  if (encryptedPhrase == null) {
    // Clear any orphaned `account_address` left by earlier buggy
    // code paths, then send the user through fresh onboarding. The
    // address without the phrase is useless (can't sign) and would
    // only cause confusion.
    await _storage.delete(key: 'account_address');
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const OnboardingScreen()),
    );
    return;
  }

  final address = await _storage.read(key: 'account_address');
  if (!mounted) return;
  if (address == null) {
    // Defensive: encrypted_phrase without account_address shouldn't
    // occur (we write them atomically in SetPassphraseScreen and the
    // restore flow), but if it ever does, treat as corrupted state
    // and re-onboard.
    await _storage.delete(key: 'encrypted_phrase');
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const OnboardingScreen()),
    );
    return;
  }

  final authenticated = await _authenticateUser();
  if (!mounted) return;
  if (!authenticated) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Authentication required to access your account')),
    );
    await _checkExistingAccount();
    return;
  }

  Navigator.pushReplacement(
    context,
    MaterialPageRoute(builder: (_) => HomeShell(address: address)),
  );
}

Future<bool> _authenticateUser() async {
    if (kDebugMode) return true;

    final auth = LocalAuthentication();
    final canAuth = await auth.canCheckBiometrics || await auth.isDeviceSupported();
    if (!canAuth) return true;

    try {
      return await auth.authenticate(
        localizedReason: 'Authenticate to access your Dotwave account',
      );
    } catch (e) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rostro lockup (mark + wordmark), white on the brand near-black. PNG
    // derived from the designer's vector so the wordmark metrics are exact;
    // width-only keeps its natural aspect (portrait).
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Center(
        child: Image.asset(
          'assets/branding/rostro-lockup-white.png',
          width: 150,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 2),
              // Full Rostro lockup (mark + wordmark).
              Center(
                child: Image.asset(
                  'assets/branding/rostro-lockup-white.png',
                  width: 190,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Your gateway to Rostro.',
                style: GoogleFonts.dmSans(
                  fontSize: 16,
                  color: AppTheme.textSecondary,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const Spacer(flex: 3),
              FilledButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CreateAccountScreen()),
                ),
                child: const Text('Create Account'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const RestoreAccountScreen()),
                ),
                child: const Text('I already have an account'),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class CreateAccountScreen extends StatefulWidget {
  const CreateAccountScreen({super.key});

  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}


class _CreateAccountScreenState extends State<CreateAccountScreen> {
  final _storage = const FlutterSecureStorage();
  final _noScreenshot = NoScreenshot.instance;
  bool _loading = false;
  String? _phrase;
  String? _address;

  Future<void> _createAccount() async {
    setState(() => _loading = true);

    try {
      final result = RustLib.instance.api.crateCoreGenerateAccount();
      final account = result.$1;
      final phrase = result.$2;

      // NOTE: `account_address` is NOT persisted here. If the user
      // exited at this point (before setting a passphrase) we'd leave
      // a persisted address with no way to recover the private key —
      // the phrase only lives in this widget's state. The address is
      // persisted atomically with `encrypted_phrase` in
      // `SetPassphraseScreen._setPassphrase()` below, so "has an
      // address" always implies "has a recoverable key".
      await _noScreenshot.screenshotOff();
      setState(() {
        _phrase = phrase;
        _address = account.address;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create account: $e')),
      );
    }
  }

  Future<void> _confirmBackup() async {
    await _noScreenshot.screenshotOn();
    if (!mounted) return;
    // "I wrote it down" → seed-phrase confirmation quiz. The quiz
    // makes the user prove they actually recorded the phrase by
    // identifying 5 random words by position before they can move
    // on to setting a passphrase. Standard wallet UX; prevents the
    // "skip and deal with it later" footgun that locks users out
    // of recovery.
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SeedPhraseQuizScreen(
          phrase: _phrase!,
          address: _address!,
          onPass: () {
            // Replace the quiz in the stack with the passphrase
            // screen so the back arrow on passphrase goes to the
            // seed-phrase view, not back into the quiz.
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (_) => SetPassphraseScreen(
                  phrase: _phrase!,
                  address: _address!,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Account')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: _phrase == null
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'We\'ll create a secure account for you.',
                      style: TextStyle(fontSize: 18),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 48),
                    FilledButton(
                      onPressed: _loading ? null : _createAccount,
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: _loading
                            ? const CircularProgressIndicator()
                            : const Text('Generate Account'),
                      ),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Write down your recovery phrase',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Store it somewhere safe. If you lose your phone and forget this, your account cannot be recovered.',
                      style: TextStyle(color: Colors.white60),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.accent),
                      ),
                      child: Text(
                        _phrase!,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 14,
                          height: 1.8,
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    FilledButton(
                      onPressed: _confirmBackup,
                      child: const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text('I\'ve saved my recovery phrase'),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}


class SetPassphraseScreen extends StatefulWidget {
  final String phrase;
  final String address;
  const SetPassphraseScreen({super.key, required this.phrase, required this.address});

  @override
  State<SetPassphraseScreen> createState() => _SetPassphraseScreenState();
}

class _SetPassphraseScreenState extends State<SetPassphraseScreen> {
  final _passphraseController = TextEditingController();
  final _confirmController = TextEditingController();
  final _storage = const FlutterSecureStorage();
  bool _loading = false;
  bool _obscure = true;

  Future<void> _savePassphrase() async {
    if (_passphraseController.text != _confirmController.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passphrases do not match')),
      );
      return;
    }
    if (_passphraseController.text.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passphrase must be at least 8 characters')),
      );
      return;
    }

    // Check entropy
    final strength = RustLib.instance.api.crateCoreCheckPassphraseStrength(
      passphrase: _passphraseController.text,
    );

    if (strength.score < 3) {
      final warning = strength.warning ?? 'Passphrase is too weak';
      final suggestions = strength.suggestions.isNotEmpty
          ? '\n• ${strength.suggestions.join('\n• ')}'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$warning$suggestions'),
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }

    setState(() => _loading = true);

    try {
      // Single-layer passphrase-encrypt: the seed phrase is wrapped
      // ONLY by Argon2+ChaCha20-Poly1305 derived from the user's
      // recovery passphrase. The previous Android Keystore outer
      // wrap was device-bound (AES-GCM with a hardware-backed key),
      // which broke cross-device restore — the cloud backup blob
      // couldn't be decrypted on a different phone because the
      // inner Keystore layer needed that specific device's key.
      // Reverted to the original scaffold design where the blob is
      // portable across devices as long as the user has their
      // passphrase.
      final fullyEncrypted = RustLib.instance.api.crateCoreEncryptPhrase(
        phrase: widget.phrase,
        passphrase: _passphraseController.text,
      );
      // Atomic persistence: the address + encrypted phrase are written
      // together, so splash can never see one without the other. Prevents
      // the "orphaned address on reopen" bug where a mid-onboarding exit
      // would leave a persisted address with no recoverable key.
      await _storage.write(
        key: 'encrypted_phrase',
        value: fullyEncrypted.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      );
      await _storage.write(key: 'account_address', value: widget.address);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BackupProviderScreen(
            encryptedBlob: Uint8List.fromList(fullyEncrypted),
            address: widget.address,
            // Wallet onboarding ends at backup. TOTP / HMAC / name
            // picking are part of the separate opt-in ZK-PKI identity
            // ceremony — not part of the SS58 wallet. Conflating them
            // would mean a compromised cert key could lock the user
            // out of their wallet. Keep the two keypair systems
            // strictly separate: seed-phrase → passphrase → backup →
            // HomeShell. ZK-PKI enrollment is done later from the
            // profile/settings area when the user actually wants an
            // on-chain identity credential.
            onComplete: () {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(
                  builder: (_) => HomeShell(address: widget.address),
                ),
                (_) => false,
              );
            },
          ),
        ),
      );
    } catch (e) {
      setState(() => _loading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to encrypt: $e')),
      );
    }
  }

  @override
  void dispose() {
    _passphraseController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
Widget build(BuildContext context) {
  return Scaffold(
    appBar: AppBar(title: const Text('Set Recovery Passphrase')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Set a recovery passphrase',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'If you lose your phone, you\'ll need this passphrase plus your cloud backup to recover your account. Use a password manager with end-to-end encryption to generate and store your passphrase. Avoid storing it anywhere that syncs to a cloud service you don\'t control.',
                style: TextStyle(color: Colors.white60),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _passphraseController,
                obscureText: _obscure,
                onChanged: (_) => setState(() {}),
                enableSuggestions: false,
                autocorrect: false,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(
                  labelText: 'Recovery passphrase',
                  border: const OutlineInputBorder(),
                  helperText: 'Paste from your password manager',
                  helperStyle: const TextStyle(color: Colors.white38),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (_passphraseController.text.isNotEmpty)
                Builder(builder: (context) {
                  final strength = RustLib.instance.api.crateCoreCheckPassphraseStrength(
                    passphrase: _passphraseController.text,
                  );
                  final colors = [
                    Colors.red,
                    Colors.orange,
                    Colors.yellow,
                    Colors.lightGreen,
                    Colors.green,
                  ];
                  final labels = ['Very weak', 'Weak', 'Fair', 'Strong', 'Very strong'];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LinearProgressIndicator(
                        value: (strength.score + 1) / 5,
                        color: colors[strength.score],
                        backgroundColor: Colors.white12,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        labels[strength.score],
                        style: TextStyle(
                          fontSize: 12,
                          color: colors[strength.score],
                        ),
                      ),
                      if (strength.warning != null)
                        Text(
                          strength.warning!,
                          style: const TextStyle(fontSize: 12, color: Colors.white60),
                        ),
                    ],
                  );
                }),
              const SizedBox(height: 16),
              TextField(
                controller: _confirmController,
                obscureText: _obscure,
                enableSuggestions: false,
                autocorrect: false,
                autofillHints: const [AutofillHints.newPassword],
                decoration: const InputDecoration(
                  labelText: 'Confirm passphrase',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: _loading ? null : _savePassphrase,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: _loading
                      ? const CircularProgressIndicator()
                      : const Text('Save & Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
}
class RestoreAccountScreen extends StatefulWidget {
  const RestoreAccountScreen({super.key});

  @override
  State<RestoreAccountScreen> createState() => _RestoreAccountScreenState();
}

class _RestoreAccountScreenState extends State<RestoreAccountScreen> {
  final _passphraseController = TextEditingController();
  final _storage = const FlutterSecureStorage();
  bool _loading = false;
  bool _obscure = true;

  Future<void> _pickBackupSource() async {
  if (_passphraseController.text.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Please enter your recovery passphrase first')),
    );
    return;
  }

  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => RestoreProviderScreen(
        onBlobDownloaded: (blob) {
          Navigator.pop(context);
          _restoreFromBlob(blob);
        },
      ),
    ),
  );
}

Future<void> _restoreFromBlob(Uint8List blob) async {
  setState(() => _loading = true);

  try {
    final phrase = RustLib.instance.api.crateCoreDecryptPhrase(
      blob: blob.toList(),
      passphrase: _passphraseController.text,
    );

    final account = RustLib.instance.api.crateCoreRestoreAccount(
      phrase: phrase,
    );

    // Write order matters: `account_address` is the splash gate, so
    // it must be LAST. If any earlier write crashes, splash sees no
    // address and the user re-runs onboarding cleanly rather than
    // landing in a half-restored state.
    //
    // The downloaded blob IS already a passphrase-encrypted seed
    // phrase (produced by the create flow's `crateCoreEncryptPhrase`
    // call). Store it directly — re-encrypting would churn entropy
    // for no gain, and the pre-fix path's Android Keystore wrap
    // broke cross-device restore in the first place.
    await _storage.write(
      key: 'encrypted_phrase',
      value: blob.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    );
    // A restored account skips the TOTP / name-picking ceremony — the
    // user already did those on the source device. Mark onboarding
    // complete so the splash gate lets the user straight into HomeShell
    // on next launch.
    await _storage.write(key: 'onboarding_complete', value: 'true');
    await _storage.write(key: 'account_address', value: account.address);

    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => HomeShell(address:
 account.address)),
      (_) => false,
    );
  } catch (e) {
    setState(() => _loading = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Restore failed: $e')),
    );
  }
}

  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }

 @override
Widget build(BuildContext context) {
  return Scaffold(
    appBar: AppBar(title: const Text('Restore Account')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Restore your account',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Enter your recovery passphrase to restore your account from your backup.',
              style: TextStyle(color: Colors.white60),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _passphraseController,
              obscureText: _obscure,
              enableSuggestions: false,
              autocorrect: false,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: 'Recovery passphrase',
                border: const OutlineInputBorder(),
                helperText: 'Paste from your password manager',
                helperStyle: const TextStyle(color: Colors.white38),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: _loading ? null : _pickBackupSource,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: _loading
                    ? const CircularProgressIndicator()
                    : const Text('Find My Backup'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
}

// ─────────────────────────────────────────────────────────────────────────────
// Post-onboarding name prompt
// ─────────────────────────────────────────────────────────────────────────────

class PickNamePromptScreen extends StatelessWidget {
  final String address;
  const PickNamePromptScreen({super.key, required this.address});

  /// Mark onboarding as fully complete. Written at both exit paths from
  /// this screen ("Pick my name" → NameRegistrationScreen → `_goHome`
  /// which also writes it, AND "Skip for now" which writes it here
  /// directly). Splash requires this flag in addition to
  /// `account_address` before dropping into `HomeShell`; without it,
  /// the user gets routed back to finish the remaining steps.
  static Future<void> markOnboardingComplete() async {
    const storage = FlutterSecureStorage();
    await storage.write(key: 'onboarding_complete', value: 'true');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 2),
              Center(
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.accent.withOpacity(0.12),
                    border: Border.all(
                      color: AppTheme.accent.withOpacity(0.3),
                      width: 2,
                    ),
                  ),
                  child: Icon(Icons.badge_outlined,
                      color: AppTheme.accent, size: 40),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                'Choose your name',
                style: GoogleFonts.syne(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: Text(
                      'Your .rst name is how people find you on Rostro — send RST and message friends, all without a long address.',
                      style: GoogleFonts.dmSans(
                        fontSize: 15,
                        color: AppTheme.textSecondary,
                        height: 1.55,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Tooltip(
                    message:
                        'Friends and family can send you RST by typing yourname.rst instead of your 48-character address. Your name is also your identity across Rostro.',
                    preferBelow: true,
                    triggerMode: TooltipTriggerMode.tap,
                    child: const Icon(Icons.info_outline,
                        size: 16, color: AppTheme.textTertiary),
                  ),
                ],
              ),
              const Spacer(flex: 3),
              FilledButton(
                onPressed: () => Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) => NameRegistrationScreen(
                      address: address,
                      isOnboarding: true,
                    ),
                  ),
                ),
                child: const Text('Pick my name'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () async {
                  await markOnboardingComplete();
                  if (!context.mounted) return;
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(
                        builder: (_) => HomeShell(address: address)),
                    (_) => false,
                  );
                },
                child: const Text('Skip for now'),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}