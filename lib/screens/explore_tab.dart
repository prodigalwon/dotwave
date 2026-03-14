import 'package:flutter/material.dart';

class ExploreTab extends StatelessWidget {
  const ExploreTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        title: const Text('Explore'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.85,
          ),
          itemCount: _apps.length,
          itemBuilder: (context, index) {
            final app = _apps[index];
            return _AppTile(app: app);
          },
        ),
      ),
    );
  }
}

class _DotApp {
  final String name;
  final IconData icon;
  final Color color;
  final bool available;

  const _DotApp({
    required this.name,
    required this.icon,
    required this.color,
    this.available = false,
  });
}

const _apps = [
  _DotApp(
    name: 'Governance',
    icon: Icons.how_to_vote_outlined,
    color: Color(0xFFE6007A),
    available: true,
  ),
  _DotApp(
    name: 'Staking',
    icon: Icons.lock_outlined,
    color: Color(0xFF6D28D9),
  ),
  _DotApp(
    name: 'NFTs',
    icon: Icons.image_outlined,
    color: Color(0xFF0EA5E9),
  ),
  _DotApp(
    name: 'DeFi',
    icon: Icons.currency_exchange,
    color: Color(0xFF10B981),
  ),
  _DotApp(
    name: 'Identity',
    icon: Icons.badge_outlined,
    color: Color(0xFFF59E0B),
  ),
  _DotApp(
    name: 'Parachains',
    icon: Icons.hub_outlined,
    color: Color(0xFFEC4899),
  ),
  _DotApp(
    name: 'Bridge',
    icon: Icons.swap_horizontal_circle_outlined,
    color: Color(0xFF8B5CF6),
  ),
  _DotApp(
    name: 'Auctions',
    icon: Icons.gavel_outlined,
    color: Color(0xFFEF4444),
  ),
  _DotApp(
    name: 'More',
    icon: Icons.add_circle_outline,
    color: Colors.white38,
  ),
];

class _AppTile extends StatelessWidget {
  final _DotApp app;
  const _AppTile({required this.app});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: app.available
          ? () {}
          : () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('${app.name} coming soon')),
              );
            },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: app.color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: app.color.withOpacity(0.3)),
            ),
            child: Icon(app.icon, color: app.color, size: 26),
          ),
          const SizedBox(height: 8),
          Text(
            app.name,
            style: TextStyle(
              color: app.available ? Colors.white : Colors.white54,
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
          if (!app.available)
            const Text(
              'soon',
              style: TextStyle(color: Colors.white24, fontSize: 10),
            ),
        ],
      ),
    );
  }
}