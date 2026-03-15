import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../bridge/bridge_generated.dart/frb_generated.dart';
import '../bridge/bridge_generated.dart/core.dart';
import '../widgets/transaction_blade.dart';

class SendScreen extends StatefulWidget {
  final String fromAddress;
  const SendScreen({super.key, required this.fromAddress});

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  static const _rpcUrl = 'ws://172.24.112.1:9944';
  static const _dotDecimals = 12;

  final _recipientController = TextEditingController();
  final _amountController = TextEditingController();

  bool _resolvingName = false;
  ResolvedName? _resolved;
  String? _recipientError;

  bool _verifying = false;
  bool? _verified;
  String? _verifyError;

  bool get _isDotName =>
      _recipientController.text.trim().toLowerCase().endsWith('.dot');

  bool get _isSelf =>
      _effectiveRecipient.isNotEmpty &&
      _effectiveRecipient == widget.fromAddress;

  bool get _canSend {
    final recipient = _recipientController.text.trim();
    final amount = _amountController.text.trim();
    if (recipient.isEmpty || amount.isEmpty) return false;
    if (_isDotName && _resolved == null) return false;
    if (_isSelf) return false;
    return true;
  }

  String get _effectiveRecipient =>
      _resolved?.owner ?? _recipientController.text.trim();

  @override
  void dispose() {
    _recipientController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  void _onRecipientChanged(String value) {
    if (_resolved != null || _verified != null || _recipientError != null) {
      setState(() {
        _resolved = null;
        _verified = null;
        _verifyError = null;
        _recipientError = null;
      });
    }
  }

  Future<void> _lookupName() async {
    final name = _recipientController.text.trim();
    setState(() {
      _resolvingName = true;
      _recipientError = null;
      _resolved = null;
      _verified = null;
      _verifyError = null;
    });
    try {
      final result = await RustLib.instance.api.crateCoreResolveNameVerified(
        name: name,
        rpcUrl: _rpcUrl,
      );
      if (!mounted) return;
      if (result == null) {
        setState(() {
          _resolvingName = false;
          _recipientError = 'Name not found on chain';
        });
      } else {
        setState(() {
          _resolvingName = false;
          _resolved = result;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resolvingName = false;
        _recipientError = 'Lookup failed: ${e.toString()}';
      });
    }
  }

  Future<void> _verifyOwnership() async {
    final resolved = _resolved;
    if (resolved == null) return;
    setState(() { _verifying = true; _verifyError = null; });
    try {
      final ok = await RustLib.instance.api.crateCoreVerifyNameOwnership(
        name: _recipientController.text.trim(),
        blockHashHex: resolved.blockHash,
        expectedOwner: resolved.owner,
        rpcUrl: _rpcUrl,
      );
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _verified = ok;
        if (!ok) _verifyError = 'No matching PNS event found at this block';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _verified = false;
        _verifyError = e.toString();
      });
    }
  }

  String _formatPlanck(String planck) {
    final value = BigInt.parse(planck);
    final divisor = BigInt.from(10).pow(_dotDecimals);
    final whole = value ~/ divisor;
    final frac = ((value % divisor) * BigInt.from(1000) ~/ divisor)
        .toString()
        .padLeft(3, '0');
    return '$whole.$frac DOT';
  }

  String _truncate(String address) =>
      '${address.substring(0, 8)}...${address.substring(address.length - 6)}';

  BigInt? _parseDotAmount(String input) {
    try {
      final parts = input.split('.');
      final whole = BigInt.parse(parts[0]);
      final frac = parts.length > 1 ? parts[1] : '';
      final fracPadded = frac.padRight(_dotDecimals, '0').substring(0, _dotDecimals);
      return whole * BigInt.from(10).pow(_dotDecimals) + BigInt.parse(fracPadded);
    } catch (_) {
      return null;
    }
  }

