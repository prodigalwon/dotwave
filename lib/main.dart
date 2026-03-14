import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'bridge/bridge_generated.dart/frb_generated.dart';
import 'package:no_screenshot/no_screenshot.dart';
import 'keystore.dart';

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
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => HomeScreen(address: address)),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const OnboardingScreen()),
      );
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
                  // TODO: restore account flow
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
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => HomeScreen(address: widget.address)),
      (_) => false,
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Set a recovery passphrase',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'If you lose your phone, you\'ll need this passphrase plus your cloud backup to recover your account. Store it somewhere safe — we cannot recover it for you.',
                style: TextStyle(color: Colors.white60),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _passphraseController,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Recovery passphrase',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _confirmController,
                obscureText: _obscure,
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
    );
  }
}