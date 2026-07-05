// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rostro Foundation contributors

//! On-device chat — dotwave's port of `rostro-chat-cli`'s proven
//! send/recover flow into `rust_core`, exposed to Flutter via
//! flutter_rust_bridge.
//!
//! Architecture (unchanged from the CLI, which was the explicit
//! stand-in for this SDK):
//!   * the user's chat-identity Ed25519 keypair lives on the device,
//!   * all sealing/signing on send and unsealing/verifying on recover
//!     happen on-device,
//!   * the gemini-node sees only the encrypted envelope + routing
//!     metadata — never plaintext or user keys.
//!
//! The RPC calls reuse dotwave's existing `subxt::rpcs::RpcClient`
//! (the same transport `core.rs` uses for `system_accountNextIndex`),
//! so no new RPC stack is introduced.
//!
//! Crypto calls are byte-identical to
//! `substrate/bin/utils/rostro-chat-cli/src/main.rs`:
//!   send:    `sign_inner` → `ss_seal` → `SealedEnvelope` →
//!             `prepare_batch` → `chat_send_prepared`
//!   recover: `chat_fetch_shares` → group-by-message_id →
//!             `combine_chunks_verified`
//!            → `ss_unseal` → `verify_sender`
//!
//! The two `auth_*` parameters on [`chat_send`] are the cert-auth
//! layer (Phase 2): the caller passes the zkpki cert thumbprint + the
//! P-256 cert secret, and `chat_send` signs
//! `blake2_256(CHAT_AUTH_DOMAIN || envelope_bytes || ts_be)` with the
//! cert key so the node's `verify_chat_auth` admits the drop. Passing
//! `None` takes the unauthenticated dev path, which a flipped
//! (production) node rejects. On real hardware the P-256 signing moves
//! into StrongBox/TPM; the digest + wire format stay identical.

use std::collections::HashMap;

use parity_scale_codec::{Decode, Encode};
// rand_core 0.6 — aliased because rust_core's other code is on
// rand_core 0.10, whose RngCore/CryptoRng traits are a different major
// and do NOT satisfy the chat crates' `R: rand_core::RngCore +
// rand_core::CryptoRng` bound. The chat layer must use the 0.6 OsRng.
use rand_core_06::{OsRng, RngCore};
use rostro_chat_primitives::{
    chunk::{combine_chunks_verified, prepare_batch, PreparedBatch, TaggedChunk},
    descriptor::{MessageId, PickupKey, CHAT_TTL_SECONDS},
    envelope::{sign_inner, EnvelopeKind, SealedEnvelope, UnsealedInner},
    identity_key::{ed25519_seed_to_x25519_secret, ed25519_to_x25519_pubkey},
    verify::{verify_sender, ChunkChecksum},
};
use rostro_chat_content_seal::{
    seal as content_seal, unseal_software as content_unseal_software, unseal_with, ContentCurve,
    ContentEcdh, ContentPublicKey, ContentSealError, ContentSealed, SoftwareContentKey,
};
use rostro_chat_sealed_sender::{seal as ss_seal, unseal as ss_unseal, SealedOutput};
use rostro_chat_onion::wrap_onion;
use rostro_node_identity::NodeIdentity;

/// Domain-separation prefix for chat-auth signatures. MUST stay
/// byte-identical to `CHAT_AUTH_DOMAIN` in gemini-node's `chat_rpc.rs`
/// (the verifying side) — it is a wire constant, not a local choice.
const CHAT_AUTH_DOMAIN: &[u8] = b"rostro/chat/auth/v1";

/// FRB-facing curve tags for content keys. Match the SCALE
/// discriminants of `rostro_chat_content_seal::ContentCurve`.
fn content_curve_from_u8(curve: u8) -> Result<ContentCurve, String> {
    match curve {
        0 => Ok(ContentCurve::P256),
        1 => Ok(ContentCurve::P384),
        other => Err(format!("unknown content curve tag {other} (0=P-256, 1=P-384)")),
    }
}

fn decode_content_scalar(curve: ContentCurve, seed_hex: &str) -> Result<Vec<u8>, String> {
    let bytes = hex::decode(seed_hex.trim_start_matches("0x"))
        .map_err(|e| format!("content seed hex: {e}"))?;
    let want = match curve {
        ContentCurve::P256 => 32,
        ContentCurve::P384 => 48,
    };
    if bytes.len() != want {
        return Err(format!(
            "content seed must be {want} bytes for this curve, got {}",
            bytes.len()
        ));
    }
    Ok(bytes)
}

// ── FRB-facing result types ─────────────────────────────────────────

/// Public keys + pickup key derived from a chat-identity seed. The two
/// parties exchange the Ed25519 pubkey out-of-band (or via RNS) so each
/// can address the other.
pub struct ChatIdentity {
    pub ed25519_pubkey_hex: String,
    pub x25519_pubkey_hex: String,
    pub pickup_key_hex: String,
}

/// Outcome of a successful `chat_send_prepared` / onion dispatch.
pub struct ChatSendOutcome {
    pub message_id_hex: String,
    pub share_count: u32,
    pub recipient_pickup_key_hex: String,
    /// Advanced DR session state after this send (Phase 5). The app
    /// MUST persist it (encrypted) before considering the send done —
    /// losing it breaks the ratchet. Empty for `Plain` sends.
    pub new_session_state_hex: String,
    /// This message's hash — the chain tip for THIS conversation. The
    /// app persists it per-contact and feeds it back as the next send's
    /// `prev_self_hash_hex`. Set by `chat_send_onion_2hop`; empty on the
    /// dormant/one-way paths that don't chain.
    pub new_self_hash_hex: String,
}

/// Signed inner payload: the sender's claimed `.rst` name + the message body.
/// The name is a *claim* — the recipient forward-resolves it and checks the
/// published key matches the verified sender pubkey. Because it's inside the
/// signed inner, the claim is bound to the sender's chat-key signature.
#[derive(Encode, Decode)]
struct InnerPayload {
    sender_name: Vec<u8>,
    body: Vec<u8>,
    /// Hash of the sender's PREVIOUS message in THIS conversation
    /// (`blake2_256` of that message's `InnerPayload` encoding —
    /// chained git-style, so each link covers the prior link too).
    /// `None` = the first message OR a chain reset: the sender had no
    /// recoverable predecessor (its prior send-state aged out at the
    /// ~72h relay TTL, or the cache was wiped). The recipient threads
    /// messages into a per-sender hash chain by this field; a
    /// referenced-but-absent hash is a detectable gap, and a `None`
    /// arriving where earlier messages already exist is a resumption.
    ///
    /// Ordering metadata lives HERE, inside the content seal — never in
    /// any node-visible layer. The relay network is dumb ephemeral
    /// transport: it must not learn order, recipient, or thread shape.
    prev_self_hash: Option<[u8; 32]>,
    /// Sender wall-clock (unix seconds) at compose time. NOT
    /// authoritative for intra-chain order — the hash chain owns that.
    /// Used only to order disjoint chain segments across a reset/gap
    /// ("the first message after a time gap") and to interleave the two
    /// directional streams. A display hint; clocks lie, so it never
    /// overrides a chain link.
    composed_at: u64,
    /// Dead-drop reply address: a fresh random 32-byte pickup key the
    /// sender mints so the recipient knows where to send replies — the
    /// ping-pong return address, kept INSIDE the content seal so it is
    /// invisible to relays and to anyone who is not the recipient. `None`
    /// for a normal addressed DM. See docs/DOTWAVE-CHAT-DEAD-DROPS.md.
    return_pickup: Option<[u8; 32]>,
}

impl InnerPayload {
    /// An ordering-free payload for paths that don't join a
    /// per-conversation hash chain: prekey-bundle publications
    /// (`chat_send_plain`), the dormant ratchet path (`chat_send`), and
    /// the 1-hop onion (`chat_send_onion`). Only the live 2-hop send
    /// chains messages.
    fn unordered(sender_name: Vec<u8>, body: Vec<u8>) -> Self {
        InnerPayload { sender_name, body, prev_self_hash: None, composed_at: 0, return_pickup: None }
    }

    /// The chain link a *successor* message references: `blake2_256` over
    /// this payload's canonical SCALE encoding. Computed by the sender
    /// (to stamp the next message) and by the recipient at read time (to
    /// match an incoming `prev_self_hash`).
    fn self_hash(&self) -> [u8; 32] {
        sp_core::hashing::blake2_256(&self.encode())
    }
}

// ── first-message avatar framing ──────────────────────────────────────
//
// A sender's tiny icon rides inside the InnerPayload `body` of the FIRST
// message of a conversation only (the chain-root, `prev_self_hash == None`).
// The crypto seal treats `body` as opaque bytes, so this needs no change to
// the sealed/SCALE format and is fully backward-compatible: an un-framed body
// is just text. Dead drops never frame (their send path is untouched).
//
// Layout: MAGIC(6) ‖ avatar_len: u32 LE(4) ‖ avatar_bytes ‖ text_bytes.
// The leading 0x00 makes MAGIC a byte sequence a real (UTF-8 text) body never
// begins with, so detection can't false-positive on an ordinary message.

const AVATAR_FRAME_MAGIC: [u8; 6] = [0x00, b'D', b'W', b'A', b'V', 0x01];

/// Prepend `avatar` (the ≤1 KB WebP) to `text` as a framed body.
fn frame_body_with_avatar(text: &[u8], avatar: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(10 + avatar.len() + text.len());
    out.extend_from_slice(&AVATAR_FRAME_MAGIC);
    out.extend_from_slice(&(avatar.len() as u32).to_le_bytes());
    out.extend_from_slice(avatar);
    out.extend_from_slice(text);
    out
}