  void _openSendBlade() {
    final amountPlanck = _parseDotAmount(_amountController.text.trim());
    if (amountPlanck == null || amountPlanck <= BigInt.zero) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid amount')),
      );
      return;
    }

    final to = _effectiveRecipient;
    final amountStr = amountPlanck.toString();
    final displayName = _isDotName
        ? _recipientController.text.trim()
        : _truncate(to);

    TransactionBlade.show(
      context,
      TransactionBlade(
        transactionType: 'Token Transfer',
        rows: [
          TxRow('To', displayName),
          if (_isDotName && _resolved != null)
            TxRow('Address', _truncate(_resolved!.owner),
                valueColor: Colors.white54),
          TxRow('Network', 'Polkadot'),
        ],
        costLabel: 'Amount',
        loadCost: () async => amountStr,
        onConfirm: (phrase) => RustLib.instance.api.crateCoreSendDot(
          toAddress: to,
          amountPlanck: amountStr,
          phrase: phrase,
          rpcUrl: _rpcUrl,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        foregroundColor: Colors.white,
        title: const Text('Send',
            style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Recipient
              const Text('Recipient',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _recipientController,
                      style: const TextStyle(color: Colors.white),
                      onChanged: _onRecipientChanged,
                      onSubmitted: (_) { if (_isDotName) _lookupName(); },
                      decoration: InputDecoration(
                        hintText: 'SS58 address or name.dot',
                        hintStyle: const TextStyle(color: Colors.white24),
                        filled: true,
                        fillColor: const Color(0xFF1E1E1E),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: _recipientError != null
                              ? const BorderSide(color: Colors.redAccent, width: 1.5)
                              : BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: Color(0xFFE6007A), width: 1.5),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        suffixIcon: _isDotName && _resolved == null
                            ? IconButton(
                                icon: _resolvingName
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            color: Color(0xFFE6007A),
                                            strokeWidth: 2),
                                      )
                                    : const Icon(Icons.search,
                                        color: Color(0xFFE6007A)),
                                onPressed: _resolvingName ? null : _lookupName,
                              )
                            : null,
                      ),
                    ),
                  ),
                ],
              ),

              // Error
              if (_recipientError != null) ...[
                const SizedBox(height: 6),
                Text(_recipientError!,
                    style: const TextStyle(
                        color: Colors.redAccent, fontSize: 12)),
              ],

              // Resolved name card
              if (_resolved != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _verified == true
                          ? const Color(0xFF16A34A).withOpacity(0.5)
                          : const Color(0xFFE6007A).withOpacity(0.2),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.account_circle_outlined,
                              color: Colors.white38, size: 16),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _truncate(_resolved!.owner),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13),
                            ),
                          ),
                          // Verify button / state
                          if (_verified == null && !_verifying &&
                              (_resolved?.blockHash.isNotEmpty ?? false))
                            GestureDetector(
                              onTap: _verifyOwnership,
                              child: const Text(
                                'Verify?',
                                style: TextStyle(
                                  color: Color(0xFFE6007A),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            )
                          else if (_verifying)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  color: Color(0xFFE6007A), strokeWidth: 2),
                            )
                          else if (_verified == true)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Icon(Icons.verified,
                                    color: Color(0xFF16A34A), size: 16),
                                SizedBox(width: 4),
                                Text('Verified',
                                    style: TextStyle(
                                        color: Color(0xFF16A34A),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                              ],
                            )
                          else
                            GestureDetector(
                              onTap: _verifyOwnership,
                              child: const Text(
                                'Retry',
                                style: TextStyle(
                                    color: Colors.redAccent, fontSize: 12),
                              ),
                            ),
                        ],
                      ),

                      // Block info
                      const SizedBox(height: 6),
                      Text(
                        _verified == true
                            ? '✓ Currently resolves to this address'
                            : 'Registered at block #${_resolved!.lastBlock}',
                        style: TextStyle(
                          color: _verified == true
                              ? const Color(0xFF16A34A)
                              : Colors.white38,
                          fontSize: 11,
                        ),
                      ),

                      if (_verifyError != null) ...[
                        const SizedBox(height: 4),
                        Text(_verifyError!,
                            style: const TextStyle(
                                color: Colors.redAccent, fontSize: 11)),
                      ],
                    ],
                  ),
                ),
              ],

              if (_isSelf) ...[
                const SizedBox(height: 8),
                const SizedBox(
                  width: double.infinity,
                  child: Text(
                    "That's you.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 22),
                  ),
                ),
              ],

              const SizedBox(height: 24),

              // Amount
              const Text('Amount',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 8),
              TextField(
                controller: _amountController,
                style: const TextStyle(color: Colors.white),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
                ],
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: '0.000',
                  hintStyle: const TextStyle(color: Colors.white24),
                  suffixText: 'DOT',
                  suffixStyle: const TextStyle(
                      color: Colors.white54, fontWeight: FontWeight.w600),
                  filled: true,
                  fillColor: const Color(0xFF1E1E1E),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                        color: Color(0xFFE6007A), width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                ),
              ),

              const SizedBox(height: 40),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _canSend ? _openSendBlade : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE6007A),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor:
                        const Color(0xFFE6007A).withOpacity(0.3),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('Continue',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
