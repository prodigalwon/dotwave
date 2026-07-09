import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme.dart';
import 'game_scores.dart';

/// Bricks. Drag anywhere to move the paddle, tap to launch. Clearing the
/// wall advances the level and speeds the ball up.
class BricksScreen extends StatefulWidget {
  const BricksScreen({super.key});

  @override
  State<BricksScreen> createState() => _BricksScreenState();
}

class _BricksScreenState extends State<BricksScreen>
    with SingleTickerProviderStateMixin {
  static const bRows = 5;
  static const bCols = 7;
  static const _rowColors = [
    Color(0xFFEF4444),
    Color(0xFFF97316),
    Color(0xFFEAB308),
    Color(0xFF22C55E),
    Color(0xFF0EA5E9),
  ];

  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  Size _size = Size.zero;
  double _paddleX = -1; // sentinel: centered on first layout
  Offset _ball = Offset.zero;
  Offset _vel = Offset.zero;
  late List<bool> _alive;

  int _score = 0;
  int? _best;
  int _lives = 3;
  int _level = 1;
  bool _launched = false;
  bool _over = false;

  // ── Geometry (derived from the current board size) ──
  double get _brickTop => _size.height * 0.06;
  double get _brickH => _size.height * 0.045;
  double get _paddleY => _size.height * 0.92;
  double get _paddleW => _size.width * 0.24;
  static const _paddleH = 12.0;
  static const _radius = 7.0;
  static const _brickGap = 4.0;

  double get _speed => min(640, 340 + 45.0 * (_level - 1));

  @override
  void initState() {
    super.initState();
    _alive = List.filled(bRows * bCols, true);
    _ticker = createTicker(_onTick);
    GameScores.read('bricks').then((v) {
      if (mounted) setState(() => _best = v);
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Rect _brickRect(int i) {
    final row = i ~/ bCols, col = i % bCols;
    final bw = (_size.width - _brickGap * (bCols + 1)) / bCols;
    return Rect.fromLTWH(
      _brickGap + col * (bw + _brickGap),
      _brickTop + row * (_brickH + _brickGap),
      bw,
      _brickH,
    );
  }

  void _layoutChanged(Size size) {
    _size = size;
    if (_paddleX < 0) _paddleX = size.width / 2;
    _paddleX = _paddleX.clamp(_paddleW / 2, size.width - _paddleW / 2);
    if (!_launched) _restBallOnPaddle();
  }

  void _restBallOnPaddle() {
    _ball = Offset(_paddleX, _paddleY - _radius - 1);
  }

  void _launch() {
    if (_launched || _over || _size == Size.zero) return;
    _launched = true;
    _vel = Offset(_speed * 0.35, -_speed * 0.85);
    _lastElapsed = Duration.zero;
    _ticker.start();
    setState(() {});
  }

  void _onTick(Duration elapsed) {
    final dt = min(
      (elapsed - _lastElapsed).inMicroseconds / 1e6,
      0.032,
    );
    _lastElapsed = elapsed;
    if (!_launched || _over || dt <= 0) return;

    var p = _ball + _vel * dt;

    // Walls.
    if (p.dx - _radius < 0) {
      p = Offset(_radius, p.dy);
      _vel = Offset(_vel.dx.abs(), _vel.dy);
    } else if (p.dx + _radius > _size.width) {
      p = Offset(_size.width - _radius, p.dy);
      _vel = Offset(-_vel.dx.abs(), _vel.dy);
    }
    if (p.dy - _radius < 0) {
      p = Offset(p.dx, _radius);
      _vel = Offset(_vel.dx, _vel.dy.abs());
    }

    // Paddle.
    if (_vel.dy > 0 &&
        p.dy + _radius >= _paddleY &&
        p.dy + _radius <= _paddleY + _paddleH + _radius &&
        (p.dx - _paddleX).abs() <= _paddleW / 2 + _radius) {
      // Bounce angle follows where the ball hits the paddle.
      final offset = ((p.dx - _paddleX) / (_paddleW / 2)).clamp(-1.0, 1.0);
      final angle = offset * (pi / 3); // up to 60 degrees off vertical
      _vel = Offset(_speed * sin(angle), -_speed * cos(angle));
      p = Offset(p.dx, _paddleY - _radius - 0.5);
    }

    // Bottom: life lost.
    if (p.dy - _radius > _size.height) {
      _lives--;
      _launched = false;
      _ticker.stop();
      if (_lives <= 0) {
        _over = true;
        GameScores.submitHighest('bricks', _score).then((newBest) {
          if (newBest && mounted) setState(() => _best = _score);
        });
      } else {
        _restBallOnPaddle();
      }
      setState(() {});
      return;
    }

    // Bricks: kill at most one per frame, reflect off the shallow axis.
    for (int i = 0; i < _alive.length; i++) {
      if (!_alive[i]) continue;
      final r = _brickRect(i).inflate(_radius);
      if (!r.contains(p)) continue;
      _alive[i] = false;
      _score += 10;
      final fromLeft = (p.dx - r.left).abs();
      final fromRight = (r.right - p.dx).abs();
      final fromTop = (p.dy - r.top).abs();
      final fromBottom = (r.bottom - p.dy).abs();
      final minX = min(fromLeft, fromRight);
      final minY = min(fromTop, fromBottom);
      if (minX < minY) {
        _vel = Offset(fromLeft < fromRight ? -_vel.dx.abs() : _vel.dx.abs(),
            _vel.dy);
      } else {
        _vel = Offset(_vel.dx,
            fromTop < fromBottom ? -_vel.dy.abs() : _vel.dy.abs());
      }
      break;
    }

    _ball = p;

    if (!_alive.contains(true)) {
      _level++;
      _score += 50;
      _alive = List.filled(bRows * bCols, true);
      _launched = false;
      _ticker.stop();
      _restBallOnPaddle();
    }

    setState(() {});
  }

  void _reset() {
    _ticker.stop();
    _alive = List.filled(bRows * bCols, true);
    _score = 0;
    _lives = 3;
    _level = 1;
    _launched = false;
    _over = false;
    _paddleX = _size == Size.zero ? -1 : _size.width / 2;
    if (_size != Size.zero) _restBallOnPaddle();
    setState(() {});
  }

  void _dragPaddle(double dx) {
    if (_over || _size == Size.zero) return;
    _paddleX =
        (_paddleX + dx).clamp(_paddleW / 2, _size.width - _paddleW / 2);
    if (!_launched) _restBallOnPaddle();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final bestLabel = _best == null ? '' : '   Best $_best';
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        title: const Text('Bricks'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Row(
                children: [
                  Text(
                    'Lv $_level   Score $_score$bestLabel   ',
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 13),
                  ),
                  for (int i = 0; i < 3; i++)
                    Icon(
                      i < _lives ? Icons.favorite : Icons.favorite_border,
                      size: 14,
                      color: i < _lives
                          ? const Color(0xFFEF4444)
                          : AppTheme.textDisabled,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: GestureDetector(
          key: const ValueKey('board-bricks'),
          onTap: _launch,
          onHorizontalDragUpdate: (d) => _dragPaddle(d.delta.dx),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.surface1,
                border: Border.all(color: AppTheme.borderSubtle),
                borderRadius: BorderRadius.circular(16),
              ),
              child: LayoutBuilder(
                builder: (context, c) {
                  final size = Size(c.maxWidth, c.maxHeight);
                  if (_size != size) _layoutChanged(size);
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      CustomPaint(
                        painter: _BricksPainter(
                          alive: _alive,
                          brickRect: _brickRect,
                          rowColors: _rowColors,
                          ball: _ball,
                          radius: _radius,
                          paddle: Rect.fromCenter(
                            center: Offset(
                                _paddleX, _paddleY + _paddleH / 2),
                            width: _paddleW,
                            height: _paddleH,
                          ),
                          accent: AppTheme.accent,
                        ),
                      ),
                      if (!_launched && !_over)
                        const IgnorePointer(
                          child: Center(
                            child: Text(
                              'Tap to launch',
                              style: TextStyle(
                                  color: AppTheme.textTertiary,
                                  fontSize: 14),
                            ),
                          ),
                        ),
                      if (_over)
                        Container(
                          color: Colors.black.withValues(alpha: 0.55),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                'Game over',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Score $_score'
                                '${_best != null ? '  ·  Best $_best' : ''}',
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
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BricksPainter extends CustomPainter {
  final List<bool> alive;
  final Rect Function(int) brickRect;
  final List<Color> rowColors;
  final Offset ball;
  final double radius;
  final Rect paddle;
  final Color accent;

  _BricksPainter({
    required this.alive,
    required this.brickRect,
    required this.rowColors,
    required this.ball,
    required this.radius,
    required this.paddle,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (int i = 0; i < alive.length; i++) {
      if (!alive[i]) continue;
      paint.color = rowColors[(i ~/ _BricksScreenState.bCols) %
          rowColors.length];
      canvas.drawRRect(
        RRect.fromRectAndRadius(brickRect(i), const Radius.circular(4)),
        paint,
      );
    }
    paint.color = accent;
    canvas.drawRRect(
      RRect.fromRectAndRadius(paddle, const Radius.circular(6)),
      paint,
    );
    paint.color = Colors.white;
    canvas.drawCircle(ball, radius, paint);
  }

  // Mutable game state is shared with the screen; repaint every frame.
  @override
  bool shouldRepaint(covariant _BricksPainter old) => true;
}
