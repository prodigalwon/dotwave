//! On-device Groth16 prover for the dotwave chat anonymous-membership proof.
//!
//! This is the "real hardware" artifact: built for aarch64-linux-android via
//! `cargo ndk`, pushed to the phone, and run in `adb shell`. It reuses the
//! exact `rostro-membership-circuit` constraint system the node verifies
//! against (one source of truth, no Circom re-implementation), so a proof it
//! emits here verifies under the node's pinned vk.
//!
//! Two modes:
//!
//!   membership_prover self-test [--pk <pk.bin>] [--vk <vk.bin>]
//!       Builds a self-consistent witness against an in-memory tree (no chain,
//!       no mint), proves, and — if a vk is given — verifies locally. Answers
//!       "can this device generate the proof, and how fast?" in isolation.
//!
//!   membership_prover prove --pk <pk.bin> --witness <witness.json> \
//!       --out <proof.bin>
//!       Builds the witness from chain-fed values (see WitnessFile below),
//!       proves, writes the compressed proof, and prints the nullifier hex the
//!       submit step must echo to the node.
//!
//! STAGE 1: `s` is supplied in the clear (software-derived). STAGE 2 moves `s`
//! derivation into the StrongBox (in-chip ECDH); the proving math below does
//! not change.

use std::time::Instant;

use ark_bn254::Fr;
use ark_std::rand::{rngs::StdRng, SeedableRng};

use rostro_chat_membership_auth::{derive_challenge, derive_session_commit};
use rostro_membership_circuit::{groth16, MembershipCircuit};
use rostro_membership_tree::{MembershipTree, DEPTH};
use rostro_poseidon_bn254::{
    fr_from_canonical_bytes_le, fr_to_bytes_le, hash_leaf, id_commitment, nullifier, params,
};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("");
    let result = match mode {
        "self-test" => run_self_test(&args[2..]),
        "prove" => run_prove(&args[2..]),
        other => Err(format!(
            "unknown mode {other:?}; expected `self-test` or `prove`"
        )),
    };
    if let Err(e) = result {
        eprintln!("membership_prover: {e}");
        std::process::exit(1);
    }
}

/// `--flag value` lookup over a slice of args.
fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

/// Leaf index → `DEPTH` little-endian bits (LSB first), the circuit's
/// `index_bits` contract.
fn index_bits(index: u64) -> Vec<bool> {
    (0..DEPTH).map(|i| (index >> i) & 1 == 1).collect()
}

fn fr_from_hex(label: &str, s: &str) -> Result<Fr, String> {
    let bytes = hex::decode(s.trim_start_matches("0x"))
        .map_err(|e| format!("{label}: bad hex: {e}"))?;
    let arr: [u8; 32] = bytes
        .try_into()
        .map_err(|_| format!("{label}: must be 32 bytes"))?;
    fr_from_canonical_bytes_le(&arr).ok_or_else(|| format!("{label}: not a canonical field element"))
}

/// Prove + report. `pk_bytes` is the proving key; `vk_bytes` optionally drives
/// a local self-verify before we trust the device.
fn prove_and_report(
    circuit: MembershipCircuit,
    pk_bytes: Option<Vec<u8>>,
    vk_bytes: Option<Vec<u8>>,
    out_path: Option<&str>,
) -> Result<(), String> {
    // Either load the pinned pk or run a local setup (self-test convenience).
    let pk = match pk_bytes {
        Some(b) => groth16::deserialize_pk(&b).ok_or("pk failed to decode")?,
        None => {
            eprintln!("no --pk given: running a local setup (TEST-ONLY, slow)…");
            let mut rng = StdRng::seed_from_u64(1);
            groth16::setup(&mut rng).0
        }
    };

    let public = groth16::public_inputs(&circuit).ok_or("circuit missing a public input")?;

    let mut rng = StdRng::seed_from_u64(7);
    let t = Instant::now();
    let proof = groth16::prove(&pk, circuit, &mut rng).ok_or("proof synthesis failed")?;
    let prove_ms = t.elapsed().as_millis();

    let proof_bytes = groth16::serialize_proof(&proof);

    println!("prove_ms={prove_ms}");
    println!("proof_bytes={}", proof_bytes.len());
    println!("nullifier_hex=0x{}", hex::encode(fr_to_bytes_le(&public[2])));

    if let Some(vk_b) = vk_bytes {
        let vk = groth16::deserialize_vk(&vk_b).ok_or("vk failed to decode")?;
        let ok = groth16::verify(&vk, &public, &proof);
        println!("local_verify={ok}");
        if !ok {
            return Err("local verification FAILED (proof would be rejected)".into());
        }
    }

    if let Some(path) = out_path {
        std::fs::write(path, &proof_bytes).map_err(|e| format!("write {path}: {e}"))?;
        println!("proof written to {path}");
    }
    Ok(())
}

