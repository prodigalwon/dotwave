import 'dart:async';
import 'package:flutter/foundation.dart';
import '../bridge/bridge_generated.dart/core.dart';

/// In-flight / recently-finished status of a tracked transaction.
enum TxStatus { pending, success, error }

/// Aggregate state the corner badge reflects.
enum TxBadgeState { hidden, pending, success, error }

class TrackedTx {
  final String id;
  final String label;
  TxStatus status;
  String? hash;
  String? error;

  TrackedTx({
    required this.id,
    required this.label,
    this.status = TxStatus.pending,
    this.hash,
    this.error,
  });
}

/// Session-scoped, fire-and-forget transaction tracker.
///
/// A write is submitted via [submit], which streams progress from rust_core's
/// `submit_action`. The returned Future completes once the tx enters the pool
/// (so the UI can shrink its blade into the corner badge) or fails-before-pool
/// (so the UI shows the error inline). After pool entry the tx lives here and
/// the badge reflects the aggregate state:
///   any pending  -> pending (sync icon)
///   else error   -> error   (red X, until the list is opened+closed)
///   else success -> success (green check, auto-clears 2s later)
///   empty        -> hidden
class TransactionTracker extends ChangeNotifier {
  TransactionTracker._();
  static final TransactionTracker instance = TransactionTracker._();

  final List<TrackedTx> _txs = [];
  List<TrackedTx> get txs => List.unmodifiable(_txs);

  int _counter = 0;
  Timer? _successTimer;

  TxBadgeState get badgeState {
    if (_txs.isEmpty) return TxBadgeState.hidden;
    if (_txs.any((t) => t.status == TxStatus.pending)) return TxBadgeState.pending;
    if (_txs.any((t) => t.status == TxStatus.error)) return TxBadgeState.error;
    return TxBadgeState.success;
  }

  /// Submit [action] and track it. Resolves when the tx is accepted into the
  /// pool (caller shrinks the blade); rejects with the error string if it fails
  /// before entering the pool (caller shows it inline — nothing is tracked).
  Future<void> submit({
    required String label,
    required TxAction action,
    required String phrase,
    required String rpcUrl,
    VoidCallback? onConfirmed,
  }) {
    final completer = Completer<void>();
    TrackedTx? tx;

    void onUpdate(TxUpdate u) {
      switch (u.kind) {
        case TxUpdateKind.submitted:
          tx = TrackedTx(id: 'tx${_counter++}', label: label);
          _txs.insert(0, tx!);
          notifyListeners();
          if (!completer.isCompleted) completer.complete();
          break;
        case TxUpdateKind.confirmed:
          if (tx != null) {
            tx!
              ..status = TxStatus.success
              ..hash = u.hash;
            notifyListeners();
            _scheduleAutoClear();
            // In-block success — run the side effect (cache name, forget on
            // release, etc.). Detached from any widget by now.
            onConfirmed?.call();
          }
          break;
        case TxUpdateKind.failed:
          if (tx == null) {
            // Failed before pool entry — surface inline, don't track.
            if (!completer.isCompleted) completer.completeError(u.error);
          } else {
            tx!
              ..status = TxStatus.error
              ..error = u.error;
            notifyListeners();
            _scheduleAutoClear();
          }
          break;
      }
    }

    submitAction(action: action, phrase: phrase, rpcUrl: rpcUrl).listen(
      onUpdate,
      onError: (Object e) {
        if (tx == null) {
          if (!completer.isCompleted) completer.completeError(e);
        } else {
          tx!
            ..status = TxStatus.error
            ..error = '$e';
          notifyListeners();
          _scheduleAutoClear();
        }
      },
      onDone: () {
        // Safety: if the stream ended without a terminal event, don't hang the
        // caller (the tx, if tracked, stays pending and the badge shows it).
        if (!completer.isCompleted) completer.complete();
      },
    );

    return completer.future;
  }

  /// When everything has settled to success (none pending, no errors), clear the
  /// list 2s later so the green check fades. Pending or errors keep it visible.
  void _scheduleAutoClear() {
    _successTimer?.cancel();
    final settledSuccess = _txs.isNotEmpty &&
        !_txs.any((t) => t.status == TxStatus.pending) &&
        !_txs.any((t) => t.status == TxStatus.error);
    if (!settledSuccess) return;
    _successTimer = Timer(const Duration(seconds: 2), () {
      final stillSettled = _txs.isNotEmpty &&
          !_txs.any((t) => t.status == TxStatus.pending) &&
          !_txs.any((t) => t.status == TxStatus.error);
      if (stillSettled) {
        _txs.clear();
        notifyListeners();
      }
    });
  }

  /// Called when the user opens then closes the transactions list. Viewing
  /// acknowledges terminal txs (success + error) and removes them, leaving only
  /// anything still pending — so a red X clears once the user has seen it.
  void acknowledgeTerminal() {
    final before = _txs.length;
    _txs.removeWhere((t) => t.status != TxStatus.pending);
    if (_txs.length != before) notifyListeners();
  }
}
