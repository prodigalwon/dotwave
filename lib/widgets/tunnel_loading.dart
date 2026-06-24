import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Full-screen loading animation: flying through the concentric rings
/// of the dotwave logo as if down a tunnel at night. Matches the
/// three-layer structure and palette of `assets/dotwave-tight.svg` —
/// outer wine, mid red, inner three-eyes-glowing / three-shadow.
///
/// Faithful Dart port of the 3 KB HTML/Canvas source animation. Zero
/// dependencies beyond Flutter's built-ins (`Ticker` + `CustomPainter`).
/// Do **not** use this for tiny inline spinners — it's intentionally a
/// full-page experience for operations heavy enough that the whole
/// screen needs to hold while something completes. Drop it in as:
///
/// ```dart
/// if (_busy) return const TunnelLoading();
/// ```
///
/// or push it as a full-screen `MaterialPageRoute` during a transition
/// that can't yield an intermediate UI.
class TunnelLoading extends StatefulWidget {
  const TunnelLoading({super.key});

  @override
  State<TunnelLoading> createState() => _TunnelLoadingState();
}

class _TunnelLoadingState extends State<TunnelLoading>
    with SingleTickerProviderStateMixin {
  // ── Animation constants (mirror the JS source verbatim) ─────────
  static const double _fov = 400;
  static const double _gap = 1400;
  static const double _maxSpd = 9;
  static const double _accel = 0.01;
  static const double _killZ = -9000;
  static const List<_Sub> _subs = [_Sub.outer, _Sub.mid, _Sub.inner];

  // ── Per-frame state ─────────────────────────────────────────────
  final List<_Ring> _rings = [];
  double _speed = 1.8;
  int _counter = 0;
  double _nextZ = 400;

  // Painter listens to this notifier instead of the whole widget
  // rebuilding each frame — CustomPainter's `repaint` constructor
  // argument triggers a repaint without going through `setState`.
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < 10; i++) _spawn();
    _ticker = createTicker(_tick)..start();
  }

  void _spawn() {
    _rings.add(_Ring(z: _nextZ, sub: _subs[_counter % 3]));
    _counter++;
    _nextZ += _gap;
  }

  void _tick(Duration elapsed) {
    _speed = math.min(_maxSpd, _speed + _accel);
    for (final r in _rings) {
      r.z -= _speed;
    }
    _rings.removeWhere((r) => r.z < _killZ);

    final mz = _rings.isNotEmpty
        ? _rings.map((r) => r.z).reduce(math.max)
        : _nextZ;
    while (_nextZ - mz < _gap * 4) {
      _spawn();
    }
    _frame.value++;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: SizedBox.expand(
        child: CustomPaint(
          painter: _TunnelPainter(_rings, _frame),
        ),
      ),
    );
  }
}

enum _Sub { outer, mid, inner }

class _Ring {
  double z;
  final _Sub sub;
  _Ring({required this.z, required this.sub});
}

class _TunnelPainter extends CustomPainter {
  final List<_Ring> rings;
  _TunnelPainter(this.rings, Listenable repaint) : super(repaint: repaint);

  static const double _fov = 400;

  // Colors from the source SVG / HTML animation.
  static const Color _outerWine = Color(0xFF8B0000);
  static const Color _midRed = Color(0xFFD10000);
  static const Color _innerShadow = Color(0xFF5A0000);
  static const Color _innerEye = Color(0xFFFFFFFF);
  static const Color _eyeGlow = Color(0xFFFF3300);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Depth-sort back-to-front so the nearest ring paints last and
    // visually occludes the farther ones (standard painter's algo).
    final sorted = [...rings]..sort((a, b) => b.z.compareTo(a.z));
    for (final r in sorted) {
      _drawRing(canvas, cx, cy, r);
    }
  }

  void _drawRing(Canvas canvas, double cx, double cy, _Ring r) {
    final ez = math.max(-_fov * 0.98, r.z);
    final s = _fov / (_fov + ez);
    final alpha = r.z > 800 ? math.min(1.0, 1.0 - (r.z - 800) / 3000) : 1.0;
    if (alpha <= 0) return;

    // v2 animation: all three ring subtypes share the same radius
    // and oval geometry. Only the color and the per-subtype rotation
    // phase offset differ. The uniformity gives a cleaner tunnel
    // and lets the 30° twist between outer/mid read clearly.
    final rad = 90 * s;
    final rw = 26 * s;
    final rh = 11 * s;

    switch (r.sub) {
      case _Sub.outer:
        for (var i = 0; i < 6; i++) {
          if (i == 3) continue; // omit the 180° (bottom) oval
          final a = (i / 6) * math.pi * 2;
          _oval(canvas, cx + math.sin(a) * rad, cy - math.cos(a) * rad,
              rw, rh, a, _outerWine, alpha, glow: false);
        }
      case _Sub.mid:
        for (var i = 0; i < 6; i++) {
          final a = (i / 6) * math.pi * 2 + math.pi / 6; // 30° phase
          _oval(canvas, cx + math.sin(a) * rad, cy - math.cos(a) * rad,
              rw, rh, a, _midRed, alpha, glow: false);
        }
      case _Sub.inner:
        // bottom three: shadow ovals (dim wine)
        for (final i in const [2, 3, 4]) {
          final a = (i / 6) * math.pi * 2;
          _oval(canvas, cx + math.sin(a) * rad, cy - math.cos(a) * rad,
              rw, rh, a, _innerShadow, alpha, glow: false);
        }
        // top three: white-hot eyes with red-orange glow
        for (final i in const [0, 1, 5]) {
          final a = (i / 6) * math.pi * 2;
          _oval(canvas, cx + math.sin(a) * rad, cy - math.cos(a) * rad,
              rw, rh, a, _innerEye, alpha, glow: true);
        }
    }
  }

  /// Rotated, alpha-blended ellipse. When [glow] is true, draws a
  /// red-orange blurred underlayer first (emulating Canvas 2D's
  /// `shadowColor` + `shadowBlur = 14` from the HTML source) then
  /// the opaque white ellipse on top.
  void _oval(
    Canvas canvas,
    double x,
    double y,
    double rx,
    double ry,
    double ang,
    Color color,
    double alpha, {
    required bool glow,
  }) {
    if (rx < 0.5 || ry < 0.5 || alpha <= 0) return;
    canvas.save();
    canvas.translate(x, y);
    canvas.rotate(ang);
    final a = math.min(1.0, alpha);

    if (glow) {
      final glowPaint = Paint()
        ..color = _eyeGlow.withOpacity(a)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: rx * 2 + 8,
          height: ry * 2 + 8,
        ),
        glowPaint,
      );
    }

    final paint = Paint()..color = color.withOpacity(a);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2),
      paint,
    );
    canvas.restore();
  }

  // Listenable in the constructor drives repaints — Flutter calls
  // paint() whenever the notifier fires and `shouldRepaint` can stay
  // false.
  @override
  bool shouldRepaint(covariant _TunnelPainter oldDelegate) => false;
}