/// Build a fully self-consistent witness against fresh in-memory trees, with no
/// chain and no mint. The leaf goes in at index 0; the two paths recompute the
/// two roots, so the proof must satisfy every constraint.
fn run_self_test(args: &[String]) -> Result<(), String> {
    let p = params();

    // A fixed software secret; the membership leaf binds its commitment.
    let s = Fr::from(0x5ec_u64) + Fr::from(1u64); // any nonzero field element
    let expiry_block: u64 = 5_000;
    let scope: u64 = 1;
    let current_epoch: u64 = 15;
    let anchor_block: u64 = 4_000;
    let fresh_until_epoch: u64 = 20;

    let idc = id_commitment(&p, s);
    let leaf = hash_leaf(&p, idc, Fr::from(expiry_block), Fr::from(scope));

    let mut mtree = MembershipTree::new(128);
    let index = mtree.insert(leaf).ok_or("membership tree full")?;
    let mut ftree = MembershipTree::new(128);
    let f_index = ftree
        .insert(Fr::from(fresh_until_epoch))
        .ok_or("freshness tree full")?;
    assert_eq!(index, f_index, "leaves must share an index");

    let membership_path = mtree.path(index).to_vec();
    let freshness_path = ftree.path(index).to_vec();

    let guard_node_id = [0u8; 32];
    let session_pubkey = [1u8; 32];
    let null = nullifier(&p, s, Fr::from(current_epoch));
    let challenge = derive_challenge(&guard_node_id, anchor_block, &session_pubkey);
    let session_commit = derive_session_commit(&session_pubkey);

    let circuit = MembershipCircuit {
        membership_root: Some(mtree.root()),
        freshness_root: Some(ftree.root()),
        nullifier: Some(null),
        current_epoch: Some(Fr::from(current_epoch)),
        anchor_block: Some(Fr::from(anchor_block)),
        scope: Some(Fr::from(scope)),
        challenge: Some(challenge),
        session_pubkey: Some(session_commit),
        s: Some(s),
        expiry_block: Some(Fr::from(expiry_block)),
        fresh_until_epoch: Some(Fr::from(fresh_until_epoch)),
        index_bits: Some(index_bits(index)),
        membership_path: Some(membership_path),
        freshness_path: Some(freshness_path),
    };

    let pk_bytes = flag(args, "--pk")
        .map(|p| std::fs::read(&p).map_err(|e| format!("read pk {p}: {e}")))
        .transpose()?;
    let vk_bytes = flag(args, "--vk")
        .map(|p| std::fs::read(&p).map_err(|e| format!("read vk {p}: {e}")))
        .transpose()?;

    eprintln!("self-test witness: leaf at index {index}, membership_root + freshness_root computed");
    prove_and_report(circuit, pk_bytes, vk_bytes, flag(args, "--out").as_deref())
}

