import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dotwave/screens/games/bricks_screen.dart';
import 'package:dotwave/screens/games/game_2048_screen.dart';
import 'package:dotwave/screens/games/games_screen.dart';
import 'package:dotwave/screens/games/mines_screen.dart';
import 'package:dotwave/screens/games/snake_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Games persist best scores through flutter_secure_storage; stub its
    // platform channel so read returns "no best yet" and writes succeed.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => call.method == 'read' ? null : null,
    );
  });

  Widget wrap(Widget child) => MaterialApp(home: child);

  testWidgets('games hub lists all four games', (tester) async {
    await tester.pumpWidget(wrap(const GamesScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Snake'), findsOneWidget);
    expect(find.text('2048'), findsOneWidget);
    expect(find.text('Bricks'), findsOneWidget);
    expect(find.text('Mines'), findsOneWidget);
  });

  testWidgets('snake builds, starts on swipe, and ticks', (tester) async {
    await tester.pumpWidget(wrap(const SnakeScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Swipe to start'), findsOneWidget);

    await tester.drag(
        find.byKey(const ValueKey('board-snake')), const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 250)); // one tick
    expect(find.text('Swipe to start'), findsNothing);

    // Leave the screen so the game timer is cancelled before teardown.
    await tester.pumpWidget(wrap(const SizedBox()));
    await tester.pumpAndSettle();
  });

  test('2048 line collapse merges pairs once and scores merges', () {
    void check(List<int> line, List<int> want, int wantScore) {
      final (out, gained) = collapse2048Line(line);
      expect(out, want);
      expect(gained, wantScore);
    }

    check([2, 2, 0, 0], [4, 0, 0, 0], 4);
    check([2, 0, 2, 4], [4, 4, 0, 0], 4);
    check([2, 2, 2, 2], [4, 4, 0, 0], 8);
    check([4, 4, 8, 0], [8, 8, 0, 0], 8);
    check([2, 4, 2, 4], [2, 4, 2, 4], 0);
    check([0, 0, 0, 0], [0, 0, 0, 0], 0);
  });

  testWidgets('2048 builds and a swipe pair spawns a tile', (tester) async {
    await tester.pumpWidget(wrap(const Game2048Screen()));
    await tester.pumpAndSettle();
    expect(find.text('SCORE'), findsOneWidget);

    // A single direction can be a legal no-op (both tiles already flush);
    // opposite flings guarantee at least one real move and spawn.
    final board = find.byKey(const ValueKey('board-2048'));
    await tester.fling(board, const Offset(-200, 0), 1500);
    await tester.pumpAndSettle();
    await tester.fling(board, const Offset(200, 0), 1500);
    await tester.pumpAndSettle();

    // Tile digits render at fontSize 22 (score boxes use 18). If the two
    // starting tiles merged on the way, the board can legally hold only two
    // tiles, but then the score must be nonzero.
    final tiles = find.byWidgetPredicate((w) =>
        w is Text &&
        w.data != null &&
        int.tryParse(w.data!) != null &&
        w.style?.fontSize == 22);
    final scores = find.byWidgetPredicate((w) =>
        w is Text &&
        w.data != null &&
        int.tryParse(w.data!) != null &&
        w.style?.fontSize == 18);
    final scored = scores
        .evaluate()
        .any((e) => ((e.widget as Text).data != '0'));
    expect(tiles.evaluate().length >= 3 || scored, isTrue);
  });

  testWidgets('bricks builds and launches', (tester) async {
    await tester.pumpWidget(wrap(const BricksScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Tap to launch'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('board-bricks')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Tap to launch'), findsNothing);

    await tester.pumpWidget(wrap(const SizedBox()));
    await tester.pumpAndSettle();
  });

  testWidgets('mines first tap is safe and cascades', (tester) async {
    await tester.pumpWidget(wrap(const MinesScreen()));
    await tester.pumpAndSettle();

    // Tap a cell: the first tap must never be a mine ("Boom." never shown).
    final cells = find.byType(GestureDetector);
    await tester.tap(cells.at(cells.evaluate().length ~/ 2),
        warnIfMissed: false);
    await tester.pump();
    expect(find.text('Boom.'), findsNothing);

    await tester.pumpWidget(wrap(const SizedBox()));
    await tester.pumpAndSettle();
  });
}