/// Split a body into `(text, avatar)`. No frame → `(body, empty)`.
fn unframe_body(body: &[u8]) -> (Vec<u8>, Vec<u8>) {
    if body.len() >= 10 && body[..6] == AVATAR_FRAME_MAGIC {
        let len = u32::from_le_bytes([body[6], body[7], body[8], body[9]]) as usize;
        if body.len() >= 10 + len {
            return (body[10 + len..].to_vec(), body[10..10 + len].to_vec());
        }
    }
    (body.to_vec(), Vec::new())
}

/// What actually gets content-sealed (Phase 5). User-to-user 1:1 is
/// ALWAYS `Ratcheted` — Double-Ratchet-encrypted, forward-secret from
/// message one (the first message carries the X3DH bootstrap).
/// `Plain` is the non-ratcheted one-way form reserved for payloads
/// that have no conversation: prekey-bundle publications (see
/// `chat_dr`) and, later, authority-signed System messages.
#[derive(Encode, Decode)]
enum ContentPayload {
    Ratcheted {
        x3dh: Option<rostro_chat_dr::X3dhInit>,
        wire: rostro_chat_dr::WireMessage,
    },
    Plain(InnerPayload),
}

/// A message reconstructed, OUTER-unsealed and sender-verified on-device —
/// with the content still sealed (Phase 3: encrypted at rest). The app
/// stores `sealed_content_hex` as-is; reading it requires the explicit
/// [`chat_read_content`] step (biometric → silicon on real hardware).
pub struct AtRestMessage {
    pub message_id_hex: String,
    /// Verified sender chat pubkey (outer-layer signature checked in
    /// the background — safe to thread/route on without decrypting).
    pub sender_pubkey_hex: String,
    /// SCALE-encoded `ContentSealed` — the encrypted-at-rest blob.
    pub sealed_content_hex: String,
}

/// Decrypted content, produced ONLY by [`chat_read_content`].
pub struct ReadMessage {
    pub claimed_sender_name: String,
    /// UTF-8 plaintext if the body decodes as UTF-8, else empty.
    pub plaintext: String,
    /// Raw body, always present.
    pub plaintext_hex: String,
    /// True for `Ratcheted` (normal 1:1) content; false for `Plain`
    /// one-way payloads (prekey bundles / System messages).
    pub ratcheted: bool,
    /// Advanced DR session state after this read. The app MUST
    /// persist it (encrypted) — feeding a stale state to the next
    /// read replays the ratchet. Empty for `Plain` content.
    pub new_session_state_hex: String,
    /// This message's own chain hash — what a successor's
    /// `prev_self_hash` references. The recipient indexes by it to link
    /// the per-sender chain at read time.
    pub self_hash_hex: String,
    /// The chain link this message references — the sender's previous
    /// message in this conversation. Empty = first message OR a reset
    /// (no recoverable predecessor). A non-empty value the recipient
    /// holds no message for = a detectable gap.
    pub prev_self_hash_hex: String,
    /// Sender wall-clock (unix seconds) at compose time. Ordering hint
    /// for cross-segment / cross-stream interleave only; never overrides
    /// a chain link.
    pub composed_at: u64,
    /// The sender's tiny avatar (WebP, hex), carried only on a first message
    /// (chain-root). Empty when the message carried none. Surfaced so the app
    /// can cache the contact's icon for the conversation list.
    pub avatar_webp_hex: String,
}

// ── RPC response mirrors (must match gemini-node/src/chat_rpc.rs) ────

#[derive(serde::Deserialize)]
struct ChatSendResultRpc {
    message_id_hex: String,
    share_count: u32,
    recipient_pickup_key_hex: String,
}

#[derive(serde::Deserialize)]
struct ChatShareDescriptorRpc {
    #[allow(dead_code)]
    relay_pubkey_hex: String,
    message_id_hex: String,
    share_index: u8,
    total_shares: u8,
    #[allow(dead_code)]
    pickup_key_hex: String,
    expires_at_unix_ts: u64,
}

#[derive(serde::Deserialize)]
struct ChatFetchedShareRaw {
    descriptor: ChatShareDescriptorRpc,
    share_bytes_hex: String,
    checksum_hex: String,
}

// ── crypto helpers (ported from rostro-chat-cli) ────────────────────

/// Crate-internal re-export of [`decode_hex32`] for `chat_dr`.
pub(crate) fn decode_hex32_pub(s: &str) -> Result<[u8; 32], String> {
    decode_hex32(s)
}

