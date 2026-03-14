import 'package:flutter/material.dart';
import '../bridge/bridge_generated.dart/frb_generated.dart';

class HomeTab extends StatefulWidget {
  final String address;
  const HomeTab({super.key, required this.address});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  static const _rpcUrl = 'ws://127.0.0.1:9944';
  static const _dotDecimals = 10;

  String? _balanceDot;
  bool _loadingBalance = true;
  String? _balanceError;

  String get _truncatedAddress =>
      '${widget.address.substring(0, 6)}...${widget.address.substring(widget.address.length - 4)}';

  @override
  void initState() {
    super.initState();
    _fetchBalance();
  }

  Future<void> _fetchBalance() async {
    setState(() {
      _loadingBalance = true;
      _balanceError = null;
    });
    try {
      final planckStr = await RustLib.instance.api.crateCoreFetchBalance(
        address: widget.address,
        rpcUrl: _rpcUrl,
      );
      final planck = BigInt.parse(planckStr);
      final divisor = BigInt.from(10).pow(_dotDecimals);
      final whole = planck ~/ divisor;
      final frac = ((planck % divisor) * BigInt.from(1000) ~/ divisor)
          .toString()
          .padLeft(3, '0');
      setState(() {
        _balanceDot = '$whole.$frac';
        _loadingBalance = false;
      });
    } catch (e) {
      setState(() {
        _balanceError = 'Sync failed';
        _loadingBalance = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Good morning',
                              style: TextStyle(
                                color: Colors.white60,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _truncatedAddress,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFFE6007A).withOpacity(0.15),
                            border: Border.all(
                              color: const Color(0xFFE6007A).withOpacity(0.3),
                            ),
                          ),
                          child: const Icon(
                            Icons.person,
                            color: Color(0xFFE6007A),
                            size: 22,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 32),

                    // Balance card
                    GestureDetector(
                      onTap: _loadingBalance ? null : _fetchBalance,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFFE6007A), Color(0xFF6D28D9)],
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Total Balance',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _loadingBalance
                                ? const SizedBox(
                                    height: 40,
                                    child: Center(
                                      child: CircularProgressIndicator(
                                        color: Colors.white54,
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                : Text(
                                    _balanceError != null
                                        ? '— DOT'
                                        : '${_balanceDot!} DOT',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 36,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                            const SizedBox(height: 4),
                            Text(
                              _balanceError ?? 'Tap to refresh',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Quick actions
                    Row(
                      children: [
                        Expanded(
                          child: _QuickActionButton(
                            icon: Icons.arrow_upward,
                            label: 'Send',
                            onTap: () {},
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _QuickActionButton(
                            icon: Icons.arrow_downward,
                            label: 'Receive',
                            onTap: () {},
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _QuickActionButton(
                            icon: Icons.swap_horiz,
                            label: 'Swap',
                            onTap: () {},
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _QuickActionButton(
                            icon: Icons.how_to_vote_outlined,
                            label: 'Vote',
                            onTap: () {},
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 32),

                    // Activity
                    const Text(
                      'Recent Activity',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          'No activity yet',
                          style: TextStyle(color: Colors.white38),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _QuickActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFFE6007A).withOpacity(0.2),
              ),
            ),
            child: Icon(icon, color: const Color(0xFFE6007A), size: 22),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ],
      ),
    );
  }
}