# Chat Guard Discovery

Authenticated, dynamic discovery of chat-capable community nodes ("guards") so
dotwave can spread dead-drops across many guards at random instead of being
pinned to one. Spans two threads: the **dotwave client** (this worktree) and the
**gemini-node RPC** (separate thread — this doc is the shared contract).

Status: client side building on `app-polish-v0`. Node side TODO.

---

## 1. Goal

Today a dotwave client sends every onion drop through a single, hand-configured
guard (`ChatStore.nodeRpc`) and a single hand-configured relay-2
(`ChatStore.relay2Rpc`). That guard sees every drop the user makes — it can
profile sending patterns — and it's a single point of failure/censorship.

We want the client to learn the set of currently-live guards and pick a random
guard (and relay-2) per drop/shard, so:

- no single guard sees a user's whole message or whole sending pattern;
- a guard going offline doesn't stop messaging;
- load spreads across the community.

## 2. Why dynamic discovery, not a published list

Guards are **community nodes under no obligation to be available** — they join
and leave the network constantly. A static or SRT-signed list is the wrong tool:
it would be stale the moment it's published, and it implies an authority over a
set that is meant to be permissionless.

The key realization: **the chat gossipsub's admission gate IS the guard
registry.** Only community nodes can enter the chat channel (the memcache of
bucketed/sharded messages lives there), and joining the network requires RNS
registration, so every channel member is bound to an accountable owner.
Therefore:

- The authoritative guard set = **current chat-channel membership** — live,
  self-maintaining, already gated.
- Discovery = a node answering *"which channel members have I seen recently?"*
- Eclipse resistance is bounded by the **channel admission gate**, not by any
  external list. Fake guards would have to pass channel admission to appear.

dotwave is an external RPC client and is **not** in the gossipsub, so a
connected node is its only window into channel membership.

## 3. Threat model / why this MUST be authenticated

Peer enumeration is a map of the relay/guard topology. Unauthenticated, it hands
an adversary — for free — the target list for relay DoS, the layout for
strategic Sybil placement, and the setup for traffic-correlation. So:

- **Discovery is gated behind an active HW-cert chat session.** No session →
  the response is indistinguishable from an unadmitted onion drop (no list, no
  info-leaking error). Enumeration then costs an attested device + a live
  handshake, which is rate-limitable and accountable.
- The gate is only ever as strong as the cert/attestation enforcement behind the
  session. See the parked finding (guard admits drops on `Active` alone, no
  ChatAuth-EKU check). Discovery inherits that and hardens automatically when the
  chain-side gate does.

## 4. Trust model: trust but verify

- The node **signs** its discovery response so the client can attribute it and
  detect tampering.
- Each returned guard is just a **PeerID / dialable address** — nothing the node
  self-asserts about the guard is trusted. The client independently
  **RNS-resolves each guard's owner against whatever RPC node it likes** for
  accountability. Never trust a guard to tell you who it is.
- The client caches each guard with **timestamps** ("node last saw it", "I last
  reached it") and prunes stale entries. Trust decays with time-since-seen.

## 5. Wire contract (client ⇄ node)

### 5.1 Request — `chat_guards`

Client → the node it is connected to. Must prove an active session, reusing the
same credential the onion drop uses (no new auth scheme). Domain-separated,
timestamped, nonce'd, signed:

```
digest = blake2_256(CHAT_GUARDS_DOMAIN ‖ nonce ‖ ts_be)
```

Params (one of the two auth carriers, matching the drop paths):
- session path: `{ session_key_hex, ts, nonce, sig }`  (sig by session key)
- cert path:    `{ cert_thumbprint_hex, ts, nonce, sig }` (sig by cert device key)

Node MUST verify: ts within skew window; session admitted / cert `Active`;
signature valid. Otherwise reject exactly as an unadmitted drop (no distinct
error).

### 5.2 Response — signed guard list

```
{
  responder: <node identity: address/PeerID (RNS-resolvable by the client)>,
  ts, nonce,                       // nonce echoes the request; anti-replay
  guards: [ { address, last_seen_secs }, ... ],
  sig,                             // node signs the whole response, see below
}
sig = node_key.sign( blake2_256(
        CHAT_GUARDS_RESP_DOMAIN ‖ responder ‖ ts ‖ nonce ‖ scale(guards) ) )
```

- `address` — a **PeerID / dialable address** for the guard. This is all the
  client needs: it dials it for drops and RNS-resolves it for accountability.
  There is NO separate "advertised RPC endpoint" record — the address a channel
  member already has is sufficient. Exact encoding is a node-side decision
  (**OPEN**); from the client's view it is an opaque dial string that goes where
  today's RPC-URL config goes.
- `last_seen_secs` — node's most recent sighting of that member in the channel.

### 5.3 Node responsibilities

- Source = recently-seen chat-channel members (the bucket/peer view, e.g.
  `chat_bucket_cache`), filtered to those seen within a recency window.
- **Bound the response** (e.g. ≤ 16) and prefer a **random sample** rather than
  the full table, so one authed cert can't map the whole topology in a call.
- **Rate-limit per session/cert.**
- Sign with the node key.
- OPEN (node thread): address encoding; sample size N; recency window;
  rate-limit policy; whether the signing key is the node key or the node's cert.

## 6. Client responsibilities (dotwave)

- **Authenticate first.** Only attempt discovery once the account holds an
  admission cert / active session (honor the gate client-side too; don't spam
  the endpoint pre-auth).
- **Cache** each guard as `{ address, node_last_seen, my_last_contact }`,
  persisted; prune entries past a staleness TTL.
- **Random spread.** Per drop (and per shard), pick a random *distinct* pair
  from the fresh set — one guard, one relay-2 — using a CSPRNG so selection isn't
  predictable. Fall back to the hand-configured guard/relay-2 when the cache
  can't supply a distinct pair (preserves today's behavior until discovery is
  populated).
- **Independent accountability.** RNS-resolve each guard's owner via any RPC node
  (recorded now; enforcement deferred — see §7).
- **Per-guard sessions.** Randomizing the guard means the membership/cert session
  is per-guard; the existing stale-session re-handshake path already covers this
  (more handshakes is the accepted cost of guard diversity).

## 7. Out of scope now (deliberately)

Single operator owns all nodes today, so these are recorded, not built:

- Eclipse mitigation by unioning discovery from multiple independent nodes.
- Strict enforcement of the response signature / per-guard RNS binding (recorded
  and verifiable; not yet a hard gate).
- On-chain node-key ↔ attestation binding (parked PQ node-identity Stage 3).

The design changes nothing for these to turn on later — that's the sign it's the
right shape.

## 8. Client build map (this worktree)

- `lib/services/guard_discovery_service.dart` — `ChatGuard` model + `GuardDiscovery`
  singleton: persisted cache (load/save/prune), `ingest()` merge with timestamps,
  `pickGuardAndRelay()` random distinct-pair selection with fallback, and a
  `refreshGuards()` that authenticates + fetches + ingests.
- The actual fetch calls the rust_core bridge fn `chatDiscoverGuards` (**TODO** —
  does not exist yet; wired behind a seam so the cache/selection logic is real
  and compiles today). Bridge signature to add:
  `chatDiscoverGuards({ rpcUrl, certThumbprintHex, certSeedHex }) -> List<GuardEntry{address, lastSeenSecs}>`.
- `ChatStore.send` selects `(guard, relay2)` via `GuardDiscovery` with fallback
  to `nodeRpc()`/`relay2Rpc()`.
