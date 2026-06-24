import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/bridge_generated.dart/chat.dart';
import '../services/chat_store.dart';
import '../theme.dart';
import '../widgets/transaction_blade.dart';

/// This account's chat identity + key material (CHAT address, MESSAGE content
/// key) and the **rotate keys** action — re-mint the silicon content key +
/// republish CHAT/MESSAGE, superseding the old records. Reached from Message
/// Options → Chat Keys.
class ChatKeysScreen extends StatefulWidget {
  final String address;
  final String name;
  const ChatKeysScreen({super.key, required this.address, required this.name});

  @override
  State<ChatKeysScreen> createState() => _ChatKeysScreenState();
}

class _ChatKeysScreenState extends State<ChatKeysScreen> {
  final _store = ChatStore.instance;

  ChatIdentity? _identity;
  String _contentKey = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = await _store.identity(widget.address);
    final ck = await _store.contentKey(widget.address);
    if (!mounted) return;
    setState(() {
      _identity = id;
      _contentKey = ck;
      _loading = false;
    });
  }

  void _copy(String value, String label) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied')),
    );
  }

  Future<void> _rotateKeys() async {
    final rpc = await _store.nodeRpc();
    if (!mounted) return;
    TransactionBlade.show(
      context,
      TransactionBlade(
        transactionType: 'Rotate Chat Keys',
        rpcUrl: rpc,
        rows: [
          TxRow('Name', '${widget.name}.rst'),
          const TxRow('Content key', 'fresh silicon P-256 (StrongBox)'),
          const TxRow('Records', 'CHAT + MESSAGE re-published'),
        ],
        costLabel: 'Network Fee',
        trackerLabel: 'Rotate chat keys',
        // Mints a new content keypair in the secure element and republishes
        // CHAT/MESSAGE under the owned name, superseding the prior keys.
        streamedSubmit: (phrase) =>
            _store.registerKeysStream(widget.address, widget.name, phrase),
        onSuccess: () async {
          await _store.onKeysConfirmed(widget.address, widget.name);
          await _load();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Keys rotated — old messages stay readable')),
            );
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: const Text('Chat Keys')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.pink, strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Text('IDENTITY', style: tt.labelMedium),
                const SizedBox(height: 8),
                _Field(
                  label: 'Name',
                  value: '${widget.name}.rst',
                  onCopy: () => _copy('${widget.name}.rst', 'Name'),
                ),
                _Field(
                  label: 'Chat address (CHAT)',
                  value: _identity?.ed25519PubkeyHex ?? '—',
                  onCopy: _identity == null
                      ? null
                      : () => _copy(_identity!.ed25519PubkeyHex, 'Your chat address'),
                ),
                _Field(
                  label: 'Content key (MESSAGE)',
                  value: _contentKey.isEmpty ? '—' : _contentKey,
                  onCopy: _contentKey.isEmpty
                      ? null
                      : () => _copy(_contentKey, 'Your content key'),
                ),
                const SizedBox(height: 28),
                Text('KEYS', style: tt.labelMedium),
                const SizedBox(height: 8),
                Text(
                  'Rotating mints a fresh content key in secure hardware and '
                  'republishes your CHAT + MESSAGE records. New conversations use '
                  'the new key; already-decrypted messages are unaffected.',
                  style: tt.bodySmall,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: AppTheme.pink),
                  icon: const Icon(Icons.autorenew, size: 18),
                  label: const Text('Rotate Keys'),
                  onPressed: _rotateKeys,
                ),
              ],
            ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onCopy;
  const _Field({required this.label, required this.value, this.onCopy});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: tt.labelSmall?.copyWith(color: Colors.white54)),
                const SizedBox(height: 2),
                Text(value,
                    style: tt.bodySmall?.copyWith(fontFamily: 'monospace'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (onCopy != null)
            IconButton(
              icon: const Icon(Icons.copy, size: 16, color: Colors.white38),
              onPressed: onCopy,
            ),
        ],
      ),
    );
  }
}
