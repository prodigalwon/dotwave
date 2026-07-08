import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// App-wide text zoom.
///
/// The app rests at a fixed [baseline] scale everywhere (the user-approved
/// default). A two-finger pinch (see `PinchTextZoom`) behaves by context:
///
///  * Outside chat threads it is ELASTIC — text follows the pinch while held,
///    then springs back to [baseline] on release (animated by the widget).
///    Nothing is persisted.
///  * Inside a chat thread it is PERSISTENT — the pinch sets a per-user chat
///    reading size that sticks across sessions.
///
/// A single scale ([scale]) drives the global `MediaQuery.textScaler`; the
/// mode (chat vs elsewhere) is toggled by the chat thread screen via
/// [enterChat]/[exitChat].
class TextScaleController extends ChangeNotifier {
  TextScaleController._();
  static final TextScaleController instance = TextScaleController._();

  static const _storage = FlutterSecureStorage();
  static const _chatKey = 'chat_text_scale';

  /// The size the whole app rests at — the default everywhere.
  static const double baseline = 1.135;

  /// Pinch bounds (shared by the elastic peek and the persistent chat size).
  static const double minScale = 0.85;
  static const double maxScale = 2.00;

  /// Scale currently applied to the global `MediaQuery.textScaler`.
  double _scale = baseline;
  double get scale => _scale;

  /// Persisted chat-thread reading size (defaults to [baseline]).
  double _chatScale = baseline;
  double get chatScale => _chatScale;

  bool _inChat = false;
  bool get inChat => _inChat;

  /// Load the persisted chat size. Call once before `runApp`.
  Future<void> load() async {
    final v = await _storage.read(key: _chatKey);
    final d = v == null ? null : double.tryParse(v);
    if (d != null) _chatScale = d.clamp(minScale, maxScale);
  }

  /// A chat thread became active: apply the persistent chat size.
  void enterChat() {
    _inChat = true;
    _set(_chatScale);
  }

  /// Left the chat thread: return to the app baseline.
  void exitChat() {
    _inChat = false;
    _set(baseline);
  }

  /// Live pinch update. In a chat thread this moves the (to-be-persisted) chat
  /// size; elsewhere it is a transient elastic peek.
  void pinchTo(double s) {
    final c = s.clamp(minScale, maxScale);
    if (_inChat) _chatScale = c;
    _set(c);
  }

  /// Drive the scale directly (used by the widget's spring-back animation).
  /// Never touches the persisted chat size.
  void driveScale(double s) => _set(s.clamp(minScale, maxScale));

  /// Persist the chat reading size — called when a pinch ends inside a chat
  /// thread. Elsewhere the widget animates back to [baseline] instead.
  Future<void> commitChat() async {
    await _storage.write(key: _chatKey, value: _chatScale.toStringAsFixed(3));
  }

  void _set(double s) {
    if ((s - _scale).abs() < 0.0005) return;
    _scale = s;
    notifyListeners();
  }
}
