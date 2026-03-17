import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../bridge/bridge_generated.dart/frb_generated.dart';
import '../bridge/bridge_generated.dart/core.dart';
import '../widgets/transaction_blade.dart';
import '../home_shell.dart';

class NameRegistrationScreen extends StatefulWidget {
  final String address;

  /// When true (post-onboarding flow), shows a "Skip for now" option and
  /// navigates to HomeShell on success instead of just popping.
  final bool isOnboarding;

  const NameRegistrationScreen({
    super.key,
    required this.address,
    this.isOnboarding = false,
  });

  @override
  State<NameRegistrationScreen> createState() => _NameRegistrationScreenState();
}

class _NameRegistrationScreenState extends State<NameRegistrationScreen> {
  static const _rpcUrl = 'ws://172.24.112.1:9944';

  final _searchController = TextEditingController();
  bool _searchingName = false;
  bool _searchingMarketplace = false;
  bool? _nameAvailable;
  bool? _nameForSale;
  String? _nameInputError;
  bool _searchForFun = false;
  bool _loadingListing = false;

  String? _ownedName;

  static final _validName = RegExp(r'^[a-zA-Z0-9]+$');

  String get _storageKey => 'owned_name_${widget.address}';

  @override
  void initState() {
    super.initState();
    _resolveOwnedName();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _resolveOwnedName() async {
    try {
      const storage = FlutterSecureStorage();
      final stored = await storage.read(key: _storageKey);
      if (stored == null || stored.isEmpty) {
        if (mounted) setState(() => _ownedName = null);
        return;
      }
      final resolved = await RustLib.instance.api.crateCoreResolveNameVerified(
        name: stored,
        rpcUrl: _rpcUrl,
      );
      final stillOwned = resolved?.owner == widget.address;
      if (!stillOwned) await storage.delete(key: _storageKey);
      if (mounted) {
        setState(() => _ownedName = stillOwned ? stored : null);
        if (stillOwned && _searchController.text.isEmpty) {
          _searchController.text = stored;
        }
      }
    } catch (_) {
      // silent
    }
  }

  Future<void> _saveOwnedName(String name) async {
    const storage = FlutterSecureStorage();
    await storage.write(key: _storageKey, value: name);
    if (mounted) setState(() => _ownedName = name);
  }

  Future<bool> _showSearchForFunBlade() async {
    final result = await Navigator.of(context).push<bool>(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black54,
        barrierDismissible: true,
        pageBuilder: (_, __, ___) =>
            _SearchForFunBlade(ownedName: _ownedName!),
        transitionsBuilder: (_, animation, __, child) {
          final slide = Tween(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
          return SlideTransition(position: slide, child: child);
        },
      ),
    );
    return result == true;
  }

  Future<void> _showGiftBlade(String name) async {
    final recipient = await Navigator.of(context).push<String>(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black54,
        barrierDismissible: true,
        pageBuilder: (_, __, ___) => _GiftNameBlade(
          name: name,
          ownedName: _ownedName!,
          rpcUrl: _rpcUrl,
        ),
        transitionsBuilder: (_, animation, __, child) {
          final slide = Tween(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
          return SlideTransition(position: slide, child: child);
        },
      ),
    );
    if (recipient == null || !mounted) return;
    TransactionBlade.show(
      context,
      TransactionBlade(
        transactionType: 'Name Registration (Gift)',
        rows: [
          TxRow('Name', '$name.dot'),
          TxRow(
              'Recipient',
              '${recipient.substring(0, 6)}'
              '...${recipient.substring(recipient.length - 4)}'),
        ],
        costLabel: 'Registration Fee',
        loadCost: () => RustLib.instance.api
            .crateCoreGetNamePrice(name: name, rpcUrl: _rpcUrl),
        preflightCheck: () async {
          final result = await RustLib.instance.api
              .crateCoreCheckNameAvailability(name: name, rpcUrl: _rpcUrl);
          if (!result.available) return 'Name no longer available';
          final existing = await RustLib.instance.api
              .crateCoreResolveAddressToName(
                  address: recipient, rpcUrl: _rpcUrl);
          if (existing != null) return 'Recipient already owns $existing.dot';
          return null;
        },
        onConfirm: (phrase) => RustLib.instance.api.crateCoreRegisterNameFor(
          name: name,
          phrase: phrase,
          recipient: recipient,
          rpcUrl: _rpcUrl,
        ),
      ),
    );
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
      final availability =
          await RustLib.instance.api.crateCoreCheckNameAvailability(
        name: name,
        rpcUrl: _rpcUrl,
      );

      if (!availability.available && _ownedName == null) {
        final resolved = await RustLib.instance.api
            .crateCoreResolveNameVerified(name: name, rpcUrl: _rpcUrl);
        if (resolved?.owner == widget.address) await _saveOwnedName(name);
      }

      if (!mounted) return;

      if (_ownedName != null && !_searchForFun) {
        setState(() => _searchingName = false);
        final confirmed = await _showSearchForFunBlade();
        if (!confirmed) return;
        setState(() => _searchForFun = true);
      }

      setState(() {
        _nameAvailable = availability.available;
        _searchingName = false;
        _nameForSale = availability.forSale ? true : null;
      });
    } catch (e, stack) {
      debugPrint('Name search error [${e.runtimeType}]: $e\n$stack');
      if (!mounted) return;
      final msg = e is String ? e : e.toString();
      setState(() {
        _searchingName = false;
        _searchingMarketplace = false;
        _nameInputError = 'Error: client appears to be offline';
      });
    }
  }

