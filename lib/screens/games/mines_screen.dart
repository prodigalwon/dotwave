import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';
import 'game_scores.dart';

/// Mines. Tap to reveal, long-press to flag, tap a satisfied number to
/// chord-reveal its neighbours. The first tap is always safe.
class MinesScreen extends StatefulWidget {
  const MinesScreen({super.key});

  @override
  State<MinesScreen> createState() => _MinesScreenState();
}

class _MinesScreenState extends State<MinesScreen> {
  static const cols = 9;
  static const rows = 13;
  static const mineCount = 20;
  static const _cell = 40.0; // logical cell size; FittedBox scales the board

  final _rng = Random();
  late List<bool> _mine;
  late List<bool> _revealed;
  late List<bool> _flagged;
  bool _minesPlaced = false;
  bool _over = false;
  bool _won = false;
  int _seconds = 0;
  int? _bestTime;
  Timer? _clock;

  static const _numberColors = <Color>[
    Colors.transparent, // 0 is never drawn
    Color(0xFF60A5FA),
    Color(0xFF4ADE80),
    Color(0xFFF87171),
    Color(0xFFC084FC),
    Color(0xFFF59E0B),
    Color(0xFF2DD4BF),
    Color(0xFFE5E7EB),
    Color(0xFF9CA3AF),
  ];

  @override
  void initState() {
    super.initState();
    GameScores.read('mines').then((v) {
      if (mounted) setState(() => _bestTime = v);
    });
    _reset();
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  void _reset() {
    _clock?.cancel();
    _mine = List.filled(cols * rows, false);
    _revealed = List.filled(cols * rows, false);
    _flagged = List.filled(cols * rows, false);
    _minesPlaced = false;
    _over = false;
    _won = false;
    _seconds = 0;
    setState(() {});
  }

  Iterable<int> _neighbors(int i) sync* {
    final x = i % cols, y = i ~/ cols;
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = x + dx, ny = y + dy;
        if (nx < 0 || nx >= cols || ny < 0 || ny >= rows) continue;
        yield ny * cols + nx;
      }
    }
  }

  int _count(int i) => _neighbors(i).where((n) => _mine[n]).length;

  /// Mines are placed on the first tap, excluding it and its neighbours,
  /// so the opening move always cascades.
  void _placeMines(int safe) {
    final forbidden = {safe, ..._neighbors(safe)};
    final candidates = [
      for (int i = 0; i < cols * rows; i++)
        if (!forbidden.contains(i)) i,
    ]..shuffle(_rng);
    for (final i in candidates.take(mineCount)) {
      _mine[i] = true;
    }
    _minesPlaced = true;
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  void _reveal(int i) {
    if (_over || _flagged[i]) return;
    if (!_minesPlaced) _placeMines(i);

    if (_revealed[i]) {
      _chord(i);
      return;
    }
    if (_mine[i]) {
      _lose();
      return;
    }
    _floodReveal(i);
    _checkWin();
    setState(() {});
  }

  void _floodReveal(int start) {
    final queue = [start];
    while (queue.isNotEmpty) {
      final i = queue.removeLast();
      if (_revealed[i] || _flagged[i] || _mine[i]) continue;
      _revealed[i] = true;
      if (_count(i) == 0) queue.addAll(_neighbors(i));
    }
  }

  /// Tap on a revealed number whose flag count matches: open the rest of
  /// its neighbours. A wrong flag makes this lose, as in the classic.
  void _chord(int i) {
    final n = _count(i);
    if (n == 0) return;
    final around = _neighbors(i).toList();
    final flags = around.where((a) => _flagged[a]).length;
    if (flags != n) return;
    bool boom = false;
    for (final a in around) {
      if (_flagged[a] || _revealed[a]) continue;
      if (_mine[a]) {
        boom = true;
      } else {
        _floodReveal(a);
      }
    }
    if (boom) {
      _lose();
      return;
    }
    _checkWin();
    setState(() {});
  }

  void _toggleFlag(int i) {
    if (_over || _revealed[i]) return;
    HapticFeedback.lightImpact();
    setState(() => _flagged[i] = !_flagged[i]);
  }

  void _lose() {
    _clock?.cancel();
    _over = true;
    _won = false;
    for (int i = 0; i < _mine.length; i++) {
      if (_mine[i]) _revealed[i] = true;
    }
    setState(() {});
  }

  void _checkWin() {
    final safeLeft = [
      for (int i = 0; i < _mine.length; i++)
        if (!_mine[i] && !_revealed[i]) i,
    ];
    if (safeLeft.isNotEmpty) return;
    _clock?.cancel();
    _over = true;
    _won = true;
    for (int i = 0; i < _mine.length; i++) {
      if (_mine[i]) _flagged[i] = true;
    }
    GameScores.submitLowest('mines', _seconds).then((newBest) {
      if (newBest && mounted) setState(() => _bestTime = _seconds);
    });
  }

  String _fmt(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final flagsLeft = mineCount - _flagged.where((f) => f).length;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        title: const Text('Mines'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'New game',
            onPressed: _reset,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _StatChip(
                  icon: Icons.flag_outlined,
                  label: '$flagsLeft',
                  color: const Color(0xFFEF4444),
                ),
                if (_over)
                  Text(
                    _won ? 'Cleared!' : 'Boom.',
                    style: TextStyle(
                      color: _won ? AppTheme.success : AppTheme.error,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                _StatChip(
                  icon: Icons.timer_outlined,
                  label: _fmt(_seconds) +
                      (_bestTime != null
                          ? '  ·  best ${_fmt(_bestTime!)}'
                          : ''),
                  color: AppTheme.textSecondary,
                ),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FittedBox(
                  child: SizedBox(
                    width: cols * _cell,
                    height: rows * _cell,
                    child: Column(
                      children: [
                        for (int y = 0; y < rows; y++)
                          Row(
                            children: [
                              for (int x = 0; x < cols; x++)
                                _buildCell(y * cols + x),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_over)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: FilledButton(
                onPressed: _reset,
                child: Text(_won ? 'Play again' : 'Try again'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCell(int i) {
    final revealed = _revealed[i];
    final flagged = _flagged[i];
    final mine = _mine[i];
    final n = _minesPlaced && revealed && !mine ? _count(i) : 0;

    Widget? child;
    if (revealed && mine) {
      child = Icon(Icons.circle,
          size: 16, color: _won ? AppTheme.success : AppTheme.error);
    } else if (flagged) {
      child = const Icon(Icons.flag,
          size: 18, color: Color(0xFFEF4444));
    } else if (revealed && n > 0) {
      child = Text(
        '$n',
        style: TextStyle(
          color: _numberColors[n],
          fontSize: 17,
          fontWeight: FontWeight.w700,
        ),
      );
    }

    return GestureDetector(
      onTap: () => _reveal(i),
      onLongPress: () => _toggleFlag(i),
      child: Container(
        width: _cell,
        height: _cell,
        padding: const EdgeInsets.all(1.5),
        child: Container(
          decoration: BoxDecoration(
            color: revealed
                ? (mine
                    ? AppTheme.error.withValues(alpha: 0.15)
                    : AppTheme.bg)
                : AppTheme.surface3,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: revealed ? AppTheme.borderSubtle : AppTheme.borderMid,
            ),
          ),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _StatChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
