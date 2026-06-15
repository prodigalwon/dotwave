// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rostro Foundation contributors

//! Chat-auth session client (the ceremony, dotwave side).
//!
//! One biometric+HIP handshake to the node establishes a **node-local,
//! time-bounded session** (W = 4 days on the node's monotonic clock); drops
//! within it ride a cheap **software session key**, so the secure element is
//! NOT touched per message. Design of record:
//! `Rostro/docs/DOTWAVE-CHAT-AUTH-CEREMONY.md`.
//!
//! Client flow (the dart layer orchestrates; HIP generation is the hardware
//! step in the middle):
//!   1. [`chat_session_gen_keypair`] — fresh software Ed25519 session key.
//!   2. [`chat_session_prepare`] — read the guard's id + a recent block and
//!      derive the block-anchored nonce the HIP must commit to.
//!   3. *(hardware)* generate a `CanonicalHipProof` with `nonce_hex` baked into
//!      the attestation challenge (StrongBox on Android / TPM2 on desktop).
//!   4. [`chat_session_authenticate`] — submit the proof; the node verifies it
//!      and records the session, returning the bound account + expiry.
//!   5. [`chat_session_sign_drop`] — per drop, sign the onion packet with the
//!      session key (no hardware crossing) for `chat_send_onion`'s session path.
//!
//! The nonce derivation and drop-signature construction here MUST stay
//! byte-identical to the node side (`gemini-node/src/chat_rpc.rs`):
//! `CHAT_SESSION_NONCE_DOMAIN` / `CHAT_SESSION_DROP_DOMAIN` and the field order.

use ed25519_zebra::{SigningKey, VerificationKey};
// rand_core 0.6 — see chat.rs: the chat crates bind the 0.6 RngCore.
use rand_core_06::{OsRng, RngCore};
use sp_core::hashing::blake2_256;

use crate::chat::decode_hex32_pub as decode_hex32;

/// Domain tag for the session-handshake nonce. MUST match
/// `CHAT_SESSION_NONCE_DOMAIN` in gemini-node's `chat_rpc.rs` — a wire constant.
const CHAT_SESSION_NONCE_DOMAIN: &[u8] = b"rostro/chat/session-nonce/v1";

/// Domain tag for a per-drop session-key signature. MUST match
/// `CHAT_SESSION_DROP_DOMAIN` in gemini-node's `chat_rpc.rs`.
const CHAT_SESSION_DROP_DOMAIN: &[u8] = b"rostro/chat/session-drop/v1";

/// Derive the block-anchored handshake nonce the HIP attestation challenge
/// commits to. Byte-identical to the node's `derive_session_nonce`:
/// `blake2_256(domain ‖ anchor_block_hash ‖ cert_thumbprint ‖ guard_node_id ‖
/// session_pubkey)`.
fn derive_session_nonce(
    anchor_block_hash: &[u8; 32],
    cert_thumbprint: &[u8; 32],
    guard_node_id: &[u8; 32],
    session_pubkey: &[u8; 32],
) -> [u8; 32] {
    let mut buf = Vec::with_capacity(CHAT_SESSION_NONCE_DOMAIN.len() + 32 * 4);
    buf.extend_from_slice(CHAT_SESSION_NONCE_DOMAIN);
    buf.extend_from_slice(anchor_block_hash);
    buf.extend_from_slice(cert_thumbprint);
    buf.extend_from_slice(guard_node_id);
    buf.extend_from_slice(session_pubkey);
    blake2_256(&buf)
}

// ── FRB-facing result types ─────────────────────────────────────────

/// A fresh software session keypair. The seed stays on-device (ordinary
/// app storage — NOT the secure element); the pubkey is authorized by the
/// handshake and stored by the node to verify per-drop signatures.
pub struct ChatSessionKeypair {
    pub seed_hex: String,
    pub pubkey_hex: String,
}

/// Inputs the client must gather (and the nonce it must derive) before the
/// hardware HIP step. `nonce_hex` is fed to the StrongBox/TPM attestation
/// challenge so the resulting proof is bound to this exact (block, cert,
/// guard, session-key) tuple.
pub struct ChatSessionPrepared {
    /// The recent block the nonce is anchored to (sent to the node so it can
    /// re-derive the same nonce against the same block hash).
    pub anchor_block_number: u64,
    pub anchor_block_hash_hex: String,
    /// The guard node's Ed25519 identity (binds the handshake to this node).
    pub guard_node_id_hex: String,
    /// The nonce to bake into the HIP attestation challenge.
    pub nonce_hex: String,
}

/// Outcome of a successful handshake. The session is now live at the node
/// until `expiry_unix_secs`; the client should pin this node and re-handshake
/// proactively (≈80% of `session_ttl_secs`) and on any node switch.
pub struct ChatSessionOutcome {
    pub bound_account_hex: String,
    pub expiry_unix_secs: u64,
    pub session_ttl_secs: u64,
}

// ── RPC response mirrors (must match gemini-node/src/chat_rpc.rs) ────

#[derive(serde::Deserialize)]
struct ChatNodeInfoRpc {
    node_pubkey_ed25519_hex: String,
}

#[derive(serde::Deserialize)]
struct HeaderRpc {
    /// Hex-encoded block number, e.g. "0x1a".
    number: String,
}

#[derive(serde::Deserialize)]
struct ChatAuthenticateResultRpc {
    bound_account_hex: String,
    expiry_unix_secs: u64,
    session_ttl_secs: u64,
}

