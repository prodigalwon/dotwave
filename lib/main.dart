import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'bridge/bridge_generated.dart/frb_generated.dart';
import 'package:no_screenshot/no_screenshot.dart';
import 'keystore.dart';
import 'dart:typed_data';
import 'package:local_auth/local_auth.dart';
import 'backup_provider_screen.dart';
import 'restore_provider_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  await AndroidKeystore.generateKey();
  runApp(const DotWaveApp());
}

class DotWaveApp extends StatelessWidget {
  const DotWaveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dotwave',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE6007A),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
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
  final address = await _storage.read(key: 'account_address');
  if (!mounted) return;

  if (address != null) {
    final authenticated = await _authenticateUser();
    if (!mounted) return;
    if (authenticated) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => HomeScreen(address: address)),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Authentication required to access your account')),
      );
      await _checkExistingAccount();
    }
  } else {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const OnboardingScreen()),
    );
  }
}

Future<bool> _authenticateUser() async {
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
    return const Scaffold(
      body: Center(
        child: Text(
          'dotwave',
          style: TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
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
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Welcome to Dotwave',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                'Your gateway to the Polkadot ecosystem.',
                style: TextStyle(fontSize: 16, color: Colors.white60),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 64),
              FilledButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const CreateAccountScreen()),
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text('Create Account'),
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const RestoreAccountScreen()),
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text('I already have an account'),
                ),
              ),
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

      // Store address in secure storage
      await _storage.write(key: 'account_address', value: account.address);
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
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => SetPassphraseScreen(
        phrase: _phrase!,
        address: _address!,
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
                        border: Border.all(color: const Color(0xFFE6007A)),
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

class HomeScreen extends StatelessWidget {
  final String address;
  const HomeScreen({super.key, required this.address});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dotwave')),
      body: Center(
        child: Text(
          address,
          style: const TextStyle(fontSize: 12, color: Colors.white60),
          textAlign: TextAlign.center,
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
      final phraseBytes = Uint8List.fromList(widget.phrase.codeUnits);
      final keystoreEncrypted = await AndroidKeystore.encrypt(phraseBytes);
      final fullyEncrypted = RustLib.instance.api.crateCoreEncryptPhrase(
        phrase: String.fromCharCodes(keystoreEncrypted),
        passphrase: _passphraseController.text,
      );
      await _storage.write(
        key: 'encrypted_phrase',
        value: fullyEncrypted.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      );
      if (!mounted) return;
      if (!mounted) return;
      if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BackupProviderScreen(
              encryptedBlob: Uint8List.fromList(fullyEncrypted),
              address: widget.address,
              onComplete: () {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => HomeScreen(address: widget.address)),
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

    await _storage.write(key: 'account_address', value: account.address);

    final phraseBytes = Uint8List.fromList(phrase.codeUnits);
    final keystoreEncrypted = await AndroidKeystore.encrypt(phraseBytes);
    final fullyEncrypted = RustLib.instance.api.crateCoreEncryptPhrase(
      phrase: String.fromCharCodes(keystoreEncrypted),
      passphrase: _passphraseController.text,
    );
    await _storage.write(
      key: 'encrypted_phrase',
      value: fullyEncrypted.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    );

    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => HomeScreen(address: account.address)),
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