fn decode_hex32(s: &str) -> Result<[u8; 32], String> {
    let trimmed = s.trim_start_matches("0x");
    let bytes = hex::decode(trimmed).map_err(|e| format!("invalid hex: {e}"))?;
    if bytes.len() != 32 {
        return Err(format!("expected 32 bytes, got {}", bytes.len()));
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

/// Derive (Ed25519 pubkey, X25519 pubkey, pickup key) from a 32-byte
/// chat-identity seed.
fn identity_from_seed(seed: &[u8; 32]) -> Result<([u8; 32], [u8; 32], [u8; 32]), String> {
    let signing = ed25519_zebra::SigningKey::from(*seed);
    let ed_pubkey: [u8; 32] = ed25519_zebra::VerificationKey::from(&signing).into();
    let x25519_pubkey = ed25519_to_x25519_pubkey(&ed_pubkey)
        .ok_or_else(|| "Ed25519 pubkey doesn't decode as a valid Edwards point".to_string())?;
    let pickup = PickupKey::for_pairwise(&x25519_pubkey).0;
    Ok((ed_pubkey, x25519_pubkey, pickup))
}

// ── FRB: gen-identity ───────────────────────────────────────────────

/// Derive a chat identity from a deterministic 32-byte seed (hex).
#[flutter_rust_bridge::frb(sync)]
pub fn chat_gen_identity(seed_hex: String) -> Result<ChatIdentity, String> {
    let seed = decode_hex32(&seed_hex)?;
    let (ed, x, pickup) = identity_from_seed(&seed)?;
    Ok(ChatIdentity {
        ed25519_pubkey_hex: hex::encode(ed),
        x25519_pubkey_hex: hex::encode(x),
        pickup_key_hex: hex::encode(pickup),
    })
}

// ── FRB: content key (Phase 3) ──────────────────────────────────────

/// Derive the publishable content key for a software content seed:
/// returns the hex of the SCALE-encoded curve-tagged `ContentPublicKey`
/// — exactly the bytes that go in the RNS record's `inner_content_key`
/// and that senders pass to [`chat_send`]. Dev-box stand-in for the
/// StrongBox/TPM keypair (`curve`: 0 = P-256 / 32-byte seed,
/// 1 = P-384 / 48-byte seed).
pub fn chat_gen_content_key(curve: u8, content_seed_hex: String) -> Result<String, String> {
    let curve = content_curve_from_u8(curve)?;
    let scalar = decode_content_scalar(curve, &content_seed_hex)?;
    let key = SoftwareContentKey::from_scalar(curve, &scalar)
        .map_err(|e| format!("content key: {e:?}"))?;
    Ok(hex::encode(key.public_key().encode()))
}

/// Decrypt an at-rest sealed blob ([`AtRestMessage::sealed_content_hex`])
/// with the device's content key. THE biometric/silicon seam: on real
/// hardware the ECDH inside runs in StrongBox/TPM behind a biometric
/// prompt and this fn takes a keystore handle instead of a seed;
/// the software seed path is the dev-box stand-in. Plaintext is
/// returned transiently — the amnesiac app must not persist it.
pub fn chat_read_content(
    sealed_content_hex: String,
    curve: u8,
    content_seed_hex: String,
    dr_session_state_hex: Option<String>,
    identity_seed_hex: String,
    opk_secrets: Vec<crate::chat_dr::DrOpkSecret>,
) -> Result<ReadMessage, String> {
    let curve = content_curve_from_u8(curve)?;
    let scalar = decode_content_scalar(curve, &content_seed_hex)?;
    let sealed = decode_sealed(&sealed_content_hex)?;
    let inner_bytes = content_unseal_software(curve, &scalar, &sealed)
        .map_err(|e| format!("content unseal: {e:?}"))?;
    finish_read(inner_bytes, dr_session_state_hex, identity_seed_hex, opk_secrets)
}

/// A dead drop's decrypted content plus its return address — the field
/// `chat_read_content` does not surface (it predates dead drops and stays
/// untouched to avoid a bridge regen). Dead-drop content is always
/// `ContentPayload::Plain`. See docs/DOTWAVE-CHAT-DEAD-DROPS.md.
pub struct DeadDropRead {
    pub claimed_sender_name: String,
    pub plaintext: String,
    pub plaintext_hex: String,
    pub self_hash_hex: String,
    pub prev_self_hash_hex: String,
    pub composed_at: u64,
    /// The sender's minted reply address (raw 32-byte pickup key, hex).
    /// Empty if the message carried none (a normal DM, not a dead drop).
    pub return_pickup_hex: String,
}

/// Read a DEAD DROP's content (software seam) and surface its return
/// address so the recipient knows where to reply (the ping-pong hop).
pub fn chat_read_deaddrop(
    sealed_content_hex: String,
    curve: u8,
    content_seed_hex: String,
) -> Result<DeadDropRead, String> {
    let curve = content_curve_from_u8(curve)?;
    let scalar = decode_content_scalar(curve, &content_seed_hex)?;
    let sealed = decode_sealed(&sealed_content_hex)?;
    let inner_bytes = content_unseal_software(curve, &scalar, &sealed)
        .map_err(|e| format!("content unseal: {e:?}"))?;
    deaddrop_read_from_inner(&inner_bytes)
}

/// Read a DEAD DROP via the HARDWARE seam (StrongBox/TPM): the content
/// scalar lives in the secure element, so the caller hands in the in-chip
/// ECDH `shared_secret_hex` (biometric-gated) — the same shape
/// [`chat_read_content_hw`] takes. Surfaces the return address. P-256 only
/// (the hardware content path is StrongBox-class silicon).
pub fn chat_read_deaddrop_hw(
    sealed_content_hex: String,
    recipient_content_key_hex: String,
    shared_secret_hex: String,
) -> Result<DeadDropRead, String> {
    let sealed = decode_sealed(&sealed_content_hex)?;
    if sealed.curve != ContentCurve::P256 {
        return Err("hardware dead-drop read is P-256 only".into());
    }
    let ck_bytes = hex::decode(recipient_content_key_hex.trim_start_matches("0x"))
        .map_err(|e| format!("recipient content key hex: {e}"))?;
    let recipient = ContentPublicKey::decode(&mut &ck_bytes[..])
        .map_err(|e| format!("ContentPublicKey decode: {e}"))?;
    if recipient.curve != ContentCurve::P256 {
        return Err("hardware dead-drop read is P-256 only".into());
    }
    let shared = hex::decode(shared_secret_hex.trim_start_matches("0x"))
        .map_err(|e| format!("shared secret hex: {e}"))?;
    let provider = PrecomputedEcdh { curve: ContentCurve::P256, shared };
    // The seal binds the recipient key's published `sec1` into the salt.
    let inner_bytes = unseal_with(&provider, &recipient.sec1, &sealed)
        .map_err(|e| format!("content unseal (hw): {e:?}"))?;
    deaddrop_read_from_inner(&inner_bytes)
}

/// Decode unsealed inner bytes (from either read seam) into a
/// [`DeadDropRead`]. Dead-drop content is always `ContentPayload::Plain`.
fn deaddrop_read_from_inner(inner_bytes: &[u8]) -> Result<DeadDropRead, String> {
    let content = ContentPayload::decode(&mut &inner_bytes[..])
        .map_err(|e| format!("ContentPayload decode: {e}"))?;
    match content {
        ContentPayload::Plain(payload) => {
            let self_hash_hex = hex::encode(payload.self_hash());
            Ok(DeadDropRead {
                claimed_sender_name: String::from_utf8(payload.sender_name).unwrap_or_default(),
                plaintext: String::from_utf8(payload.body.clone()).unwrap_or_default(),
                plaintext_hex: hex::encode(&payload.body),
                self_hash_hex,
                prev_self_hash_hex: payload.prev_self_hash.map(hex::encode).unwrap_or_default(),
                composed_at: payload.composed_at,
                return_pickup_hex: payload.return_pickup.map(hex::encode).unwrap_or_default(),
            })
        }
        ContentPayload::Ratcheted { .. } => {
            Err("dead drop content must be Plain, got Ratcheted".to_string())
        }
    }
}

/// Decode a hex-encoded SCALE `ContentSealed` blob (shared by the software
/// and hardware read seams).
fn decode_sealed(sealed_content_hex: &str) -> Result<ContentSealed, String> {
    let sealed_bytes = hex::decode(sealed_content_hex.trim_start_matches("0x"))
        .map_err(|e| format!("sealed content hex: {e}"))?;
    ContentSealed::decode(&mut &sealed_bytes[..])
        .map_err(|e| format!("ContentSealed decode: {e}"))
}

/// Shared tail of the read path: decode the unsealed inner bytes as a
/// [`ContentPayload`] and turn it into a [`ReadMessage`] — a `Plain`
/// pass-through or a Double-Ratchet decrypt. Both the software
/// ([`chat_read_content`]) and hardware ([`chat_read_content_hw`]) seams
/// converge here once the inner plaintext is in hand; only the one
/// private-key ECDH that produced `inner_bytes` differs between them.
fn finish_read(
    inner_bytes: Vec<u8>,
    dr_session_state_hex: Option<String>,
    identity_seed_hex: String,
    opk_secrets: Vec<crate::chat_dr::DrOpkSecret>,
) -> Result<ReadMessage, String> {
    let content = ContentPayload::decode(&mut &inner_bytes[..])
        .map_err(|e| format!("ContentPayload decode: {e}"))?;

    match content {
        // One-way, non-conversational payload (prekey bundle / System).
        ContentPayload::Plain(payload) => {
            let self_hash_hex = hex::encode(payload.self_hash());
            let prev_self_hash_hex =
                payload.prev_self_hash.map(hex::encode).unwrap_or_default();
            let composed_at = payload.composed_at;
            let (text, avatar) = unframe_body(&payload.body);
            Ok(ReadMessage {
                claimed_sender_name: String::from_utf8(payload.sender_name)
                    .unwrap_or_default(),
                plaintext: String::from_utf8(text.clone()).unwrap_or_default(),
                plaintext_hex: hex::encode(&text),
                ratcheted: false,
                new_session_state_hex: String::new(),
                self_hash_hex,
                prev_self_hash_hex,
                composed_at,
                avatar_webp_hex: hex::encode(&avatar),
            })
        }
        // Normal 1:1: Double-Ratchet decrypt. An existing session
        // takes precedence (a retransmitted first message must not
        // re-bootstrap); a brand-new conversation bootstraps the
        // responder side from the carried X3dhInit.
        ContentPayload::Ratcheted { x3dh, wire } => {
            let mut session = match dr_session_state_hex.filter(|s| !s.is_empty()) {
                Some(state_hex) => {
                    let bytes = hex::decode(state_hex.trim_start_matches("0x"))
                        .map_err(|e| format!("dr session state hex: {e}"))?;
                    rostro_chat_dr::Session::from_state_bytes(&bytes)
                        .map_err(|_| "dr session state corrupt".to_string())?
                }
                None => {
                    let init = x3dh.as_ref().ok_or(
                        "no DR session for this sender and the message carries \
                         no X3DH bootstrap — cannot decrypt",
                    )?;
                    let identity_seed = decode_hex32(&identity_seed_hex)?;
                    let secrets: Vec<(u32, [u8; 32])> = opk_secrets
                        .iter()
                        .map(|s| Ok((s.id, decode_hex32(&s.secret_hex)?)))
                        .collect::<Result<_, String>>()?;
                    crate::chat_dr::responder_session_from_init(
                        &identity_seed,
                        &secrets,
                        init,
                    )?
                }
            };
            let plaintext_bytes = session
                .decrypt(&wire)
                .map_err(|e| format!("dr decrypt: {e:?}"))?;
            let payload = InnerPayload::decode(&mut &plaintext_bytes[..])
                .map_err(|e| format!("InnerPayload decode: {e}"))?;
            let self_hash_hex = hex::encode(payload.self_hash());
            let prev_self_hash_hex =
                payload.prev_self_hash.map(hex::encode).unwrap_or_default();
            let composed_at = payload.composed_at;
            let (text, avatar) = unframe_body(&payload.body);
            Ok(ReadMessage {
                claimed_sender_name: String::from_utf8(payload.sender_name)
                    .unwrap_or_default(),
                plaintext: String::from_utf8(text.clone()).unwrap_or_default(),
                plaintext_hex: hex::encode(&text),
                ratcheted: true,
                new_session_state_hex: hex::encode(session.to_state_bytes()),
                self_hash_hex,
                prev_self_hash_hex,
                composed_at,
                avatar_webp_hex: hex::encode(&avatar),
            })
        }
    }
}

// ── FRB: hardware content key (Phase 3 silicon seam) ────────────────

/// Wrap a hardware content public key (the SEC1 bytes StrongBox/TPM exports
/// for its non-extractable `PURPOSE_AGREE_KEY` key) into the publishable
/// curve-tagged `ContentPublicKey` bytes for the RNS `MESSAGE` record — the
/// hardware counterpart to [`chat_gen_content_key`]. Validates the bytes are
/// a real point on the curve and re-encodes COMPRESSED so the record is
/// compact and uniform with the software path. P-256 only: the hardware
/// content path is StrongBox-class silicon (P-384/TPM stays deferred).
pub fn chat_content_pubkey_from_sec1(curve: u8, sec1_hex: String) -> Result<String, String> {
    use p256::elliptic_curve::sec1::ToEncodedPoint;
    let curve = content_curve_from_u8(curve)?;
    if curve != ContentCurve::P256 {
        return Err("hardware content key path is P-256 only".into());
    }
    let sec1 = hex::decode(sec1_hex.trim_start_matches("0x"))
        .map_err(|e| format!("content sec1 hex: {e}"))?;
    let pk = p256::PublicKey::from_sec1_bytes(&sec1)
        .map_err(|_| "content key is not a valid P-256 point".to_string())?;
    let compressed = pk.to_encoded_point(true).as_bytes().to_vec();
    Ok(hex::encode(ContentPublicKey { curve: ContentCurve::P256, sec1: compressed }.encode()))
}

/// Extract the sender's per-message ephemeral public key from a sealed blob,
/// re-encoded UNCOMPRESSED SEC1 (65 bytes) — the form Android's
/// `KeyAgreement` consumes when building the peer `ECPublicKey`. Hand this to
/// the StrongBox in-chip ECDH; the resulting shared secret feeds
/// [`chat_read_content_hw`]. (Decompressing here keeps the curve math in Rust,
/// out of Kotlin.)
pub fn chat_content_ephemeral_of(sealed_content_hex: String) -> Result<String, String> {
    use p256::elliptic_curve::sec1::ToEncodedPoint;
    let sealed = decode_sealed(&sealed_content_hex)?;
    if sealed.curve != ContentCurve::P256 {
        return Err("hardware content read is P-256 only".into());
    }
    let pk = p256::PublicKey::from_sec1_bytes(&sealed.ephemeral_pub_sec1)
        .map_err(|_| "sealed ephemeral is not a valid P-256 point".to_string())?;
    Ok(hex::encode(pk.to_encoded_point(false).as_bytes()))
}

/// A [`ContentEcdh`] provider whose ECDH result was already computed inside
/// StrongBox/TPM by the platform keystore. The static content scalar never
/// enters this process; we only hold the per-message shared secret the chip
/// returned. [`unseal_with`] asks this provider for the ECDH of the one
/// ephemeral carried in the sealed blob — the exact ephemeral the chip was
/// given — so we hand back the precomputed secret.
struct PrecomputedEcdh {
    curve: ContentCurve,
    shared: Vec<u8>,
}

impl ContentEcdh for PrecomputedEcdh {
    fn curve(&self) -> ContentCurve {
        self.curve
    }

    fn ecdh(&self, _ephemeral_pub_sec1: &[u8]) -> Result<Vec<u8>, ContentSealError> {
        let want = match self.curve {
            ContentCurve::P256 => 32,
            ContentCurve::P384 => 48,
        };
        if self.shared.len() != want {
            return Err(ContentSealError::EcdhProvider(format!(
                "shared secret is {} bytes, expected {want} for this curve",
                self.shared.len()
            )));
        }
        Ok(self.shared.clone())
    }
}

/// Hardware read seam: the recipient's content scalar lives in StrongBox/TPM
/// and never leaves it. The in-chip ECDH (against the sealed ephemeral, behind
/// a biometric prompt) is performed by the platform keystore via
/// [`chat_content_ephemeral_of`] → Kotlin; its 32-byte shared secret is passed
/// in here as `shared_secret_hex`. HKDF + AEAD then run in-process exactly as
/// the software path — only the one private-key op moved into silicon.
/// `recipient_content_key_hex` MUST be this device's OWN published `MESSAGE`
/// value (the SCALE-encoded curve-tagged `ContentPublicKey` from
/// [`chat_content_pubkey_from_sec1`]): its inner `sec1` bytes are bound into
/// the KDF salt exactly as the sender bound them, so passing the published
/// value verbatim makes the salt match by construction. Plaintext is returned
/// transiently — the amnesiac app must not persist it.
pub fn chat_read_content_hw(
    sealed_content_hex: String,
    recipient_content_key_hex: String,
    shared_secret_hex: String,
    dr_session_state_hex: Option<String>,
    identity_seed_hex: String,
    opk_secrets: Vec<crate::chat_dr::DrOpkSecret>,
) -> Result<ReadMessage, String> {
    let sealed = decode_sealed(&sealed_content_hex)?;
    if sealed.curve != ContentCurve::P256 {
        return Err("hardware content read is P-256 only".into());
    }
    let ck_bytes = hex::decode(recipient_content_key_hex.trim_start_matches("0x"))
        .map_err(|e| format!("recipient content key hex: {e}"))?;
    let recipient = ContentPublicKey::decode(&mut &ck_bytes[..])
        .map_err(|e| format!("ContentPublicKey decode: {e}"))?;
    if recipient.curve != ContentCurve::P256 {
        return Err("hardware content read is P-256 only".into());
    }
    let shared = hex::decode(shared_secret_hex.trim_start_matches("0x"))
        .map_err(|e| format!("shared secret hex: {e}"))?;
    let provider = PrecomputedEcdh { curve: ContentCurve::P256, shared };
    // The seal binds the recipient key's `sec1` (as published) into the salt;
    // pass those exact bytes so a blob sealed to the published key authenticates.
    let inner_bytes = unseal_with(&provider, &recipient.sec1, &sealed)
        .map_err(|e| format!("content unseal (hw): {e:?}"))?;
    finish_read(inner_bytes, dr_session_state_hex, identity_seed_hex, opk_secrets)
}

// ── FRB: cert-auth key (Phase 2) ────────────────────────────────────

/// Derive the uncompressed SEC1 public key (65 bytes, hex) for a
/// software P-256 cert secret. This is the `device_pubkey` registered
/// on-chain via `register_root` and the key `verify_chat_auth` checks
/// drops against. Dev-box stand-in for the StrongBox/TPM keypair.
pub fn chat_cert_pubkey(cert_seed_hex: String) -> Result<String, String> {
    let signing = p256_signing_key(&cert_seed_hex)?;
    let sec1 = signing
        .verifying_key()
        .to_encoded_point(false)
        .as_bytes()
        .to_vec();
    Ok(hex::encode(sec1))
}

fn p256_signing_key(cert_seed_hex: &str) -> Result<p256::ecdsa::SigningKey, String> {
    let seed = decode_hex32(cert_seed_hex)?;
    p256::ecdsa::SigningKey::from_slice(&seed)
        .map_err(|e| format!("invalid P-256 secret scalar: {e}"))
}

/// Sign the chat-auth digest with the P-256 cert key. Mirrors the
/// node's `verify_chat_auth`: digest = blake2_256(domain || envelope ||
/// ts_be); the ECDSA sign/verify pair then runs over SHA-256 of that
/// digest via the p256 crate's standard `Signer`/`Verifier` traits on
/// both sides. Returns the raw r||s signature (64 bytes, hex).
fn chat_auth_sign(
    cert_seed_hex: &str,
    envelope_bytes: &[u8],
    timestamp_secs: u64,
) -> Result<String, String> {
    use p256::ecdsa::signature::Signer;
    let signing = p256_signing_key(cert_seed_hex)?;
    let mut to_sign =
        Vec::with_capacity(CHAT_AUTH_DOMAIN.len() + envelope_bytes.len() + 8);
    to_sign.extend_from_slice(CHAT_AUTH_DOMAIN);
    to_sign.extend_from_slice(envelope_bytes);
    to_sign.extend_from_slice(&timestamp_secs.to_be_bytes());
    let digest = sp_core::hashing::blake2_256(&to_sign);
    let sig: p256::ecdsa::Signature = signing.sign(&digest);
    Ok(hex::encode(sig.to_bytes()))
}

// ── FRB: send ───────────────────────────────────────────────────────

/// Build + sign + sealed-sender-seal a pairwise message on-device, then
/// dispatch it through the named node via `chat_send_prepared`.
///
/// `recipient_content_key_hex` is the recipient's published content key
/// (hex of the SCALE curve-tagged `ContentPublicKey`, from the resolved
/// RNS record's `inner_content_key` / [`chat_gen_content_key`]). The
/// inner payload is SEALED to it (Phase 3) — content is encrypted at
/// rest on the recipient device and only their silicon key opens it.
/// REQUIRED: there is no plaintext-inner path.
///
/// `auth_cert_thumbprint_hex` + `auth_cert_seed_hex` are the Phase-2
/// cert-auth layer: the zkpki cert thumbprint (from
/// `chat_mint_test_cert` / the on-chain `Roots` record) and the P-256
/// cert secret. When present, `chat_send` timestamps the envelope and
/// signs the auth digest so the node's `verify_chat_auth` admits the
/// drop. Pass both or neither — `None` is the unauthenticated dev
/// path, which a production (flipped) node rejects.
pub fn chat_send(
    node_rpc: String,
    sender_seed_hex: String,
    recipient_pubkey_hex: String,
    recipient_content_key_hex: String,
    message: String,
    sender_name: String,
    total_shares: u8,
    dr_session_state_hex: String,
    x3dh_init_hex: Option<String>,
    auth_cert_thumbprint_hex: Option<String>,
    auth_cert_seed_hex: Option<String>,
) -> Result<ChatSendOutcome, String> {
    // Phase 5: every 1:1 message is Double-Ratchet-encrypted. Restore
    // the session, ratchet the payload, attach the X3DH bootstrap on
    // the first message of a new conversation.
    let state_bytes = hex::decode(dr_session_state_hex.trim_start_matches("0x"))
        .map_err(|e| format!("dr session state hex: {e}"))?;
    let mut session = rostro_chat_dr::Session::from_state_bytes(&state_bytes)
        .map_err(|_| "dr session state corrupt — cannot decode".to_string())?;

    let x3dh = match x3dh_init_hex {
        None => None,
        Some(h) => {
            let bytes = hex::decode(h.trim_start_matches("0x"))
                .map_err(|e| format!("x3dh init hex: {e}"))?;
            Some(
                rostro_chat_dr::X3dhInit::decode(&mut &bytes[..])
                    .map_err(|e| format!("X3dhInit decode: {e}"))?,
            )
        }
    };

    let payload = InnerPayload::unordered(sender_name.into_bytes(), message.into_bytes()).encode();
    let wire = session.encrypt(&payload);
    let content = ContentPayload::Ratcheted { x3dh, wire }.encode();
    let new_session_state_hex = hex::encode(session.to_state_bytes());

    let mut outcome = send_content(
        node_rpc,
        &sender_seed_hex,
        &recipient_pubkey_hex,
        &recipient_content_key_hex,
        content,
        total_shares,
        auth_cert_thumbprint_hex,
        auth_cert_seed_hex,
    )?;
    outcome.new_session_state_hex = new_session_state_hex;
    Ok(outcome)
}

/// Send a NON-ratcheted [`ContentPayload::Plain`] body. NOT a user
/// 1:1 path — reserved for one-way payloads with no conversation:
/// prekey-bundle publications (`chat_dr`) and, later,
/// authority-signed System messages.
pub(crate) fn chat_send_plain(
    node_rpc: String,
    sender_seed_hex: String,
    recipient_pubkey_hex: String,
    recipient_content_key_hex: String,
    body: Vec<u8>,
    total_shares: u8,
    auth_cert_thumbprint_hex: Option<String>,
    auth_cert_seed_hex: Option<String>,
) -> Result<ChatSendOutcome, String> {
    let content =
        ContentPayload::Plain(InnerPayload::unordered(Vec::new(), body)).encode();
    send_content(
        node_rpc,
        &sender_seed_hex,
        &recipient_pubkey_hex,
        &recipient_content_key_hex,
        content,
        total_shares,
        auth_cert_thumbprint_hex,
        auth_cert_seed_hex,
    )
}

/// Query a node's chat identity (its Ed25519 node pubkey, hex) via the
/// `chat_nodeInfo` RPC. The phone uses this to learn its connected
/// node's identity so it can seal an onion layer to it as the guard.
pub fn chat_node_info(node_rpc: String) -> Result<String, String> {
    #[derive(serde::Deserialize)]
    struct ChatNodeInfoRpc {
        node_pubkey_ed25519_hex: String,
    }
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("tokio runtime: {e}"))?;
    rt.block_on(async move {
        let rpc = subxt::rpcs::RpcClient::from_insecure_url(&node_rpc)
            .await
            .map_err(|e| format!("connecting to {node_rpc}: {e}"))?;
        let info: ChatNodeInfoRpc = rpc
            .request("chat_nodeInfo", subxt::rpcs::rpc_params![])
            .await
            .map_err(|e| format!("chat_nodeInfo RPC failed: {e}"))?;
        Ok(info.node_pubkey_ed25519_hex)
    })
}

/// Send a message through a **one-hop onion** to `guard_pubkey_hex`
/// (the connected node's Ed25519 identity, e.g. from `chat_nodeInfo`).
/// The guard peels the onion and injects the recipient-sealed envelope
/// into the normal distribution — it forwards a drop without learning
/// the sender↔recipient link beyond "a drop passed through."
///
/// Phase-4 transport: uses `Plain` content (no DR session) so the
/// recipient reads it via `chat_read_content`'s Plain branch. The
/// Ratcheted (forward-secret) onion send composes identically once the
/// DR session is threaded through.
pub fn chat_send_onion(
    node_rpc: String,
    guard_pubkey_hex: String,
    sender_seed_hex: String,
    recipient_pubkey_hex: String,
    recipient_content_key_hex: String,
    message: String,
    sender_name: String,
    total_shares: u8,
    auth_cert_thumbprint_hex: Option<String>,
    auth_cert_seed_hex: Option<String>,
) -> Result<ChatSendOutcome, String> {
    let content =
        ContentPayload::Plain(InnerPayload::unordered(sender_name.into_bytes(), message.into_bytes()))
            .encode();
    send_content_onion(
        node_rpc,
        &guard_pubkey_hex,
        None,
        &sender_seed_hex,
        &recipient_pubkey_hex,
        &recipient_content_key_hex,
        content,
        total_shares,
        auth_cert_thumbprint_hex,
        auth_cert_seed_hex,
        None,
        None,
        None,
    )
}

/// Two-hop onion send (Phase 4 slice 2). Same as [`chat_send_onion`] but
/// wraps the drop in a 2-hop path: guard → relay-2 → (stripe). The guard
/// peels and FORWARDS the inner packet directly to relay-2 over
/// `/rostro/chat-onion-forward/1`; relay-2 peels and delivers. A single
/// relay sees sender-or-bucket, never both. `relay2_pubkey_hex` is
/// relay-2's Ed25519 node identity (distinct from the guard; obtained
/// from `chat_nodeInfo` on a different relay).
pub fn chat_send_onion_2hop(
    node_rpc: String,
    guard_pubkey_hex: String,
    relay2_pubkey_hex: String,
    sender_seed_hex: String,
    recipient_pubkey_hex: String,
    recipient_content_key_hex: String,
    message: String,
    sender_name: String,
    total_shares: u8,
    auth_cert_thumbprint_hex: Option<String>,
    auth_cert_seed_hex: Option<String>,
    // `prev_self_hash_hex`: the sender's last chain tip for THIS
    // conversation — the hash returned by the previous
    // `chat_send_onion_2hop` to this contact. `None`/empty = first
    // message OR a reset (no recoverable predecessor). The app persists
    // the returned `new_self_hash_hex` and feeds it back here next send.
    prev_self_hash_hex: Option<String>,
    // `composed_at_secs`: sender wall-clock (unix seconds) at compose
    // time — stamped into the sealed payload for cross-segment /
    // cross-stream ordering.
    composed_at_secs: u64,
    // `avatar_webp_hex`: the sender's tiny WebP icon, embedded ONLY on a
    // first message (chain-root). Empty/None otherwise. Gated on
    // `prev_self_hash.is_none()` below so a follow-up never carries it even
    // if one is passed.
    avatar_webp_hex: Option<String>,
    // Membership-session auth (M5): when BOTH are present the drop is
    // signed by the software session key (no secure element, no cert)
    // and the `auth_cert_*` pair above is unused. From
    // `membership_authenticate`'s outcome: `session_key_hex` = the
    // session pubkey (the guard's lookup key), `session_seed_hex` = the
    // session's Ed25519 seed.
    session_key_hex: Option<String>,
    session_seed_hex: Option<String>,
) -> Result<ChatSendOutcome, String> {
    let prev_self_hash = match prev_self_hash_hex.filter(|h| !h.is_empty()) {
        Some(h) => Some(decode_hex32(&h)?),
        None => None,
    };
    // Avatar rides only on the chain-root message.
    let body = match avatar_webp_hex.filter(|h| !h.is_empty()) {
        Some(h) if prev_self_hash.is_none() => {
            let avatar = hex::decode(h.trim_start_matches("0x"))
                .map_err(|e| format!("avatar hex: {e}"))?;
            frame_body_with_avatar(message.as_bytes(), &avatar)
        }
        _ => message.into_bytes(),
    };
    let inner = InnerPayload {
        sender_name: sender_name.into_bytes(),
        body,
        prev_self_hash,
        composed_at: composed_at_secs,
        return_pickup: None,
    };
    // The tip the NEXT message in this conversation will reference.
    let new_self_hash = inner.self_hash();
    let content = ContentPayload::Plain(inner).encode();
    let mut outcome = send_content_onion(
        node_rpc,
        &guard_pubkey_hex,
        Some(&relay2_pubkey_hex),
        &sender_seed_hex,
        &recipient_pubkey_hex,
        &recipient_content_key_hex,
        content,
        total_shares,
        auth_cert_thumbprint_hex,
        auth_cert_seed_hex,
        session_key_hex,
        session_seed_hex,
        None,
    )?;
    outcome.new_self_hash_hex = hex::encode(new_self_hash);
    Ok(outcome)
}

/// Send a DEAD DROP: routed by an opaque `label` (a callsign) instead of
/// by recipient identity, and carrying a freshly-minted return address in
/// the content seal. The message is still sealed to the recipient's REAL
/// keys (`recipient_pubkey_hex` + `recipient_content_key_hex`, held
/// out-of-band) — the label is pure routing, fully decoupled from the
/// crypto, so relays only ever see an opaque pickup key. The recipient
/// polls `chat_fetch_deaddrop` with the same `label`. The conversation
/// then walks rotating `return_pickup`s (ping-pong) — Phase 3 owns the
/// rotation state machine. See docs/DOTWAVE-CHAT-DEAD-DROPS.md.
#[allow(clippy::too_many_arguments)]
pub fn chat_send_deaddrop(
    node_rpc: String,
    guard_pubkey_hex: String,
    relay2_pubkey_hex: String,
    sender_seed_hex: String,
    recipient_pubkey_hex: String,
    recipient_content_key_hex: String,
    label: String,
    message: String,
    sender_name: String,
    total_shares: u8,
    auth_cert_thumbprint_hex: Option<String>,
    auth_cert_seed_hex: Option<String>,
    prev_self_hash_hex: Option<String>,
    composed_at_secs: u64,
) -> Result<ChatSendOutcome, String> {
    let prev_self_hash = match prev_self_hash_hex.filter(|h| !h.is_empty()) {
        Some(h) => Some(decode_hex32(&h)?),
        None => None,
    };
    // Mint a fresh return address — a raw 32-byte pickup key the recipient
    // replies to (used directly, no hashing; never human-facing).
    let mut return_pickup = [0u8; 32];
    OsRng.fill_bytes(&mut return_pickup);
    let inner = InnerPayload {
        sender_name: sender_name.into_bytes(),
        body: message.into_bytes(),
        prev_self_hash,
        composed_at: composed_at_secs,
        return_pickup: Some(return_pickup),
    };
    let new_self_hash = inner.self_hash();
    let content = ContentPayload::Plain(inner).encode();
    // Route by the callsign, NOT by recipient identity.
    let pickup = PickupKey::for_deaddrop(label.as_bytes()).0;
    let mut outcome = send_content_onion(
        node_rpc,
        &guard_pubkey_hex,
        Some(&relay2_pubkey_hex),
        &sender_seed_hex,
        &recipient_pubkey_hex,
        &recipient_content_key_hex,
        content,
        total_shares,
        auth_cert_thumbprint_hex,
        auth_cert_seed_hex,
        None,
        None,
        Some(pickup),
    )?;
    outcome.new_self_hash_hex = hex::encode(new_self_hash);
    Ok(outcome)
}

/// The pickup-key (hex) a dead-drop `label` (callsign) routes to. The
/// sender uses it as the opener's send target; the recipient uses it as
/// the poll bucket. Pure (no I/O) — just `for_deaddrop(label)`.
pub fn chat_deaddrop_pickup(label: String) -> String {
    hex::encode(PickupKey::for_deaddrop(label.as_bytes()).0)
}

/// Mint a fresh random 32-byte dead-drop return address (hex). The
/// rotation state machine calls this to advertise a new inbound address
/// each turn; the value is never human-facing and is used directly as a
/// pickup key (no hashing).
pub fn chat_mint_return_pickup() -> String {
    let mut b = [0u8; 32];
    OsRng.fill_bytes(&mut b);
    hex::encode(b)
}

// ── FRB bridge for the ping-pong rotation (Phase 4) ──────────────────
// Plain-data mirror of `dead_drop::DeadDropThread` + thin delegating
// wrappers, so the rotation logic stays in ONE place (core) while Dart
// holds and persists the state. Hex strings keep it FRB-friendly and
// easy to serialise; an empty string means `None`.

/// One live grace-window entry: a superseded return address still polled.
pub struct DeadDropGraceEntry {
    pub pickup_hex: String,
    pub rounds_left: u8,
}

/// FRB mirror of a conversation's ping-pong rotation state. The app
/// persists this per thread and feeds it back into the transition fns.
pub struct DeadDropThreadDto {
    /// Where this party sends next ("" before a responder's first receive).
    pub outbound_target_hex: String,
    /// The return address this party advertises ("" before first receive).
    pub inbound_current_hex: String,
    /// Superseded inbound addresses still being polled (the grace window).
    pub grace: Vec<DeadDropGraceEntry>,
}

impl DeadDropThreadDto {
    fn from_core(t: &crate::dead_drop::DeadDropThread) -> Self {
        DeadDropThreadDto {
            outbound_target_hex: t.outbound_target.map(hex::encode).unwrap_or_default(),
            inbound_current_hex: t.inbound_current.map(hex::encode).unwrap_or_default(),
            grace: t
                .grace
                .iter()
                .map(|(p, r)| DeadDropGraceEntry { pickup_hex: hex::encode(p), rounds_left: *r })
                .collect(),
        }
    }
    fn to_core(&self) -> Result<crate::dead_drop::DeadDropThread, String> {
        let opt = |s: &str| -> Result<Option<[u8; 32]>, String> {
            if s.is_empty() { Ok(None) } else { Ok(Some(decode_hex32(s)?)) }
        };
        let grace = self
            .grace
            .iter()
            .map(|g| Ok((decode_hex32(&g.pickup_hex)?, g.rounds_left)))
            .collect::<Result<Vec<_>, String>>()?;
        Ok(crate::dead_drop::DeadDropThread {
            outbound_target: opt(&self.outbound_target_hex)?,
            inbound_current: opt(&self.inbound_current_hex)?,
            grace,
        })
    }
}

/// Opener (Alice): start a thread addressing `callsign_pickup_hex`
/// (= `chat_deaddrop_pickup(label)`), advertising freshly-minted
/// `first_inbound_hex` (= `chat_mint_return_pickup()`).
pub fn deaddrop_open(
    callsign_pickup_hex: String,
    first_inbound_hex: String,
) -> Result<DeadDropThreadDto, String> {
    let t = crate::dead_drop::DeadDropThread::open(
        decode_hex32(&callsign_pickup_hex)?,
        decode_hex32(&first_inbound_hex)?,
    );
    Ok(DeadDropThreadDto::from_core(&t))
}

/// Responder (Bob): an empty thread, initialised on its first receive.
pub fn deaddrop_responder() -> DeadDropThreadDto {
    DeadDropThreadDto::from_core(&crate::dead_drop::DeadDropThread::responder())
}

/// A receive→send turn: the peer replied with `received_return_hex` (their
/// new inbound, from the message's return address); rotate to advertise
/// caller-minted `new_inbound_hex`, retiring the old one into the 3-round
/// grace window. Returns the updated state for the app to persist.
pub fn deaddrop_on_turn(
    state: DeadDropThreadDto,
    received_return_hex: String,
    new_inbound_hex: String,
) -> Result<DeadDropThreadDto, String> {
    let mut t = state.to_core()?;
    t.on_turn(decode_hex32(&received_return_hex)?, decode_hex32(&new_inbound_hex)?);
    Ok(DeadDropThreadDto::from_core(&t))
}

/// Every bucket this party must poll for replies (current inbound + grace),
/// as hex pickup keys. Callsign polling is the separate standing pool.
pub fn deaddrop_poll_set(state: DeadDropThreadDto) -> Result<Vec<String>, String> {
    Ok(state.to_core()?.poll_set().iter().map(hex::encode).collect())
}

/// Send a dead-drop message to a RAW 32-byte pickup key — the ping-pong
/// REPLY hop, where the target is a return address the peer minted (or
/// `chat_deaddrop_pickup(label)` for the opener). Unlike
/// `chat_send_deaddrop`, the caller supplies `return_pickup_hex` (its own
/// current inbound address, owned by the rotation state machine) rather
/// than minting one internally. Still sealed to the recipient's REAL keys.
#[allow(clippy::too_many_arguments)]
pub fn chat_send_to_pickup(
    node_rpc: String,
    guard_pubkey_hex: String,
    relay2_pubkey_hex: String,
    sender_seed_hex: String,
    recipient_pubkey_hex: String,
    recipient_content_key_hex: String,
    target_pickup_hex: String,
    return_pickup_hex: String,
    message: String,
    sender_name: String,
    total_shares: u8,
    auth_cert_thumbprint_hex: Option<String>,
    auth_cert_seed_hex: Option<String>,
    prev_self_hash_hex: Option<String>,
    composed_at_secs: u64,
) -> Result<ChatSendOutcome, String> {
    let prev_self_hash = match prev_self_hash_hex.filter(|h| !h.is_empty()) {
        Some(h) => Some(decode_hex32(&h)?),
        None => None,
    };
    let target = decode_hex32(&target_pickup_hex)?;
    let return_pickup = decode_hex32(&return_pickup_hex)?;
    let inner = InnerPayload {
        sender_name: sender_name.into_bytes(),
        body: message.into_bytes(),
        prev_self_hash,
        composed_at: composed_at_secs,
        return_pickup: Some(return_pickup),
    };
    let new_self_hash = inner.self_hash();
    let content = ContentPayload::Plain(inner).encode();
    let mut outcome = send_content_onion(
        node_rpc,
        &guard_pubkey_hex,
        Some(&relay2_pubkey_hex),
        &sender_seed_hex,
        &recipient_pubkey_hex,
        &recipient_content_key_hex,
        content,
        total_shares,
        auth_cert_thumbprint_hex,
        auth_cert_seed_hex,
        None,
        None,
        Some(target),
    )?;
    outcome.new_self_hash_hex = hex::encode(new_self_hash);
    Ok(outcome)
}

/// Build the SealedEnvelope (content-seal → sign → sealed-sender) for a
/// pairwise send. Shared by the direct (`send_content`) and onion
/// (`send_content_onion`) dispatch paths. Returns the envelope + the
/// recipient's raw Ed25519 pubkey.
fn build_sealed_envelope(
    sender_seed_hex: &str,
    recipient_pubkey_hex: &str,
    recipient_content_key_hex: &str,
    content_payload_bytes: &[u8],
) -> Result<(SealedEnvelope, [u8; 32]), String> {
    let sender_seed = decode_hex32(sender_seed_hex)?;
    let recipient_ed = decode_hex32(recipient_pubkey_hex)?;
    let recipient_x = ed25519_to_x25519_pubkey(&recipient_ed)
        .ok_or_else(|| "recipient pubkey not on Edwards curve".to_string())?;

    let signing = ed25519_zebra::SigningKey::from(sender_seed);

    let mut message_id_bytes = [0u8; 32];
    OsRng.fill_bytes(&mut message_id_bytes);
    let message_id = MessageId(message_id_bytes);

    let recipient_content_key_bytes =
        hex::decode(recipient_content_key_hex.trim_start_matches("0x"))
            .map_err(|e| format!("recipient content key hex: {e}"))?;
    let recipient_content_key =
        ContentPublicKey::decode(&mut &recipient_content_key_bytes[..])
            .map_err(|e| format!("recipient ContentPublicKey decode: {e}"))?;
    let inner_ciphertext = content_seal(&recipient_content_key, content_payload_bytes, &mut OsRng)
        .map_err(|e| format!("content seal: {e:?}"))?
        .encode();

    let unsealed = sign_inner(inner_ciphertext, &message_id, &signing);
    let unsealed_encoded = unsealed.encode();
    let mut rng = OsRng;
    let sealed = ss_seal(&recipient_x, &unsealed_encoded, &mut rng);

    let envelope = SealedEnvelope {
        kind: EnvelopeKind::Pairwise,
        outer_ciphertext: sealed.ciphertext,
        ephemeral_pubkey: sealed.ephemeral_pub,
        message_id,
    };
    Ok((envelope, recipient_ed))
}

/// Chunk cutover (docs/CHAT-SHARE-CHUNKING.md): split the SCALE-encoded
/// envelope into `total_chunks` contiguous chunks and attach a keyless
/// integrity checksum to each, producing the `PreparedBatch` that is
/// both the `chat_send_prepared` payload and the onion `Deliver` drop.
/// `pickup_key` is the sender-derived routing key (for_pairwise for a
/// normal DM, for_deaddrop / a raw return address for a dead drop — the
/// relay only ever sees opaque bytes). Keyless: the recipient needs no
/// session state to verify, and authenticity remains the sealed-sender
/// AEAD + sender signature downstream.
fn build_prepared_batch(
    envelope: &SealedEnvelope,
    pickup_key: [u8; 32],
    total_chunks: u8,
) -> Result<PreparedBatch, String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // A 0 slips through as the crate default (5); the crate rejects <2.
    let n = if total_chunks == 0 { 5 } else { total_chunks as usize };
    prepare_batch(
        &envelope.encode(),
        n,
        envelope.message_id,
        PickupKey(pickup_key),
        now + CHAT_TTL_SECONDS,
    )
    .map_err(|e| format!("prepare_batch: {e:?}"))
}

