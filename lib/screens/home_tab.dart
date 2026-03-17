import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../bridge/bridge_generated.dart/frb_generated.dart';
import 'governance_screen.dart';
import 'tokens_screen.dart';
import 'receive_screen.dart';
import 'send_screen.dart';

class HomeTab extends StatefulWidget {
  final String address;
  const HomeTab({super.key, required this.address});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  static const _rpcUrl = 'ws://172.24.112.1:9944';
  static const _dotDecimals = 12;

  String? _balanceDot;
  bool _loadingBalance = true;
  String? _balanceError;
  DateTime? _lastRefreshed;
  Timer? _refreshTimer;

  String? _ownedName; // resolved PNS name without ".dot"
  Timer? _namePoller;

  String get _refreshLabel {
    if (_lastRefreshed == null) return 'Tap to refresh';
    final elapsed = DateTime.now().difference(_lastRefreshed!);
    final mm = elapsed.inMinutes.toString().padLeft(2, '0');
    final ss = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return 'Tap to refresh · $mm:$ss ago';
  }

  String get _displayIdentity => _ownedName ??
      '${widget.address.substring(0, 6)}...${widget.address.substring(widget.address.length - 4)}';

  @override
  void initState() {
    super.initState();
    _fetchBalance();
    _resolveOwnedName();
    _namePoller = Timer.periodic(const Duration(minutes: 10), (_) {
      _resolveOwnedName();
    });
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_lastRefreshed != null && mounted) setState(() {});
    });
  }

  String get _storageKey => 'owned_name_${widget.address}';

  Future<void> _resolveOwnedName() async {
    try {
      const storage = FlutterSecureStorage();
      final stored = await storage.read(key: _storageKey);
      if (stored == null || stored.isEmpty) {
        if (mounted) setState(() => _ownedName = null);
        return;
      }
      // Verify the stored name still resolves to this address on-chain.
      final resolved = await RustLib.instance.api.crateCoreResolveNameVerified(
        name: stored,
        rpcUrl: _rpcUrl,
      );
      final stillOwned = resolved?.owner == widget.address;
      if (!stillOwned) {
        await storage.delete(key: _storageKey);
      }
      if (mounted) setState(() => _ownedName = stillOwned ? stored : null);
    } catch (_) {
      // silent — keep showing whatever we had
    }
  }

  /// Silently reverse-lookup the address on-chain. If a name is found it is
  /// written to secure storage (same key the poller and NameRegistrationScreen
  /// use) and the header updates immediately.
  Future<void> _lookupNameForAddress() async {
    try {
      final name = await RustLib.instance.api.crateCoreResolveAddressToName(
        address: widget.address,
        rpcUrl: _rpcUrl,
      );
      if (name == null || !mounted) return;
      const storage = FlutterSecureStorage();
      await storage.write(key: _storageKey, value: name);
      if (mounted) setState(() => _ownedName = name);
    } catch (_) {
      // silent
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _namePoller?.cancel();
    super.dispose();
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
        _lastRefreshed = DateTime.now();
      });
    } catch (e) {
      setState(() {
        _balanceError = 'Error: client appears to be offline';
        _loadingBalance = false;
      });
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _balanceError = null);
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
                        GestureDetector(
                          onTap: _lookupNameForAddress,
                          child: Column(
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
                                _displayIdentity,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
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
                                    (_balanceError != null || _balanceDot == null)
                                        ? 'Offline'
                                        : '$_balanceDot DOT',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 36,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                            const SizedBox(height: 4),
                            Text(
                              _balanceError ?? _refreshLabel,
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
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    SendScreen(fromAddress: widget.address),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _QuickActionButton(
                            icon: Icons.arrow_downward,
                            label: 'Receive',
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ReceiveScreen(address: widget.address),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _QuickActionButton(
                            icon: Icons.toll_outlined,
                            label: 'Tokens',
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => TokensScreen(address: widget.address),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _QuickActionButton(
                            icon: Icons.how_to_vote_outlined,
                            label: 'Vote',
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const GovernanceScreen()),
                            ),
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
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: cs.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: cs.primary.withOpacity(0.2),
              ),
            ),
            child: Icon(icon, color: cs.primary, size: 22),
          ),
          const SizedBox(height: 8),
          Text(label, style: tt.labelMedium),
        ],
      ),
    );
  }
}