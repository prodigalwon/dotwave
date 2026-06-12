// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rostro Foundation contributors

//! Phase 5 — Double Ratchet bootstrap + prekey lifecycle for dotwave.
//!
//! The ratchet itself lives in `rostro-chat-dr` (full Signal
//! semantics: bounded skipped keys, PN headers, persistence) and the
//! per-message integration lives in [`crate::chat::chat_send`] /
//! [`crate::chat::chat_read_content`]. This module owns what happens
//! AROUND the ratchet:
//!
//! - **Signed prekey (SPK)**: derived deterministically from the
//!   identity seed, signed by the identity Ed25519, published in the
//!   RNS chat-identity record (see `core::chat_publish_identity`).
//! - **One-time prekeys (OPK)**: random batches, identity-signed,
//!   published THROUGH THE EXISTING RELAY TRANSPORT sealed to a
//!   *publicly-derivable address keypair* (`H(identity_pub ‖ domain)`
//!   as the seed) — anyone planning to message the user can derive
//!   the address, fetch, unseal, and verify the batch. The seal is
//!   pure addressing (contents are public keys); authenticity comes
//!   from the identity signatures + the envelope's sender
//!   verification. Zero node changes.
//! - **X3DH initiation**: resolve the recipient's record (SPK) +
//!   fetch an OPK → derive the shared secret → a ready-to-send
//!   [`DrInitiation`] whose session state goes straight into
//!   `chat_send`.
//!
//! ## Honest limits (documented, not hidden)
//!
//! One-time semantics are BEST-EFFORT: the relay store does not
//! consume on fetch, so two concurrent initiators can pick the same
//! OPK. The recipient holds each OPK secret until first use; the
//! second initiation then fails with a recoverable
//! `OpkUnavailable`-class error and retries SPK-only — exactly
//! Signal's prekey-exhaustion degradation. Batches also TTL-expire
//! with the relay store; clients republish on a cadence (and after
//! consuming).

use parity_scale_codec::{Decode, Encode};
use rostro_chat_dr::{
    sign_opk, sign_spk, spk_preimage, verify_spk, x3dh_initiate, PrekeyBundle, Session,
    SignedOneTimePrekey, X3dhInit,
};
use rostro_chat_primitives::identity_key::{
    ed25519_seed_to_x25519_secret, ed25519_to_x25519_pubkey,
};
use x25519_dalek::{PublicKey as X25519PublicKey, StaticSecret as X25519SecretKey};

use crate::chat::{
    chat_fetch, chat_gen_content_key, chat_read_content, chat_send_plain, decode_hex32_pub,
    AtRestMessage, ChatSendOutcome,
};

/// Domain for deriving the device's signed-prekey secret from the
/// identity seed. Deterministic: the responder re-derives the same
/// SPK secret at read time without separate storage. Rotation (a new
/// SPK epoch) is a productionization item — bump via a new domain or
/// an epoch suffix when built.
const SPK_SEED_DOMAIN: &[u8] = b"rostro/chat/spk-seed/v1";

/// Domain for deriving the PUBLIC one-time-prekey mailbox address
/// from an identity pubkey. Everyone derives the same address from
/// the same identity — that is the point (a public pickup spot).
const OTPK_ADDRESS_DOMAIN: &[u8] = b"rostro/chat/otpk-address/v1";

fn blake2(parts: &[&[u8]]) -> [u8; 32] {
    let mut buf = Vec::new();
    for p in parts {
        buf.extend_from_slice(p);
    }
    sp_core::hashing::blake2_256(&buf)
}

/// Derive the device's SPK X25519 secret from the identity seed.
pub(crate) fn spk_secret_from_identity_seed(seed: &[u8; 32]) -> X25519SecretKey {
    X25519SecretKey::from(blake2(&[seed, SPK_SEED_DOMAIN]))
}

/// Derive the (publicly-derivable) OPK mailbox address seed for an
/// identity pubkey. The returned bytes are an Ed25519 seed: its
/// pubkey is the "recipient" the bundle is sealed to, and the
/// matching content-key/unseal seeds derive from it the same way as
/// for any chat identity.
pub(crate) fn otpk_address_seed(identity_ed25519_pub: &[u8; 32]) -> [u8; 32] {
    blake2(&[identity_ed25519_pub, OTPK_ADDRESS_DOMAIN])
}

// ── FRB types ───────────────────────────────────────────────────────

/// Output of [`chat_dr_gen_prekeys`]. `spk_*` go into the RNS record
/// (via `chat_publish_identity`); `opk_bundle_hex` is published with
/// [`chat_dr_publish_opks`]; `opk_secrets` MUST be stored by the app
/// (encrypted) — each is consumed by the first inbound conversation
/// that used it.
pub struct DrPrekeySetup {
    pub spk_pubkey_hex: String,
    pub spk_signature_hex: String,
    pub opk_bundle_hex: String,
    pub opk_secrets: Vec<DrOpkSecret>,
}

