import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'governance_screen.dart';
import '../bridge/bridge_generated.dart/frb_generated.dart';
import '../widgets/transaction_blade.dart';

// ─── Models ────────────────────────────────────────────────────────────────

class _Comment {
  final String author;
  final String content;
  final DateTime createdAt;
  final List<_Comment> replies;

  const _Comment({
    required this.author,
    required this.content,
    required this.createdAt,
    required this.replies,
  });

  factory _Comment.fromJson(Map<String, dynamic> j) {
    final authorObj = j['author'] as Map<String, dynamic>?;
    final username = (authorObj?['username'] as String?) ?? '';
    final address = (authorObj?['address'] as String?) ?? '';
    final author = username.isNotEmpty ? username : truncateAddr(address);

    final replies = ((j['replies'] as List?) ?? [])
        .map((r) => _Comment.fromJson(r as Map<String, dynamic>))
        .toList();

    return _Comment(
      author: author.isNotEmpty ? author : 'Anonymous',
      content: (j['content'] as String?) ?? '',
      createdAt:
          DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime(2000),
      replies: replies,
    );
  }
}

// ─── Screen ────────────────────────────────────────────────────────────────

class ReferendumDetailScreen extends StatefulWidget {
  final ReferendumPost post;
  const ReferendumDetailScreen({super.key, required this.post});

  @override
  State<ReferendumDetailScreen> createState() =>
      _ReferendumDetailScreenState();
}

bool _isActiveReferendum(String status) {
  final s = status.toLowerCase();
  return s == 'deciding' || s == 'confirmstarted' || s == 'submitted' || s == 'active';
}

class _ReferendumDetailScreenState extends State<ReferendumDetailScreen> {
  static const _base = 'https://polkadot-api.subsquare.io';
  static const _mainnetRpc = 'wss://rpc.polkadot.io';

  String? _body;
  List<_Comment> _comments = [];
  bool _loadingBody = true;
  bool _loadingComments = true;
  String? _bodyError;
  String? _commentsError;

  @override
  void initState() {
    super.initState();
    _fetchDetail();
    _fetchComments();
  }

  Future<void> _fetchDetail() async {
    try {
      final res = await http
          .get(Uri.parse('$_base/gov2/referendums/${widget.post.postId}'))
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      setState(() {
        _body = (j['content'] as String?)?.trim() ?? '';
        _loadingBody = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _bodyError = 'Error: client appears to be offline';
        _loadingBody = false;
      });
    }
  }

  Future<void> _fetchComments() async {
    try {
      final res = await http
          .get(Uri.parse(
              '$_base/gov2/referendums/${widget.post.postId}/comments'))
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final items = (j['items'] as List?) ?? [];
      setState(() {
        _comments = items
            .map((e) => _Comment.fromJson(e as Map<String, dynamic>))
            .toList();
        _loadingComments = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _commentsError = 'Error: client appears to be offline';
        _loadingComments = false;
      });
    }
  }

  Future<void> _onVoteTap() async {
    final aye = await _showVoteChoiceSheet();
    if (aye == null || !mounted) return;
    await _showVoteBlade(aye: aye);
  }

