//! Chat anonymous-membership client: the hardware-derived member secret
//! `s` and the mint-time enrollment binding.
//!
//! Design of record: Rostro `docs/DOTWAVE-CHAT-ANON-MEMBERSHIP-AUTH.md`
//! (D1/D2) and the dotwave build plan
//! `docs/DOTWAVE-MEMBERSHIP-AUTH-CLIENT-PLAN.md` (M1).
//!
//! Key facts this module encodes:
//!
//! - `s = hash_to_field_bn254(ECDH(W_priv, P_FIXED))` where `W` is a
//!   non-exportable, auth-gated StrongBox `PURPOSE_AGREE_KEY` P-256 key
//!   (D1). The ECDH runs in-chip on the Kotlin side
//!   (`StrongBoxManager.computeMembershipEcdh`); only the 32-byte shared
//!   secret (the X coordinate) crosses into Rust, is reduced to `s`,
//!   used, and zeroized.
//! - `P_FIXED` is a nothing-up-my-sleeve P-256 point derived via RFC 9380
//!   hash-to-curve (P256_XMD:SHA-256_SSWU_RO), so nobody knows its
//!   discrete log — which is what makes `s = W_priv · P_FIXED` a secret
//!   only the chip can produce. (ECDH against the generator would make
//!   `s` equal `W_pub`, i.e. public.)
//! - `id_commitment = Poseidon(s)`, canonical little-endian bytes — the
//!   value `mint_cert`'s `chat_enrollment` argument carries and the
//!   membership leaf commits.
//! - `id_binding_signature` = attest_ec (StrongBox, attested at mint)
//!   over `blake2_256(ID_BINDING_CONTEXT || id_commitment || challenge)`
//!   where `challenge` is the offer nonce (D2; chain verifier:
//!   `zkpki-tpm::chat_enrollment::verify_chat_enrollment`). The message
//!   is built here so the context bytes have exactly one definition on
//!   the phone; Kotlin only ever signs the finished 32-byte digest.

use flutter_rust_bridge::frb;
use zeroize::Zeroize;

use crate::core::{decode_hex_32, decode_hex_bytes};

/// Domain-separation context for the id-commitment binding signature.
/// MUST match `zkpki-tpm::chat_enrollment::ID_BINDING_CONTEXT`.
pub const ID_BINDING_CONTEXT: &[u8] = b"rostro-chat-id-binding-v1";

/// Hash-to-curve inputs for [`membership_p_fixed_sec1`]. The DST follows
/// the RFC 9380 suite-naming convention; the message names the point's
/// single purpose. Changing either changes `P_FIXED`, which changes every
/// enrolled `s` — version-bump, never edit.
const P_FIXED_DST: &[u8] = b"rostro-membership-w:P256_XMD:SHA-256_SSWU_RO_";
const P_FIXED_MSG: &[u8] = b"rostro-membership-P_fixed-v1";

/// The fixed public point `W` performs its in-chip ECDH against, as
/// 65-byte uncompressed SEC1 (`0x04 || X || Y`) — the encoding Android
/// Keystore's `KeyAgreement` peer expects. Deterministic: derived fresh
/// on every call via RFC 9380 hash-to-curve and pinned by a KAT below.
pub fn membership_p_fixed_sec1() -> Vec<u8> {
    use p256::elliptic_curve::hash2curve::{ExpandMsgXmd, GroupDigest};
    use p256::elliptic_curve::sec1::ToEncodedPoint;

    let point = p256::NistP256::hash_from_bytes::<ExpandMsgXmd<sha2::Sha256>>(
        &[P_FIXED_MSG],
        &[P_FIXED_DST],
    )
    .expect("hash-to-curve with a non-empty DST cannot fail");
    p256::PublicKey::from_affine(point.to_affine())
        .expect("hash-to-curve never yields the identity point")
        .to_encoded_point(false)
        .as_bytes()
        .to_vec()
}

