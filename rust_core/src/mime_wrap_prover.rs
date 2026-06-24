//! Stage 2 PoC: Groth16 proof-generation benchmark for the mime-wrap
//! circuit, on-device.
//!
//! This module exists solely to answer one question: **how long does
//! Groth16 proof generation take on S20 with a circuit this size?** If
//! the answer is <1.5s we're on the right track; if it's >3s the whole
//! Android tier of the zkpki design needs a rethink.
//!
//! Uses `ark-circom` (pure Rust) for witness generation + proof
//! production. This is materially slower than real rapidsnark (C++,
//! typically 2-5x faster), but compiles cleanly under `cargo ndk`
//! and gets us the go/no-go signal in a single afternoon. If the
//! ark-circom number is close to the target we can optimise with
//! the rapidsnark FFI in a follow-up; if it's 10x too slow, the
//! design has a fundamental problem and no amount of FFI tuning
//! will save it.
//!
//! NOT production code. Fixture inputs are random every call; the
//! Rust side recomputes `commitment_C` and `user_otp` to match what
//! the Circom circuit will verify. No real ceremony state is touched.

use std::fs::File;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use ark_bn254::{Bn254, Fr};
use ark_circom::{CircomBuilder, CircomConfig, read_zkey};
use ark_groth16::{Groth16, ProvingKey};
use ark_serialize::CanonicalSerialize;
use ark_snark::SNARK;
use ark_std::rand::thread_rng;
use sha2::{Digest, Sha256};

/// Process-wide cache of parsed proving keys keyed by absolute file
/// path. The zkey parse is ~10s on S20 for a 49MB Groth16 key —
/// far and away the dominant cost of the benchmark. In production
/// the key is loaded once at app startup and reused for every sign;
/// this cache mirrors that property so the "warm" benchmark reflects
/// real per-sign latency, not first-boot latency.
///
/// Not sized-bounded on purpose (one entry per unique path, and we
/// only ever have one circuit in this PoC). For production, swap for
/// an LRU or explicit preload-at-startup API.
static PK_CACHE: OnceLock<Mutex<Vec<(String, Arc<ProvingKey<Bn254>>)>>> = OnceLock::new();

fn load_or_cache_zkey(zkey_path: &str) -> anyhow::Result<(Arc<ProvingKey<Bn254>>, u32, bool)> {
    let cache = PK_CACHE.get_or_init(|| Mutex::new(Vec::new()));
    // Fast path: cache hit.
    {
        let guard = cache.lock().unwrap();
        if let Some((_, pk)) = guard.iter().find(|(p, _)| p == zkey_path) {
            return Ok((Arc::clone(pk), 0, true));
        }
    }
    // Miss: parse the zkey and insert.
    let start = Instant::now();
    let mut file = File::open(PathBuf::from(zkey_path))?;
    let (pk, _matrices) = read_zkey(&mut file)?;
    let pk = Arc::new(pk);
    let elapsed = start.elapsed().as_millis() as u32;
    {
        let mut guard = cache.lock().unwrap();
        guard.push((zkey_path.to_string(), Arc::clone(&pk)));
    }
    Ok((pk, elapsed, false))
}

/// Benchmark result surfaced to Dart via flutter_rust_bridge. All
/// timing fields are milliseconds. `success` is `false` when any step
/// of the pipeline errored; `error_message` then carries the Rust-side
/// `Display` string.
///
/// `zkey_cache_hit` distinguishes the "cold" (first call, key parse
/// included) vs "warm" (cached key) path. Only the warm number is a
/// real measure of per-sign latency.
pub struct MimeWrapProofBenchmark {
    pub success: bool,
    pub error_message: Option<String>,
    pub zkey_load_ms: u32,
    pub zkey_cache_hit: bool,
    pub witness_gen_ms: u32,
    pub proof_gen_ms: u32,
    pub total_ms: u32,
    pub proof_bytes: Vec<u8>,
    pub public_inputs_count: u32,
}

/// Generate a random-fixture Groth16 proof for the mime_wrap circuit
/// and return end-to-end timing. Inputs are the absolute paths to:
///
///  - `wasm_path`  — Circom wasm for witness generation
///  - `r1cs_path`  — Circom r1cs (circuit structure)
///  - `zkey_path`  — Groth16 proving key
///
/// Paths must be absolute file paths on the device's filesystem. The
/// Kotlin side is responsible for copying the Android assets to
/// `context.filesDir` and passing the resulting paths here — this
/// module does not touch Android APIs.
pub fn benchmark_mime_wrap_proof(
    wasm_path: String,
    r1cs_path: String,
    zkey_path: String,
) -> MimeWrapProofBenchmark {
    // ark-circom's wasm witness generator drives wasmer internally,
    // and wasmer's async internals reach for `tokio::runtime::Handle::current()`.
    // FRB dispatches sync functions on a worker pool without a Tokio
    // runtime bound, so we spin up a short-lived current-thread runtime
    // and run the whole benchmark under its context. Current-thread is
    // intentional — we don't need a multi-threaded scheduler for what
    // is effectively a single synchronous workload, and it avoids
    // spawning extra worker threads just for a one-shot benchmark.
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            return MimeWrapProofBenchmark {
                success: false,
                error_message: Some(format!("Tokio runtime build failed: {e:?}")),
                zkey_load_ms: 0,
                zkey_cache_hit: false,
                witness_gen_ms: 0,
                proof_gen_ms: 0,
                total_ms: 0,
                proof_bytes: Vec::new(),
                public_inputs_count: 0,
            };
        }
    };
    let _guard = rt.enter();

    match run_benchmark(wasm_path, r1cs_path, zkey_path) {
        Ok(b) => b,
        Err(e) => MimeWrapProofBenchmark {
            success: false,
            error_message: Some(format!("{e:?}")),
            zkey_load_ms: 0,
            zkey_cache_hit: false,
            witness_gen_ms: 0,
            proof_gen_ms: 0,
            total_ms: 0,
            proof_bytes: Vec::new(),
            public_inputs_count: 0,
        },
    }
}

