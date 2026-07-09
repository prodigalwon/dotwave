import 'package:flutter/material.dart';

import '../../theme.dart';
import 'bricks_screen.dart';
import 'game_2048_screen.dart';
import 'game_scores.dart';
import 'mines_screen.dart';
import 'snake_screen.dart';

/// Games hub (Explore → Games). Lightweight built-in classics: pure Flutter,
/// no assets, no network. Everything runs and persists on this device only.
class GamesScreen extends StatefulWidget {
  const GamesScreen({super.key});

  @override
  State<GamesScreen> createState() => _GamesScreenState();
}

class _GameEntry {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final bool lowerIsBetter;
  final Widget Function() open;

  const _GameEntry({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    this.lowerIsBetter = false,
    required this.open,
  });
}

final _games = [
  _GameEntry(
    id: 'snake',
    title: 'Snake',
    subtitle: 'Swipe to steer. Eat, grow, don\'t crash.',
    icon: Icons.timeline,
    color: const Color(0xFF22C55E),
    open: () => const SnakeScreen(),
  ),
  _GameEntry(
    id: '2048',
    title: '2048',
    subtitle: 'Slide tiles, merge numbers, reach 2048.',
    icon: Icons.grid_view,
    color: const Color(0xFFF59E0B),
    open: () => const Game2048Screen(),
  ),
  _GameEntry(
    id: 'bricks',
    title: 'Bricks',
    subtitle: 'Drag the paddle, clear the wall.',
    icon: Icons.view_week_outlined,
    color: const Color(0xFF0EA5E9),
    open: () => const BricksScreen(),
  ),
  _GameEntry(
    id: 'mines',
    title: 'Mines',
    subtitle: 'Tap to reveal, hold to flag.',
    icon: Icons.flag_outlined,
    color: const Color(0xFFEF4444),
    lowerIsBetter: true,
    open: () => const MinesScreen(),
  ),
];

class _GamesScreenState extends State<GamesScreen> {
  final Map<String, int?> _best = {};

  @override
  void initState() {
    super.initState();
    _loadBests();
  }

  Future<void> _loadBests() async {
    for (final g in _games) {
      final v = await GameScores.read(g.id);
      if (!mounted) return;
      setState(() => _best[g.id] = v);
    }
  }

  String? _bestLabel(_GameEntry g) {
    final v = _best[g.id];
    if (v == null) return null;
    if (g.lowerIsBetter) {
      final m = v ~/ 60, s = v % 60;
      return 'Best $m:${s.toString().padLeft(2, '0')}';
    }
    return 'Best $v';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        title: const Text('Games'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surface1,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.borderSubtle),
            ),
            child: const Text(
              'Built-in classics. No downloads, no network, no tracking. '
              'They run entirely on this device and work offline.',
              style: TextStyle(
                  color: AppTheme.textSecondary, fontSize: 13, height: 1.45),
            ),
          ),
          const SizedBox(height: 24),
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              'ARCADE',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final g in _games) ...[
            _GameTile(
              entry: g,
              best: _bestLabel(g),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => g.open()),
                );
                _loadBests();
              },
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _GameTile extends StatelessWidget {
  final _GameEntry entry;
  final String? best;
  final VoidCallback onTap;

  const _GameTile({
    required this.entry,
    required this.best,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface1,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.borderSubtle),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: entry.color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(14),
                  border:
                      Border.all(color: entry.color.withValues(alpha: 0.3)),
                ),
                child: Icon(entry.icon, color: entry.color, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.subtitle,
                      style: const TextStyle(
                          color: AppTheme.textTertiary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (best != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    best!,
                    style: TextStyle(
                      color: entry.color.withValues(alpha: 0.9),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right,
                  color: AppTheme.textTertiary, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