/// Reduce the in-chip ECDH shared secret to the member secret `s` and
/// return `id_commitment = Poseidon(s)` as canonical little-endian hex.
///
/// The shared secret is zeroized before returning. `s` itself never
/// leaves this function; callers that need `s` again (the per-epoch
/// handshake proof) re-run the in-chip ECDH.
pub fn membership_id_commitment(shared_secret_hex: String) -> Result<String, String> {
    use rostro_poseidon_bn254::{fr_to_bytes_le, hash_to_field_bn254, id_commitment, params};

    let mut shared = decode_hex_32(&shared_secret_hex, "shared_secret")?;
    let s = hash_to_field_bn254(&shared);
    shared.zeroize();
    let idc = id_commitment(&params(), s);
    Ok(hex::encode(fr_to_bytes_le(&idc)))
}

/// The 32-byte message attest_ec signs for chat enrollment:
/// `blake2_256(ID_BINDING_CONTEXT || id_commitment || challenge)`.
/// `challenge` is the offer nonce (`contract_nonce`) — the same bytes
/// `mint_cert` passes to `verify_chat_enrollment` on-chain.
pub fn membership_id_binding_msg(
    id_commitment_hex: String,
    challenge_hex: String,
) -> Result<String, String> {
    let idc = decode_hex_32(&id_commitment_hex, "id_commitment")?;
    let challenge = decode_hex_32(&challenge_hex, "challenge")?;
    let mut input = Vec::with_capacity(ID_BINDING_CONTEXT.len() + 32 + 32);
    input.extend_from_slice(ID_BINDING_CONTEXT);
    input.extend_from_slice(&idc);
    input.extend_from_slice(&challenge);
    Ok(hex::encode(sp_core::hashing::blake2_256(&input)))
}

/// Mirror of the chain's `verify_chat_enrollment` for the M1 gate and
/// labtool: does `signature` (DER or raw r||s) verify under the SEC1
/// `attest_ec` pubkey over the id-binding message? Uses the same p256
/// crate + prehash behavior as `DevicePublicKey::verify_signature`, so
/// a `true` here means the chain will accept the enrollment (modulo the
/// attestation gates).
#[frb(ignore)]
pub fn verify_id_binding(
    attest_ec_sec1_hex: String,
    id_commitment_hex: String,
    challenge_hex: String,
    signature_hex: String,
) -> Result<bool, String> {
    use p256::ecdsa::signature::Verifier;

    let msg = decode_hex_32(
        &membership_id_binding_msg(id_commitment_hex, challenge_hex)?,
        "binding_msg",
    )?;
    let pubkey = decode_hex_bytes(&attest_ec_sec1_hex, "attest_ec_sec1")?;
    let signature = decode_hex_bytes(&signature_hex, "signature")?;

    let vk = p256::ecdsa::VerifyingKey::from_sec1_bytes(&pubkey)
        .map_err(|e| format!("attest_ec pubkey: {e}"))?;
    if let Ok(sig) = p256::ecdsa::Signature::from_der(&signature) {
        if vk.verify(&msg, &sig).is_ok() {
            return Ok(true);
        }
    }
    if let Ok(sig) = p256::ecdsa::Signature::from_slice(&signature) {
        if vk.verify(&msg, &sig).is_ok() {
            return Ok(true);
        }
    }
    Ok(false)
}

// ── Witness fetch (M3) + membership handshake (M4) ─────────────────────

/// Client mirror of `zkpki-primitives::runtime_api::MembershipWitnessData`
/// (SCALE field order pinned to that definition — the witness-check gate
/// round-trips it against the live chain). Mirrored instead of imported so
/// the phone `.so` doesn't pull `sp-api`.
#[derive(parity_scale_codec::Decode)]
struct MembershipWitnessDataScale {
    leaf_position: u64,
    expiry_block: u64,
    fresh_until_epoch: u32,
    membership_path: Vec<[u8; 32]>,
    freshness_path: Vec<[u8; 32]>,
}