/// Build the (thumbprint, ts, sig) cert-auth triple over `signed_bytes`
/// — the envelope for a direct send, the onion packet for an onion
/// send. The node recomputes the same digest and verifies against the
/// cert's device pubkey.
fn build_cert_auth(
    signed_bytes: &[u8],
    auth_cert_thumbprint_hex: Option<String>,
    auth_cert_seed_hex: Option<String>,
) -> Result<(Option<String>, Option<u64>, Option<String>), String> {
    match (auth_cert_thumbprint_hex, auth_cert_seed_hex) {
        (Some(thumbprint), Some(cert_seed)) => {
            let ts = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_err(|e| format!("system clock before epoch: {e}"))?
                .as_secs();
            let sig = chat_auth_sign(&cert_seed, signed_bytes, ts)?;
            Ok((Some(thumbprint), Some(ts), Some(sig)))
        }
        (None, None) => Ok((None, None, None)),
        _ => Err("auth_cert_thumbprint_hex and auth_cert_seed_hex must be passed \
                  together (or both omitted for the unauthenticated dev path)"
            .to_string()),
    }
}

/// Onion send core (Phase 4): build the same recipient-sealed envelope,
/// then wrap it in a one-hop onion sealed to the `guard` node identity
/// and dispatch via `chat_send_onion`. The guard peels it and injects
/// the envelope into the normal distribution; cert-auth is over the
/// onion packet bytes (what the node verifies). `guard_pubkey_hex` is
/// the guard's Ed25519 node identity (e.g. from `chat_nodeInfo`).
fn send_content_onion(
    node_rpc: String,
    guard_pubkey_hex: &str,
    relay2_pubkey_hex: Option<&str>,
    sender_seed_hex: &str,
    recipient_pubkey_hex: &str,
    recipient_content_key_hex: &str,
    content_payload_bytes: Vec<u8>,
    total_shares: u8,
    auth_cert_thumbprint_hex: Option<String>,
    auth_cert_seed_hex: Option<String>,
    // Session auth (M5): when BOTH are present the drop is admitted by the
    // cheap Ed25519 session signature and cert auth is skipped entirely.
    // `session_key_hex` is the guard's 32-byte session lookup key — the
    // session pubkey for an anonymous membership session
    // (`chat_authenticateMembership`), or the cert thumbprint for an
    // identified session (`chat_authenticate`). `session_seed_hex` is the
    // software session-key seed from the handshake.
    session_key_hex: Option<String>,
    session_seed_hex: Option<String>,
    // `Some(pickup)` routes by a caller-derived pickup key (a dead drop's
    // for_deaddrop(label)); `None` derives for_pairwise over the recipient.
    pickup_override: Option<[u8; 32]>,
) -> Result<ChatSendOutcome, String> {
    let (envelope, recipient_ed) = build_sealed_envelope(
        sender_seed_hex,
        recipient_pubkey_hex,
        recipient_content_key_hex,
        &content_payload_bytes,
    )?;

    // Onion path: [guard] (1-hop) or [guard, relay-2] (2-hop). The
    // innermost Deliver{recipient + envelope} is sealed to the LAST hop;
    // each preceding hop gets a Forward to the next. The guard peels its
    // layer and either delivers (1-hop) or forwards to relay-2 (2-hop).
    let guard = NodeIdentity::from_ed25519_pubkey(decode_hex32(guard_pubkey_hex)?);
    // Sender derives the pickup key — relays are dumb infra that only ever
    // see opaque pickup keys, so a dead drop (for_deaddrop label) and a
    // normal DM (for_pairwise) are indistinguishable on the wire.
    let pickup_key = match pickup_override {
        Some(pk) => pk,
        None => {
            // recipient_ed was already on-curve-validated by
            // build_sealed_envelope, so this cannot fail.
            let recipient_x = ed25519_to_x25519_pubkey(&recipient_ed)
                .ok_or_else(|| "recipient pubkey not on Edwards curve".to_string())?;
            PickupKey::for_pairwise(&recipient_x).0
        }
    };
    // The onion Deliver drop IS the client-prepared chunk batch
    // (split + checksummed here); the relay treats it as opaque bytes.
    let batch = build_prepared_batch(&envelope, pickup_key, total_shares)?;
    let path: Vec<NodeIdentity> = match relay2_pubkey_hex {
        Some(r2) => vec![guard, NodeIdentity::from_ed25519_pubkey(decode_hex32(r2)?)],
        None => vec![guard],
    };
    let packet = wrap_onion(&path, &batch.encode(), &mut OsRng)
        .map_err(|e| format!("onion wrap: {e:?}"))?;
    let packet_bytes = packet.encode();
    let packet_hex = hex::encode(&packet_bytes);

    // Auth over the ONION PACKET bytes: session signature when a live
    // session is supplied (validate-at-handoff: one session field without
    // the other is a caller bug), else per-drop cert auth (Phase 2).
    let (session_key_param, session_sig_param) = match (&session_key_hex, &session_seed_hex) {
        (Some(key), Some(seed)) => {
            let sig = crate::chat_session::chat_session_sign_drop(
                seed.clone(),
                packet_hex.clone(),
            )?;
            (Some(key.clone()), Some(sig))
        }
        (None, None) => (None, None),
        _ => {
            return Err(
                "session auth needs BOTH session_key_hex and session_seed_hex (or neither)"
                    .into(),
            )
        }
    };
    let (auth_thumbprint_hex, auth_timestamp_secs, auth_sig_hex) =
        if session_key_param.is_some() {
            (None, None, None)
        } else {
            build_cert_auth(&packet_bytes, auth_cert_thumbprint_hex, auth_cert_seed_hex)?
        };

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("tokio runtime: {e}"))?;
    rt.block_on(async move {
        let rpc = subxt::rpcs::RpcClient::from_insecure_url(&node_rpc)
            .await
            .map_err(|e| format!("connecting to {node_rpc}: {e}"))?;
        let result: ChatSendResultRpc = rpc
            .request(
                "chat_send_onion",
                subxt::rpcs::rpc_params![
                    packet_hex,
                    auth_thumbprint_hex,
                    auth_timestamp_secs,
                    auth_sig_hex,
                    session_key_param,
                    session_sig_param
                ],
            )
            .await
            .map_err(|e| format!("chat_send_onion RPC failed: {e}"))?;
        Ok(ChatSendOutcome {
            message_id_hex: result.message_id_hex,
            share_count: result.share_count,
            recipient_pickup_key_hex: result.recipient_pickup_key_hex,
            new_session_state_hex: String::new(),
            new_self_hash_hex: String::new(),
        })
    })
}