/// A stored one-time-prekey secret.
pub struct DrOpkSecret {
    pub id: u32,
    pub secret_hex: String,
}

/// An OPK picked from a fetched, signature-verified batch.
pub struct DrFetchedOpk {
    pub found: bool,
    pub id: u32,
    pub pubkey_hex: String,
}

/// A ready-to-send conversation bootstrap: pass `session_state_hex`
/// and `x3dh_init_hex` to the first `chat_send`.
pub struct DrInitiation {
    pub session_state_hex: String,
    pub x3dh_init_hex: String,
}

// ── FRB: prekey generation + publication ───────────────────────────

/// Generate the device's prekey material: the deterministic SPK
/// (signed) + `opk_count` RANDOM one-time prekeys starting at
/// `opk_start_id`.
pub fn chat_dr_gen_prekeys(
    identity_seed_hex: String,
    opk_start_id: u32,
    opk_count: u32,
) -> Result<DrPrekeySetup, String> {
    let seed = decode_hex32_pub(&identity_seed_hex)?;
    let signing = ed25519_zebra::SigningKey::from(seed);

    let spk_secret = spk_secret_from_identity_seed(&seed);
    let spk_pub = X25519PublicKey::from(&spk_secret);
    let spk_signature = sign_spk(&spk_pub, &signing);

    let mut bundle = Vec::with_capacity(opk_count as usize);
    let mut secrets = Vec::with_capacity(opk_count as usize);
    for i in 0..opk_count {
        let id = opk_start_id + i;
        let secret = X25519SecretKey::random_from_rng(rand_core_06::OsRng);
        let pubkey = X25519PublicKey::from(&secret);
        bundle.push(SignedOneTimePrekey {
            id,
            x25519: *pubkey.as_bytes(),
            signature: sign_opk(id, &pubkey, &signing),
        });
        secrets.push(DrOpkSecret { id, secret_hex: hex::encode(secret.to_bytes()) });
    }

    Ok(DrPrekeySetup {
        spk_pubkey_hex: hex::encode(spk_pub.as_bytes()),
        spk_signature_hex: hex::encode(spk_signature),
        opk_bundle_hex: hex::encode(bundle.encode()),
        opk_secrets: secrets,
    })
}

/// Publish an OPK bundle to the identity's public prekey mailbox
/// (derived address) through the normal relay send path. Cert-gated
/// like every drop.
pub fn chat_dr_publish_opks(
    node_rpc: String,
    identity_seed_hex: String,
    opk_bundle_hex: String,
    total_shares: u8,
    auth_cert_thumbprint_hex: Option<String>,
    auth_cert_seed_hex: Option<String>,
) -> Result<ChatSendOutcome, String> {
    let seed = decode_hex32_pub(&identity_seed_hex)?;
    let identity_pub: [u8; 32] =
        ed25519_zebra::VerificationKey::from(&ed25519_zebra::SigningKey::from(seed)).into();
    let addr_seed = otpk_address_seed(&identity_pub);
    let addr_pub: [u8; 32] =
        ed25519_zebra::VerificationKey::from(&ed25519_zebra::SigningKey::from(addr_seed)).into();
    // The mailbox's content key derives from the address seed the
    // same public way (P-256, scalar = addr_seed).
    let addr_content_key = chat_gen_content_key(0, hex::encode(addr_seed))?;

    let bundle_bytes = hex::decode(opk_bundle_hex.trim_start_matches("0x"))
        .map_err(|e| format!("opk bundle hex: {e}"))?;

    chat_send_plain(
        node_rpc,
        identity_seed_hex,
        hex::encode(addr_pub),
        addr_content_key,
        bundle_bytes,
        total_shares,
        auth_cert_thumbprint_hex,
        auth_cert_seed_hex,
    )
}

/// Fetch + verify the newest OPK batch from `identity_pubkey_hex`'s
/// public prekey mailbox and pick one. `found = false` (no batch on
/// the relays — expired or never published) is the SPK-only
/// degradation path, not an error.
pub fn chat_dr_fetch_opk(
    node_rpc: String,
    identity_pubkey_hex: String,
    exclude_ids: Vec<u32>,
) -> Result<DrFetchedOpk, String> {
    let identity_pub = decode_hex32_pub(&identity_pubkey_hex)?;
    let addr_seed = otpk_address_seed(&identity_pub);

    let messages: Vec<AtRestMessage> =
        chat_fetch(node_rpc, hex::encode(addr_seed), None)?;
    for m in messages {
        // The bundle must come from the identity itself.
        if m.sender_pubkey_hex != identity_pubkey_hex {
            continue;
        }
        let read = match chat_read_content(
            m.sealed_content_hex,
            0,
            hex::encode(addr_seed),
            None,
            hex::encode(addr_seed),
            Vec::new(),
        ) {
            Ok(r) => r,
            Err(_) => continue,
        };
        let bytes = hex::decode(&read.plaintext_hex).map_err(|e| e.to_string())?;
        let batch = match Vec::<SignedOneTimePrekey>::decode(&mut &bytes[..]) {
            Ok(b) => b,
            Err(_) => continue,
        };
        for opk in batch {
            if exclude_ids.contains(&opk.id) {
                continue;
            }
            if opk.verify(&identity_pub).is_ok() {
                return Ok(DrFetchedOpk {
                    found: true,
                    id: opk.id,
                    pubkey_hex: hex::encode(opk.x25519),
                });
            }
        }
    }
    Ok(DrFetchedOpk { found: false, id: 0, pubkey_hex: String::new() })
}