/// The cert's membership witness, fetched from the chain and verified
/// locally: `root_matches` says the root recomputed from
/// `leaf(id_commitment, expiry, scope)` + the returned path equals the
/// chain's `membership_root()` (and likewise for the freshness tree).
pub struct MembershipWitness {
    pub leaf_position: u64,
    pub expiry_block: u64,
    pub fresh_until_epoch: u32,
    pub scope: u64,
    pub current_epoch: u64,
    pub best_block: u64,
    pub local_membership_root_hex: String,
    pub chain_membership_root_hex: String,
    pub local_freshness_root_hex: String,
    pub chain_freshness_root_hex: String,
    pub root_matches: bool,
}

/// Everything [`fetch_witness`] pulls, in circuit-ready form. Internal —
/// the handshake consumes it; the FRB surface returns [`MembershipWitness`].
struct FetchedWitness {
    data: MembershipWitnessDataScale,
    membership_path: Vec<ark_bn254::Fr>,
    freshness_path: Vec<ark_bn254::Fr>,
    local_membership_root: ark_bn254::Fr,
    local_freshness_root: ark_bn254::Fr,
    chain_membership_root: [u8; 32],
    chain_freshness_root: [u8; 32],
    scope: u64,
    current_epoch: u64,
    best_block: u64,
}

/// `state_call` a zkpki runtime-API method and return the SCALE result.
async fn zkpki_state_call(
    rpc: &subxt::rpcs::RpcClient,
    method: &str,
    args: &[u8],
) -> Result<Vec<u8>, String> {
    let out: String = rpc
        .request(
            "state_call",
            subxt::rpcs::rpc_params![method, format!("0x{}", hex::encode(args))],
        )
        .await
        .map_err(|e| format!("{method}: {e}"))?;
    hex::decode(out.trim_start_matches("0x")).map_err(|e| format!("{method} result hex: {e}"))
}

