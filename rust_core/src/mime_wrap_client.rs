//! Stage 4c client-side plumbing for the mime-wrap end-to-end flow.
//!
//! This module does three jobs:
//!
//!   1. **Deterministic trusted setup (PoC only).** `prepare_mime_wrap_setup`
//!      runs ark-groth16's `circuit_specific_setup` with a fixed-seeded RNG
//!      to produce a reproducible (pk, vk) pair for the mime_wrap circuit.
//!      Not production-safe — a real deployment needs a multi-party ceremony
//!      so no single actor knows the toxic waste. For the Stage 4c demo we
//!      just need client and chain to agree on a vk, and a hardcoded seed
//!      gets us there.
//!
//!   2. **Commitment computation.** `compute_commitment` computes
//!      `SHA256(ec_key_pub || seed)` — the value the pallet expects to see
//!      registered at ceremony time.
//!
//!   3. **Real-ceremony proof generation.** `generate_mime_wrap_signing_proof`
//!      takes real ec_key_pub + seed + bucket + user_otp and produces the
//!      128-byte Groth16 proof bytes that `verify_and_record` will accept.
//!      Uses the cached pk from step 1 — so the setup must have been run
//!      at least once on this device before signing.
//!
//! All public entry points assume the mime_wrap circuit artifacts are
//! available as files on-device (copied from Android assets by the Kotlin
//! side, same pattern as Stage 2's `mime_wrap_prover`).

use std::fs::File;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use ark_bn254::{Bn254, Fr};
use ark_circom::{CircomBuilder, CircomConfig};
use ark_groth16::{Groth16, ProvingKey};
use ark_serialize::CanonicalSerialize;
use ark_snark::SNARK;
use ark_std::rand::SeedableRng;
use sha2::{Digest, Sha256};

// ── Deterministic setup ─────────────────────────────────────────────

/// Hardcoded RNG seed for the PoC trusted setup. Anything 32 bytes will
/// do — the property we want is that every device + the paseo-node VK
/// installer derive the same (pk, vk) pair. Not cryptographically safe
/// for production.
const POC_SETUP_SEED: [u8; 32] = *b"zkpki-mime-wrap-poc-setup-seed_0";

/// Process-wide cache of (pk, vk) produced by the one-time setup.
/// Populated on first call to `prepare_mime_wrap_setup`; subsequent
/// calls return the cached value without re-running setup.
static SETUP_CACHE: OnceLock<Mutex<Option<CachedSetup>>> = OnceLock::new();

struct CachedSetup {
    pk: Arc<ProvingKey<Bn254>>,
    vk_bytes: Vec<u8>,
}

/// Shape surfaced to Dart from the one-time setup call. `vk_bytes_hex`
/// is the compressed Groth16 VK that Tony installs on paseo-node via
/// sudo `set_verifying_key` (one-time, per chain).
pub struct MimeWrapSetupResult {
    pub success: bool,
    pub error_message: Option<String>,
    pub vk_bytes_hex: String,
    /// If true, this call actually ran circuit_specific_setup (~30-60s
    /// on S20). If false, the cache was already populated — call
    /// returns in ms.
    pub fresh_setup: bool,
    pub setup_ms: u32,
}

/// Run the one-time trusted setup for the mime_wrap circuit and
/// return the compressed verifying key hex. Idempotent — subsequent
/// calls return the cached vk without re-running setup.
pub fn prepare_mime_wrap_setup(
    wasm_path: String,
    r1cs_path: String,
) -> MimeWrapSetupResult {
    let cache = SETUP_CACHE.get_or_init(|| Mutex::new(None));
    // Fast path: cache hit.
    {
        let guard = cache.lock().unwrap();
        if let Some(s) = guard.as_ref() {
            return MimeWrapSetupResult {
                success: true,
                error_message: None,
                vk_bytes_hex: hex_encode(&s.vk_bytes),
                fresh_setup: false,
                setup_ms: 0,
            };
        }
    }

    // ark-circom's wasmer internals require an active Tokio runtime
    // (same constraint the Stage 2 benchmark hit).
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            return MimeWrapSetupResult {
                success: false,
                error_message: Some(format!("Tokio runtime build failed: {e:?}")),
                vk_bytes_hex: String::new(),
                fresh_setup: false,
                setup_ms: 0,
            };
        }
    };
    let _guard = rt.enter();

    let t0 = Instant::now();
    let cached = match build_setup(&wasm_path, &r1cs_path) {
        Ok(c) => c,
        Err(e) => {
            return MimeWrapSetupResult {
                success: false,
                error_message: Some(format!("{e:?}")),
                vk_bytes_hex: String::new(),
                fresh_setup: false,
                setup_ms: 0,
            };
        }
    };
    let setup_ms = t0.elapsed().as_millis() as u32;
    let vk_hex = hex_encode(&cached.vk_bytes);

    {
        let mut guard = cache.lock().unwrap();
        *guard = Some(cached);
    }

    MimeWrapSetupResult {
        success: true,
        error_message: None,
        vk_bytes_hex: vk_hex,
        fresh_setup: true,
        setup_ms,
    }
}

