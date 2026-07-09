import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Best-score persistence for the Games area.
///
/// Rides the existing flutter_secure_storage dependency (keys namespaced
/// `games.best.*`) so the games add zero packages. Scores are
/// higher-is-better; Mines stores a best time via [submitLowest].
class GameScores {
  static const _storage = FlutterSecureStorage();

  static Future<int?> read(String game) async {
    final v = await _storage.read(key: 'games.best.$game');
    return v == null ? null : int.tryParse(v);
  }

  /// Records [score] if it beats the stored best. Returns true on a new best.
  static Future<bool> submitHighest(String game, int score) async {
    final best = await read(game);
    if (best != null && score <= best) return false;
    await _storage.write(key: 'games.best.$game', value: '$score');
    return true;
  }

  /// Records [score] if it undercuts the stored best (times).
  static Future<bool> submitLowest(String game, int score) async {
    final best = await read(game);
    if (best != null && score >= best) return false;
    await _storage.write(key: 'games.best.$game', value: '$score');
    return true;
  }
}
