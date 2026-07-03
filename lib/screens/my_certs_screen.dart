import 'package:flutter/material.dart';

import '../bridge/bridge_generated.dart/zkpki_certs.dart' as bridge_certs;
import '../config/rpc_endpoints.dart';
import '../theme.dart';
import '../utils/block_time.dart';
import 'cert_detail_screen.dart';

/// My Certs (Explore → ZK-PKI → My Certs): every cert minted to this
/// account via `mint_cert`, any issuer, any template. Tap a row for the
/// full trust context + release flow.
class MyCertsScreen extends StatefulWidget {
  final String address;
  const MyCertsScreen({super.key, required this.address});

  @override
  State<MyCertsScreen> createState() => _MyCertsScreenState();
}

class _MyCertsScreenState extends State<MyCertsScreen> {
  bool _loading = true;
  String? _error;
  bridge_certs.CertListFfi? _list;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // The chat badge rides the summary's ChatAuth EKU — no per-cert
      // membership_witness probes needed.
      final list = await bridge_certs.zkpkiCertsByUser(
        chainRpc: RpcEndpoints.chain,
        address: widget.address,
      );
      if (!mounted) return;
      setState(() {
        _list = list;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        title: const Text('My Certs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _Message(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load certs',
        detail: _error!,
      );
    }
    final list = _list!;
    if (list.certs.isEmpty) {
      return const _Message(
        icon: Icons.badge_outlined,
        title: 'No certs yet',
        detail:
            'When an issuer offers you a certificate and you accept it, '
            'it will show up here.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: list.certs.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final cert = list.certs[i];
          return _CertRow(
            cert: cert,
            bestBlock: list.bestBlock,
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CertDetailScreen(
                    address: widget.address,
                    thumbprintHex: cert.thumbprintHex,
                  ),
                ),
              );
              // The detail screen may have released the cert.
              if (mounted) _load();
            },
          );
        },
      ),
    );
  }
}

String shortThumbprint(String hex) {
  final h = hex.startsWith('0x') ? hex.substring(2) : hex;
  if (h.length <= 16) return '0x$h';
  return '0x${h.substring(0, 8)}…${h.substring(h.length - 8)}';
}

Color certStateColor(String state) {
  switch (state) {
    case 'Active':
      return AppTheme.success;
    case 'Suspended':
      return AppTheme.warning;
    default: // Expired / Purged
      return AppTheme.error;
  }
}

class _CertRow extends StatelessWidget {
  final bridge_certs.CertSummaryFfi cert;
  final BigInt bestBlock;
  final VoidCallback onTap;

  const _CertRow({
    required this.cert,
    required this.bestBlock,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final stateColor = certStateColor(cert.state);
    final expiresIn = (cert.expiryBlock - bestBlock).toInt();
    final expiryText = cert.isActive
        ? (expiresIn > 0
            ? 'expires in ${approxDurationFromBlocks(expiresIn)}'
            : 'expiring')
        : 'expiry block ${cert.expiryBlock}';
    return Material(
      color: AppTheme.surface1,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.borderSubtle),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.verified_user_outlined,
                    color: stateColor, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // Flexible + ellipsis: the thumbprint yields so the
                        // chat chip never pushes the row past its bounds on
                        // narrow screens.
                        Flexible(
                          child: Text(
                            shortThumbprint(cert.thumbprintHex),
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 13.5,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (cert.chatAuth) ...[
                          const SizedBox(width: 6),
                          _Chip(label: 'chat', color: AppTheme.accent),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      expiryText,
                      style: const TextStyle(
                          color: AppTheme.textTertiary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              _Chip(label: cert.state, color: stateColor),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right,
                  color: AppTheme.textTertiary, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontSize: 10.5, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  const _Message(
      {required this.icon, required this.title, required this.detail});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: AppTheme.textTertiary, size: 44),
            const SizedBox(height: 14),
            Text(title,
                style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AppTheme.textTertiary, fontSize: 13, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
