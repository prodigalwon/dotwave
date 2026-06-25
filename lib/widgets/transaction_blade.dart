import 'dart:typed_data';
import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import '../bridge/bridge_generated.dart/frb_generated.dart';
import '../bridge/bridge_generated.dart/core.dart' show TxAction, TxUpdate, estimateFee;
import '../services/transaction_tracker.dart';
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
  submitted, // accepted into the pool — shows "Submitted" then shrinks to badge
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

  /// RPC endpoint used for the connectivity/balance pre-check.
  final String rpcUrl;

  /// Tracked, fire-and-forget submission. When set, the blade streams the action
  /// through [TransactionTracker]: on pool entry it shows "Submitted", shrinks
  /// into the corner badge, and the final in-block result is reported by the
  /// badge. Preferred over [onConfirm].
  final TxAction? txAction;

  /// Human label for the tracker entry, e.g. "Register tony.rst".
  final String? trackerLabel;

  /// Legacy blocking path: called after auth with the decrypted phrase; should
  /// throw a [String] on failure. Used only when [txAction] and [streamedSubmit]
  /// are both null.
  final Future<void> Function(String phrase)? onConfirm;

  /// Tracked, streamed submission for composite ceremonies that aren't a single
  /// [TxAction] (e.g. chat-key registration: silicon mint + publish + cert).
  /// Given the decrypted phrase, returns a [TxUpdate] stream that emits
  /// `Submitted` up front (the blade shrinks into the corner badge) then runs
  /// in the background. Preferred over [onConfirm] when set; mutually exclusive
  /// with [txAction].
  final Stream<TxUpdate> Function(String phrase)? streamedSubmit;

  /// Optional extra availability check before signing.
  /// Return null if OK, or an error string to block submission.
  final Future<String?> Function()? preflightCheck;

  /// Side effect to run once the tx is confirmed in a block (tracked path) or
  /// immediately after success (legacy path). Must be safe to run detached from
  /// this widget — it may fire after the blade has closed.
  final VoidCallback? onSuccess;

  /// Fired once the tx enters the pool, just before the blade shrinks away — for
  /// UI transitions on the still-alive originating screen (navigate, clear a
  /// form). If it navigates away (unmounting the blade), the shrink is skipped.
  final VoidCallback? onSubmitted;

  const TransactionBlade({
    super.key,
    required this.transactionType,
    required this.rpcUrl,
    required this.rows,
    this.txAction,
    this.trackerLabel,
    this.onConfirm,
    this.streamedSubmit,
    this.loadCost,
    this.costLabel = 'Fee',
    this.preflightCheck,
    this.onSuccess,
    this.onSubmitted,
  }) : assert(txAction != null || onConfirm != null || streamedSubmit != null,
            'Provide txAction (tracked), streamedSubmit (tracked stream), or onConfirm (legacy)');

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

