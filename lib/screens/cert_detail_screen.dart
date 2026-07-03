import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../bridge/bridge_generated.dart/core.dart' as bridge_core;
import '../bridge/bridge_generated.dart/zkpki_certs.dart' as bridge_certs;
import '../config/rpc_endpoints.dart';
import '../theme.dart';
import '../utils/block_time.dart';
import '../widgets/rostro_confirm_dialog.dart';
import '../widgets/transaction_blade.dart';
import 'my_certs_screen.dart' show certStateColor, shortThumbprint;

/// Cert detail (My Certs → row): full trust context for one cert, plus the
/// release flow (branded confirm → biometric → transaction blade → recovery
/// self-discard, i.e. `self_discard_cert(thumbprint, None)` signed by the
/// bound account).
class CertDetailScreen extends StatefulWidget {
  final String address;
  final String thumbprintHex;

  const CertDetailScreen({
    super.key,
    required this.address,
    required this.thumbprintHex,
  });

  @override
  State<CertDetailScreen> createState() => _CertDetailScreenState();
}

class _CertDetailScreenState extends State<CertDetailScreen> {
  bool _loading = true;
  String? _error;
  bridge_certs.CertStatusFfi? _status;
  bool _released = false;

  /// RNS names for the trust-chain entities, when resolvable. Reverse
  /// lookup is best-effort by design (RNS may not carry a reverse
  /// record); null falls back to the SS58.
  String? _issuerName;
  String? _rootName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<String?> _tryResolveName(String ss58) async {
    try {
      return await bridge_core.resolveAddressToName(
        address: ss58,
        rpcUrl: RpcEndpoints.chain,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final status = await bridge_certs.zkpkiCertStatus(
        chainRpc: RpcEndpoints.chain,
        thumbprintHex: widget.thumbprintHex,
      );
      final names = await Future.wait([
        _tryResolveName(status.issuerSs58),
        _tryResolveName(status.rootSs58),
      ]);
      if (!mounted) return;
      setState(() {
        _status = status;
        _issuerName = names[0];
        _rootName = names[1];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _releaseFlow() async {
    // 1. Branded confirm (Rostro lockup + the question).
    final confirmed = await RostroConfirmDialog.show(
      context,
      message: 'Are you sure you want to delete this cert?',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    // 2. Biometric, same gate the blade normally owns (skipped there via
    //    requireBiometric: false so the user isn't prompted twice).
    bool authenticated = false;
    if (kDebugMode) {
      authenticated = true;
    } else {
      try {
        final auth = LocalAuthentication();
        final canAuth =
            await auth.canCheckBiometrics || await auth.isDeviceSupported();
        authenticated = !canAuth ||
            await auth.authenticate(localizedReason: 'Confirm cert deletion');
      } catch (_) {
        authenticated = false;
      }
    }
    if (!authenticated || !mounted) return;

    // 3. Transaction blade → recovery self-discard.
    final status = _status!;
    await TransactionBlade.show(
      context,
      TransactionBlade(
        transactionType: 'Delete Cert',
        rpcUrl: RpcEndpoints.chain,
        requireBiometric: false,
        rows: [
          TxRow('Cert', shortThumbprint(status.thumbprintHex)),
          TxRow('Issuer', _shortSs58(status.issuerSs58)),
          TxRow('Action', 'Release cert + reclaim deposit'),
        ],
        onConfirm: (phrase) async {
          await bridge_core.submitSelfDiscardCertRecovery(
            certThumbprintHex: status.thumbprintHex,
            phrase: phrase,
            rpcUrl: RpcEndpoints.chain,
          );
        },
        onSuccess: () => _released = true,
      ),
    );
    // Blade route has popped; leave the (now stale) detail screen too.
    if (_released && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        title: const Text('Cert Detail'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textTertiary, fontSize: 13),
          ),
        ),
      );
    }
    final s = _status!;
    final stateColor = certStateColor(s.state);
    final expiresIn = (s.expiryBlock - s.thisUpdate).toInt();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Status card ────────────────────────────────────────────────
        _Card(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    shortThumbprint(s.thumbprintHex),
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _StateChip(label: s.state, color: stateColor),
              ],
            ),
            if (s.hasChatAuth) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.forum_outlined, color: AppTheme.accent, size: 15),
                  const SizedBox(width: 6),
                  Text(
                    'Enrolled for messaging auth',
                    style: TextStyle(color: AppTheme.accent, fontSize: 12.5),
                  ),
                ],
              ),
            ],
            const Divider(color: AppTheme.borderSubtle, height: 24),
            _DetailRow(
              'Expires',
              s.isActive && expiresIn > 0
                  ? 'block ${s.expiryBlock} (in ${approxDurationFromBlocks(expiresIn)})'
                  : 'block ${s.expiryBlock}',
            ),
            _DetailRow('Minted', 'block ${s.mintBlock}'),
            if (s.revocationReason != null)
              _DetailRow('Revoked', s.revocationReason!,
                  valueColor: AppTheme.error),
            if (s.revocationTime != null)
              _DetailRow('Revoked at', 'block ${s.revocationTime}',
                  valueColor: AppTheme.error),
          ],
        ),
        const SizedBox(height: 12),

        // ── Trust chain card ──────────────────────────────────────────
        _Card(
          children: [
            const _CardTitle('Trust chain'),
            // RNS name when resolvable, SS58 otherwise; copy always
            // yields the full address.
            _DetailRow('Issued by', _issuerName ?? _shortSs58(s.issuerSs58),
                copyValue: s.issuerSs58,
                trailing: _entityBadge(s.issuerStatus)),
            _DetailRow('Root', _rootName ?? _shortSs58(s.rootSs58),
                copyValue: s.rootSs58, trailing: _entityBadge(s.rootStatus)),
            if (s.templateName.isNotEmpty)
              _DetailRow('Template', s.templateName),
            _DetailRow('Attestation', s.attestationType),
            // A PoP *credential* (ProofOfPersonhood EKU), not the
            // template's mint-time hardware requirement.
            _DetailRow('Personhood', s.hasPersonhood ? 'Certified' : 'None'),
          ],
        ),
        const SizedBox(height: 12),

        // ── EKUs card ─────────────────────────────────────────────────
        _Card(
          children: [
            const _CardTitle('Extended key usage'),
            for (final eku in s.ekus)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  children: [
                    // Read-only: onChanged null renders the checkbox in
                    // the disabled (grayed) style so it can't be toggled.
                    SizedBox(
                      width: 30,
                      height: 30,
                      child: Checkbox(value: eku.held, onChanged: null),
                    ),
                    const SizedBox(width: 8),
                    // Same style as the trust-chain value column; the
                    // checkbox alone carries the held/unheld signal.
                    Text(
                      eku.label,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),

        // ── Release ───────────────────────────────────────────────────
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.error,
            side: BorderSide(color: AppTheme.error.withValues(alpha: 0.6)),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: _releaseFlow,
          icon: const Icon(Icons.delete_outline, size: 19),
          label: const Text('Release cert'),
        ),
        const SizedBox(height: 8),
        const Text(
          'Releasing deletes this cert on-chain and reclaims its deposit. '
          'Services that relied on it (like messaging) stop accepting it '
          'immediately.',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: AppTheme.textTertiary, fontSize: 11.5, height: 1.4),
        ),
      ],
    );
  }

  Widget _entityBadge(String status) {
    final color = status == 'Active' ? AppTheme.success : AppTheme.error;
    return _StateChip(label: status, color: color);
  }
}

