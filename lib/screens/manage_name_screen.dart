import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../bridge/bridge_generated.dart/frb_generated.dart';
import '../config/rpc_endpoints.dart';
import '../widgets/transaction_blade.dart';

/// Lifecycle management for a canonical name the caller owns: renew, transfer,
/// and release. Each action runs through [TransactionBlade], which (with the
/// submit-and-watch path in rust_core) only reports success once the extrinsic
/// is actually in a block and dispatched — a real DispatchError surfaces instead
/// of a false success.
///
/// `name` is the bare label (no ".rst"); PNS resolves by the bare label.
class ManageNameScreen extends StatefulWidget {
  final String address;
  final String name;
  const ManageNameScreen({super.key, required this.address, required this.name});

  @override
  State<ManageNameScreen> createState() => _ManageNameScreenState();
}

class _ManageNameScreenState extends State<ManageNameScreen> {
  static const _rpcUrl = RpcEndpoints.pnsNode;
  static const _accent = Color(0xFFE6007A);

  final _recipientController = TextEditingController();
  bool _resolvingRecipient = false;
  String? _recipientError;

  String get _storageKey => 'owned_name_${widget.address}';

  @override
  void dispose() {
    _recipientController.dispose();
    super.dispose();
  }

  /// Drop the locally-cached owned name. The chain has no address→label reverse
  /// lookup, so the home header relies on this cache; clearing it after the name
  /// leaves this account keeps the UI honest.
  Future<void> _forgetCachedName() async {
    const storage = FlutterSecureStorage();
    await storage.delete(key: _storageKey);
  }

  // ── Renew ──────────────────────────────────────────────────────────────
  void _renew() {
    TransactionBlade.show(
      context,
      TransactionBlade(
        transactionType: 'Renew Name',
        rpcUrl: _rpcUrl,
        rows: [
          TxRow('Name', '${widget.name}.rst'),
          TxRow('Action', 'Extend expiry +365 days'),
        ],
        onConfirm: (phrase) =>
            RustLib.instance.api.crateCoreRenewName(phrase: phrase, rpcUrl: _rpcUrl),
      ),
    );
  }

  // ── Transfer ───────────────────────────────────────────────────────────
  bool get _recipientIsName =>
      _recipientController.text.trim().toLowerCase().endsWith('.rst');

  Future<void> _transfer() async {
    final raw = _recipientController.text.trim();
    if (raw.isEmpty) {
      setState(() => _recipientError = 'Enter a recipient address or name.rst');
      return;
    }

    // Resolve a .rst name to its owner address; otherwise treat as raw SS58.
    String toAddress = raw;
    if (_recipientIsName) {
      setState(() {
        _resolvingRecipient = true;
        _recipientError = null;
      });
      try {
        final bare = raw.replaceFirst(RegExp(r'\.rst$', caseSensitive: false), '');
        final resolved = await RustLib.instance.api
            .crateCoreResolveNameVerified(name: bare, rpcUrl: _rpcUrl);
        if (!mounted) return;
        if (resolved == null) {
          setState(() {
            _resolvingRecipient = false;
            _recipientError = 'Name not found on chain';
          });
          return;
        }
        toAddress = resolved.owner;
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _resolvingRecipient = false;
          _recipientError = 'Error: client appears to be offline';
        });
        return;
      }
      setState(() => _resolvingRecipient = false);
    }

    if (toAddress == widget.address) {
      setState(() => _recipientError = 'You already own this name');
      return;
    }

    if (!mounted) return;
    TransactionBlade.show(
      context,
      TransactionBlade(
        transactionType: 'Transfer Name',
        rpcUrl: _rpcUrl,
        rows: [
          TxRow('Name', '${widget.name}.rst'),
          TxRow('To', _truncate(toAddress)),
        ],
        onConfirm: (phrase) => RustLib.instance.api.crateCoreTransferName(
          toAddress: toAddress,
          phrase: phrase,
          rpcUrl: _rpcUrl,
        ),
        onSuccess: () async {
          await _forgetCachedName();
          if (mounted) Navigator.of(context).pop(true);
        },
      ),
    );
  }

  // ── Release ────────────────────────────────────────────────────────────
  Future<void> _release() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Release name', style: TextStyle(color: Colors.white)),
        content: Text(
          'This releases ${widget.name}.rst back to the available pool. Anyone '
          'can then register it, and you give up ownership. This cannot be undone.\n\n'
          '(Cancel any active marketplace listing first, or release will fail.)',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Release', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    TransactionBlade.show(
      context,
      TransactionBlade(
        transactionType: 'Release Name',
        rpcUrl: _rpcUrl,
        rows: [
          TxRow('Name', '${widget.name}.rst'),
          TxRow('Action', 'Release — back to pool'),
        ],
        onConfirm: (phrase) =>
            RustLib.instance.api.crateCoreReleaseName(phrase: phrase, rpcUrl: _rpcUrl),
        onSuccess: () async {
          await _forgetCachedName();
          if (mounted) Navigator.of(context).pop(true);
        },
      ),
    );
  }

  String _truncate(String a) =>
      a.length <= 14 ? a : '${a.substring(0, 8)}...${a.substring(a.length - 6)}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        foregroundColor: Colors.white,
        title: const Text('Manage Name',
            style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Text(
                  '${widget.name}.rst',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // Renew
              _ActionCard(
                icon: Icons.autorenew,
                title: 'Renew',
                subtitle: 'Extend expiry by 365 days',
                onTap: _renew,
              ),
              const SizedBox(height: 16),

              // Transfer
              const Text('Transfer to',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 8),
              TextField(
                controller: _recipientController,
                style: const TextStyle(color: Colors.white),
                onChanged: (_) {
                  if (_recipientError != null) {
                    setState(() => _recipientError = null);
                  }
                },
                decoration: InputDecoration(
                  hintText: 'SS58 address or name.rst',
                  hintStyle: const TextStyle(color: Colors.white24),
                  errorText: _recipientError,
                  filled: true,
                  fillColor: const Color(0xFF1E1E1E),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _resolvingRecipient ? null : _transfer,
                  child: _resolvingRecipient
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Transfer Name'),
                ),
              ),

              const SizedBox(height: 40),
              const Divider(color: Colors.white12),
              const SizedBox(height: 16),

              // Release — relinquish ownership back to the pool
              _ActionCard(
                icon: Icons.lock_open_outlined,
                title: 'Release',
                subtitle: 'Release name back to pool',
                destructive: true,
                onTap: _release,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool destructive;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? Colors.redAccent : const Color(0xFFE6007A);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 13)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white24),
          ],
        ),
      ),
    );
  }
}