/// Shared send core: content-seal the payload to the recipient's
/// silicon content key, sign, sealed-sender-wrap, cert-auth, dispatch.
fn send_content(
    node_rpc: String,
    sender_seed_hex: &str,
    recipient_pubkey_hex: &str,
    recipient_content_key_hex: &str,
    content_payload_bytes: Vec<u8>,
    total_shares: u8,
    auth_cert_thumbprint_hex: Option<String>,
    auth_cert_seed_hex: Option<String>,
) -> Result<ChatSendOutcome, String> {
    let (envelope, recipient_ed) = build_sealed_envelope(
        sender_seed_hex,
        recipient_pubkey_hex,
        recipient_content_key_hex,
        &content_payload_bytes,
    )?;
    // Direct DM: pickup is the recipient's pairwise bucket. Chunk +
    // checksum on-device into the PreparedBatch the node distributes.
    let recipient_x = ed25519_to_x25519_pubkey(&recipient_ed)
        .ok_or_else(|| "recipient pubkey not on Edwards curve".to_string())?;
    let pickup_key = PickupKey::for_pairwise(&recipient_x).0;
    let batch = build_prepared_batch(&envelope, pickup_key, total_shares)?;
    let batch_bytes = batch.encode();
    let batch_hex = hex::encode(&batch_bytes);

    // Cert-auth (Phase 2) over the EXACT batch bytes the node receives.
    let (auth_thumbprint_hex, auth_timestamp_secs, auth_sig_hex) =
        build_cert_auth(&batch_bytes, auth_cert_thumbprint_hex, auth_cert_seed_hex)?;

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("tokio runtime: {e}"))?;
    rt.block_on(async move {
        let rpc = subxt::rpcs::RpcClient::from_insecure_url(&node_rpc)
            .await
            .map_err(|e| format!("connecting to {node_rpc}: {e}"))?;
        let result: ChatSendResultRpc = rpc
            .request(
                "chat_send_prepared",
                subxt::rpcs::rpc_params![
                    batch_hex,
                    auth_thumbprint_hex,
                    auth_timestamp_secs,
                    auth_sig_hex
                ],
            )
            .await
            .map_err(|e| format!("chat_send_prepared RPC failed: {e}"))?;
        Ok(ChatSendOutcome {
            message_id_hex: result.message_id_hex,
            share_count: result.share_count,
            recipient_pickup_key_hex: result.recipient_pickup_key_hex,
            new_session_state_hex: String::new(),
            new_self_hash_hex: String::new(),
        })
    })
}

