/// Rough block-count → wall-clock rendering for expiry countdowns.
/// 6s target block time (Sassafras slots on the lab chain); estimates only,
/// never used for on-chain math.
const int secondsPerBlock = 6;

/// "~42 days", "~3 hours", "~5 minutes", or "now" for non-positive deltas.
String approxDurationFromBlocks(int blocks) {
  if (blocks <= 0) return 'now';
  final seconds = blocks * secondsPerBlock;
  if (seconds >= 86400) {
    final days = (seconds / 86400).round();
    return '~$days day${days == 1 ? '' : 's'}';
  }
  if (seconds >= 3600) {
    final hours = (seconds / 3600).round();
    return '~$hours hour${hours == 1 ? '' : 's'}';
  }
  final minutes = (seconds / 60).ceil();
  return '~$minutes minute${minutes == 1 ? '' : 's'}';
}
