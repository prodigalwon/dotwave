import 'dart:async';
import '../theme.dart';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../bridge/bridge_generated.dart/frb_generated.dart';
import '../config/rpc_endpoints.dart';
import '../services/avatar_service.dart';
import '../services/chat_store.dart';
import '../services/feed_service.dart';
import '../models/feed_item.dart';
import '../widgets/feed_card.dart';
import 'avatar_screen.dart';
import 'receive_screen.dart';
import 'send_screen.dart';

class HomeTab extends StatefulWidget {
  final String address;

  /// Switch the shell to the Messages tab (a feed message row opens there).
  final VoidCallback? onOpenMessages;
  const HomeTab({super.key, required this.address, this.onOpenMessages});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  static const _rpcUrl = RpcEndpoints.pnsNode;
  static const _rstDecimals = 12;

  String? _balanceRst;
  bool _loadingBalance = true;
  String? _balanceError;
  DateTime? _lastRefreshed;
  Timer? _refreshTimer;

  String? _ownedName; // resolved PNS name without ".rst"
  Timer? _namePoller;

  Uint8List? _avatar; // this account's chat icon, if set

  String get _refreshLabel {
    if (_lastRefreshed == null) return 'Tap to refresh';
    final elapsed = DateTime.now().difference(_lastRefreshed!);
    final mm = elapsed.inMinutes.toString().padLeft(2, '0');
    final ss = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return 'Tap to refresh · $mm:$ss ago';
  }

  String get _displayIdentity => _ownedName ??
      '${widget.address.substring(0, 6)}...${widget.address.substring(widget.address.length - 4)}';

  /// True once this account has resolved a canonical .rst name.
  bool get _hasName => _ownedName != null && _ownedName!.isNotEmpty;