String _shortSs58(String ss58) {
  if (ss58.length <= 14) return ss58;
  return '${ss58.substring(0, 6)}…${ss58.substring(ss58.length - 6)}';
}

class _Card extends StatelessWidget {
  final List<Widget> children;
  const _Card({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _CardTitle extends StatelessWidget {
  final String title;
  const _CardTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: AppTheme.textTertiary,
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  final String label;
  final Color color;
  const _StateChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  /// When set, tapping the row copies this (full) value.
  final String? copyValue;
  final Widget? trailing;

  const _DetailRow(this.label, this.value,
      {this.valueColor, this.copyValue, this.trailing});

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: const TextStyle(
                    color: AppTheme.textTertiary, fontSize: 12.5)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? AppTheme.textSecondary,
                fontSize: 12.5,
              ),
            ),
          ),
          if (copyValue != null) ...[
            const SizedBox(width: 4),
            const Icon(Icons.copy, color: AppTheme.textDisabled, size: 13),
          ],
          if (trailing != null) ...[
            const SizedBox(width: 6),
            trailing!,
          ],
        ],
      ),
    );
    if (copyValue == null) return row;
    return InkWell(
      onTap: () {
        Clipboard.setData(ClipboardData(text: copyValue!));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$label copied')),
        );
      },
      child: row,
    );
  }
}