// ── FRB: session client ─────────────────────────────────────────────

/// Generate a fresh software Ed25519 session keypair. The dart layer
/// persists `seed_hex` (encrypted) for the session's lifetime and re-derives
/// the signing key per drop; it never touches the secure element.
pub fn chat_session_gen_keypair() -> ChatSessionKeypair {
    let mut seed = [0u8; 32];
    OsRng.fill_bytes(&mut seed);
    let signing = SigningKey::from(seed);
    let pubkey: [u8; 32] = VerificationKey::from(&signing).into();
    ChatSessionKeypair {
        seed_hex: hex::encode(seed),
        pubkey_hex: hex::encode(pubkey),
    }
}

/// Read the guard's identity (`chat_nodeInfo`) and a recent block, then derive
/// the handshake nonce. The caller feeds `nonce_hex` to the hardware HIP
/// ceremony as the attestation challenge before calling
/// [`chat_session_authenticate`].
pub fn chat_session_prepare(
    node_rpc: String,
    cert_thumbprint_hex: String,
    session_pubkey_hex: String,
) -> Result<ChatSessionPrepared, String> {
    let thumbprint = decode_hex32(&cert_thumbprint_hex)
        .map_err(|e| format!("cert_thumbprint_hex: {e}"))?;
    let session_pubkey = decode_hex32(&session_pubkey_hex)
        .map_err(|e| format!("session_pubkey_hex: {e}"))?;

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
        let guard_node_id = decode_hex32(&info.node_pubkey_ed25519_hex)
            .map_err(|e| format!("guard node id: {e}"))?;

        // Best block: hash (for the nonce) + number (sent to the node).
        let best_hash_hex: String = rpc
            .request("chain_getBlockHash", subxt::rpcs::rpc_params![])
            .await
            .map_err(|e| format!("chain_getBlockHash RPC failed: {e}"))?;
        let anchor_hash = decode_hex32(&best_hash_hex)
            .map_err(|e| format!("anchor block hash: {e}"))?;
        let header: HeaderRpc = rpc
            .request("chain_getHeader", subxt::rpcs::rpc_params![best_hash_hex.clone()])
            .await
            .map_err(|e| format!("chain_getHeader RPC failed: {e}"))?;
        let anchor_block_number =
            u64::from_str_radix(header.number.trim_start_matches("0x"), 16)
                .map_err(|e| format!("decode block number '{}': {e}", header.number))?;

        let nonce =
            derive_session_nonce(&anchor_hash, &thumbprint, &guard_node_id, &session_pubkey);

        Ok(ChatSessionPrepared {
            anchor_block_number,
            anchor_block_hash_hex: hex::encode(anchor_hash),
            guard_node_id_hex: hex::encode(guard_node_id),
            nonce_hex: hex::encode(nonce),
        })
    })
}

/// Submit the HIP proof to the node's `chat_authenticate`, establishing the
/// session. `hip_proof_hex` is the SCALE-encoded `CanonicalHipProof` produced
/// by the hardware ceremony with `prepare`'s nonce baked in; `anchor_block_number`
/// is the value from [`chat_session_prepare`].
pub fn chat_session_authenticate(
    node_rpc: String,
    cert_thumbprint_hex: String,
    hip_proof_hex: String,
    anchor_block_number: u64,
    session_pubkey_hex: String,
) -> Result<ChatSessionOutcome, String> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("tokio runtime: {e}"))?;
    rt.block_on(async move {
        let rpc = subxt::rpcs::RpcClient::from_insecure_url(&node_rpc)
            .await
            .map_err(|e| format!("connecting to {node_rpc}: {e}"))?;
        let res: ChatAuthenticateResultRpc = rpc
            .request(
                "chat_authenticate",
                subxt::rpcs::rpc_params![
                    cert_thumbprint_hex,
                    hip_proof_hex,
                    anchor_block_number,
                    session_pubkey_hex
                ],
            )
            .await
            .map_err(|e| format!("chat_authenticate RPC failed: {e}"))?;
        Ok(ChatSessionOutcome {
            bound_account_hex: res.bound_account_hex,
            expiry_unix_secs: res.expiry_unix_secs,
            session_ttl_secs: res.session_ttl_secs,
        })
    })
}

/// Sign an onion packet with the session key for `chat_send_onion`'s session
/// path. Returns the 64-byte Ed25519 signature (hex) over
/// `blake2_256(CHAT_SESSION_DROP_DOMAIN ‖ packet)`. Pure software — no
/// secure-element crossing, no biometric (the handshake already proved those).
pub fn chat_session_sign_drop(
    session_seed_hex: String,
    onion_packet_hex: String,
) -> Result<String, String> {
    let seed =
        decode_hex32(&session_seed_hex).map_err(|e| format!("session_seed_hex: {e}"))?;
    let packet = hex::decode(onion_packet_hex.trim_start_matches("0x"))
        .map_err(|e| format!("onion_packet_hex: {e}"))?;
    let signing = SigningKey::from(seed);
    let mut to_sign = Vec::with_capacity(CHAT_SESSION_DROP_DOMAIN.len() + packet.len());
    to_sign.extend_from_slice(CHAT_SESSION_DROP_DOMAIN);
    to_sign.extend_from_slice(&packet);
    let digest = blake2_256(&to_sign);
    let sig: [u8; 64] = signing.sign(&digest).into();
    Ok(hex::encode(sig))
}
