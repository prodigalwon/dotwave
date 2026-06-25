import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../theme.dart';

/// Owns the runtime brand accent: persists the user's pick (Settings → Theme →
/// Color) and notifies the app to rebuild with the new colour.
class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  static const _storage = FlutterSecureStorage();
  static const _key = 'brand_accent_argb';

  Color get accent => AppTheme.accent;

  /// Load the persisted accent. Call once before `runApp` so the app starts in
  /// the chosen colour.
  Future<void> load() async {
    final v = await _storage.read(key: _key);
    final argb = v == null ? null : int.tryParse(v);
    if (argb != null) AppTheme.accent = Color(argb);
  }

  /// Switch the brand accent: applies immediately (rebuild) and persists.
  Future<void> setAccent(Color c) async {
    if (c.toARGB32() == AppTheme.accent.toARGB32()) return;
    AppTheme.accent = c;
    notifyListeners();
    await _storage.write(key: _key, value: c.toARGB32().toString());
  }
}
