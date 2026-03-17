import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import '../keystore.dart';
import '../bridge/bridge_generated.dart/frb_generated.dart';
import 'package:flutter/foundation.dart';

/// A single label/value row shown in the transaction detail section.
class TxRow {
  final String label;
  final String value;
  final Color? valueColor;
  const TxRow(this.label, this.value, {this.valueColor});
}

enum _BladeState {
  idle,
  checkingAvailability,
  awaitingPassphrase,
  submitting,
  success,
  error,
}

class TransactionBlade extends StatefulWidget {
  /// e.g. "Name Registration"
  final String transactionType;

  /// Detail rows shown below the type header.
  final List<TxRow> rows;

  /// Optional async cost loader — returns raw planck string.
  final Future<String> Function()? loadCost;

  /// Label for the cost line, e.g. "Registration Fee".
  final String costLabel;

  /// Called after biometric + passphrase auth. Receives the decrypted phrase.
  /// Should throw a [String] message on failure.
  final Future<void> Function(String phrase) onConfirm;

  /// Optional extra availability check before signing.
  /// Return null if OK, or an error string to block submission.
  final Future<String?> Function()? preflightCheck;

  /// Called immediately after a successful transaction, before the blade closes.
  final VoidCallback? onSuccess;

  const TransactionBlade({
    super.key,
    required this.transactionType,
    required this.rows,
    required this.onConfirm,
    this.loadCost,
    this.costLabel = 'Fee',
    this.preflightCheck,
    this.onSuccess,
  });

  /// Push the blade as a translucent slide-up overlay.
  static Future<void> show(BuildContext context, TransactionBlade blade) {
    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black54,
        barrierDismissible: true,
        pageBuilder: (_, __, ___) => blade,
        transitionsBuilder: (_, animation, __, child) {
          final slide = Tween(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
          final fade = Tween(begin: 0.0, end: 1.0)
              .animate(CurvedAnimation(parent: animation, curve: const Interval(0, 0.3)));
          return FadeTransition(
            opacity: fade,
            child: SlideTransition(position: slide, child: child),
          );
        },
      ),
    );
  }

  @override
  State<TransactionBlade> createState() => _TransactionBladeState();
}

class _TransactionBladeState extends State<TransactionBlade> {
  static const _rpcUrl = 'ws://172.24.112.1:9944';
  static const _dotDecimals = 12;

