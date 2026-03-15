import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'governance_screen.dart';

class ReferendumDetailScreen extends StatelessWidget {
  final ReferendumPost post;
  const ReferendumDetailScreen({super.key, required this.post});

  @override
  Widget build(BuildContext context) {
    final (statusColor, statusBg) = statusColors(post.status);
    final tally = post.tally;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        foregroundColor: Colors.white,
        title: Text('#${post.postId}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status + Track row
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: statusBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    post.status,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Track ${post.trackNo}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                const Spacer(),
                Text(
                  relativeTime(post.createdAt),
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Title
            Text(
              post.displayTitle.isNotEmpty
                  ? post.displayTitle
                  : 'Referendum #${post.postId}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
                height: 1.35,
              ),
            ),

            if (post.method.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  post.method,
                  style: const TextStyle(
                    color: Color(0xFFE6007A),
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],

            const SizedBox(height: 24),
            const _Divider(),
            const SizedBox(height: 20),

            // Proposer
            _DetailRow(
              icon: Icons.person_outline,
              label: 'Proposer',
              child: GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: post.proposer));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Address copied')),
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      truncateAddr(post.proposer),
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14),
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.copy_outlined,
                        size: 13, color: Colors.white38),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Created
            _DetailRow(
              icon: Icons.schedule_outlined,
              label: 'Created',
              child: Text(
                _formatDate(post.createdAt),
                style:
                    const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),

            const SizedBox(height: 24),
            const _Divider(),
            const SizedBox(height: 20),

            // Tally section
            if (tally != null) ...[
              const Text(
                'Vote Tally',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),

              // Aye / Nay bar
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  height: 10,
                  child: Row(
                    children: [
                      Expanded(
                        flex: (tally.ayeRatio * 1000).round().clamp(1, 999),
                        child: Container(color: const Color(0xFF16A34A)),
                      ),
                      Expanded(
                        flex: ((1 - tally.ayeRatio) * 1000)
                            .round()
                            .clamp(1, 999),
                        child: Container(color: const Color(0xFFEF4444)),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

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
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.how_to_vote_outlined,
                          size: 16, color: Colors.white38),
                      const SizedBox(width: 8),
                      const Text('Support',
                          style: TextStyle(
                              color: Colors.white54, fontSize: 13)),
                      const Spacer(),
                      Text(
                        ReferendumTally.shortDot(tally.support),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Center(
                  child: Text('No tally data yet',
                      style:
                          TextStyle(color: Colors.white38, fontSize: 14)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}  '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')} UTC';
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
              style:
                  const TextStyle(color: Colors.white38, fontSize: 13)),
        ),
        Expanded(child: child),
      ],
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
            Text(
              amount,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