// ── FRB: fetch ──────────────────────────────────────────────────────

/// Fetch shares for the recipient, then reconstruct, OUTER-unseal and
/// sender-verify any complete message stripes on-device. The content
/// stays SEALED (encrypted at rest) — background-safe, no biometric.
/// Decrypt individual messages with [`chat_read_content`].
/// Poll the recipient's own pairwise pickup bucket (normal DMs).
pub fn chat_fetch(
    node_rpc: String,
    recipient_seed_hex: String,
    relay_peer: Option<String>,
) -> Result<Vec<AtRestMessage>, String> {
    let recipient_seed = decode_hex32(&recipient_seed_hex)?;
    let (_recipient_ed, _recipient_x_pub, pickup_bytes) = identity_from_seed(&recipient_seed)?;
    fetch_and_decrypt(node_rpc, pickup_bytes, recipient_seed, relay_peer)
}

/// Poll a DEAD-DROP `label` (callsign): fetch at `for_deaddrop(label)` and
/// decrypt with the recipient's REAL seed. The message is sealed to the
/// recipient's keys (the label is only routing), so the same seed that
/// opens a normal DM opens a dead drop. See docs/DOTWAVE-CHAT-DEAD-DROPS.md.
pub fn chat_fetch_deaddrop(
    node_rpc: String,
    recipient_seed_hex: String,
    label: String,
    relay_peer: Option<String>,
) -> Result<Vec<AtRestMessage>, String> {
    let recipient_seed = decode_hex32(&recipient_seed_hex)?;
    let pickup_bytes = PickupKey::for_deaddrop(label.as_bytes()).0;
    fetch_and_decrypt(node_rpc, pickup_bytes, recipient_seed, relay_peer)
}