  /// Time-of-day greeting (was hardcoded "Good morning").
  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  void initState() {
    super.initState();
    _fetchBalance();
    _resolveOwnedName();
    _loadAvatar();
    _namePoller = Timer.periodic(const Duration(minutes: 10), (_) {
      _resolveOwnedName();
    });
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_lastRefreshed != null && mounted) setState(() {});
    });
    FeedService.instance.addListener(_onFeed);
  }

  void _onFeed() {
    if (mounted) setState(() {});
  }

  /// The activity feed, newest-first.
  List<FeedItem> get _feed => FeedService.instance.items;

  /// The red "remove" backdrop revealed as a feed row is swiped away.
  Widget _dismissBg(Alignment align) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      alignment: align,
      decoration: BoxDecoration(
        color: AppTheme.error.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Icon(Icons.delete_outline, color: AppTheme.error),
    );
  }

  void _onFeedTap(FeedItem item) {
    // Messages open the conversation (never the plaintext); everything else
    // opens a detail popup.
    if (item.kind == FeedKind.message) {
      widget.onOpenMessages?.call();
      return;
    }
    showDialog<void>(
      context: context,
      builder: (_) => FeedDetailDialog(item: item),
    );
  }

  String get _storageKey => 'owned_name_${widget.address}';

  Future<void> _loadAvatar() async {
    final a = await AvatarService.instance.ownAvatar(widget.address);
    if (mounted) setState(() => _avatar = a);
  }

  Future<void> _openAvatar() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AvatarScreen(address: widget.address),
    ));
    _loadAvatar(); // reflect a change made on the icon screen
  }

  Future<void> _resolveOwnedName() async {
    // Delegate to the shared resolver so Home, Messages, and Profile all show
    // the same name and reverify (but never blank offline) identically.
    final name = await ChatStore.instance.resolveOwnedName(widget.address);
    if (mounted) setState(() => _ownedName = name);
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
    FeedService.instance.removeListener(_onFeed);
    super.dispose();
  }

  String _formatRst(String planckStr) {
    final p = BigInt.parse(planckStr);
    final d = BigInt.from(10).pow(_rstDecimals);
    final whole = p ~/ d;
    final frac = ((p % d) * BigInt.from(1000) ~/ d).toString().padLeft(3, '0');
    return '$whole.$frac';
  }

  Future<void> _fetchBalance() async {
    setState(() {
      _loadingBalance = true;
      _balanceError = null;
    });

    String? rstRaw;
    try {
      rstRaw = await RustLib.instance.api.crateCoreFetchBalance(
        address: widget.address,
        rpcUrl: _rpcUrl,
      );
    } catch (_) {
      rstRaw = null;
    }

    if (!mounted) return;

    setState(() {
      _balanceRst = rstRaw != null ? _formatRst(rstRaw) : null;
      _loadingBalance = false;
      if (rstRaw != null) {
        _lastRefreshed = DateTime.now();
      } else {
        _balanceError = 'Error: client appears to be offline';
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _balanceError = null);
        });
      }
    });
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
                              Text(
                                _greeting,
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 4),
                              // Canonical name gets emphasis (bigger, bold, "!");
                              // a bare address stays plain (lighter, smaller).
                              Text(
                                _hasName ? '$_ownedName!' : _displayIdentity,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: _hasName ? 26 : 20,
                                  fontWeight:
                                      _hasName ? FontWeight.bold : FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: _openAvatar,
                          child: Container(
                            width: 44,
                            height: 44,
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppTheme.accent.withOpacity(0.15),
                              border: Border.all(
                                color: AppTheme.accent.withOpacity(0.3),
                              ),
                            ),
                            child: _avatar != null
                                ? Image.memory(_avatar!,
                                    fit: BoxFit.cover, gaplessPlayback: true)
                                : Icon(
                                    Icons.person,
                                    color: AppTheme.accent,
                                    size: 22,
                                  ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 32),

                    // Balance card. A minimum height keeps its proportions,
                    // but it grows with the text scale instead of clipping.
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 160),
                      child: Builder(
                        builder: (_) {
                          const token   = 'RST';
                          final balance = _balanceRst;
                          return GestureDetector(
                            onTap: _loadingBalance ? null : _fetchBalance,
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                // accent body — adapts to the picked colour
                                gradient: AppTheme.cardGradient,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              // Gloss: a light specular reflection across the top,
                              // like light on a wet surface. Painted OVER the body.
                              foregroundDecoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(20),
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.white.withValues(alpha: 0.28),
                                    Colors.white.withValues(alpha: 0.06),
                                    Colors.transparent,
                                  ],
                                  stops: const [0.0, 0.14, 0.46],
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        '$token Balance',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 14,
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          token,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
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
                                          balance != null
                                              ? '$balance $token'
                                              : 'Offline',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 32,
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
                          );
                        },
                      ),
                    ),

                    const SizedBox(height: 16),

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
                  ],
                ),
              ),
            ),
            // ── Activity feed ────────────────────────────────────────────
            // Source-agnostic stream (chain activity, chat events, identity
            // events, posts), newest-first, social-feed styled. Empty state
            // when there's nothing yet.
            if (_feed.isEmpty)
              const SliverToBoxAdapter(child: _FeedEmptyState())
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                sliver: SliverList.builder(
                  itemCount: _feed.length,
                  itemBuilder: (_, i) {
                    final item = _feed[i];
                    // Swipe either direction to dismiss the entry.
                    return Dismissible(
                      key: ValueKey(item.id),
                      direction: DismissDirection.horizontal,
                      background: _dismissBg(Alignment.centerLeft),
                      secondaryBackground: _dismissBg(Alignment.centerRight),
                      onDismissed: (_) => FeedService.instance.remove(item.id),
                      child: FeedCard(
                        item: item,
                        onTap: () => _onFeedTap(item),
                      ),
                    );
                  },
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }
}

/// Shown under "Recent Activity" when the feed has no entries yet.
class _FeedEmptyState extends StatelessWidget {
  const _FeedEmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
      child: Column(
        children: [
          Icon(Icons.dynamic_feed_outlined,
              size: 40, color: Colors.white24),
          const SizedBox(height: 12),
          const Text(
            'Nothing here yet',
            style: TextStyle(
                color: Colors.white54,
                fontSize: 15,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            'Your transactions, messages and updates will show up here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 13, height: 1.4),
          ),
        ],
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
      // Whole cell is tappable, not just the painted icon/label — otherwise a
      // tap on the surrounding padding registers as "nothing happened".
      behavior: HitTestBehavior.opaque,
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
