import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../bridge/bridge_generated.dart/frb_generated.dart';
import '../bridge/bridge_generated.dart/core.dart';
import '../widgets/transaction_blade.dart';
import 'governance_screen.dart';
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

  final _searchController = TextEditingController();
  bool _searchingName = false;
  bool _searchingMarketplace = false;
  bool? _nameAvailable;
  bool? _nameForSale;
  String? _nameInputError;

  static final _validName = RegExp(r'^[a-zA-Z0-9]+$');
  bool _loadingListing = false;

  String? _ownedName; // resolved PNS name without ".dot"

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
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_lastRefreshed != null && mounted) setState(() {});
    });
  }

  Future<void> _resolveOwnedName() async {
    try {
      final name = await RustLib.instance.api.crateCoreResolveAddressToName(
        address: widget.address,
        rpcUrl: _rpcUrl,
      );
      if (mounted && name != null) {
        setState(() => _ownedName = name);
      }
    } catch (_) {
      // silent — just keep showing the truncated address
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _searchName() async {
    final name = _searchController.text.trim();
    if (name.isEmpty) return;

    if (!_validName.hasMatch(name)) {
      setState(() {
        _nameInputError = 'Only letters and numbers allowed';
        _nameAvailable = null;
        _nameForSale = null;
      });
      return;
    }

    setState(() {
      _nameInputError = null;
      _searchingName = true;
      _nameAvailable = null;
      _nameForSale = null;
    });
    try {
      final result = await RustLib.instance.api.crateCoreCheckNameAvailability(
        name: name,
        rpcUrl: _rpcUrl,
      );
      setState(() {
        _nameAvailable = result.available;
        _searchingName = false;
        _searchingMarketplace = !result.available;
        _nameForSale = result.forSale ? true : null;
        _searchingMarketplace = false;
      });
    } catch (e, stack) {
      debugPrint('Name search error [${e.runtimeType}]: $e\n$stack');
      if (!mounted) return;
      final msg = e is String ? e : e.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Search error: $msg'),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 8),
        ),
      );
      setState(() {
        _searchingName = false;
        _searchingMarketplace = false;
        _nameInputError = msg.isEmpty ? 'Unknown error (see console)' : msg;
      });
    }
  }

  Future<void> _onForSaleTap() async {
    final name = _searchController.text.trim();
    setState(() => _loadingListing = true);
    try {
      final listing = await RustLib.instance.api.crateCoreGetNameListing(
        name: name,
        rpcUrl: _rpcUrl,
      );
      if (!mounted) return;
      setState(() => _loadingListing = false);

      if (listing == null) {
        // Listing expired between search and tap
        setState(() => _nameForSale = null);
        return;
      }

      final shouldContinue = await showDialog<bool>(
        context: context,
        builder: (ctx) => _ForSaleDialog(name: name, listing: listing),
      );

      if (shouldContinue == true && mounted) {
        TransactionBlade.show(
          context,
          TransactionBlade(
            transactionType: 'Name Purchase',
            rows: [
              TxRow('Name', '$name.dot'),
              TxRow('Seller',
                  '${listing.seller.substring(0, 6)}...${listing.seller.substring(listing.seller.length - 4)}'),
            ],
            costLabel: 'Asking Price',
            loadCost: () async => listing.price,
            preflightCheck: () async {
              final current = await RustLib.instance.api.crateCoreGetNameListing(
                name: name,
                rpcUrl: _rpcUrl,
              );
              return current == null ? 'Name is no longer for sale' : null;
            },
            onConfirm: (phrase) => RustLib.instance.api.crateCoreBuyName(
              name: name,
              phrase: phrase,
              rpcUrl: _rpcUrl,
            ),
          ),
        );
      }
    } catch (_) {
      setState(() => _loadingListing = false);
    }
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
                              _displayIdentity,
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
                                        ? 'Offline'
                                        : '${_balanceDot!} DOT',
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

                    // Name search
                    const Text(
                      'Find a Name',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            style: const TextStyle(color: Colors.white),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
                            ],
                            onChanged: (_) {
                              if (_nameInputError != null) {
                                setState(() => _nameInputError = null);
                              }
                            },
                            decoration: InputDecoration(
                              hintText: 'Search a name...',
                              hintStyle: const TextStyle(color: Colors.white38),
                              filled: true,
                              fillColor: const Color(0xFF1E1E1E),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: _nameInputError != null
                                    ? const BorderSide(color: Colors.redAccent, width: 1.5)
                                    : BorderSide.none,
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: _nameInputError != null
                                      ? Colors.redAccent
                                      : const Color(0xFFE6007A),
                                  width: 1.5,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                            ),
                            onSubmitted: (_) => _searchName(),
                          ),
                        ),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: _searchingName ? null : _searchName,
                          child: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: const Color(0xFFE6007A),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: _searchingName
                                ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: CircularProgressIndicator(
                                      color: Colors.white,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.search, color: Colors.white, size: 22),
                          ),
                        ),
                      ],
                    ),
                    if (_nameInputError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _nameInputError!,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                      ),
                    ],
                    if (_nameAvailable == true) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () {
                            final name = _searchController.text.trim();
                            TransactionBlade.show(
                              context,
                              TransactionBlade(
                                transactionType: 'Name Registration',
                                rows: [
                                  TxRow('Name', '$name.dot'),
                                ],
                                costLabel: 'Registration Fee',
                                loadCost: () =>
                                    RustLib.instance.api.crateCoreGetNamePrice(
                                      name: name,
                                      rpcUrl: _rpcUrl,
                                    ),
                                preflightCheck: () async {
                                  final result = await RustLib.instance.api
                                      .crateCoreCheckNameAvailability(
                                    name: name,
                                    rpcUrl: _rpcUrl,
                                  );
                                  return result.available
                                      ? null
                                      : 'Name no longer available';
                                },
                                onConfirm: (phrase) =>
                                    RustLib.instance.api.crateCoreRegisterName(
                                  name: name,
                                  phrase: phrase,
                                  rpcUrl: _rpcUrl,
                                ),
                              ),
                            );
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF16A34A),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text(
                            'Available!',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ] else if (_nameAvailable == false) ...[
                      const SizedBox(height: 12),
                      const SizedBox(
                        width: double.infinity,
                        child: Text(
                          'Taken. Try Again.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (_searchingMarketplace) ...[
                        const SizedBox(height: 8),
                        const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(
                            color: Colors.white38,
                            strokeWidth: 2,
                          ),
                        ),
                      ] else if (_nameForSale == true) ...[
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _loadingListing ? null : _onForSaleTap,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFE6007A),
                              foregroundColor: Colors.white,
                              disabledBackgroundColor:
                                  const Color(0xFFE6007A).withOpacity(0.4),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: _loadingListing
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                        color: Colors.white, strokeWidth: 2),
                                  )
                                : const Text(
                                    'For Sale!',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ],

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

class _ForSaleDialog extends StatelessWidget {
  final String name;
  final NameListing listing;

  const _ForSaleDialog({required this.name, required this.listing});

  static const _dotDecimals = 12;

  String _formatDot(String planck) {
    final value = BigInt.parse(planck);
    final divisor = BigInt.from(10).pow(_dotDecimals);
    final whole = value ~/ divisor;
    final frac = ((value % divisor) * BigInt.from(1000) ~/ divisor)
        .toString()
        .padLeft(3, '0');
    return '$whole.$frac DOT';
  }

  @override
  Widget build(BuildContext context) {
    final seller = listing.seller;
    final truncatedSeller =
        '${seller.substring(0, 6)}...${seller.substring(seller.length - 4)}';

    return Dialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$name.dot',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Listed for sale',
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
            const SizedBox(height: 20),
            const Divider(color: Colors.white12),
            const SizedBox(height: 16),
            _row('Asking Price', _formatDot(listing.price),
                valueColor: const Color(0xFFE6007A)),
            const SizedBox(height: 10),
            _row('Seller', truncatedSeller),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white54,
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Close'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE6007A),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text(
                      'Continue',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 14)),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
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