/// Fetch `membership_witness(thumbprint)` plus the chain roots / scope /
/// epoch / best block, convert to field elements, and recompute both local
/// roots from the leaf this cert's enrollment implies.
fn fetch_witness(
    chain_rpc: &str,
    thumbprint: [u8; 32],
    id_commitment: ark_bn254::Fr,
) -> Result<FetchedWitness, String> {
    use parity_scale_codec::{Decode, Encode};
    use rostro_membership_tree::{root_from_path, DEPTH};
    use rostro_poseidon_bn254::{fr_from_canonical_bytes_le, hash_leaf, params};
    use ark_bn254::Fr;

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    let (witness_scale, m_root, f_root, scope_scale, epoch_scale, best_block) =
        rt.block_on(async {
            let rpc = subxt::rpcs::RpcClient::from_insecure_url(chain_rpc)
                .await
                .map_err(|e| format!("connecting to {chain_rpc}: {e}"))?;
            let w = zkpki_state_call(&rpc, "ZkPkiApi_membership_witness", &thumbprint.encode())
                .await?;
            let m = zkpki_state_call(&rpc, "ZkPkiApi_membership_root", &[]).await?;
            let f = zkpki_state_call(&rpc, "ZkPkiApi_freshness_root", &[]).await?;
            let s = zkpki_state_call(&rpc, "ZkPkiApi_membership_scope", &[]).await?;
            let e = zkpki_state_call(&rpc, "ZkPkiApi_membership_epoch", &[]).await?;
            let header: serde_json::Value = rpc
                .request("chain_getHeader", subxt::rpcs::rpc_params![])
                .await
                .map_err(|e| e.to_string())?;
            let num = header
                .get("number")
                .and_then(|v| v.as_str())
                .ok_or("header.number missing")?
                .to_string();
            let best = u64::from_str_radix(num.trim_start_matches("0x"), 16)
                .map_err(|e| format!("parse block number: {e}"))?;
            Ok::<_, String>((w, m, f, s, e, best))
        })?;

    let data = Option::<MembershipWitnessDataScale>::decode(&mut &witness_scale[..])
        .map_err(|e| format!("membership_witness decode: {e}"))?
        .ok_or("no membership witness: cert absent or minted without chat enrollment")?;
    let chain_membership_root: [u8; 32] = <[u8; 32]>::decode(&mut &m_root[..])
        .map_err(|e| format!("membership_root decode: {e}"))?;
    let chain_freshness_root: [u8; 32] = <[u8; 32]>::decode(&mut &f_root[..])
        .map_err(|e| format!("freshness_root decode: {e}"))?;
    let scope = u64::decode(&mut &scope_scale[..])
        .map_err(|e| format!("membership_scope decode: {e}"))?;
    let current_epoch = u32::decode(&mut &epoch_scale[..])
        .map_err(|e| format!("membership_epoch decode: {e}"))? as u64;

    let to_frs = |path: &[[u8; 32]], label: &str| -> Result<Vec<Fr>, String> {
        if path.len() != DEPTH {
            return Err(format!("{label} path has {} nodes, expected {DEPTH}", path.len()));
        }
        path.iter()
            .map(|b| {
                fr_from_canonical_bytes_le(b)
                    .ok_or_else(|| format!("{label} path node is not a canonical field element"))
            })
            .collect()
    };
    let membership_path = to_frs(&data.membership_path, "membership")?;
    let freshness_path = to_frs(&data.freshness_path, "freshness")?;

    let p = params();
    let leaf = hash_leaf(
        &p,
        id_commitment,
        Fr::from(data.expiry_block),
        Fr::from(scope),
    );
    let m_arr: [Fr; DEPTH] = membership_path.clone().try_into().expect("length checked");
    let f_arr: [Fr; DEPTH] = freshness_path.clone().try_into().expect("length checked");
    let local_membership_root = root_from_path(&p, leaf, data.leaf_position, &m_arr);
    let local_freshness_root = root_from_path(
        &p,
        Fr::from(data.fresh_until_epoch),
        data.leaf_position,
        &f_arr,
    );

    Ok(FetchedWitness {
        data,
        membership_path,
        freshness_path,
        local_membership_root,
        local_freshness_root,
        chain_membership_root,
        chain_freshness_root,
        scope,
        current_epoch,
        best_block,
    })
}

/// M3 FRB surface (also the labtool `witness-check` gate): fetch the real
/// Merkle witness for `thumbprint` and reconstruct the chain roots locally.
/// `shared_secret_hex` is the in-chip ECDH output (the same bytes the mint
/// enrollment used) — needed to re-derive the leaf's `id_commitment`.
pub fn membership_fetch_witness(
    chain_rpc: String,
    thumbprint_hex: String,
    shared_secret_hex: String,
) -> Result<MembershipWitness, String> {
    use rostro_poseidon_bn254::{fr_to_bytes_le, hash_to_field_bn254, id_commitment, params};

    let thumbprint = decode_hex_32(&thumbprint_hex, "thumbprint")?;
    let mut shared = decode_hex_32(&shared_secret_hex, "shared_secret")?;
    let s = hash_to_field_bn254(&shared);
    shared.zeroize();
    let idc = id_commitment(&params(), s);

    let w = fetch_witness(&chain_rpc, thumbprint, idc)?;
    Ok(MembershipWitness {
        leaf_position: w.data.leaf_position,
        expiry_block: w.data.expiry_block,
        fresh_until_epoch: w.data.fresh_until_epoch,
        scope: w.scope,
        current_epoch: w.current_epoch,
        best_block: w.best_block,
        local_membership_root_hex: hex::encode(fr_to_bytes_le(&w.local_membership_root)),
        chain_membership_root_hex: hex::encode(w.chain_membership_root),
        local_freshness_root_hex: hex::encode(fr_to_bytes_le(&w.local_freshness_root)),
        chain_freshness_root_hex: hex::encode(w.chain_freshness_root),
        root_matches: fr_to_bytes_le(&w.local_membership_root) == w.chain_membership_root
            && fr_to_bytes_le(&w.local_freshness_root) == w.chain_freshness_root,
    })
}

