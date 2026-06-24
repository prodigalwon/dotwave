import 'package:flutter/material.dart';
import '../services/transaction_tracker.dart';

/// Root navigator key — lets the corner badge (which lives *above* the Navigator
/// in MaterialApp.builder) open the transactions sheet against a context that
/// has an Overlay/Navigator below it.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Small status badge pinned to the upper-right, above all routes. Reflects the
/// aggregate [TransactionTracker.badgeState]:
///   pending -> spinning sync icon
///   success -> green check (auto-clears 2s later via the tracker)
///   error   -> red X (clears once the user opens + closes the sheet)
class TxBadgeOverlay extends StatefulWidget {
  const TxBadgeOverlay({super.key});

  @override
  State<TxBadgeOverlay> createState() => _TxBadgeOverlayState();
}

class _TxBadgeOverlayState extends State<TxBadgeOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))
        ..repeat();
  final _tracker = TransactionTracker.instance;

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _tracker,
      builder: (context, _) {
        final state = _tracker.badgeState;
        if (state == TxBadgeState.hidden) return const SizedBox.shrink();

        late final Widget icon;
        late final Color bg;
        switch (state) {
          case TxBadgeState.pending:
            icon = RotationTransition(
              turns: _spin,
              child: const Icon(Icons.sync, color: Color(0xFFD1D5DB), size: 18),
            );
            bg = const Color(0xFF374151);
            break;
          case TxBadgeState.success:
            icon = const Icon(Icons.check, color: Colors.white, size: 20);
            bg = const Color(0xFF10B981);
            break;
          case TxBadgeState.error:
            icon = const Icon(Icons.close, color: Colors.white, size: 20);
            bg = const Color(0xFFEF4444);
            break;
          case TxBadgeState.hidden:
            return const SizedBox.shrink();
        }

        final count = _tracker.txs.length;
        return GestureDetector(
          onTap: showTransactionsSheet,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              boxShadow: const [
                BoxShadow(color: Colors.black54, blurRadius: 6, offset: Offset(0, 2)),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                icon,
                if (count > 1)
                  Positioned(
                    right: 1,
                    top: 1,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        color: Colors.black, shape: BoxShape.circle),
                      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                      child: Text('$count',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Open the transactions list. Viewing acknowledges terminal txs on close, so a
/// red X clears once the user has seen the error.
void showTransactionsSheet() {
  final ctx = rootNavigatorKey.currentContext;
  if (ctx == null) return;
  showModalBottomSheet<void>(
    context: ctx,
    backgroundColor: const Color(0xFF1A1A1A),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _TransactionsSheet(),
  ).whenComplete(TransactionTracker.instance.acknowledgeTerminal);
}

class _TransactionsSheet extends StatefulWidget {
  const _TransactionsSheet();

  @override
  State<_TransactionsSheet> createState() => _TransactionsSheetState();
}

class _TransactionsSheetState extends State<_TransactionsSheet> {
  final _tracker = TransactionTracker.instance;
  final _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _tracker,
      builder: (context, _) {
        final txs = _tracker.txs;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Transactions',
                    style: TextStyle(
                        color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                if (txs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text('No active transactions',
                          style: TextStyle(color: Colors.white38)),
                    ),
                  )
                else
                  ...txs.map(_row),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _row(TrackedTx tx) {
    final isError = tx.status == TxStatus.error;
    final open = _expanded.contains(tx.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _statusDot(tx.status),
          title: Text(tx.label, style: const TextStyle(color: Colors.white, fontSize: 15)),
          subtitle: Text(_statusLabel(tx.status),
              style: TextStyle(color: _statusColor(tx.status), fontSize: 12)),
          trailing: isError
              ? Icon(open ? Icons.expand_less : Icons.expand_more,
                  color: Colors.white38)
              : null,
          onTap: isError
              ? () => setState(() =>
                  open ? _expanded.remove(tx.id) : _expanded.add(tx.id))
              : null,
        ),
        if (isError && open)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFEF4444).withOpacity(0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(tx.error ?? 'Unknown error',
                style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12)),
          ),
      ],
    );
  }

  Widget _statusDot(TxStatus s) {
    switch (s) {
      case TxStatus.pending:
        return const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD1D5DB)),
        );
      case TxStatus.success:
        return const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 20);
      case TxStatus.error:
        return const Icon(Icons.cancel, color: Color(0xFFEF4444), size: 20);
    }
  }

  String _statusLabel(TxStatus s) => switch (s) {
        TxStatus.pending => 'Pending',
        TxStatus.success => 'Success',
        TxStatus.error => 'Error — tap to view',
      };

  Color _statusColor(TxStatus s) => switch (s) {
        TxStatus.pending => Colors.white54,
        TxStatus.success => const Color(0xFF10B981),
        TxStatus.error => const Color(0xFFEF4444),
      };
}