class _TransactionBladeState extends State<TransactionBlade>
    with SingleTickerProviderStateMixin {
  static const _dotDecimals = 12;

  String? _costRaw;
  bool _loadingCost = false;
  String? _feeRaw; // estimated network fee in planck (tracked path)
  bool _loadingFee = false;
  final _passphraseController = TextEditingController();
  bool _passphraseObscured = true;
  _BladeState _state = _BladeState.idle;
  String? _errorMessage;

  /// Drives the shrink-into-the-corner animation after pool entry.
  late final AnimationController _shrink =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 420));

  @override
  void initState() {
    super.initState();
    if (widget.loadCost != null) _loadCost();
    if (widget.txAction != null) _loadFee();
  }

  @override
  void dispose() {
    _shrink.dispose();
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

  Future<void> _loadFee() async {
    setState(() => _loadingFee = true);
    try {
      final fee = await estimateFee(action: widget.txAction!, rpcUrl: widget.rpcUrl);
      if (mounted) setState(() { _feeRaw = fee; _loadingFee = false; });
    } catch (_) {
      if (mounted) setState(() { _feeRaw = null; _loadingFee = false; });
    }
  }

  String _formatDot(String planck) {
    final value = BigInt.parse(planck);
    final divisor = BigInt.from(10).pow(_dotDecimals);
    final whole = value ~/ divisor;
    final frac = ((value % divisor) * BigInt.from(1000) ~/ divisor)
        .toString()
        .padLeft(3, '0');
    return '$whole.$frac RST';
  }

  /// Higher-precision formatter for the network fee (6 decimals) so a small fee
  /// isn't rounded to 0.000.
  String _formatFee(String planck) {
    final value = BigInt.parse(planck);
    final divisor = BigInt.from(10).pow(_dotDecimals);
    final whole = value ~/ divisor;
    final frac = ((value % divisor) * BigInt.from(1000000) ~/ divisor)
        .toString()
        .padLeft(6, '0');
    return '$whole.$frac RST';
  }

  /// price (loadCost) + estimated network fee, in planck.
  String? get _totalRaw {
    final p = _costRaw != null ? BigInt.tryParse(_costRaw!) : null;
    final f = _feeRaw != null ? BigInt.tryParse(_feeRaw!) : null;
    if (p == null && f == null) return null;
    return ((p ?? BigInt.zero) + (f ?? BigInt.zero)).toString();
  }

  Widget _costRow(String label, bool loading, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 14)),
        loading
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(color: Colors.white38, strokeWidth: 2),
              )
            : Text(value,
                style: const TextStyle(
                    color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Future<void> _onSubmit() async {
    // Step 1: connectivity check — try to fetch balance; failure means offline
    setState(() { _state = _BladeState.checkingAvailability; _errorMessage = null; });
    try {
      const storage = FlutterSecureStorage();
      final address = await storage.read(key: 'account_address') ?? '';
      await RustLib.instance.api.crateCoreFetchBalance(
        address: address,
        rpcUrl: widget.rpcUrl,
      );
    } catch (_) {
      setState(() {
        _state = _BladeState.error;
        _errorMessage = 'Error: client appears to be offline';
      });
      return;
    }

    // Step 2: optional preflight (e.g. re-check name availability)
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

  /// Decrypt the stored seed phrase with the entered passphrase. Single-layer
  /// (Argon2 + ChaCha20-Poly1305) — the stored blob is passphrase-only.
  Future<String> _decryptPhrase(String passphrase) async {
    const storage = FlutterSecureStorage();
    final hex = await storage.read(key: 'encrypted_phrase');
    if (hex == null) throw 'No account found in storage';
    final bytes = Uint8List.fromList(
      List.generate(hex.length ~/ 2,
          (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)),
    );
    return RustLib.instance.api
        .crateCoreDecryptPhrase(blob: bytes, passphrase: passphrase);
  }

  Future<void> _onSign() async {
    final passphrase = _passphraseController.text;
    if (passphrase.isEmpty) return;

    setState(() {
      _state = _BladeState.submitting;
      _errorMessage = null;
    });

    // Decrypt first — a wrong passphrase is a distinct, common failure.
    final String phrase;
    try {
      phrase = await _decryptPhrase(passphrase);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _state = _BladeState.error;
        _errorMessage = 'Incorrect passphrase';
      });
      return;
    }

    // Tracked path (single TxAction): resolve on pool entry, shrink to badge.
    final action = widget.txAction;
    if (action != null) {
      await _runTracked(TransactionTracker.instance.submit(
        label: widget.trackerLabel ?? widget.transactionType,
        action: action,
        phrase: phrase,
        rpcUrl: widget.rpcUrl,
        onConfirmed: widget.onSuccess,
      ));
      return;
    }

    // Tracked streamed path (composite ceremony): same hand-off, but the stream
    // is supplied by the caller (it emits Submitted up front then runs in the
    // background).
    final streamed = widget.streamedSubmit;
    if (streamed != null) {
      await _runTracked(TransactionTracker.instance.submitStream(
        label: widget.trackerLabel ?? widget.transactionType,
        stream: streamed(phrase),
        onConfirmed: widget.onSuccess,
      ));
      return;
    }

    // Legacy blocking path.
    try {
      await widget.onConfirm!(phrase);
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

  /// Shared tail for the tracked paths (TxAction or streamed): await pool entry,
  /// flash "Submitted", fire [TransactionBlade.onSubmitted], shrink the blade
  /// into the corner badge, and close. A failure before pool entry surfaces
  /// inline; everything after pool entry is tracked by the badge.
  Future<void> _runTracked(Future<void> submitFut) async {
    try {
      await submitFut;
      if (!mounted) return;
      setState(() => _state = _BladeState.submitted);
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      widget.onSubmitted?.call();
      if (!mounted) return; // onSubmitted may have navigated away
      await _shrink.forward();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      // Failed before pool entry (bad nonce/sig, offline, silicon mint) — inline.
      if (!mounted) return;
      setState(() {
        _state = _BladeState.error;
        _errorMessage = e is String ? e : e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AnimatedBuilder(
        animation: _shrink,
        builder: (context, child) => _shrinkWrap(child!),
        child: Stack(
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

                  // Cost section — shown when there's a price (loadCost) and/or
                  // a tracked action we can estimate the network fee for.
                  if (widget.loadCost != null || widget.txAction != null) ...[
                    if (widget.loadCost != null)
                      _costRow(
                        widget.costLabel,
                        _loadingCost,
                        _costRaw != null ? _formatDot(_costRaw!) : '—',
                      ),
                    if (widget.txAction != null) ...[
                      if (widget.loadCost != null) const SizedBox(height: 8),
                      _costRow(
                        'Network Fee',
                        _loadingFee,
                        _feeRaw != null ? _formatFee(_feeRaw!) : '—',
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Total',
                            style: TextStyle(
                                color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                        Text(
                          _totalRaw != null ? _formatFee(_totalRaw!) : '—',
                          style: TextStyle(
                              color: AppTheme.accent,
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
                        backgroundColor: AppTheme.accent,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: AppTheme.accent.withOpacity(0.4),
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
          // Submitted overlay (tracked path) — brief "Submitted" before shrink.
          if (_state == _BladeState.submitted) _submittedOverlay(),
        ],
        ),
      ),
    );
  }

  /// Shrink the whole blade scene up into the corner badge after pool entry.
  Widget _shrinkWrap(Widget child) {
    if (_shrink.value == 0) return child;
    final t = Curves.easeInCubic.transform(_shrink.value);
    final size = MediaQuery.of(context).size;
    return Opacity(
      opacity: 1 - t,
      child: Transform.translate(
        offset: Offset(size.width * 0.42 * t, -size.height * 0.80 * t),
        child: Transform.scale(
          scale: 1 - 0.9 * t,
          alignment: Alignment.topRight,
          child: child,
        ),
      ),
    );
  }

  Widget _submittedOverlay() {
    return Positioned.fill(
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
                  color: const Color(0xFF9CA3AF).withOpacity(0.12),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF9CA3AF), width: 2),
                ),
                child: const Icon(Icons.outbox_outlined,
                    color: Color(0xFFD1D5DB), size: 34),
              ),
              const SizedBox(height: 20),
              const Text('Submitted',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ),
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
