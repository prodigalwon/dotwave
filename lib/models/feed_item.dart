/// The kind of activity a [FeedItem] represents. Drives the leading glyph,
/// accent colour, tap behaviour, and (for messages) the privacy rule that
/// plaintext is never shown.
enum FeedKind {
  received,
  sent,
  message,
  name,
  cert,
  nameExpiring,
  certExpiring,
  post,
  system,
}

/// One entry in the Home "Recent Activity" feed.
///
/// Deliberately source-agnostic: on-chain value transfers, chat events,
/// identity/cert events (including upcoming expiries), and social posts all
/// normalise into this one shape so the feed can aggregate heterogeneous
/// sources into a single stream. Render order is newest-first (see
/// [FeedService]).
class FeedItem {
  /// Stable identity for dedupe/replace/dismiss (tx hash, message id, event key).
  final String id;
  final FeedKind kind;
  final DateTime time;

  /// The headline line — a counterparty/action ("Received from ferdie") or,
  /// for a post, the author.
  final String title;

  /// Secondary line: a description, expiry notice, or post body.
  ///
  /// NOTE: for [FeedKind.message] this is IGNORED — the feed never renders
  /// message plaintext, only that a message arrived from the named sender.
  final String? subtitle;

  /// Signed amount label for value transfers, e.g. "+12.5 RST" / "-4 RST".
  final String? amount;

  /// Seed for a generated avatar (a counterparty or author). Null → the feed
  /// card falls back to a [kind]-based glyph.
  final String? avatarSeed;

  /// Extra key/value rows shown in the detail popup (transactions, expiry).
  final Map<String, String>? details;

  const FeedItem({
    required this.id,
    required this.kind,
    required this.time,
    required this.title,
    this.subtitle,
    this.amount,
    this.avatarSeed,
    this.details,
  });

  bool get isTransfer => kind == FeedKind.received || kind == FeedKind.sent;
  bool get isExpiry =>
      kind == FeedKind.nameExpiring || kind == FeedKind.certExpiring;
}