/// LAB (M2 gate): like [`membership_fetch_witness`] but keyed by the
/// id_commitment the phone printed at mint (the desktop never sees the
/// in-chip shared secret). Confirms the chain's witness for `thumbprint`
/// reconstructs the live `membership_root()` / `freshness_root()`.
#[frb(ignore)]
pub fn lab_witness_check(
    chain_rpc: String,
    thumbprint_hex: String,
    id_commitment_hex: String,
) -> Result<String, String> {
    use rostro_poseidon_bn254::{fr_from_canonical_bytes_le, fr_to_bytes_le};

    let thumbprint = decode_hex_32(&thumbprint_hex, "thumbprint")?;
    let idc = fr_from_canonical_bytes_le(&decode_hex_32(&id_commitment_hex, "id_commitment")?)
        .ok_or("id_commitment is not a canonical field element")?;
    let w = fetch_witness(&chain_rpc, thumbprint, idc)?;
    let m_ok = fr_to_bytes_le(&w.local_membership_root) == w.chain_membership_root;
    let f_ok = fr_to_bytes_le(&w.local_freshness_root) == w.chain_freshness_root;
    Ok(format!(
        "leaf_position={} expiry_block={} fresh_until_epoch={} scope={} epoch={}\n\
         membership root: local=0x{} chain=0x{} {}\n\
         freshness  root: local=0x{} chain=0x{} {}",
        w.data.leaf_position,
        w.data.expiry_block,
        w.data.fresh_until_epoch,
        w.scope,
        w.current_epoch,
        hex::encode(fr_to_bytes_le(&w.local_membership_root)),
        hex::encode(w.chain_membership_root),
        if m_ok { "MATCH" } else { "MISMATCH" },
        hex::encode(fr_to_bytes_le(&w.local_freshness_root)),
        hex::encode(w.chain_freshness_root),
        if f_ok { "MATCH" } else { "MISMATCH" },
    ))
}

/// Find the caller's chat-ENROLLED cert: iterate `CertsByUser(account)`
/// (Blake2_128Concat keys, so each raw key's last 32 bytes ARE the
/// thumbprint) and return the first whose `membership_witness` exists.
/// `None` = the account holds no enrolled cert, so membership auth is
/// unavailable and callers should not burn a biometric trying.
///
/// This lookup exists because an account can hold certs WITHOUT a chat
/// enrollment (the app's dev admission cert, certs minted before the
/// feature): the send path's cert is not necessarily the enrolled one.
pub fn membership_enrolled_thumbprint(
    chain_rpc: String,
    account_ss58: String,
) -> Result<Option<String>, String> {
    use sp_core::hashing::{blake2_128, twox_128};
    use std::str::FromStr;

    let account = subxt::utils::AccountId32::from_str(&account_ss58)
        .map_err(|e| format!("account_ss58: {e}"))?;
    let mut prefix = Vec::with_capacity(16 + 16 + 16 + 32);
    prefix.extend_from_slice(&twox_128(b"ZkPki"));
    prefix.extend_from_slice(&twox_128(b"CertsByUser"));
    prefix.extend_from_slice(&blake2_128(&account.0));
    prefix.extend_from_slice(&account.0);

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    rt.block_on(async {
        let rpc = subxt::rpcs::RpcClient::from_insecure_url(&chain_rpc)
            .await
            .map_err(|e| format!("connecting to {chain_rpc}: {e}"))?;
        let keys: Vec<String> = rpc
            .request(
                "state_getKeysPaged",
                subxt::rpcs::rpc_params![format!("0x{}", hex::encode(&prefix)), 16u32],
            )
            .await
            .map_err(|e| format!("state_getKeysPaged: {e}"))?;
        for key in keys {
            let raw = hex::decode(key.trim_start_matches("0x"))
                .map_err(|e| format!("storage key hex: {e}"))?;
            if raw.len() < 32 {
                continue;
            }
            let thumbprint: [u8; 32] = raw[raw.len() - 32..].try_into().expect("32-byte tail");
            use parity_scale_codec::Encode;
            let w =
                zkpki_state_call(&rpc, "ZkPkiApi_membership_witness", &thumbprint.encode())
                    .await?;
            // SCALE Option tag: 0x01 = Some -> this cert has a membership leaf.
            if w.first() == Some(&1) {
                return Ok(Some(hex::encode(thumbprint)));
            }
        }
        Ok(None)
    })
}