/// Poll a RAW 32-byte pickup key — used for your own minted return
/// addresses (the ping-pong inbound + its grace window), where the bucket
/// is not derived from a label. Decrypts with the recipient's real seed.
pub fn chat_fetch_at_pickup(
    node_rpc: String,
    recipient_seed_hex: String,
    pickup_hex: String,
    relay_peer: Option<String>,
) -> Result<Vec<AtRestMessage>, String> {
    let recipient_seed = decode_hex32(&recipient_seed_hex)?;
    let pickup_bytes = decode_hex32(&pickup_hex)?;
    fetch_and_decrypt(node_rpc, pickup_bytes, recipient_seed, relay_peer)
}

/// Shared fetch → reconstruct → sealed-sender-unseal for both the normal
/// (`chat_fetch`) and dead-drop (`chat_fetch_deaddrop`) paths. `pickup_bytes`
/// selects the bucket; `recipient_seed` yields the X25519 secret that
/// unseals the sealed-sender layer.
fn fetch_and_decrypt(
    node_rpc: String,
    pickup_bytes: [u8; 32],
    recipient_seed: [u8; 32],
    relay_peer: Option<String>,
) -> Result<Vec<AtRestMessage>, String> {
    let recipient_x_secret = ed25519_seed_to_x25519_secret(&recipient_seed);

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("tokio runtime: {e}"))?;
    let shares: Vec<ChatFetchedShareRaw> = rt.block_on(async move {
        let rpc = subxt::rpcs::RpcClient::from_insecure_url(&node_rpc)
            .await
            .map_err(|e| format!("connecting to {node_rpc}: {e}"))?;
        rpc.request(
            "chat_fetch_shares",
            subxt::rpcs::rpc_params![hex::encode(pickup_bytes), relay_peer],
        )
        .await
        .map_err(|e| format!("chat_fetch_shares RPC failed: {e}"))
    })?;

    // Group fetched chunks by message_id, keeping the descriptor fields
    // (index, total, expires) + checksum per chunk exactly as fetched
    // (the checksum binds them all). Dedupe on (message_id, index): with
    // per-chunk replica sets, aggregation may return a chunk from more
    // than one relay.
    type FetchedChunk = (u8, u8, u64, Vec<u8>, ChunkChecksum);
    let mut by_message: HashMap<String, Vec<FetchedChunk>> = HashMap::new();
    for s in shares {
        let mid = s.descriptor.message_id_hex.clone();
        let bytes = hex::decode(s.share_bytes_hex.trim_start_matches("0x"))
            .map_err(|e| format!("share_bytes_hex not valid hex: {e}"))?;
        let checksum = decode_hex32(&s.checksum_hex)?;
        let entry = by_message.entry(mid).or_default();
        if entry.iter().any(|(idx, ..)| *idx == s.descriptor.share_index) {
            continue;
        }
        entry.push((
            s.descriptor.share_index,
            s.descriptor.total_shares,
            s.descriptor.expires_at_unix_ts,
            bytes,
            checksum,
        ));
    }

    // The recipient fetched under `pickup_bytes`; that key is bound into
    // every chunk's checksum, so verification uses it directly.
    let pickup_key = PickupKey(pickup_bytes);

    let mut recovered = Vec::new();
    for (mid_hex, chunk_list) in by_message {
        let message_id = match decode_hex32(&mid_hex) {
            Ok(b) => MessageId(b),
            Err(_) => continue,
        };
        let refs: Vec<TaggedChunk<'_>> = chunk_list
            .iter()
            .map(|(idx, total, expires, bytes, checksum)| TaggedChunk {
                share_index: *idx,
                total_shares: *total,
                expires_at_unix_ts: *expires,
                bytes,
                checksum,
            })
            .collect();
        // Verify each chunk's checksum + concatenate. On a corrupt or
        // incomplete set the message is skipped; the bucket-subscription
        // scheme supplies a good copy on a later poll (no client-side
        // recovery — docs/CHAT-SHARE-CHUNKING.md §4.3a).
        let envelope_bytes = match combine_chunks_verified(&message_id, &pickup_key, &refs) {
            Ok(b) => b,
            Err(_) => continue,
        };
        let envelope = match SealedEnvelope::decode(&mut &envelope_bytes[..]) {
            Ok(e) => e,
            Err(_) => continue,
        };
        // Pairwise only for now (group flow not yet wired).
        if !matches!(envelope.kind, EnvelopeKind::Pairwise) {
            continue;
        }

        let sealed = SealedOutput {
            ephemeral_pub: envelope.ephemeral_pubkey,
            ciphertext: envelope.outer_ciphertext,
        };
        let unsealed_bytes = match ss_unseal(&recipient_x_secret, &sealed) {
            Ok(b) => b,
            Err(_) => continue,
        };
        let unsealed = match UnsealedInner::decode(&mut &unsealed_bytes[..]) {
            Ok(u) => u,
            Err(_) => continue,
        };
        // Verify the sealed sender signature on-device.
        let sender_pubkey = match verify_sender(&unsealed, &envelope.message_id) {
            Ok(pk) => pk,
            Err(_) => continue,
        };

        // Phase 3: the inner stays SEALED. Validate it decodes as a
        // ContentSealed (reject malformed/legacy-plaintext inners at the
        // handoff) but do NOT decrypt — the blob is returned encrypted
        // at rest; [`chat_read_content`] is the only way to plaintext.
        if ContentSealed::decode(&mut &unsealed.inner_ciphertext[..]).is_err() {
            continue;
        }
        recovered.push(AtRestMessage {
            message_id_hex: mid_hex,
            sender_pubkey_hex: hex::encode(sender_pubkey),
            sealed_content_hex: hex::encode(&unsealed.inner_ciphertext),
        });
    }

    Ok(recovered)
}

