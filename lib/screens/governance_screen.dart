import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'referendum_detail_screen.dart';

// ─── Filter ────────────────────────────────────────────────────────────────

enum _Filter { all, active, executed }

extension _FilterExt on _Filter {
  String get label => switch (this) {
        _Filter.all => 'All',
        _Filter.active => 'Active',
        _Filter.executed => 'Executed',
      };

  bool matches(String status) {
    final s = status.toLowerCase();
    return switch (this) {
      _Filter.all => true,
      _Filter.active => s == 'deciding' ||
          s == 'confirmstarted' ||
          s == 'submitted' ||
          s == 'active',
      _Filter.executed => s == 'executed' || s == 'confirmed',
    };
  }
}

// ─── Screen ────────────────────────────────────────────────────────────────

class GovernanceScreen extends StatefulWidget {
  const GovernanceScreen({super.key});

  @override
  State<GovernanceScreen> createState() => _GovernanceScreenState();
}

class _GovernanceScreenState extends State<GovernanceScreen> {
  static const _pageSize = 25;

  // All posts fetched so far — filters and search operate on this cache
  final List<ReferendumPost> _allPosts = [];
  final ScrollController _scroll = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _page = 0;
  _Filter _filter = _Filter.all;
  String _query = '';

  List<ReferendumPost> get _visible {
    return _allPosts.where((p) {
      if (!_filter.matches(p.status)) return false;
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return p.displayTitle.toLowerCase().contains(q) ||
          p.method.toLowerCase().contains(q) ||
          p.status.toLowerCase().contains(q) ||
          p.proposer.toLowerCase().contains(q) ||
          p.postId.toString().contains(q);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _load();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 300 &&
        !_loadingMore &&
        _hasMore) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _page = 0;
      _allPosts.clear();
      _hasMore = true;
    });
    try {
      final posts = await _fetch(0);
      if (mounted) {
        setState(() {
          _allPosts.addAll(posts);
          _loading = false;
          _hasMore = posts.length == _pageSize;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final posts = await _fetch(next);
      if (mounted) {
        setState(() {
          _page = next;
          _allPosts.addAll(posts);
          _loadingMore = false;
          _hasMore = posts.length == _pageSize;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<List<ReferendumPost>> _fetch(int page) async {
    final uri = Uri.parse(
      'https://polkadot-api.subsquare.io/gov2/referendums'
      '?page=$page&page_size=$_pageSize',
    );
    final res = await http
        .get(uri, headers: {'Content-Type': 'application/json'})
        .timeout(const Duration(seconds: 15));

    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final items = (body['items'] as List?) ?? [];
    return items
        .map((e) => ReferendumPost.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        foregroundColor: Colors.white,
        title: const Text('Governance',
            style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                // Filter chips
                ..._Filter.values.map((f) {
                  final sel = f == _filter;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => setState(() => _filter = f),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: sel
                              ? const Color(0xFFE6007A)
                              : const Color(0xFF1E1E1E),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(f.label,
                            style: TextStyle(
                              color: sel ? Colors.white : Colors.white54,
                              fontSize: 12,
                              fontWeight: sel
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            )),
                      ),
                    ),
                  );
                }),
                // Search box
                Expanded(
                  child: Container(
                    height: 32,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: TextField(
                      controller: _searchCtrl,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12),
                      onChanged: (v) =>
                          setState(() => _query = v.trim()),
                      decoration: const InputDecoration(
                        hintText: 'Search…',
                        hintStyle: TextStyle(
                            color: Colors.white38, fontSize: 12),
                        prefixIcon: Icon(Icons.search,
                            size: 16, color: Colors.white38),
                        prefixIconConstraints:
                            BoxConstraints(minWidth: 32, minHeight: 0),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child:
                  CircularProgressIndicator(color: Color(0xFFE6007A)))
          : _error != null
              ? _ErrorView(error: _error!, onRetry: _load)
              : visible.isEmpty
                  ? const Center(
                      child: Text('No referenda',
                          style: TextStyle(color: Colors.white38)))
                  : RefreshIndicator(
                      color: const Color(0xFFE6007A),
                      backgroundColor: const Color(0xFF1E1E1E),
                      onRefresh: _load,
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        itemCount:
                            visible.length + (_loadingMore ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (i == visible.length) {
                            return const Padding(
                              padding:
                                  EdgeInsets.symmetric(vertical: 24),
                              child: Center(
                                child: CircularProgressIndicator(
                                    color: Color(0xFFE6007A)),
                              ),
                            );
                          }
                          return _PostCard(
                            post: visible[i],
                            query: _query,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ReferendumDetailScreen(
                                    post: visible[i]),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}

// ─── Data model ────────────────────────────────────────────────────────────

class ReferendumPost {
  final int postId;
  final String title;
  final String method;
  final String status;
  final int trackNo;
  final String proposer;
  final DateTime createdAt;
  final ReferendumTally? tally;

  const ReferendumPost({
    required this.postId,
    required this.title,
    required this.method,
    required this.status,
    required this.trackNo,
    required this.proposer,
    required this.createdAt,
    this.tally,
  });

  factory ReferendumPost.fromJson(Map<String, dynamic> j) {
    final onchain = j['onchainData'] as Map<String, dynamic>?;
    final state = j['state'] as Map<String, dynamic>?;
    final proposal = onchain?['proposal'] as Map<String, dynamic>?;

    ReferendumTally? tally;
    final tallyData = onchain?['tally'] as Map<String, dynamic>?;
    if (tallyData != null) tally = ReferendumTally.fromJson(tallyData);

    final createdAt =
        DateTime.tryParse(j['createdAt'] as String? ?? '') ??
            DateTime(2000);

    final method = [
      proposal?['section'] as String?,
      proposal?['method'] as String?,
    ].whereType<String>().join('.');

    return ReferendumPost(
      postId: (j['referendumIndex'] as num?)?.toInt() ?? 0,
      title: (j['title'] as String?) ?? '',
      method: method,
      status: (state?['name'] as String?) ?? '',
      trackNo: (j['track'] as num?)?.toInt() ?? 0,
      proposer: (j['proposer'] as String?) ?? '',
      createdAt: createdAt,
      tally: tally,
    );
  }

  String get displayTitle =>
      title.trim().isNotEmpty ? title : method;
}

class ReferendumTally {
  final BigInt ayes;
  final BigInt nays;
  final BigInt support;

  const ReferendumTally(
      {required this.ayes, required this.nays, required this.support});

  factory ReferendumTally.fromJson(Map<String, dynamic> j) {
    BigInt parse(String key) {
      try {
        final v = j[key];
        if (v == null) return BigInt.zero;
        final s = v.toString();
        return s.startsWith('0x') || s.startsWith('0X')
            ? BigInt.parse(s.substring(2), radix: 16)
            : BigInt.parse(s);
      } catch (_) {
        return BigInt.zero;
      }
    }

    return ReferendumTally(
        ayes: parse('ayes'),
        nays: parse('nays'),
        support: parse('support'));
  }

  double get ayeRatio {
    final total = ayes + nays;
    if (total == BigInt.zero) return 0.5;
    return (ayes / total).toDouble();
  }

  static String shortDot(BigInt planck) {
    const decimals = 12;
    final dot = planck / BigInt.from(10).pow(decimals);
    if (dot >= 1000000000) {
      return '${(dot / 1000000000).toStringAsFixed(1)}B DOT';
    }
    if (dot >= 1000000) return '${(dot / 1000000).toStringAsFixed(1)}M DOT';
    if (dot >= 1000) return '${(dot / 1000).toStringAsFixed(1)}K DOT';
    return '${dot.toStringAsFixed(2)} DOT';
  }
}

// ─── Helpers ───────────────────────────────────────────────────────────────

String relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 30) return '${diff.inDays}d ago';
  final months = (diff.inDays / 30).floor();
  if (months < 12) return '${months}mo ago';
  return '${(months / 12).floor()}y ago';
}

String truncateAddr(String addr) {
  if (addr.length <= 12) return addr;
  return '${addr.substring(0, 6)}…${addr.substring(addr.length - 4)}';
}

(Color, Color) statusColors(String status) {
  switch (status.toLowerCase()) {
    case 'executed':
    case 'confirmed':
      return (const Color(0xFF16A34A),
          const Color(0xFF16A34A).withOpacity(0.15));
    case 'deciding':
    case 'confirmstarted':
    case 'submitted':
      return (const Color(0xFFE6007A),
          const Color(0xFFE6007A).withOpacity(0.15));
    default:
      return (Colors.white54, Colors.white.withOpacity(0.06));
  }
}

/// Returns a TextSpan that highlights all occurrences of [query] in [text].
InlineSpan highlightText(String text, String query,
    {TextStyle? baseStyle}) {
  final base = baseStyle ?? const TextStyle(color: Colors.white);
  if (query.isEmpty) return TextSpan(text: text, style: base);

  final spans = <TextSpan>[];
  final lower = text.toLowerCase();
  final q = query.toLowerCase();
  int start = 0;

  while (true) {
    final idx = lower.indexOf(q, start);
    if (idx == -1) {
      if (start < text.length) {
        spans.add(TextSpan(text: text.substring(start), style: base));
      }
      break;
    }
    if (idx > start) {
      spans.add(
          TextSpan(text: text.substring(start, idx), style: base));
    }
    spans.add(TextSpan(
      text: text.substring(idx, idx + q.length),
      style: base.copyWith(
        backgroundColor: const Color(0xFFE6007A).withOpacity(0.4),
        color: Colors.white,
        fontWeight: FontWeight.bold,
      ),
    ));
    start = idx + q.length;
  }

  return TextSpan(children: spans);
}

// ─── Widgets ───────────────────────────────────────────────────────────────

class _PostCard extends StatelessWidget {
  final ReferendumPost post;
  final String query;
  final VoidCallback onTap;

  const _PostCard(
      {required this.post, required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final (statusColor, statusBg) = statusColors(post.status);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: ref # + track + status
            Row(
              children: [
                RichText(
                  text: highlightText(
                    '#${post.postId}',
                    query,
                    baseStyle: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('Track ${post.trackNo}',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 11)),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: statusBg,
                      borderRadius: BorderRadius.circular(6)),
                  child: RichText(
                    text: highlightText(
                      post.status,
                      query,
                      baseStyle: TextStyle(
                          color: statusColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Title
            RichText(
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              text: highlightText(
                post.displayTitle,
                query,
                baseStyle: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),
            ),

            const SizedBox(height: 8),

            // Proposer + time
            Row(
              children: [
                const Icon(Icons.person_outline,
                    size: 13, color: Colors.white38),
                const SizedBox(width: 4),
                RichText(
                  text: highlightText(
                    truncateAddr(post.proposer),
                    query,
                    baseStyle: const TextStyle(
                        color: Colors.white38, fontSize: 12),
                  ),
                ),
                const Spacer(),
                Text(relativeTime(post.createdAt),
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 12)),
              ],
            ),

            // Tally bar
            if (post.tally != null) ...[
              const SizedBox(height: 12),
              _TallyBar(tally: post.tally!),
            ],
          ],
        ),
      ),
    );
  }
}

class _TallyBar extends StatelessWidget {
  final ReferendumTally tally;
  const _TallyBar({required this.tally});

  @override
  Widget build(BuildContext context) {
    final ratio = tally.ayeRatio;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 6,
            child: Row(
              children: [
                Expanded(
                  flex: (ratio * 1000).round().clamp(1, 999),
                  child: Container(color: const Color(0xFF16A34A)),
                ),
                Expanded(
                  flex: ((1 - ratio) * 1000).round().clamp(1, 999),
                  child: Container(color: const Color(0xFFEF4444)),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            const Icon(Icons.thumb_up_outlined,
                size: 11, color: Color(0xFF16A34A)),
            const SizedBox(width: 3),
            Text(ReferendumTally.shortDot(tally.ayes),
                style: const TextStyle(
                    color: Color(0xFF16A34A),
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(ReferendumTally.shortDot(tally.nays),
                style: const TextStyle(
                    color: Color(0xFFEF4444),
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 3),
            const Icon(Icons.thumb_down_outlined,
                size: 11, color: Color(0xFFEF4444)),
          ],
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, color: Colors.white38, size: 48),
            const SizedBox(height: 16),
            const Text('Could not load referenda',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(error,
                style: const TextStyle(
                    color: Colors.white38, fontSize: 12),
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE6007A),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
