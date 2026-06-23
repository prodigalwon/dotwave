/// Centralized RPC endpoints for dotwave.
///
/// Screens and services reference [RpcEndpoints] constants rather
/// than hardcoding URLs inline. When the chain we're pointed at
/// changes (lab ↔ deployed testnet), update here once and every
/// caller moves together.
///
/// Rule of thumb: any WebSocket URL that lives in more than one
/// screen belongs here. One-offs can stay inline if they're genuinely
/// one-off.
///
/// dotwave's home is Rostro (rostro.org). Rostro's public
/// infrastructure is not built out yet — there is no `rpc.rostro.org`
/// today — so every endpoint below points at the local Rostro lab
/// node. When the public testnet stands up, the lab address is
/// replaced by the `rpc.rostro.org` family noted in the comments.
class RpcEndpoints {
  /// Rostro chain node — authoritative for PNS pallets (registrar,
  /// resolvers, marketplace, price oracle), the home account balance,
  /// and the extrinsic submission path.
  ///
  /// Current: local Rostro lab node over plain ws (loopback, no TLS).
  /// Future public default: `wss://rpc.rostro.org`.
  static const chain = 'ws://127.0.0.1:9954';

  /// Back-compat alias. Older screens reference [pnsNode]; the Rostro
  /// chain node serves the PNS pallets, so it resolves to [chain].
  static const pnsNode = chain;

  /// Chat relay node — the gemini-node this device dispatches encrypted
  /// envelopes through (`chat_send_envelope`) and pulls shares from
  /// (`chat_fetch_shares`). The same node serves chain + chat RPC, so
  /// this defaults to [chain]; in the lab it can be overridden per-device
  /// to a LAN node's address via the in-app node setting
  /// (`ChatStore.nodeRpc`).
  static const chatNode = chain;

  // --- DORMANT (pending Rostro public testnet) ---------------------
  //
  // The governance screen is hidden in the live app: Rostro has no
  // referendum indexer yet, and on-chain governance is out of scope
  // until testnet. The screen code is kept dormant in-repo and the
  // constant below is retained only so it continues to compile. It is
  // NOT used by any reachable screen and must be repointed at a Rostro
  // indexer before governance is re-enabled. Do not wire new code to it.
  static const governanceIndexer = 'wss://rpc.rostro.org';
}
