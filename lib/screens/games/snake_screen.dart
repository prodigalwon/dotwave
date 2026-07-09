import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../theme.dart';
import 'game_scores.dart';

/// Snake. Swipe anywhere on the board to steer; the first swipe starts the
/// run. Speed ramps with every apple eaten.
class SnakeScreen extends StatefulWidget {
  const SnakeScreen({super.key});

  @override
  State<SnakeScreen> createState() => _SnakeScreenState();
}

class _SnakeScreenState extends State<SnakeScreen> {
  static const cols = 15;
  static const rows = 22;

  final _rng = Random();
  List<Point<int>> _snake = [];
  Point<int> _food = const Point(0, 0);
  Point<int> _dir = const Point(0, -1);
  Point<int>? _queued;
  Timer? _timer;
  Offset _drag = Offset.zero;

  int _score = 0;
  int? _best;
  bool _running = false;
  bool _over = false;

  @override
  void initState() {
    super.initState();
    GameScores.read('snake').then((v) {
      if (mounted) setState(() => _best = v);
    });
    _reset();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _reset() {
    _timer?.cancel();
    _snake = [
      for (int i = 0; i < 4; i++) Point(cols ~/ 2, rows ~/ 2 + i),
    ];
    _dir = const Point(0, -1);
    _queued = null;
    _score = 0;
    _running = false;
    _over = false;
    _spawnFood();
    setState(() {});
  }

  Duration get _tickInterval =>
      Duration(milliseconds: max(80, 210 - _score * 4));

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_tickInterval, (_) => _tick());
  }

  void _spawnFood() {
    final empty = <Point<int>>[
      for (int x = 0; x < cols; x++)
        for (int y = 0; y < rows; y++)
          if (!_snake.contains(Point(x, y))) Point(x, y),
    ];
    if (empty.isEmpty) return; // board full: player has effectively won
    _food = empty[_rng.nextInt(empty.length)];
  }

  void _tick() {
    if (_queued != null) {
      // Drop a queued reversal instead of applying it: it can slip in when
      // two swipes land between ticks.
      if (_queued! + _dir != const Point(0, 0)) _dir = _queued!;
      _queued = null;
    }
    final head = _snake.first + _dir;
    // The tail cell is vacated this same tick, so it does not count as a
    // self-collision target.
    final body = _snake.sublist(0, _snake.length - 1);
    if (head.x < 0 ||
        head.x >= cols ||
        head.y < 0 ||
        head.y >= rows ||
        body.contains(head)) {
      _gameOver();
      return;
    }
    _snake.insert(0, head);
    if (head == _food) {
      _score++;
      _spawnFood();
      _startTimer(); // re-arm at the new, faster interval
    } else {
      _snake.removeLast();
    }
    setState(() {});
  }

  void _gameOver() {
    _timer?.cancel();
    _running = false;
    _over = true;
    GameScores.submitHighest('snake', _score).then((newBest) {
      if (newBest && mounted) setState(() => _best = _score);
    });
    setState(() {});
  }

  void _onSwipe(Point<int> nd) {
    final current = _queued ?? _dir;
    if (nd + current == const Point(0, 0)) return; // no reversing
    _queued = nd;
    if (!_running && !_over) {
      _running = true;
      _startTimer();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final bestLabel = _best == null ? '' : '   Best $_best';
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        title: const Text('Snake'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                'Score $_score$bestLabel',
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: AspectRatio(
            aspectRatio: cols / rows,
            child: GestureDetector(
              key: const ValueKey('board-snake'),
              onPanStart: (_) => _drag = Offset.zero,
              onPanUpdate: (d) {
                _drag += d.delta;
                if (_drag.distance < 14) return;
                final horizontal = _drag.dx.abs() > _drag.dy.abs();
                final nd = horizontal
                    ? Point<int>(_drag.dx > 0 ? 1 : -1, 0)
                    : Point<int>(0, _drag.dy > 0 ? 1 : -1);
                _drag = Offset.zero;
                _onSwipe(nd);
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppTheme.surface1,
                        border: Border.all(color: AppTheme.borderSubtle),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: CustomPaint(
                        painter: _SnakePainter(
                          snake: _snake,
                          food: _food,
                          accent: AppTheme.accent,
                        ),
                      ),
                    ),
                  ),
                  if (!_running && !_over)
                    const _BoardOverlay(
                      title: 'Swipe to start',
                      subtitle: 'Swipe up, down, left or right to steer',
                    ),
                  if (_over)
                    _BoardOverlay(
                      title: 'Game over',
                      subtitle: 'Score $_score'
                          '${_best != null ? '  ·  Best $_best' : ''}',
                      action: FilledButton(
                        onPressed: _reset,
                        child: const Text('Play again'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BoardOverlay extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? action;

  const _BoardOverlay({
    required this.title,
    required this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        color: Colors.black.withValues(alpha: 0.55),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[
              const SizedBox(height: 20),
              SizedBox(width: 180, child: action),
            ],
          ],
        ),
      ),
    );
  }
}

class _SnakePainter extends CustomPainter {
  final List<Point<int>> snake;
  final Point<int> food;
  final Color accent;

  _SnakePainter({
    required this.snake,
    required this.food,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cw = size.width / _SnakeScreenState.cols;
    final ch = size.height / _SnakeScreenState.rows;

    // Food.
    final foodCenter =
        Offset((food.x + 0.5) * cw, (food.y + 0.5) * ch);
    canvas.drawCircle(
      foodCenter,
      min(cw, ch) * 0.32,
      Paint()..color = const Color(0xFFEF4444),
    );

    // Snake: head brightest, tail fades.
    for (int i = 0; i < snake.length; i++) {
      final s = snake[i];
      final t = snake.length == 1 ? 0.0 : i / (snake.length - 1);
      final paint = Paint()
        ..color = Color.lerp(accent, accent.withValues(alpha: 0.35), t)!;
      final rect = Rect.fromLTWH(s.x * cw, s.y * ch, cw, ch).deflate(1);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(min(cw, ch) * 0.28)),
        paint,
      );
    }
  }

  // The snake list is mutated in place between frames, so an identity
  // comparison would suppress every repaint. The board is tiny; just repaint.
  @override
  bool shouldRepaint(covariant _SnakePainter old) => true;
}