/// The anonymous membership session (M4): what the phone holds after a
/// successful `chat_authenticateMembership`. `session_seed_hex` is the
/// software Ed25519 seed that signs each drop (`chat_session_sign_drop`);
/// `session_pubkey_hex` doubles as the send path's session lookup key.
pub struct MembershipSessionOutcome {
    pub session_pubkey_hex: String,
    pub session_seed_hex: String,
    pub expires_epoch: u64,
    pub current_epoch: u64,
    pub nullifier_hex: String,
    pub guard_node_id_hex: String,
    /// The witnessed spend record, SCALE-encoded (hex): the PORTABLE
    /// admission ticket (CHAT-SESSION-TICKET.md). Persist it with the
    /// session; present it at another guard via `membership_present_ticket`
    /// to enter there without a fresh handshake (or spend).
    pub ticket_hex: String,
}

/// M4: the real membership handshake. Re-derives `s` from the in-chip ECDH
/// output, fetches the REAL chain witness for the cert's leaf, proves
/// membership on-device (Groth16), and POSTs `chat_authenticateMembership`
/// to the guard. On success the guard's witnessed-spend committee has
/// co-signed the nullifier spend and the returned session key is authorized
/// for drops until `expires_epoch`.
///
/// Fails fast (before proving, which costs ~1s) if the locally recomputed
/// roots don't match the chain's — a mismatch means the leaf/witness are
/// inconsistent and the guard would reject the proof anyway.
pub fn membership_authenticate(
    chain_rpc: String,
    guard_rpc: String,
    thumbprint_hex: String,
    shared_secret_hex: String,
    pk_bytes: Vec<u8>,
) -> Result<MembershipSessionOutcome, String> {
    use ark_std::rand::{rngs::StdRng, SeedableRng};
    use rostro_chat_membership_auth::{derive_challenge, derive_session_commit};
    use rostro_membership_circuit::{groth16, MembershipCircuit};
    use rostro_membership_tree::DEPTH;
    use rostro_poseidon_bn254::{
        fr_to_bytes_le, hash_to_field_bn254, id_commitment, nullifier, params,
    };
    use ark_bn254::Fr;

    let thumbprint = decode_hex_32(&thumbprint_hex, "thumbprint")?;
    let mut shared = decode_hex_32(&shared_secret_hex, "shared_secret")?;
    let s = hash_to_field_bn254(&shared);
    shared.zeroize();
    let idc = id_commitment(&params(), s);

    let w = fetch_witness(&chain_rpc, thumbprint, idc)?;
    if fr_to_bytes_le(&w.local_membership_root) != w.chain_membership_root {
        return Err("local membership root != chain root (stale witness or wrong secret)".into());
    }
    if fr_to_bytes_le(&w.local_freshness_root) != w.chain_freshness_root {
        return Err("local freshness root != chain root (stale witness)".into());
    }

    // Guard identity + fresh software session keypair.
    let guard_node_id_hex = crate::chat::chat_node_info(guard_rpc.clone())?;
    let guard_node_id = decode_hex_32(&guard_node_id_hex, "guard_node_id")?;
    let session = crate::chat_session::chat_session_gen_keypair();
    let session_pubkey = decode_hex_32(&session.pubkey_hex, "session_pubkey")?;

    // Circuit witness: the REAL chain path, freshness, epoch, and anchor.
    let anchor_block = w.best_block;
    let current_epoch = w.current_epoch;
    let null = nullifier(&params(), s, Fr::from(current_epoch));
    let challenge = derive_challenge(&guard_node_id, anchor_block, &session_pubkey);
    let session_commit = derive_session_commit(&session_pubkey);
    let index_bits: Vec<bool> =
        (0..DEPTH).map(|i| (w.data.leaf_position >> i) & 1 == 1).collect();
    let circuit = MembershipCircuit {
        membership_root: Some(w.local_membership_root),
        freshness_root: Some(w.local_freshness_root),
        nullifier: Some(null),
        current_epoch: Some(Fr::from(current_epoch)),
        anchor_block: Some(Fr::from(anchor_block)),
        scope: Some(Fr::from(w.scope)),
        challenge: Some(challenge),
        session_pubkey: Some(session_commit),
        s: Some(s),
        expiry_block: Some(Fr::from(w.data.expiry_block)),
        fresh_until_epoch: Some(Fr::from(w.data.fresh_until_epoch)),
        index_bits: Some(index_bits),
        membership_path: Some(w.membership_path),
        freshness_path: Some(w.freshness_path),
    };

    let pk = groth16::deserialize_pk(&pk_bytes).ok_or("proving key failed to decode")?;
    let mut seed = [0u8; 32];
    getrandom::fill(&mut seed).map_err(|e| format!("getrandom: {e}"))?;
    let mut rng = StdRng::from_seed(seed);
    let proof = groth16::prove(&pk, circuit, &mut rng).ok_or("proof synthesis failed")?;
    let proof_bytes = groth16::serialize_proof(&proof);

    // POST to the guard: verification + witnessed-spend committee + session.
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    let result: serde_json::Value = rt.block_on(async {
        let guard = subxt::rpcs::RpcClient::from_insecure_url(&guard_rpc)
            .await
            .map_err(|e| format!("connecting to {guard_rpc}: {e}"))?;
        guard
            .request(
                "chat_authenticateMembership",
                subxt::rpcs::rpc_params![
                    format!("0x{}", hex::encode(&proof_bytes)),
                    format!("0x{}", hex::encode(fr_to_bytes_le(&w.local_membership_root))),
                    format!("0x{}", hex::encode(fr_to_bytes_le(&w.local_freshness_root))),
                    format!("0x{}", hex::encode(fr_to_bytes_le(&null))),
                    current_epoch,
                    anchor_block,
                    format!("0x{}", hex::encode(session_pubkey))
                ],
            )
            .await
            .map_err(|e| format!("chat_authenticateMembership: {e}"))
    })?;

    let expires_epoch = result
        .get("expires_epoch")
        .and_then(|v| v.as_u64())
        .ok_or_else(|| format!("guard response missing expires_epoch: {result}"))?;
    let ticket_hex = result
        .get("ticket_hex")
        .and_then(|v| v.as_str())
        .ok_or_else(|| format!("guard response missing ticket_hex: {result}"))?
        .to_string();
    Ok(MembershipSessionOutcome {
        session_pubkey_hex: session.pubkey_hex,
        session_seed_hex: session.seed_hex,
        expires_epoch,
        current_epoch,
        nullifier_hex: hex::encode(fr_to_bytes_le(&null)),
        guard_node_id_hex,
        ticket_hex,
    })
}