fn run_benchmark(
    wasm_path: String,
    r1cs_path: String,
    zkey_path: String,
) -> anyhow::Result<MimeWrapProofBenchmark> {
    let total_start = Instant::now();

    // ── Load the zkey (cached across calls) ──────────────────────
    // First call parses the 49MB Groth16 key (~10s on S20). Subsequent
    // calls hit the process-wide cache and return in ~0ms. Production
    // would preload at app startup, mirroring the warm-path latency.
    let (pk, zkey_load_ms, zkey_cache_hit) = load_or_cache_zkey(&zkey_path)?;

    // ── Build fixture inputs ──────────────────────────────────────
    // Mirrors scripts/smoke.js fixture generator: random seed +
    // ecKeyPub, deterministic bucket, computed commitment and otp.
    let seed = random_bytes(32);
    let ec_key_pub = random_bytes(32);
    let bucket_u64: u64 = 0x0000_0000_0387_d660;
    let bucket_be = bucket_u64.to_be_bytes();

    // C1 expected: commitment = SHA256(ecKeyPub || seed)
    let commitment = sha256_concat(&[&ec_key_pub, &seed]);
    // C2 expected: otp = low-24-bits (= last 24 bits big-endian) of
    //              SHA256(seed || bucket_be)
    let c2_hash = sha256_concat(&[&seed, &bucket_be]);
    let c2_bits = bits_from_bytes_be(&c2_hash);
    let otp_bits = &c2_bits[(256 - 24)..];

    // ── Witness generation via Circom wasm ────────────────────────
    // CircomConfig loads the wasm + r1cs and the builder accumulates
    // signal-name → value bindings. Each array-valued signal is
    // pushed bit-by-bit in the same declaration order as the circuit
    // expects.
    let witness_start = Instant::now();
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
    for &bit in otp_bits {
        builder.push_input("userOtp", bit as u64);
    }
    for bit in bits_from_bytes_be(&seed) {
        builder.push_input("seed", bit as u64);
    }

    let circom = builder
        .build()
        .map_err(|e| anyhow::anyhow!("CircomBuilder build failed: {e:?}"))?;
    let witness_gen_ms = witness_start.elapsed().as_millis() as u32;

    // ── Groth16 prove ─────────────────────────────────────────────
    let proof_start = Instant::now();
    let mut rng = thread_rng();
    let proof = Groth16::<Bn254>::prove(pk.as_ref(), circom, &mut rng)
        .map_err(|e| anyhow::anyhow!("Groth16 prove failed: {e:?}"))?;
    let proof_gen_ms = proof_start.elapsed().as_millis() as u32;

    // Serialize proof for transport back to Dart (compressed form).
    let mut proof_bytes = Vec::new();
    proof.serialize_compressed(&mut proof_bytes)?;

    let total_ms = total_start.elapsed().as_millis() as u32;

    Ok(MimeWrapProofBenchmark {
        success: true,
        error_message: None,
        zkey_load_ms,
        zkey_cache_hit,
        witness_gen_ms,
        proof_gen_ms,
        total_ms,
        proof_bytes,
        public_inputs_count: 600,
    })
}

// -- helpers ---------------------------------------------------------

fn random_bytes(n: usize) -> Vec<u8> {
    use ark_std::rand::RngCore;
    let mut rng = ark_std::rand::thread_rng();
    let mut out = vec![0u8; n];
    rng.fill_bytes(&mut out);
    out
}

fn sha256_concat(parts: &[&[u8]]) -> Vec<u8> {
    let mut hasher = Sha256::new();
    for p in parts {
        hasher.update(p);
    }
    hasher.finalize().to_vec()
}

/// Byte → bit, MSB-first within each byte. Matches `bytesToBitsBE`
/// in `scripts/smoke.js` — the Circom circuit expects bits in this
/// convention (high bit first), consistent with circomlib's Sha256.
fn bits_from_bytes_be(bytes: &[u8]) -> Vec<u8> {
    let mut bits = Vec::with_capacity(bytes.len() * 8);
    for &byte in bytes {
        for i in (0..8).rev() {
            bits.push((byte >> i) & 1);
        }
    }
    bits
}