// ── FRB: X3DH initiation ────────────────────────────────────────────

/// Start a new conversation: verify the recipient's published SPK,
/// run full X3DH (with the OPK if one was fetched), and return the
/// initiator session + the X3dhInit to attach to the FIRST
/// `chat_send`.
pub fn chat_dr_initiate(
    identity_seed_hex: String,
    recipient_identity_pubkey_hex: String,
    recipient_spk_hex: String,
    recipient_spk_signature_hex: String,
    opk_id: Option<u32>,
    opk_pubkey_hex: Option<String>,
) -> Result<DrInitiation, String> {
    let seed = decode_hex32_pub(&identity_seed_hex)?;
    let my_identity_ed: [u8; 32] =
        ed25519_zebra::VerificationKey::from(&ed25519_zebra::SigningKey::from(seed)).into();
    let my_identity_x = X25519SecretKey::from(ed25519_seed_to_x25519_secret(&seed));

    let recipient_ed = decode_hex32_pub(&recipient_identity_pubkey_hex)?;
    let recipient_x = ed25519_to_x25519_pubkey(&recipient_ed)
        .ok_or("recipient identity not a valid Edwards point")?;
    let spk = decode_hex32_pub(&recipient_spk_hex)?;
    let spk_sig_bytes = hex::decode(recipient_spk_signature_hex.trim_start_matches("0x"))
        .map_err(|e| format!("spk signature hex: {e}"))?;
    let spk_signature: [u8; 64] =
        spk_sig_bytes.try_into().map_err(|_| "spk signature must be 64 bytes")?;

    let opk = match (opk_id, opk_pubkey_hex) {
        (Some(id), Some(pk)) => Some((id, decode_hex32_pub(&pk)?)),
        (None, None) => None,
        _ => return Err("opk_id and opk_pubkey_hex must be passed together".into()),
    };

    let bundle = PrekeyBundle {
        identity_ed25519: recipient_ed,
        identity_x25519: recipient_x,
        spk_x25519: spk,
        spk_signature,
        opk,
    };
    verify_spk(&bundle).map_err(|e| format!("SPK signature invalid: {e:?}"))?;
    // The signature covers the SPK preimage; sanity-pin the domain so
    // a future preimage change can't silently pass stale signatures.
    debug_assert!(spk_preimage(&spk).starts_with(b"rostro/chat-channel/spk/v1"));

    let (init, sk, ephemeral) =
        x3dh_initiate(&my_identity_x, my_identity_ed, &bundle, &mut rand_core_06::OsRng);
    let session =
        Session::from_handshake_initiator(sk, ephemeral, X25519PublicKey::from(spk));

    Ok(DrInitiation {
        session_state_hex: hex::encode(session.to_state_bytes()),
        x3dh_init_hex: hex::encode(init.encode()),
    })
}

/// Re-export for chat.rs's read path (responder bootstrap).
pub(crate) fn responder_session_from_init(
    identity_seed: &[u8; 32],
    opk_secrets: &[(u32, [u8; 32])],
    init: &X3dhInit,
) -> Result<Session, String> {
    let my_identity_x = X25519SecretKey::from(ed25519_seed_to_x25519_secret(identity_seed));
    let spk_secret = spk_secret_from_identity_seed(identity_seed);

    let initiator_x = ed25519_to_x25519_pubkey(&init.initiator_identity_ed25519)
        .ok_or("initiator identity not a valid Edwards point")?;

    let opk_secret = match init.opk_id {
        None => None,
        Some(id) => Some(X25519SecretKey::from(
            opk_secrets
                .iter()
                .find(|(sid, _)| *sid == id)
                .map(|(_, s)| *s)
                .ok_or(format!(
                    "OPK {id} secret not held (consumed or never ours) — \
                     initiator must retry SPK-only"
                ))?,
        )),
    };

    let sk = rostro_chat_dr::x3dh_respond(
        &my_identity_x,
        &spk_secret,
        opk_secret.as_ref(),
        &X25519PublicKey::from(initiator_x),
        init,
    )
    .map_err(|e| format!("x3dh respond: {e:?}"))?;

    Ok(Session::from_handshake_responder(
        sk,
        spk_secret,
        X25519PublicKey::from(init.ephemeral_x25519),
    ))
}