fn build_setup(wasm_path: &str, r1cs_path: &str) -> anyhow::Result<CachedSetup> {
    // We need a CircomCircuit instance to feed to circuit_specific_setup.
    // ark-circom requires a populated witness to build the circuit, so
    // we push a dummy all-zeros input set — the witness values don't
    // affect the setup output (setup depends only on the constraint
    // structure, which is identical regardless of inputs).
    let cfg = CircomConfig::<Fr>::new(wasm_path, r1cs_path)
        .map_err(|e| anyhow::anyhow!("CircomConfig load failed: {e:?}"))?;
    let mut builder = CircomBuilder::new(cfg);

    // 256 commitmentC bits + 256 ecKeyPub bits + 64 bucket bits + 24 userOtp bits
    for _ in 0..256 {
        builder.push_input("commitmentC", 0u64);
    }
    for _ in 0..256 {
        builder.push_input("ecKeyPub", 0u64);
    }
    for _ in 0..64 {
        builder.push_input("bucket", 0u64);
    }
    for _ in 0..24 {
        builder.push_input("userOtp", 0u64);
    }
    for _ in 0..256 {
        builder.push_input("seed", 0u64);
    }

    let circom = builder
        .build()
        .map_err(|e| anyhow::anyhow!("CircomBuilder build failed: {e:?}"))?;

    // Deterministic RNG so client + chain agree on the (pk, vk) pair.
    let mut rng = ark_std::rand::rngs::StdRng::from_seed(POC_SETUP_SEED);
    let (pk, vk) = Groth16::<Bn254>::circuit_specific_setup(circom, &mut rng)
        .map_err(|e| anyhow::anyhow!("circuit_specific_setup failed: {e:?}"))?;

    let mut vk_bytes = Vec::new();
    vk.serialize_compressed(&mut vk_bytes)?;

    Ok(CachedSetup {
        pk: Arc::new(pk),
        vk_bytes,
    })
}

// ── Commitment ──────────────────────────────────────────────────────

/// Compute the ceremony-time commitment `C = SHA256(ec_key_pub || seed)`.
/// Must match byte-for-byte what the pallet's `verify_and_record` expects
/// to see — same sha2 crate, same concatenation order as the Circom
/// C1 constraint and the pallet's `build_public_inputs`.
pub fn compute_commitment(ec_key_pub: Vec<u8>, seed: Vec<u8>) -> Vec<u8> {
    let mut h = Sha256::new();
    h.update(&ec_key_pub);
    h.update(&seed);
    h.finalize().to_vec()
}

// ── Proof generation ───────────────────────────────────────────────

pub struct MimeWrapProofResult {
    pub success: bool,
    pub error_message: Option<String>,
    pub proof_bytes_hex: String,
    pub total_ms: u32,
}

/// Generate a mime_wrap Groth16 proof for real ceremony state.
///
/// Inputs must match the Circom circuit's expectations bit-for-bit:
///  - `ec_key_pub`, `seed`: 32 bytes each
///  - `bucket`: u64, big-endian inside the circuit
///  - `user_otp`: low-24-bits (24 bits total, big-endian)
///
/// The caller is responsible for matching these against on-chain state
/// (the registered commitment + the bucket/otp being claimed). A proof
/// generated with mismatching inputs will deserialize fine but fail the
/// pairing check at the pallet.
///
/// Requires `prepare_mime_wrap_setup` to have been called at least
/// once (populates the PK cache). Returns an error if the cache is
/// empty.
pub fn generate_mime_wrap_signing_proof(
    wasm_path: String,
    r1cs_path: String,
    ec_key_pub: Vec<u8>,
    seed: Vec<u8>,
    bucket: u64,
    user_otp: u32,
) -> MimeWrapProofResult {
    let t_total = Instant::now();

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            return MimeWrapProofResult {
                success: false,
                error_message: Some(format!("Tokio runtime build failed: {e:?}")),
                proof_bytes_hex: String::new(),
                total_ms: 0,
            };
        }
    };
    let _guard = rt.enter();

    match run_generate(
        wasm_path, r1cs_path, ec_key_pub, seed, bucket, user_otp,
    ) {
        Ok(bytes) => MimeWrapProofResult {
            success: true,
            error_message: None,
            proof_bytes_hex: hex_encode(&bytes),
            total_ms: t_total.elapsed().as_millis() as u32,
        },
        Err(e) => MimeWrapProofResult {
            success: false,
            error_message: Some(format!("{e:?}")),
            proof_bytes_hex: String::new(),
            total_ms: t_total.elapsed().as_millis() as u32,
        },
    }
}