/// The chain's current membership epoch (the 24h nullifier rate-limit
/// clock). Cheap state_call, no biometric — the client uses it to decide
/// whether a persisted session is still valid before reusing its ticket.
pub fn membership_current_epoch(chain_rpc: String) -> Result<u64, String> {
    use parity_scale_codec::Decode;
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    rt.block_on(async {
        let rpc = subxt::rpcs::RpcClient::from_insecure_url(&chain_rpc)
            .await
            .map_err(|e| format!("connecting to {chain_rpc}: {e}"))?;
        let out = zkpki_state_call(&rpc, "ZkPkiApi_membership_epoch", &[]).await?;
        let epoch = u32::decode(&mut &out[..])
            .map_err(|e| format!("membership_epoch decode: {e}"))?;
        Ok(epoch as u64)
    })
}

/// Present a portable session ticket to `guard_rpc` — install the session
/// at a guard that never ran the handshake (CHAT-SESSION-TICKET.md 2.2).
/// `ticket_hex` is the record from a prior `membership_authenticate`.
/// Returns the epoch the session is valid through.
pub fn membership_present_ticket(
    guard_rpc: String,
    ticket_hex: String,
) -> Result<u64, String> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    rt.block_on(async {
        let guard = subxt::rpcs::RpcClient::from_insecure_url(&guard_rpc)
            .await
            .map_err(|e| format!("connecting to {guard_rpc}: {e}"))?;
        let epoch: u64 = guard
            .request(
                "chat_presentSessionTicket",
                subxt::rpcs::rpc_params![ticket_hex],
            )
            .await
            .map_err(|e| format!("chat_presentSessionTicket: {e}"))?;
        Ok(epoch)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// KAT pin on `P_FIXED`. If this fails, the hash-to-curve inputs (or
    /// the p256 crate's suite implementation) changed — either way every
    /// previously enrolled `s` is orphaned, so treat as a breaking change.
    #[test]
    fn p_fixed_is_pinned() {
        assert_eq!(
            hex::encode(membership_p_fixed_sec1()),
            "0411bc0efaf4667904be31cfdae429c157bbd07a9a6fd8cfde7f9c2bb3d19209\
             7fb9d010a8052bff4218669ecfd81b542faf5edc03e44adf7a9c42f135b4b47fa4",
        );
    }

    /// End-to-end M1 shape check with a software stand-in for the chip:
    /// ECDH(W, P_FIXED) -> s -> id_commitment -> binding msg -> attest_ec
    /// signature verifies through the same checks the chain runs.
    #[test]
    fn binding_roundtrip_with_software_keys() {
        use p256::ecdsa::signature::Signer;
        use p256::elliptic_curve::ecdh::diffie_hellman;
        use p256::elliptic_curve::sec1::ToEncodedPoint;

        // Software "W" (the chip key stand-in).
        let w = p256::SecretKey::random(&mut rand_core_06::OsRng);
        let p_fixed = p256::PublicKey::from_sec1_bytes(&membership_p_fixed_sec1()).unwrap();
        let shared = diffie_hellman(w.to_nonzero_scalar(), p_fixed.as_affine());
        let shared_hex = hex::encode(shared.raw_secret_bytes());

        let idc_hex = membership_id_commitment(shared_hex.clone()).unwrap();
        // Deterministic: same shared secret, same commitment.
        assert_eq!(idc_hex, membership_id_commitment(shared_hex).unwrap());

        // Software "attest_ec" signs the binding message.
        let challenge_hex = hex::encode([7u8; 32]);
        let msg = decode_hex_32(
            &membership_id_binding_msg(idc_hex.clone(), challenge_hex.clone()).unwrap(),
            "msg",
        )
        .unwrap();
        let attest = p256::ecdsa::SigningKey::random(&mut rand_core_06::OsRng);
        let sig: p256::ecdsa::DerSignature = attest.sign(&msg);
        let attest_sec1_hex = hex::encode(
            attest.verifying_key().to_encoded_point(false).as_bytes(),
        );

        assert!(verify_id_binding(
            attest_sec1_hex.clone(),
            idc_hex.clone(),
            challenge_hex.clone(),
            hex::encode(sig.as_bytes()),
        )
        .unwrap());
        // Wrong challenge must fail.
        assert!(!verify_id_binding(
            attest_sec1_hex,
            idc_hex,
            hex::encode([8u8; 32]),
            hex::encode(sig.as_bytes()),
        )
        .unwrap());
    }
}
