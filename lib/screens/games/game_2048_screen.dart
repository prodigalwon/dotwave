import 'dart:math';

import 'package:flutter/material.dart';

import '../../theme.dart';
import 'game_scores.dart';

/// Slides one line toward index 0, merging adjacent equal pairs once each.
/// Returns the collapsed line (padded back to the input length) and the
/// merge score gained.
@visibleForTesting
(List<int>, int) collapse2048Line(List<int> line) {
  final tiles = [
    for (final v in line)
      if (v != 0) v,
  ];
  final out = <int>[];
  int gained = 0;
  for (int i = 0; i < tiles.length; i++) {
    if (i + 1 < tiles.length && tiles[i] == tiles[i + 1]) {
      out.add(tiles[i] * 2);
      gained += tiles[i] * 2;
      i++;
    } else {
      out.add(tiles[i]);
    }
  }
  while (out.length < line.length) {
    out.add(0);
  }
  return (out, gained);
}

/// 2048. Swipe to slide the whole board; equal tiles merge. The mechanic is
/// public-domain-simple and this implementation is entirely original code.
class Game2048Screen extends StatefulWidget {
  const Game2048Screen({super.key});

  @override
  State<Game2048Screen> createState() => _Game2048ScreenState();
}

class _Game2048ScreenState extends State<Game2048Screen> {
  static const n = 4;

  final _rng = Random();
  late List<int> _board; // row-major n*n, 0 = empty
  int _score = 0;
  int _best = 0;
  bool _over = false;
  bool _wonShown = false;
  int _generation = 0; // bumps every spawn, keys the pop-in animation
  int _lastSpawn = -1;

  @override
  void initState() {
    super.initState();
    GameScores.read('2048').then((v) {
      if (mounted) setState(() => _best = max(_best, v ?? 0));
    });
    _reset();
  }

  @override
  void dispose() {
    // Persist a run abandoned mid-game (back button) if it set a record.
    GameScores.submitHighest('2048', _score);
    super.dispose();
  }

  void _reset() {
    _board = List.filled(n * n, 0);
    _score = 0;
    _over = false;
    _wonShown = false;
    _spawn();
    _spawn();
    setState(() {});
  }

  void _spawn() {
    final empty = [
      for (int i = 0; i < n * n; i++)
        if (_board[i] == 0) i,
    ];
    if (empty.isEmpty) return;
    final i = empty[_rng.nextInt(empty.length)];
    _board[i] = _rng.nextInt(10) == 0 ? 4 : 2;
    _lastSpawn = i;
    _generation++;
  }

  void _move({required bool horizontal, required bool forward}) {
    if (_over) return;
    bool moved = false;
    int gained = 0;

    for (int i = 0; i < n; i++) {
      final idx = [
        for (int j = 0; j < n; j++) horizontal ? i * n + j : j * n + i,
      ];
      if (forward) {
        // Sliding right/down = collapse toward the high index.
        idx.setAll(0, idx.reversed.toList());
      }
      final line = [for (final k in idx) _board[k]];
      final (out, g) = collapse2048Line(line);
      gained += g;
      for (int j = 0; j < n; j++) {
        if (_board[idx[j]] != out[j]) {
          moved = true;
          _board[idx[j]] = out[j];
        }
      }
    }

    if (!moved) return;
    _score += gained;
    _spawn();

    if (!_wonShown && _board.contains(2048)) {
      _wonShown = true;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('2048! Keep going for a high score.')),
      );
    }
    if (!_hasMoves()) {
      _over = true;
      GameScores.submitHighest('2048', _score);
    }
    if (_score > _best) _best = _score;
    setState(() {});
  }

  bool _hasMoves() {
    for (int y = 0; y < n; y++) {
      for (int x = 0; x < n; x++) {
        final v = _board[y * n + x];
        if (v == 0) return true;
        if (x + 1 < n && _board[y * n + x + 1] == v) return true;
        if (y + 1 < n && _board[(y + 1) * n + x] == v) return true;
      }
    }
    return false;
  }

  static const _tileColors = <int, Color>{
    2: Color(0xFF262626),
    4: Color(0xFF35301F),
    8: Color(0xFF8A5A16),
    16: Color(0xFFA85F1A),
    32: Color(0xFFC2571E),
    64: Color(0xFFD43D1C),
    128: Color(0xFFB08C1E),
    256: Color(0xFFC29A18),
    512: Color(0xFFD4A511),
    1024: Color(0xFFE3B008),
    2048: Color(0xFFF2A93B),
  };

  Color _tileColor(int v) =>
      _tileColors[v] ?? const Color(0xFF7C3AED); // 4096+ goes violet

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        title: const Text('2048'),
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
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Row(
              children: [
                _ScoreBox(label: 'SCORE', value: _score),
                const SizedBox(width: 10),
                _ScoreBox(label: 'BEST', value: _best),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: GestureDetector(
                    key: const ValueKey('board-2048'),
                    onHorizontalDragEnd: (d) {
                      final v = d.primaryVelocity ?? 0;
                      if (v.abs() < 100) return;
                      _move(horizontal: true, forward: v > 0);
                    },
                    onVerticalDragEnd: (d) {
                      final v = d.primaryVelocity ?? 0;
                      if (v.abs() < 100) return;
                      _move(horizontal: false, forward: v > 0);
                    },
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppTheme.surface1,
                            borderRadius: BorderRadius.circular(16),
                            border:
                                Border.all(color: AppTheme.borderSubtle),
                          ),
                          child: Column(
                            children: [
                              for (int y = 0; y < n; y++)
                                Expanded(
                                  child: Row(
                                    children: [
                                      for (int x = 0; x < n; x++)
                                        Expanded(
                                          child: _buildTile(y * n + x),
                                        ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (_over)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Container(
                              color: Colors.black.withValues(alpha: 0.55),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    'No more moves',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Score $_score',
                                    style: const TextStyle(
                                        color: AppTheme.textSecondary,
                                        fontSize: 13),
                                  ),
                                  const SizedBox(height: 20),
                                  SizedBox(
                                    width: 180,
                                    child: FilledButton(
                                      onPressed: _reset,
                                      child: const Text('Play again'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTile(int i) {
    final v = _board[i];
    final tile = Container(
      margin: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: v == 0 ? AppTheme.surface2 : _tileColor(v),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: v == 0
          ? null
          : FittedBox(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  '$v',
                  style: TextStyle(
                    color: v <= 4 ? AppTheme.textSecondary : Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
    );
    if (i != _lastSpawn || v == 0) return tile;
    // Pop-in for the freshly spawned tile; keyed by generation so the same
    // cell re-animates when re-spawned later.
    return TweenAnimationBuilder<double>(
      key: ValueKey(_generation),
      tween: Tween(begin: 0.4, end: 1.0),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutBack,
      builder: (_, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: tile,
    );
  }
}

class _ScoreBox extends StatelessWidget {
  final String label;
  final int value;
  const _ScoreBox({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.surface1,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderSubtle),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: AppTheme.textTertiary,
                fontSize: 10,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '$value',
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
