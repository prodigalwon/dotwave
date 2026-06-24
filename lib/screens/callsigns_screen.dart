import 'package:flutter/material.dart';

import '../services/dead_drop_service.dart';
import '../theme.dart';

/// Manage the standing-callsign pool: the labels (human or random) this
/// account polls for incoming dead drops. The front door — conversations
/// then walk rotating return addresses, so a callsign only ever receives
/// the opening message. See docs/DOTWAVE-CHAT-DEAD-DROPS.md.
class CallsignsScreen extends StatefulWidget {
  final String address;
  const CallsignsScreen({super.key, required this.address});

  @override
  State<CallsignsScreen> createState() => _CallsignsScreenState();
}

class _CallsignsScreenState extends State<CallsignsScreen> {
  final _svc = DeadDropService.instance;
  List<String> _callsigns = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await _svc.callsigns(widget.address);
    if (!mounted) return;
    setState(() {
      _callsigns = list;
      _loading = false;
    });
  }

  Future<void> _add(String label) async {
    label = label.trim();
    if (label.isEmpty) return;
    try {
      await _svc.addCallsign(widget.address, label);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _generate() async {
    final label = await _svc.generateRandomLabel();
    await _add(label);
  }

  Future<void> _remove(String label) async {
    await _svc.removeCallsign(widget.address, label);
    await _load();
  }

  /// Poll a callsign for incoming dead drops + show what decrypts. On a
  /// StrongBox device the read prompts for a fingerprint (in-chip ECDH).
  Future<void> _check(String callsign) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: AppTheme.pink, strokeWidth: 2),
      ),
    );
    List<DeadDropReceived> got = [];
    String? err;
    try {
      got = await _svc.checkCallsign(widget.address, callsign);
    } catch (e) {
      err = '$e';
    }
    if (!mounted) return;
    Navigator.pop(context); // dismiss spinner
    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface2,
        title: Text("Drops at '$callsign'"),
        content: got.isEmpty
            ? const Text('No drops here yet.')
            : SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final d in got)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(d.text),
                        subtitle: Text(
                          '${d.senderName.isEmpty ? "(unnamed)" : "${d.senderName}.rst"}'
                          ' · reply→ ${d.returnPickupHex.isEmpty ? "—" : "${d.returnPickupHex.substring(0, 10)}…"}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                  ],
                ),
              ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  void _addDialog() {
    final ctrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface2,
        title: const Text('Add callsign'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. pigballs'),
          onSubmitted: (v) {
            Navigator.pop(ctx);
            _add(v);
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _add(ctrl.text);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final atCap = _callsigns.length >= DeadDropService.maxCallsigns;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: const Text('Callsigns')),
      body: _loading
          ? const Center(
              child:
                  CircularProgressIndicator(color: AppTheme.pink, strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Text(
                  'Callsigns are labels you poll for dead drops, shared offline. '
                  'A human word (like "pigballs") is easy to exchange aloud; a '
                  'generated random label is opaque, so the drop blends into every '
                  'other drop on the wire instead of advertising a name. You can '
                  'hold up to ${DeadDropService.maxCallsigns}.',
                  style: tt.bodySmall,
                ),
                const SizedBox(height: 16),
                if (_callsigns.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text('No callsigns yet',
                          style:
                              tt.bodyMedium?.copyWith(color: Colors.white38)),
                    ),
                  ),
                for (final cs in _callsigns)
                  _CallsignTile(
                    label: cs,
                    onRemove: () => _remove(cs),
                    onCheck: () => _check(cs),
                  ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.casino, size: 18),
                        label: const Text('Generate'),
                        onPressed: atCap ? null : _generate,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.pink),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add'),
                        onPressed: atCap ? null : _addDialog,
                      ),
                    ),
                  ],
                ),
                if (atCap)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'At the ${DeadDropService.maxCallsigns}-callsign limit — '
                      'remove one to add another.',
                      style: tt.bodySmall?.copyWith(color: Colors.white38),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _CallsignTile extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;
  final VoidCallback onCheck;
  const _CallsignTile(
      {required this.label, required this.onRemove, required this.onCheck});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    // A 64-hex label is a generated random one; show it compactly.
    final isRandom =
        label.length == 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(label);
    final display =
        isRandom ? '${label.substring(0, 10)}… (random)' : label;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderSubtle),
      ),
      child: Row(
        children: [
          Icon(isRandom ? Icons.casino : Icons.tag,
              size: 18, color: AppTheme.textTertiary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(display,
                style: tt.bodyMedium
                    ?.copyWith(fontFamily: isRandom ? 'monospace' : null)),
          ),
          IconButton(
            icon: const Icon(Icons.move_to_inbox, size: 18, color: AppTheme.pink),
            tooltip: 'Check for drops',
            onPressed: onCheck,
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: Colors.white38),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