fn run_generate(
    wasm_path: String,
    r1cs_path: String,
    ec_key_pub: Vec<u8>,
    seed: Vec<u8>,
    bucket: u64,
    user_otp: u32,
) -> anyhow::Result<Vec<u8>> {
    if ec_key_pub.len() != 32 {
        anyhow::bail!(
            "ec_key_pub must be 32 bytes (got {}); caller should SHA256 the cert_ec DER pubkey first",
            ec_key_pub.len()
        );
    }
    if seed.len() != 32 {
        anyhow::bail!("seed must be 32 bytes (got {})", seed.len());
    }
    if user_otp & 0xFF00_0000 != 0 {
        anyhow::bail!("user_otp exceeds 24-bit window: {user_otp:#x}");
    }

    // Load cached pk produced at setup time.
    let cache = SETUP_CACHE
        .get()
        .ok_or_else(|| anyhow::anyhow!("prepare_mime_wrap_setup has not been called yet"))?;
    let pk = {
        let guard = cache.lock().unwrap();
        let s = guard
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("setup cache empty — call prepare_mime_wrap_setup first"))?;
        Arc::clone(&s.pk)
    };

    // Compute the fixed circuit inputs the prover has to commit to.
    let commitment = {
        let mut h = Sha256::new();
        h.update(&ec_key_pub);
        h.update(&seed);
        h.finalize().to_vec()
    };
    let bucket_be = bucket.to_be_bytes();

    // Build the CircomCircuit witness. Same push_input order as the
    // Stage 2 benchmark and the Stage 3 lab — declaration order in the
    // circuit is load-bearing.
    let cfg = CircomConfig::<Fr>::new(wasm_path, r1cs_path)
        .map_err(|e| anyhow::anyhow!("CircomConfig load failed: {e:?}"))?;
    let mut builder = CircomBuilder::new(cfg);
    for bit in bits_from_bytes_be(&commitment) {
        builder.push_input("commitmentC", bit as u64);
    }
    for bit in bits_from_bytes_be(&ec_key_pub) {
        builder.push_input("ecKeyPub", bit as u64);
    }
    for bit in bits_from_bytes_be(&bucket_be) {
        builder.push_input("bucket", bit as u64);
    }
    for shift in (0..24).rev() {
        builder.push_input("userOtp", ((user_otp >> shift) & 1) as u64);
    }
    for bit in bits_from_bytes_be(&seed) {
        builder.push_input("seed", bit as u64);
    }

    let circom = builder
        .build()
        .map_err(|e| anyhow::anyhow!("CircomBuilder build failed: {e:?}"))?;

    let mut rng = ark_std::rand::thread_rng();
    let proof = Groth16::<Bn254>::prove(pk.as_ref(), circom, &mut rng)
        .map_err(|e| anyhow::anyhow!("Groth16 prove failed: {e:?}"))?;

    let mut proof_bytes = Vec::new();
    proof.serialize_compressed(&mut proof_bytes)?;
    Ok(proof_bytes)
}

// ── helpers ─────────────────────────────────────────────────────────

fn bits_from_bytes_be(bytes: &[u8]) -> Vec<u8> {
    let mut bits = Vec::with_capacity(bytes.len() * 8);
    for &byte in bytes {
        for i in (0..8).rev() {
            bits.push((byte >> i) & 1);
        }
    }
    bits
}

fn hex_encode(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        use std::fmt::Write;
        let _ = write!(s, "{b:02x}");
    }
    s
}

/// Convenience for the Dart side: SHA256 the raw DER-SPKI cert_ec pubkey
/// (91 bytes from Stage 0 ceremony) to get the 32-byte ec_key_pub
/// representative the circuit expects.
pub fn derive_ec_key_pub_from_der(der: Vec<u8>) -> Vec<u8> {
    let mut h = Sha256::new();
    h.update(&der);
    h.finalize().to_vec()
}