  Future<void> _onForSaleTap() async {
    final name = _searchController.text.trim();
    setState(() => _loadingListing = true);
    try {
      final listing = await RustLib.instance.api
          .crateCoreGetNameListing(name: name, rpcUrl: _rpcUrl);
      if (!mounted) return;
      setState(() => _loadingListing = false);

      if (listing == null) {
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
              TxRow(
                  'Seller',
                  '${listing.seller.substring(0, 6)}'
                  '...${listing.seller.substring(listing.seller.length - 4)}'),
            ],
            costLabel: 'Asking Price',
            loadCost: () async => listing.price,
            preflightCheck: () async {
              final current = await RustLib.instance.api
                  .crateCoreGetNameListing(name: name, rpcUrl: _rpcUrl);
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

  void _goHome() {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => HomeShell(address: widget.address)),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Register a Name'),
        actions: [
          if (widget.isOnboarding)
            TextButton(
              onPressed: _goHome,
              child: const Text('Skip'),
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Find a Name',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              Text(
                'Search for a .dot name to register on the Polkadot network.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white60,
                    ),
              ),
              const SizedBox(height: 20),

              // Search row
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      style: const TextStyle(color: Colors.white),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[a-zA-Z0-9]')),
                      ],
                      onChanged: (_) {
                        setState(() {
                          _nameInputError = null;
                          _searchForFun = false;
                          _nameAvailable = null;
                          _nameForSale = null;
                        });
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
                              ? const BorderSide(
                                  color: Colors.redAccent, width: 1.5)
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
                            horizontal: 16, vertical: 14),
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
                          : const Icon(Icons.search,
                              color: Colors.white, size: 22),
                    ),
                  ),
                ],
              ),

              if (_nameInputError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _nameInputError!,
                  style:
                      const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ],

              if (_nameAvailable == true) ...[
                const SizedBox(height: 12),
                if (_ownedName != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border:
                          Border.all(color: Colors.orange.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline,
                            color: Colors.orange, size: 16),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'You already own $_ownedName.dot',
                            style: const TextStyle(
                                color: Colors.orange, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else if (_searchForFun) ...[
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => _showGiftBlade(
                          _searchController.text.trim()),
                      icon: const Icon(Icons.card_giftcard_outlined, size: 18),
                      label: const Text(
                        'Register for someone else',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF16A34A),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ] else ...[
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
                                      name: name, rpcUrl: _rpcUrl);
                              if (!result.available) {
                                return 'Name no longer available';
                              }
                              final existing = await RustLib.instance.api
                                  .crateCoreResolveAddressToName(
                                      address: widget.address,
                                      rpcUrl: _rpcUrl);
                              if (existing != null) {
                                return 'You already own $existing.dot';
                              }
                              return null;
                            },
                            onConfirm: (phrase) =>
                                RustLib.instance.api.crateCoreRegisterName(
                              name: name,
                              phrase: phrase,
                              rpcUrl: _rpcUrl,
                            ),
                            onSuccess: () async {
                              await _saveOwnedName(name);
                              if (!mounted) return;
                              if (widget.isOnboarding) {
                                _goHome();
                              } else {
                                setState(() {
                                  _nameAvailable = null;
                                  _searchController.clear();
                                });
                              }
                            },
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF16A34A),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text(
                        'Available!',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
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
                        color: Colors.white38, strokeWidth: 2),
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
                            borderRadius: BorderRadius.circular(12)),
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
                                  fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                ],
              ],

              if (widget.isOnboarding) ...[
                const SizedBox(height: 48),
                Center(
                  child: TextButton(
                    onPressed: _goHome,
                    child: const Text('Skip for now'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// For-sale dialog
// ─────────────────────────────────────────────────────────────────────────────

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
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text('Listed for sale',
                style: TextStyle(color: Colors.white38, fontSize: 13)),
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
                    child: const Text('Continue',
                        style: TextStyle(fontWeight: FontWeight.bold)),
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
        Text(label,
            style: const TextStyle(color: Colors.white54, fontSize: 14)),
        Text(
          value,
          style: TextStyle(
              color: valueColor ?? Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Search-for-fun blade
// ─────────────────────────────────────────────────────────────────────────────

class _SearchForFunBlade extends StatelessWidget {
  final String ownedName;
  const _SearchForFunBlade({required this.ownedName});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(false),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          Container(
            decoration: const BoxDecoration(
              color: Color(0xFF141414),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40, height: 4,
                    margin: const EdgeInsets.only(bottom: 24),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Container(
                    width: 64, height: 64,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE6007A).withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.badge_outlined,
                        color: Color(0xFFE6007A), size: 30),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    "You're $ownedName.dot",
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'You already own a name.\nSearch for fun?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white54, fontSize: 15, height: 1.5),
                  ),
                  const SizedBox(height: 28),
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
                            padding:
                                const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text('No thanks'),
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
                            padding:
                                const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text('Sure!',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Gift-name blade
// ─────────────────────────────────────────────────────────────────────────────

enum _GiftCheckState { idle, checking, clear, taken }

class _GiftNameBlade extends StatefulWidget {
  final String name;
  final String ownedName;
  final String rpcUrl;

  const _GiftNameBlade({
    required this.name,
    required this.ownedName,
    required this.rpcUrl,
  });

  @override
  State<_GiftNameBlade> createState() => _GiftNameBladeState();
}

class _GiftNameBladeState extends State<_GiftNameBlade> {
  final _recipientController = TextEditingController();
  _GiftCheckState _checkState = _GiftCheckState.idle;
  String? _takenByName;
  String? _inputError;

  static final _ss58Re = RegExp(r'^[1-9A-HJ-NP-Za-km-z]+$');

  bool _isValidSs58(String s) =>
      s.length >= 46 && s.length <= 50 && _ss58Re.hasMatch(s);

  @override
  void dispose() {
    _recipientController.dispose();
    super.dispose();
  }

  void _onAddressChanged(String _) {
    if (_checkState != _GiftCheckState.idle) {
      setState(() {
        _checkState = _GiftCheckState.idle;
        _takenByName = null;
        _inputError = null;
      });
    }
  }

  Future<void> _check() async {
    final addr = _recipientController.text.trim();
    if (!_isValidSs58(addr)) {
      setState(() => _inputError = 'Enter a valid SS58 address');
      return;
    }
    setState(() {
      _inputError = null;
      _checkState = _GiftCheckState.checking;
    });
    try {
      final existing =
          await RustLib.instance.api.crateCoreResolveAddressToName(
        address: addr,
        rpcUrl: widget.rpcUrl,
      );
      if (!mounted) return;
      setState(() {
        if (existing != null) {
          _checkState = _GiftCheckState.taken;
          _takenByName = existing;
        } else {
          _checkState = _GiftCheckState.clear;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checkState = _GiftCheckState.idle;
        _inputError = 'Error: client appears to be offline';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final addr = _recipientController.text.trim();
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          Container(
            decoration: const BoxDecoration(
              color: Color(0xFF141414),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40, height: 4,
                      margin: const EdgeInsets.only(bottom: 24),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Center(
                    child: Container(
                      width: 64, height: 64,
                      decoration: BoxDecoration(
                        color: const Color(0xFF16A34A).withOpacity(0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.card_giftcard_outlined,
                          color: Color(0xFF16A34A), size: 30),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Center(
                    child: Text(
                      'Register ${widget.name}.dot for someone else',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Center(
                    child: Text(
                      "You're ${widget.ownedName}.dot",
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 14),
                    ),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _recipientController,
                    onChanged: _onAddressChanged,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      hintText: 'Recipient SS58 address',
                      hintStyle: const TextStyle(
                          color: Colors.white38, fontSize: 13),
                      filled: true,
                      fillColor: const Color(0xFF1E1E1E),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            const BorderSide(color: Colors.white12, width: 1),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                            color: const Color(0xFF16A34A).withOpacity(0.5),
                            width: 1.5),
                      ),
                    ),
                  ),
                  if (_inputError != null) ...[
                    const SizedBox(height: 6),
                    Text(_inputError!,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 12)),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _checkState == _GiftCheckState.checking
                          ? null
                          : _check,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: _checkState == _GiftCheckState.checking
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white54),
                            )
                          : const Text('Check address'),
                    ),
                  ),
                  if (_checkState == _GiftCheckState.taken) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: Colors.orange.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline,
                              color: Colors.orange, size: 16),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'This address already owns $_takenByName.dot',
                              style: const TextStyle(
                                  color: Colors.orange, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_checkState == _GiftCheckState.clear) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(addr),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF16A34A),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text(
                          'Continue to payment',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
