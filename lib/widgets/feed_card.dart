import 'package:flutter/material.dart';

import '../models/feed_item.dart';
import '../theme.dart';
import 'chat_avatar.dart';

/// One card in the Home activity feed — social-feed styled: a leading avatar
/// or kind glyph, a headline + timestamp, an optional preview line, and an
/// optional signed amount for value transfers.
class FeedCard extends StatelessWidget {
  final FeedItem item;
  final VoidCallback? onTap;
  const FeedCard({super.key, required this.item, this.onTap});

  ({IconData icon, Color color}) get _kindStyle {
    switch (item.kind) {
      case FeedKind.received:
        return (icon: Icons.south_west, color: AppTheme.success);
      case FeedKind.sent:
        return (icon: Icons.north_east, color: AppTheme.accent);
      case FeedKind.message:
        return (icon: Icons.chat_bubble_outline, color: AppTheme.accent);
      case FeedKind.name:
        return (icon: Icons.badge_outlined, color: AppTheme.accent);
      case FeedKind.cert:
        return (icon: Icons.verified_user_outlined, color: AppTheme.success);
      case FeedKind.nameExpiring:
        return (icon: Icons.schedule, color: AppTheme.warning);
      case FeedKind.certExpiring:
        return (icon: Icons.gpp_maybe_outlined, color: AppTheme.warning);
      case FeedKind.post:
        return (icon: Icons.article_outlined, color: AppTheme.accent);
      case FeedKind.system:
        return (icon: Icons.info_outline, color: Colors.white54);
    }
  }

  /// The preview line under the title. Messages are privacy-gated: the feed
  /// never renders their plaintext, only a "tap to read" affordance.
  Widget? _preview() {
    if (item.kind == FeedKind.message) {
      return const Text(
        'Encrypted message · tap to read',
        style: TextStyle(
          color: Colors.white60,
          fontSize: 13,
          fontStyle: FontStyle.italic,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    if (item.subtitle == null) return null;
    return Text(
      item.subtitle!,
      style: const TextStyle(color: Colors.white60, fontSize: 13, height: 1.3),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ks = _kindStyle;
    final amount = item.amount;
    final isCredit = item.kind == FeedKind.received;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderSubtle),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Leading: a counterparty/author avatar, else a kind glyph.
                if (item.avatarSeed != null)
                  ChatAvatar(seed: item.avatarSeed!, size: 44)
                else
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: ks.color.withValues(alpha: 0.12),
                    ),
                    child: Icon(ks.icon, color: ks.color, size: 20),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              item.title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _relTime(item.time),
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 12),
                          ),
                        ],
                      ),
                      if (_preview() case final preview?) ...[
                        const SizedBox(height: 3),
                        preview,
                      ],
                      if (amount != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          amount,
                          style: TextStyle(
                            color: isCredit ? AppTheme.success : Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Detail popup for a tapped feed item — transactions, expiries, and other
/// non-message events. (Messages open the conversation instead, so their
/// plaintext is never surfaced here.)
class FeedDetailDialog extends StatelessWidget {
  final FeedItem item;
  const FeedDetailDialog({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final amount = item.amount;
    final isCredit = item.kind == FeedKind.received;
    return Dialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(_absTime(item.time),
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
            if (amount != null) ...[
              const SizedBox(height: 16),
              Text(
                amount,
                style: TextStyle(
                  color: isCredit ? AppTheme.success : Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
            if (item.subtitle != null) ...[
              const SizedBox(height: 12),
              Text(
                item.subtitle!,
                style: const TextStyle(
                    color: Colors.white70, fontSize: 14, height: 1.4),
              ),
            ],
            if (item.details != null) ...[
              const SizedBox(height: 16),
              for (final e in item.details!.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(e.key,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 13)),
                      const SizedBox(width: 16),
                      Flexible(
                        child: Text(
                          e.value,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _absTime(DateTime t) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final ap = t.hour < 12 ? 'AM' : 'PM';
  final m = t.minute.toString().padLeft(2, '0');
  return '${months[t.month - 1]} ${t.day}, ${t.year} · $h:$m $ap';
}

/// Compact relative time for a feed row (now / 6m / 4h / 2d / 3w).
String _relTime(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  return '${(d.inDays / 7).floor()}w';
}
