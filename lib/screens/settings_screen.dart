import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/theme_controller.dart';
import '../theme.dart';

/// App settings. Today: Theme — a Dark/Light toggle (light mode not wired yet)
/// and the brand-colour picker: a horizontal row of tilted, rope-bordered oval
/// swatches plus a shade slider. Selecting a swatch re-skins the app instantly.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _dark = true; // cosmetic for now — light mode isn't implemented yet
  int _selected = 0;
  double _shade = 0.5; // 0 = darkest … 0.5 = base … 1 = lightest

  @override
  void initState() {
    super.initState();
    final cur = AppTheme.accent.toARGB32();
    final idx =
        AppTheme.palette.indexWhere((e) => e.color.toARGB32() == cur);
    _selected = idx < 0 ? 0 : idx;
  }

  /// Shift a colour's lightness by the slider (0.5 = unchanged, ±0.25 at ends).
  Color _shaded(Color c, double shade) {
    final h = HSLColor.fromColor(c);
    return h
        .withLightness((h.lightness + (shade - 0.5) * 0.5).clamp(0.0, 1.0))
        .toColor();
  }

  void _select(int i) {
    setState(() {
      _selected = i;
      _shade = 0.5;
    });
    ThemeController.instance.setAccent(AppTheme.palette[i].color);
  }

  void _slide(double v) {
    setState(() => _shade = v);
    ThemeController.instance
        .setAccent(_shaded(AppTheme.palette[_selected].color, v));
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: const Text('Settings')),
      body: AnimatedBuilder(
        animation: ThemeController.instance,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Text('THEME', style: tt.labelMedium),
            const SizedBox(height: 4),

            // Appearance toggle (first). Light mode is a placeholder for now.
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _dark,
              activeThumbColor: AppTheme.accent,
              secondary: Icon(
                  _dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined),
              title: Text(_dark ? 'Dark mode' : 'Light mode'),
              subtitle: const Text('Light mode coming soon'),
              onChanged: (v) {
                setState(() => _dark = true);
                if (!v) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Light mode is coming soon')),
                  );
                }
              },
            ),

            const SizedBox(height: 20),
            Text('Color', style: tt.titleMedium),
            const SizedBox(height: 16),

            // Tilted, rope-bordered oval swatches — drag to reach the rest.
            SizedBox(
              height: 84,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: AppTheme.palette.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => GestureDetector(
                  onTap: () => _select(i),
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    width: 74,
                    child: Center(
                      child: Transform.rotate(
                        angle: -math.pi / 6, // 30° counter-clockwise
                        child: CustomPaint(
                          size: const Size(58, 40),
                          painter: _RopeOvalPainter(
                            color: AppTheme.palette[i].color,
                            selected: i == _selected,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),
            // Shade slider for the selected colour.
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: AppTheme.accent,
                thumbColor: AppTheme.accent,
                inactiveTrackColor: AppTheme.surface3,
                overlayColor: AppTheme.accentGlow,
              ),
              child: Slider(value: _shade, onChanged: _slide),
            ),
          ],
        ),
      ),
    );
  }
}

/// Paints a tilted oval swatch with a rope-textured white margin. When
/// [selected] the colour fill darkens as a "pressed" cue.
class _RopeOvalPainter extends CustomPainter {
  final Color color;
  final bool selected;
  _RopeOvalPainter({required this.color, required this.selected});

  @override
  void paint(Canvas canvas, Size size) {
    const margin = 7.0;
    final rect = Offset.zero & size;
    final inner = rect.deflate(margin);

    final fill = selected ? _darken(color, 0.16) : color;

    // White margin ring + colour fill.
    canvas.drawOval(rect, Paint()..color = Colors.white);
    canvas.drawOval(inner, Paint()..color = fill);

    // Rope twist: short diagonal ticks around the mid-ring — a dark strand and
    // an offset light strand read as a twisted rope.
    final cx = size.width / 2, cy = size.height / 2;
    final rx = (size.width - margin) / 2, ry = (size.height - margin) / 2;
    const n = 30;
    final dark = Paint()
      ..color = Colors.black.withValues(alpha: 0.22)
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round;
    final light = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < n; i++) {
      _tick(canvas, cx, cy, rx, ry, 2 * math.pi * i / n, margin * 0.95, dark);
      _tick(canvas, cx, cy, rx, ry, 2 * math.pi * (i + 0.5) / n, margin * 0.7,
          light);
    }
  }

  void _tick(Canvas canvas, double cx, double cy, double rx, double ry,
      double a, double len, Paint p) {
    final px = cx + rx * math.cos(a), py = cy + ry * math.sin(a);
    final dir = a + math.pi / 3; // ~60° off radial → diagonal twist
    final dx = math.cos(dir) * len / 2, dy = math.sin(dir) * len / 2;
    canvas.drawLine(Offset(px - dx, py - dy), Offset(px + dx, py + dy), p);
  }

  static Color _darken(Color c, double amt) {
    final h = HSLColor.fromColor(c);
    return h.withLightness((h.lightness - amt).clamp(0.0, 1.0)).toColor();
  }

  @override
  bool shouldRepaint(_RopeOvalPainter o) =>
      o.color != color || o.selected != selected;
}
