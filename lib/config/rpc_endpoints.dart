/// Centralized RPC endpoints for dotwave.
///
/// Screens and services reference [RpcEndpoints] constants rather
/// than hardcoding URLs inline. When the chain we're pointed at
/// changes (testnet ↔ mainnet, localhost ↔ deployed), update here
/// once and every caller moves together.
///
/// Rule of thumb: any WebSocket URL that lives in more than one
/// screen belongs here. One-offs can stay inline if they're genuinely
/// one-off.
class RpcEndpoints {
  /// pns-node chain — authoritative for PNS pallets (registrar,
  /// resolvers, marketplace, price oracle) and the home account
  /// balance + extrinsic submission path.
  ///
  /// Canonical subdomain naming family on substrate.icu:
  ///   rpc.substrate.icu        → pns-node (current)
  ///   paseorpc.substrate.icu   → Paseo vanilla (future)
  ///   dotrpc.substrate.icu     → Polkadot mainnet
  ///   dotahrpc.substrate.icu   → Polkadot Asset Hub
  ///   kusrpc.substrate.icu     → Kusama
  ///   kusahrpc.substrate.icu   → Kusama Asset Hub
  ///   westrpc.substrate.icu    → Westend
  ///
  /// Local dev node override is the developer's responsibility — set
  /// via an environment flag if we ever add one.
  static const pnsNode = 'wss://rpc.substrate.icu';

  /// Polkadot Asset Hub — non-DOT asset balances (USDT, USDC, etc.).
  /// Not PNS-related; a pure Polkadot ecosystem lookup.
  ///
  /// TODO(nginx): move to `wss://dotahrpc.substrate.icu` once the
  /// subdomain is provisioned. Keeps all chain traffic on our
  /// infrastructure rather than a third-party public endpoint.
  static const assetHub = 'wss://asset-hub-polkadot.dotters.network';

  /// Polkadot mainnet RPC — used by the governance screen for
  /// read-only display of live referenda. dotwave does not submit
  /// votes here; the screen is observational.
  ///
  /// TODO(nginx): move to `wss://dotrpc.substrate.icu` once the
  /// subdomain is provisioned.
  ///
  /// TODO(beta launch): for the Paseo-targeted public beta we either
  /// (a) point this at Paseo so users see testnet referenda matching
  /// the chain they're transacting on, or (b) clearly label the
  /// governance screen as "live Polkadot view" while keeping the rest
  /// of the app on Paseo.
  static const polkadotMainnet = 'wss://rpc.polkadot.io';
}
