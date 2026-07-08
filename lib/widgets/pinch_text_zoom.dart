import 'package:flutter/widgets.dart';

import '../services/text_scale_controller.dart';

/// Root wrapper that turns a two-finger pinch ANYWHERE in the app into a live
/// text-scale change, without stealing single-finger gestures.
///
/// It uses a passive [Listener] (raw pointer events that never join the
/// gesture arena), so taps, scrolls and drags pass straight through to the
/// widgets below untouched. Only when exactly two pointers are down does it
/// treat the change in their separation as a zoom, driving
/// [TextScaleController].
///
/// On release: inside a chat thread the size is persisted; everywhere else it
/// springs back to the baseline with an animated overshoot-and-settle bounce.
class PinchTextZoom extends StatefulWidget {
  final Widget child;
  const PinchTextZoom({super.key, required this.child});

  @override
  State<PinchTextZoom> createState() => _PinchTextZoomState();
}

class _PinchTextZoomState extends State<PinchTextZoom>
    with SingleTickerProviderStateMixin {
  final Map<int, Offset> _pointers = {};
  double? _startDist;
  double _startScale = 1.0;

  late final AnimationController _spring;
  double _springFrom = TextScaleController.baseline;

  @override
  void initState() {
    super.initState();
    _spring = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    )..addListener(() {
        // easeOutBack overshoots the target then settles — the "bounce back"
        // feel of a modern rubber-band zoom.
        final t = Curves.easeOutBack.transform(_spring.value);
        final v = _springFrom +
            (TextScaleController.baseline - _springFrom) * t;
        TextScaleController.instance.driveScale(v);
      });
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  void _beginPinch() {
    _spring.stop(); // interrupt any in-flight spring-back
    final p = _pointers.values.toList();
    _startDist = (p[0] - p[1]).distance;
    // Anchor to the CURRENT live scale so re-grabbing mid-bounce is seamless.
    _startScale = TextScaleController.instance.scale;
  }

  void _onDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) _beginPinch();
  }

  void _onMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2 && _startDist != null && _startDist! > 0) {
      final p = _pointers.values.toList();
      final dist = (p[0] - p[1]).distance;
      TextScaleController.instance.pinchTo(_startScale * dist / _startDist!);
    }
  }

  void _onEnd(int pointer) {
    if (!_pointers.containsKey(pointer)) return;
    final wasPinching = _pointers.length == 2;
    _pointers.remove(pointer);
    if (_pointers.length < 2 && wasPinching) {
      _startDist = null;
      if (TextScaleController.instance.inChat) {
        // Persistent: keep the size the user set.
        TextScaleController.instance.commitChat();
      } else {
        // Elastic: spring back to the baseline.
        _springFrom = TextScaleController.instance.scale;
        _spring.forward(from: 0);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: (e) => _onEnd(e.pointer),
      onPointerCancel: (e) => _onEnd(e.pointer),
      child: widget.child,
    );
  }
}
