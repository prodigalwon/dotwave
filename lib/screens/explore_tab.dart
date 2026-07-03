import 'package:flutter/material.dart';
import '../theme.dart';
import 'zkpki_screen.dart';

class ExploreTab extends StatelessWidget {
  final String address;
  const ExploreTab({super.key, required this.address});

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
            return _AppTile(app: app, address: address);
          },
        ),
      ),
    );
  }
}

class _RostroApp {
  final String name;
  final IconData icon;
  final Color color;

  /// Live tiles navigate here on tap; null = "coming soon" placeholder.
  final Widget Function(String address)? open;

  const _RostroApp({
    required this.name,
    required this.icon,
    required this.color,
    this.open,
  });
}

// Rostro app surfaces. Placeholder tiles ("coming soon") have no on-chain
// backend before testnet. Parachains, Bridge, and Auctions were intentionally
// dropped: those are Polkadot multi-chain structures that Rostro culled at
// inception (monolithic sovereign L1, no parachains / relay chain / XCM /
// EVM bridges), so they will never ship.
final _apps = [
  _RostroApp(
    name: 'Governance',
    icon: Icons.how_to_vote_outlined,
    color: AppTheme.accent,
  ),
  _RostroApp(
    name: 'Staking',
    icon: Icons.lock_outlined,
    color: Color(0xFF6D28D9),
  ),
  _RostroApp(
    name: 'NFTs',
    icon: Icons.image_outlined,
    color: Color(0xFF0EA5E9),
  ),
  _RostroApp(
    name: 'DeFi',
    icon: Icons.currency_exchange,
    color: Color(0xFF10B981),
  ),
  _RostroApp(
    name: 'ZK-PKI',
    icon: Icons.verified_user_outlined,
    color: Color(0xFFF59E0B),
    open: (address) => ZkPkiScreen(address: address),
  ),
  _RostroApp(
    name: 'More',
    icon: Icons.add_circle_outline,
    color: Colors.white38,
  ),
];

class _AppTile extends StatelessWidget {
  final _RostroApp app;
  final String address;
  const _AppTile({required this.app, required this.address});

  @override
  Widget build(BuildContext context) {
    final live = app.open != null;
    return GestureDetector(
      onTap: () {
        if (live) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => app.open!(address)),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${app.name} coming soon')),
          );
        }
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
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
          Text(
            live ? '' : 'soon',
            style: const TextStyle(color: Colors.white24, fontSize: 10),
          ),
        ],
      ),
    );
  }
}