#[cfg(test)]
mod ordering_tests {
    //! The in-seal self-hash chain primitive (in-order delivery). The
    //! recipient's ordering engine lives in Dart (`orderThread`); these
    //! cover the Rust side: a deterministic chain link that survives the
    //! SCALE round-trip the content seal carries.
    use super::*;

    #[test]
    fn self_hash_is_blake2_of_encoding_and_deterministic() {
        let p = InnerPayload {
            sender_name: b"alice".to_vec(),
            body: b"hi".to_vec(),
            prev_self_hash: None,
            composed_at: 1_700_000_000,
            return_pickup: None,
        };
        assert_eq!(p.self_hash(), sp_core::hashing::blake2_256(&p.encode()));
        assert_eq!(p.self_hash(), p.self_hash());
    }

    #[test]
    fn unordered_carries_no_chain() {
        let p = InnerPayload::unordered(b"x".to_vec(), b"y".to_vec());
        assert!(p.prev_self_hash.is_none());
        assert_eq!(p.composed_at, 0);
    }

    #[test]
    fn chain_link_survives_scale_round_trip() {
        // msg1 (first: no prev) -> msg2 references msg1's self_hash.
        let m1 = InnerPayload {
            sender_name: b"a".to_vec(),
            body: b"one".to_vec(),
            prev_self_hash: None,
            composed_at: 10,
            return_pickup: None,
        };
        let tip = m1.self_hash();
        let m2 = InnerPayload {
            sender_name: b"a".to_vec(),
            body: b"two".to_vec(),
            prev_self_hash: Some(tip),
            composed_at: 20,
            return_pickup: None,
        };
        // Decode m2 as the recipient would, after content-unseal.
        let decoded = InnerPayload::decode(&mut &m2.encode()[..]).unwrap();
        assert_eq!(decoded.prev_self_hash, Some(tip));
        assert_eq!(decoded.composed_at, 20);
        // The recipient recomputes m1's self_hash and the link matches.
        assert_eq!(decoded.prev_self_hash.unwrap(), m1.self_hash());
    }

    #[test]
    fn distinct_bodies_yield_distinct_hashes() {
        let a = InnerPayload::unordered(b"n".to_vec(), b"hello".to_vec());
        let b = InnerPayload::unordered(b"n".to_vec(), b"world".to_vec());
        assert_ne!(a.self_hash(), b.self_hash());
    }
}