/// JSON witness produced by labtool from chain state (`membership_witness` RPC)
/// plus the locally held secret `s` and the guard/session binding inputs.
///
/// ```json
/// {
///   "s_hex": "...",                 // 32-byte LE field secret
///   "membership_root_hex": "...",   // current/recent R_m (LE)
///   "freshness_root_hex": "...",    // current/recent R_f (LE)
///   "current_epoch": 15,
///   "anchor_block": 4000,
///   "scope": 1,
///   "expiry_block": 5000,
///   "fresh_until_epoch": 20,
///   "leaf_position": 0,
///   "membership_path_hex": ["...", ...32],
///   "freshness_path_hex": ["...", ...32],
///   "guard_node_id_hex": "...",     // the relay's 32-byte ed25519 node key
///   "session_pubkey_hex": "..."     // raw per-session public key
/// }
/// ```
fn run_prove(args: &[String]) -> Result<(), String> {
    let p = params();

    let witness_path = flag(args, "--witness").ok_or("prove mode needs --witness <json>")?;
    let pk_path = flag(args, "--pk").ok_or("prove mode needs --pk <pk.bin>")?;
    let raw = std::fs::read_to_string(&witness_path)
        .map_err(|e| format!("read witness {witness_path}: {e}"))?;
    let w: serde_json::Value =
        serde_json::from_str(&raw).map_err(|e| format!("parse witness json: {e}"))?;

    let str_field = |k: &str| -> Result<String, String> {
        w.get(k)
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or_else(|| format!("witness missing string field `{k}`"))
    };
    let u64_field = |k: &str| -> Result<u64, String> {
        w.get(k)
            .and_then(|v| v.as_u64())
            .ok_or_else(|| format!("witness missing u64 field `{k}`"))
    };
    let path_field = |k: &str| -> Result<Vec<Fr>, String> {
        let arr = w
            .get(k)
            .and_then(|v| v.as_array())
            .ok_or_else(|| format!("witness missing array field `{k}`"))?;
        if arr.len() != DEPTH {
            return Err(format!("`{k}` must have {DEPTH} entries, got {}", arr.len()));
        }
        arr.iter()
            .enumerate()
            .map(|(i, v)| {
                let s = v.as_str().ok_or_else(|| format!("`{k}`[{i}] not a string"))?;
                fr_from_hex(&format!("{k}[{i}]"), s)
            })
            .collect()
    };

    let s = fr_from_hex("s_hex", &str_field("s_hex")?)?;
    let membership_root = fr_from_hex("membership_root_hex", &str_field("membership_root_hex")?)?;
    let freshness_root = fr_from_hex("freshness_root_hex", &str_field("freshness_root_hex")?)?;
    let current_epoch = u64_field("current_epoch")?;
    let anchor_block = u64_field("anchor_block")?;
    let scope = u64_field("scope")?;
    let expiry_block = u64_field("expiry_block")?;
    let fresh_until_epoch = u64_field("fresh_until_epoch")?;
    let leaf_position = u64_field("leaf_position")?;
    let membership_path = path_field("membership_path_hex")?;
    let freshness_path = path_field("freshness_path_hex")?;
    let guard_node_id = hex::decode(str_field("guard_node_id_hex")?.trim_start_matches("0x"))
        .map_err(|e| format!("guard_node_id_hex: {e}"))?;
    let session_pubkey = hex::decode(str_field("session_pubkey_hex")?.trim_start_matches("0x"))
        .map_err(|e| format!("session_pubkey_hex: {e}"))?;

    let null = nullifier(&p, s, Fr::from(current_epoch));
    let challenge = derive_challenge(&guard_node_id, anchor_block, &session_pubkey);
    let session_commit = derive_session_commit(&session_pubkey);

    let circuit = MembershipCircuit {
        membership_root: Some(membership_root),
        freshness_root: Some(freshness_root),
        nullifier: Some(null),
        current_epoch: Some(Fr::from(current_epoch)),
        anchor_block: Some(Fr::from(anchor_block)),
        scope: Some(Fr::from(scope)),
        challenge: Some(challenge),
        session_pubkey: Some(session_commit),
        s: Some(s),
        expiry_block: Some(Fr::from(expiry_block)),
        fresh_until_epoch: Some(Fr::from(fresh_until_epoch)),
        index_bits: Some(index_bits(leaf_position)),
        membership_path: Some(membership_path),
        freshness_path: Some(freshness_path),
    };

    let pk_bytes = std::fs::read(&pk_path).map_err(|e| format!("read pk {pk_path}: {e}"))?;
    let vk_bytes = flag(args, "--vk")
        .map(|p| std::fs::read(&p).map_err(|e| format!("read vk {p}: {e}")))
        .transpose()?;

    prove_and_report(circuit, Some(pk_bytes), vk_bytes, flag(args, "--out").as_deref())
}
