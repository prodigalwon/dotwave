import 'package:flutter/material.dart';

import '../services/theme_controller.dart';
import '../theme.dart';

/// App settings. Today: Theme — a Dark/Light toggle (light mode not wired yet)
/// and the brand-colour picker (a horizontal row of swatches; press-drag to
/// reach the rest). Selecting a swatch re-skins the whole app instantly.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _dark = true; // cosmetic for now — light mode isn't implemented yet

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: const Text('Settings')),
      // Rebuild on accent change so the selected swatch + accents update live.
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
                setState(() => _dark = true); // stays dark for now
                if (!v) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Light mode is coming soon')),
                  );
                }
              },
            ),

            const SizedBox(height: 20),
            Text('Color', style: tt.titleMedium),
            const SizedBox(height: 4),
            Text('Pick your brand colour — drag for more.',
                style: tt.bodySmall),
            const SizedBox(height: 16),

            SizedBox(
              height: 60,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: AppTheme.palette.length,
                separatorBuilder: (_, __) => const SizedBox(width: 18),
                itemBuilder: (_, i) {
                  final entry = AppTheme.palette[i];
                  final selected = entry.color.toARGB32() ==
                      AppTheme.accent.toARGB32();
                  return Center(
                    child: _Swatch(
                      color: entry.color,
                      selected: selected,
                      onTap: () =>
                          ThemeController.instance.setAccent(entry.color),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _Swatch(
      {required this.color, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final on = color.computeLuminance() > 0.45 ? Colors.black : Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.white : Colors.white24,
            width: selected ? 3 : 1,
          ),
          boxShadow: selected
              ? [BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: 12)]
              : null,
        ),
        child: selected ? Icon(Icons.check, color: on, size: 22) : null,
      ),
    );
  }
}