  Future<bool?> _showVoteChoiceSheet() {
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Text(
                'Vote on #${widget.post.postId}',
                style: const TextStyle(
                  color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                widget.post.displayTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: _VoteChoiceButton(
                      label: 'Aye',
                      icon: Icons.thumb_up_outlined,
                      color: const Color(0xFF16A34A),
                      onTap: () => Navigator.pop(ctx, true),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _VoteChoiceButton(
                      label: 'Nay',
                      icon: Icons.thumb_down_outlined,
                      color: const Color(0xFFEF4444),
                      onTap: () => Navigator.pop(ctx, false),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showVoteBlade({required bool aye}) async {
    const storage = FlutterSecureStorage();
    final address = await storage.read(key: 'account_address') ?? '';
    const defaultBalance = '100000000000'; // 0.1 DOT

    if (!mounted) return;
    await TransactionBlade.show(
      context,
      TransactionBlade(
        transactionType: 'Governance Vote',
        rows: [
          TxRow('Referendum', '#${widget.post.postId}'),
          TxRow('Vote', aye ? 'Aye' : 'Nay',
              valueColor: aye ? const Color(0xFF16A34A) : const Color(0xFFEF4444)),
          TxRow('Conviction', '1x Locked'),
          TxRow('Amount', '0.1 DOT'),
        ],
        onConfirm: (phrase) => RustLib.instance.api.crateCoreVoteOnReferendum(
          referendumIndex: widget.post.postId,
          aye: aye,
          balancePlanck: defaultBalance,
          conviction: 1,
          rpcUrl: _mainnetRpc,
          phrase: phrase,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final (statusColor, statusBg) = statusColors(post.status);
    final tally = post.tally;
    final canVote = _isActiveReferendum(post.status);

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        foregroundColor: Colors.white,
        title: Text('#${post.postId}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        actions: [
          if (canVote)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: TextButton(
                onPressed: _onVoteTap,
                style: TextButton.styleFrom(
                  backgroundColor: const Color(0xFFE6007A).withOpacity(0.15),
                  foregroundColor: const Color(0xFFE6007A),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                child: const Text('Vote',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Status + Track + time ──
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                      color: statusBg,
                      borderRadius: BorderRadius.circular(8)),
                  child: Text(post.status,
                      style: TextStyle(
                          color: statusColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(8)),
                  child: Text('Track ${post.trackNo}',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12)),
                ),
                const Spacer(),
                Text(relativeTime(post.createdAt),
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 12)),
              ],
            ),

            const SizedBox(height: 16),

            // ── Title ──
            Text(
              post.displayTitle.isNotEmpty
                  ? post.displayTitle
                  : 'Referendum #${post.postId}',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  height: 1.35),
            ),

            if (post.method.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(8)),
                child: Text(post.method,
                    style: const TextStyle(
                        color: Color(0xFFE6007A),
                        fontSize: 12,
                        fontFamily: 'monospace')),
              ),
            ],

            const SizedBox(height: 20),
            const _Divider(),
            const SizedBox(height: 16),

            // ── Proposer + Created ──
            _DetailRow(
              icon: Icons.person_outline,
              label: 'Proposer',
              child: GestureDetector(
                onTap: () {
                  Clipboard.setData(
                      ClipboardData(text: post.proposer));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Address copied')),
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(truncateAddr(post.proposer),
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14)),
                    const SizedBox(width: 6),
                    const Icon(Icons.copy_outlined,
                        size: 13, color: Colors.white38),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 14),

            _DetailRow(
              icon: Icons.schedule_outlined,
              label: 'Created',
              child: Text(_formatDate(post.createdAt),
                  style: const TextStyle(
                      color: Colors.white, fontSize: 14)),
            ),

            const SizedBox(height: 20),
            const _Divider(),
            const SizedBox(height: 20),

            // ── Vote Tally ──
            if (tally != null) ...[
              const _SectionTitle('Vote Tally'),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  height: 10,
                  child: Row(
                    children: [
                      Expanded(
                        flex: (tally.ayeRatio * 1000)
                            .round()
                            .clamp(1, 999),
                        child: Container(
                            color: const Color(0xFF16A34A)),
                      ),
                      Expanded(
                        flex: ((1 - tally.ayeRatio) * 1000)
                            .round()
                            .clamp(1, 999),
                        child: Container(
                            color: const Color(0xFFEF4444)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _VoteBox(
                    label: 'Aye',
                    amount: ReferendumTally.shortDot(tally.ayes),
                    percent:
                        '${(tally.ayeRatio * 100).toStringAsFixed(1)}%',
                    color: const Color(0xFF16A34A),
                    icon: Icons.thumb_up_outlined,
                  ),
                  const SizedBox(width: 12),
                  _VoteBox(
                    label: 'Nay',
                    amount: ReferendumTally.shortDot(tally.nays),
                    percent:
                        '${((1 - tally.ayeRatio) * 100).toStringAsFixed(1)}%',
                    color: const Color(0xFFEF4444),
                    icon: Icons.thumb_down_outlined,
                  ),
                ],
              ),
              if (tally.support > BigInt.zero) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    children: [
                      const Icon(Icons.how_to_vote_outlined,
                          size: 16, color: Colors.white38),
                      const SizedBox(width: 8),
                      const Text('Support',
                          style: TextStyle(
                              color: Colors.white54, fontSize: 13)),
                      const Spacer(),
                      Text(ReferendumTally.shortDot(tally.support),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ],
            ] else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(12)),
                child: const Center(
                  child: Text('No tally data yet',
                      style: TextStyle(
                          color: Colors.white38, fontSize: 14)),
                ),
              ),
            ],

            const SizedBox(height: 24),
            const _Divider(),
            const SizedBox(height: 20),

            // ── Proposal Body ──
            const _SectionTitle('Proposal'),
            const SizedBox(height: 12),
            if (_loadingBody)
              const _LoadingRow()
            else if (_bodyError != null)
              _ErrorRow(message: _bodyError!, onRetry: _fetchDetail)
            else if (_body == null || _body!.isEmpty)
              const Text('No description provided.',
                  style: TextStyle(color: Colors.white38, fontSize: 14))
            else
              _BodyText(content: _body!),

            const SizedBox(height: 28),
            const _Divider(),
            const SizedBox(height: 20),

            // ── Discussion ──
            Row(
              children: [
                const _SectionTitle('Discussion'),
                if (!_loadingComments && _commentsError == null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(10)),
                    child: Text('${_comments.length}',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),

            if (_loadingComments)
              const _LoadingRow()
            else if (_commentsError != null)
              _ErrorRow(
                  message: _commentsError!, onRetry: _fetchComments)
            else if (_comments.isEmpty)
              const Text('No comments yet.',
                  style: TextStyle(
                      color: Colors.white38, fontSize: 14))
            else
              ..._comments.map((c) => _CommentTile(comment: c)),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}  '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')} UTC';
  }
}

// ─── Body rendering ────────────────────────────────────────────────────────

/// Renders markdown-ish content as readable text without a full MD parser.
class _BodyText extends StatefulWidget {
  final String content;
  const _BodyText({required this.content});

  @override
  State<_BodyText> createState() => _BodyTextState();
}

class _BodyTextState extends State<_BodyText> {
  bool _expanded = false;
  static const _previewLines = 12;

  @override
  Widget build(BuildContext context) {
    final lines = widget.content.split('\n');
    final isLong = lines.length > _previewLines;
    final shown = _expanded || !isLong
        ? widget.content
        : lines.take(_previewLines).join('\n');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          shown,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 14,
            height: 1.6,
          ),
        ),
        if (isLong) ...[
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Text(
              _expanded ? 'Show less' : 'Read more…',
              style: const TextStyle(
                color: Color(0xFFE6007A),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ─── Helpers ───────────────────────────────────────────────────────────────

// Returns true if [text] appears to be in a script the [deviceLang] user
// cannot read — i.e. there is a script mismatch worth translating.
bool _needsTranslation(String text, String deviceLang) {
  // Map each script's regex to the language codes that natively use it.
  final scripts = <RegExp, List<String>>{
    RegExp(r'[\u3040-\u309F\u30A0-\u30FF]'):        ['ja'],           // Hiragana / Katakana
    RegExp(r'[\u4E00-\u9FFF\u3400-\u4DBF]'):        ['zh', 'ja'],     // CJK
    RegExp(r'[\uAC00-\uD7AF]'):                     ['ko'],           // Hangul
    RegExp(r'[\u0600-\u06FF]'):                     ['ar', 'fa', 'ur', 'ps'],  // Arabic
    RegExp(r'[\u0590-\u05FF]'):                     ['he', 'yi'],              // Hebrew / Yiddish
    RegExp(r'[\u0400-\u04FF]'):                     ['ru', 'uk', 'bg', 'sr', 'mk', 'be'],  // Cyrillic
    RegExp(r'[\u0900-\u097F]'):                     ['hi', 'mr', 'ne', 'sa'],        // Devanagari
    RegExp(r'[\u0980-\u09FF]'):                     ['bn', 'as'],                    // Bengali
    RegExp(r'[\u0A00-\u0A7F]'):                     ['pa'],                          // Gurmukhi (Punjabi)
    RegExp(r'[\u0A80-\u0AFF]'):                     ['gu'],                          // Gujarati
    RegExp(r'[\u0B00-\u0B7F]'):                     ['or'],                          // Odia
    RegExp(r'[\u0B80-\u0BFF]'):                     ['ta'],                          // Tamil
    RegExp(r'[\u0C00-\u0C7F]'):                     ['te'],                          // Telugu
    RegExp(r'[\u0C80-\u0CFF]'):                     ['kn'],                          // Kannada
    RegExp(r'[\u0D00-\u0D7F]'):                     ['ml'],                          // Malayalam
    RegExp(r'[\u0D80-\u0DFF]'):                     ['si'],                          // Sinhala
    RegExp(r'[\u0F00-\u0FFF]'):                     ['bo'],                          // Tibetan
    RegExp(r'[\u1000-\u109F]'):                     ['my'],                          // Myanmar/Burmese
    RegExp(r'[\u1780-\u17FF]'):                     ['km'],                          // Khmer
    RegExp(r'[\u0E00-\u0E7F]'):                     ['th'],           // Thai
    RegExp(r'[\u0370-\u03FF]'):                     ['el'],           // Greek
    RegExp(r'[\u1200-\u137F]'):                     ['am', 'ti'],     // Ethiopic (Amharic, Tigrinya)
    RegExp(r'[\u10A0-\u10FF]'):                     ['ka'],           // Georgian
    RegExp(r'[\u0530-\u058F]'):                     ['hy'],           // Armenian
    RegExp(r'[\u1800-\u18AF]'):                     ['mn'],           // Mongolian
    RegExp(r'[\u0E80-\u0EFF]'):                     ['lo'],           // Lao
    RegExp(r'[\u1EA0-\u1EF9]'):                     ['vi'],           // Vietnamese (tonal diacritics)
    RegExp(r'[\u015F\u011F\u0131]'):                ['tr', 'az'],     // Turkish / Azerbaijani (ş, ğ, ı)
    RegExp(r'[\u0141\u0142\u0105\u0119\u015B\u017A\u017C\u0107\u0144]'): ['pl'], // Polish (ł ą ę ś ź ż ć ń)
    RegExp(r'[\u010D\u0161\u017E\u0159\u016F\u010F]'):               ['cs', 'sk'], // Czech / Slovak (č š ž ř ů ď)
    RegExp(r'[\u0219\u021B]'):                                       ['ro'],       // Romanian (ș ț — comma-below, distinct from Turkish ş)
    RegExp(r'[\u0151\u0171]'):                                       ['hu'],       // Hungarian (ő ű — double acute, unique)
  };

  for (final entry in scripts.entries) {
    if (entry.key.hasMatch(text) && !entry.value.contains(deviceLang)) {
      return true;
    }
  }
  return false;
}

// ─── Comment tile ──────────────────────────────────────────────────────────

class _CommentTile extends StatefulWidget {
  final _Comment comment;
  final int depth;
  const _CommentTile({required this.comment, this.depth = 0});

  @override
  State<_CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends State<_CommentTile> {
  String? _translation;
  bool _translating = false;
  String? _translateError;

  Future<void> _translate(String targetLang) async {
    if (_translating) return;
    setState(() { _translating = true; _translateError = null; });
    try {
      final encoded = Uri.encodeComponent(widget.comment.content);
      final uri = Uri.parse(
          'https://api.mymemory.translated.net/get?q=$encoded&langpair=auto|$targetLang');
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final text =
          (j['responseData']?['translatedText'] as String?) ?? '';
      if (text.isEmpty) throw Exception('Empty response');
      setState(() { _translation = text; _translating = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _translateError = 'Translation failed';
        _translating = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final comment = widget.comment;
    final depth = widget.depth;
    final deviceLang = Localizations.localeOf(context).languageCode;
    final needsTranslate = _needsTranslation(comment.content, deviceLang);

    return Container(
      margin: EdgeInsets.only(
          left: depth * 16.0, bottom: depth == 0 ? 14 : 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: depth == 0
            ? const Color(0xFF1A1A1A)
            : const Color(0xFF161616),
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: depth > 0
              ? const BorderSide(color: Color(0xFFE6007A), width: 2)
              : BorderSide.none,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Author + translate + time
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: const Color(0xFFE6007A).withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    comment.author.isNotEmpty
                        ? comment.author[0].toUpperCase()
                        : '?',
                    style: const TextStyle(
                        color: Color(0xFFE6007A),
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  comment.author,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (needsTranslate && _translation == null) ...[
                GestureDetector(
                  onTap: () => _translate(
                      Localizations.localeOf(context).languageCode),
                  child: _translating
                      ? const SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(
                              color: Color(0xFF22C55E), strokeWidth: 1.5),
                        )
                      : Text(
                          _translateError != null ? 'Retry' : 'Translate',
                          style: TextStyle(
                            color: _translateError != null
                                ? Colors.redAccent
                                : const Color(0xFF22C55E),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
                const SizedBox(width: 8),
              ],
              if (_translation != null)
                GestureDetector(
                  onTap: () =>
                      setState(() => _translation = null),
                  child: const Text(
                    'Original',
                    style: TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        fontWeight: FontWeight.w500),
                  ),
                ),
              if (_translation != null) const SizedBox(width: 8),
              Text(
                relativeTime(comment.createdAt),
                style: const TextStyle(
                    color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Content or translation
          if (_translation != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 4),
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF22C55E).withOpacity(0.08),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.translate,
                      size: 11, color: Color(0xFF22C55E)),
                  SizedBox(width: 4),
                  Text('Translated',
                      style: TextStyle(
                          color: Color(0xFF22C55E), fontSize: 10)),
                ],
              ),
            ),
            SelectableText(
              _translation!,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.5),
            ),
          ] else
            SelectableText(
              comment.content,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.5),
            ),

          // Replies
          if (comment.replies.isNotEmpty) ...[
            const SizedBox(height: 10),
            ...comment.replies.map((r) =>
                _CommentTile(comment: r, depth: depth + 1)),
          ],
        ],
      ),
    );
  }
}

// ─── Shared small widgets ──────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold),
      );
}

class _LoadingRow extends StatelessWidget {
  const _LoadingRow();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: CircularProgressIndicator(
              color: Color(0xFFE6007A), strokeWidth: 2),
        ),
      );
}

class _ErrorRow extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorRow({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.error_outline,
            color: Colors.redAccent, size: 16),
        const SizedBox(width: 6),
        Expanded(
          child: Text(message,
              style: const TextStyle(
                  color: Colors.redAccent, fontSize: 12)),
        ),
        GestureDetector(
          onTap: onRetry,
          child: const Text('Retry',
              style: TextStyle(
                  color: Color(0xFFE6007A),
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) =>
      const Divider(color: Colors.white12, height: 1);
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget child;
  const _DetailRow(
      {required this.icon, required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: Colors.white38),
        const SizedBox(width: 10),
        SizedBox(
          width: 80,
          child: Text(label,
              style: const TextStyle(
                  color: Colors.white38, fontSize: 13)),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _VoteChoiceButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _VoteChoiceButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.4), width: 1.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(label,
                style: TextStyle(
                    color: color,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

class _VoteBox extends StatelessWidget {
  final String label;
  final String amount;
  final String percent;
  final Color color;
  final IconData icon;

  const _VoteBox({
    required this.label,
    required this.amount,
    required this.percent,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 5),
                Text(label,
                    style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(percent,
                    style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 6),
            Text(amount,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}