  String? _costRaw;
  bool _loadingCost = false;
  final _passphraseController = TextEditingController();
  bool _passphraseObscured = true;
  _BladeState _state = _BladeState.idle;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    if (widget.loadCost != null) _loadCost();
  }

  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }

  Future<void> _loadCost() async {
    setState(() => _loadingCost = true);
    try {
      final raw = await widget.loadCost!();
      setState(() { _costRaw = raw; _loadingCost = false; });
    } catch (_) {
      setState(() { _costRaw = null; _loadingCost = false; });
    }
  }

  String _formatDot(String planck) {
    final value = BigInt.parse(planck);
    final divisor = BigInt.from(10).pow(_dotDecimals);
    final whole = value ~/ divisor;
    final frac = ((value % divisor) * BigInt.from(1000) ~/ divisor)
        .toString()
        .padLeft(3, '0');
    return '$whole.$frac DOT';
  }

  Future<void> _onSubmit() async {
    // Step 1: optional preflight (e.g. re-check name availability)
    setState(() { _state = _BladeState.checkingAvailability; _errorMessage = null; });
    if (widget.preflightCheck != null) {
      final err = await widget.preflightCheck!();
      if (err != null) {
        setState(() { _state = _BladeState.error; _errorMessage = err; });
        return;
      }
    }

    // Step 2: biometric
// Step 2: biometric
// Step 2: biometric
    final auth = LocalAuthentication();
    bool authenticated = false;
    if (kDebugMode) {
      authenticated = true;
    } else {
      try {
        final canAuth = await auth.canCheckBiometrics || await auth.isDeviceSupported();
        if (canAuth) {
          authenticated = await auth.authenticate(
            localizedReason: 'Confirm ${widget.transactionType}',
          );
        } else {
          authenticated = true;
        }
      } catch (_) {
        authenticated = false;
      }
    }
    if (!authenticated) {
      setState(() => _state = _BladeState.idle);
      return;
    }

    // Step 3: show passphrase entry
    setState(() => _state = _BladeState.awaitingPassphrase);
  }

  Future<void> _onSign() async {
    final passphrase = _passphraseController.text;
    if (passphrase.isEmpty) return;

    setState(() { _state = _BladeState.submitting; _errorMessage = null; });

    try {
      // Decrypt the stored phrase (two-layer: Argon2 outer → Keystore inner)
      const storage = FlutterSecureStorage();
      final hex = await storage.read(key: 'encrypted_phrase');
      if (hex == null) throw 'No account found in storage';

      final bytes = Uint8List.fromList(
        List.generate(hex.length ~/ 2, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)),
      );
      final innerStr = await RustLib.instance.api.crateCoreDecryptPhrase(
        blob: bytes,
        passphrase: passphrase,
      );
      final keystoreBytes = Uint8List.fromList(innerStr.codeUnits);
      final phraseBytes = await AndroidKeystore.decrypt(keystoreBytes);
      final phrase = String.fromCharCodes(phraseBytes);

      await widget.onConfirm(phrase);

      if (!mounted) return;
      setState(() => _state = _BladeState.success);
      widget.onSuccess?.call();
      await Future.delayed(const Duration(milliseconds: 1800));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _BladeState.error;
        _errorMessage = 'Error: client appears to be offline';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Column(
            children: [
              // Tappable dim area above the blade
              Expanded(
                child: GestureDetector(
                  onTap: _state == _BladeState.success
                      ? null
                      : () => Navigator.of(context).pop(),
                  behavior: HitTestBehavior.opaque,
                  child: const SizedBox.expand(),
                ),
              ),
              // The blade itself
              Container(
            decoration: const BoxDecoration(
              color: Color(0xFF141414),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Drag handle
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  // Type header
                  Text(
                    'Type',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.transactionType,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 20),
                  const Divider(color: Colors.white12),
                  const SizedBox(height: 16),

                  // Detail rows
                  ...widget.rows.map((row) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(row.label,
                            style: const TextStyle(color: Colors.white54, fontSize: 14)),
                        Text(
                          row.value,
                          style: TextStyle(
                            color: row.valueColor ?? Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  )),

                  const SizedBox(height: 4),
                  const Divider(color: Colors.white12),
                  const SizedBox(height: 16),

                  // Cost section
                  if (widget.loadCost != null) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(widget.costLabel,
                            style: const TextStyle(color: Colors.white54, fontSize: 14)),
                        _loadingCost
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    color: Colors.white38, strokeWidth: 2),
                              )
                            : Text(
                                _costRaw != null ? _formatDot(_costRaw!) : '—',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                              ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'plus network transaction fees',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Total',
                            style: TextStyle(
                                color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                        Text(
                          _costRaw != null ? _formatDot(_costRaw!) : '—',
                          style: const TextStyle(
                              color: Color(0xFFE6007A),
                              fontSize: 15,
                              fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ],

                  // Passphrase field (shown after biometric)
                  if (_state == _BladeState.awaitingPassphrase) ...[
                    const Text(
                      'Enter your passphrase to sign',
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _passphraseController,
                      obscureText: _passphraseObscured,
                      style: const TextStyle(color: Colors.white),
                      autofocus: true,
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: const Color(0xFF1E1E1E),
                        hintText: 'Passphrase',
                        hintStyle: const TextStyle(color: Colors.white38),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _passphraseObscured ? Icons.visibility_off : Icons.visibility,
                            color: Colors.white38,
                            size: 20,
                          ),
                          onPressed: () =>
                              setState(() => _passphraseObscured = !_passphraseObscured),
                        ),
                      ),
                      onSubmitted: (_) => _onSign(),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Error message
                  if (_state == _BladeState.error && _errorMessage != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.red.withOpacity(0.3)),
                      ),
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                      ),
                    ),
                  ],

                  // Action button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _actionEnabled ? _action : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE6007A),
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: const Color(0xFFE6007A).withOpacity(0.4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: _actionChild,
                    ),
                  ),
                ],
              ),
            ),
          ),
            ],
          ),

          // Success overlay
          if (_state == _BladeState.success)
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: 1.0,
                duration: const Duration(milliseconds: 300),
                child: Container(
                  color: Colors.black87,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: const Color(0xFF16A34A).withOpacity(0.15),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: const Color(0xFF16A34A),
                              width: 2,
                            ),
                          ),
                          child: const Icon(
                            Icons.check,
                            color: Color(0xFF16A34A),
                            size: 36,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'Success!',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  bool get _actionEnabled =>
      _state == _BladeState.idle ||
      _state == _BladeState.awaitingPassphrase ||
      _state == _BladeState.error;

  VoidCallback? get _action {
    if (_state == _BladeState.awaitingPassphrase) return _onSign;
    if (_state == _BladeState.error) return () => setState(() { _state = _BladeState.idle; _errorMessage = null; });
    return _onSubmit;
  }

  Widget get _actionChild {
    switch (_state) {
      case _BladeState.checkingAvailability:
        return const SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        );
      case _BladeState.submitting:
        return const SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        );
      case _BladeState.awaitingPassphrase:
        return const Text('Sign & Submit',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold));
      case _BladeState.error:
        return const Text('Okay',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold));
      default:
        return const Text('Confirm',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold));
    }
  }
}
