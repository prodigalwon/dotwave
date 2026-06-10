//! PoP (Proof of Personhood) extrinsic submitters + queries.
//!
//! Mirrors the Stage 5e zkpki submit pattern in `core.rs`: connect via
//! subxt, fetch best-block nonce, build the call, sign, submit, return
//! the tx hash.
//!
//! ## Why dynamic instead of typed
//!
//! The pallet `pallet-rostro-personhood` was added to gemini-runtime
//! AFTER `src/polkadot_metadata.scale` was captured (April 2026), so
//! the typed `polkadot::tx().personhood()` macro path is unavailable
//! until the metadata is regenerated. Until then, every personhood
//! call here uses `subxt::dynamic::tx(pallet, call, fields)`. subxt
//! fetches the runtime metadata at connect time, so dynamic encoding
//! works against any chain whose live metadata exposes the pallet.
//!
//! ## Functions
//!
//! - [`submit_mint_pop`] — atomic single-extrinsic mint of a PoP cert
//!   from the two Groth16 proofs + a fresh StrongBox HIP attestation.
//! - [`submit_discard_pop`] — caller destroys their own cert and frees
//!   the nullifier. No proof needed; destroying own state isn't a
//!   new claim.
//! - [`submit_srt_set_csca_root`] / [`submit_srt_set_seats_root`] —
//!   SRT-only. Single extrinsic for first-publish + quarterly + emergency
//!   rotation. Hard cutover (no grace).
//! - [`submit_srt_set_vk`] — SRT-only. Strict monotonic version bumping
//!   for one of the two circuits (passport_attest or liveness_facematch).
//! - [`query_pop_cert`] — read-side: look up the `PopCert` record for an
//!   AccountId from `Personhood.PopCerts` storage.

use crate::core::{
	connect_rostro_with_rpc, decode_hex_32, decode_hex_bytes, decode_hex_n, fetch_best_nonce,
	rostro_tx_params, BINDING_PROOF_CONTEXT, Sr25519Signer, StrongBoxCeremonyBundle,
};
use crate::rostro_config::RostroConfig;
use sp_core::{sr25519, Pair};
use std::str::FromStr;
use subxt::dynamic::Value;
use subxt::utils::AccountId32;

// ═══════════════════════════════════════════════════════════════════════════
// Field bundles — Flutter-friendly shapes for the public-input args.
// ═══════════════════════════════════════════════════════════════════════════

/// Public-input bundle for the `passport_attest` circuit, in
/// hex-string / primitive form for FFI.
#[flutter_rust_bridge::frb(sync)]
pub struct PassportInputsFields {
	/// `Poseidon(MRZ_canonical, ROSTRO_POP_DOMAIN)` — 32-byte hex.
	pub nullifier_hex: String,
	/// SS58 the proof binds to. Must match the signer.
	pub bound_account: String,
	/// Passport expiry expressed in chain block-number form.
	pub ttl_block: u32,
	/// `(anchor_block - dob_block) >= 18_years_in_blocks`.
	pub adult: bool,
	/// Country resolved through the seats merkle tree (country code stays
	/// private, only seat_id reveals).
	pub seat_id: u16,
	/// Recent chain anchor's block number.
	pub anchor_block: u32,
	/// 32-byte hex of the chain block hash at `anchor_block`.
	pub anchor_hash_hex: String,
	/// 32-byte hex of the CSCA bundle merkle root the proof was generated against.
	pub csca_root_hex: String,
	/// 32-byte hex of the seats mapping merkle root the proof was generated against.
	pub seats_root_hex: String,
	/// 32-byte hex of the chip's DG2 (photo) hash. Cross-proof binding to
	/// the liveness_facematch proof.
	pub dg2_hash_hex: String,
}

/// Public-input bundle for the `liveness_facematch` circuit.
#[flutter_rust_bridge::frb(sync)]
pub struct LivenessInputsFields {
	/// 32-byte hex. Must equal the paired passport_attest's `dg2_hash`.
	pub dg2_hash_hex: String,
	/// SS58 the proof binds to. Must match the signer.
	pub bound_account: String,
	pub liveness_passed: bool,
	/// Same chain anchor block as the paired passport_attest proof.
	pub anchor_block: u32,
	pub anchor_hash_hex: String,
}

/// Returned by [`query_pop_cert`]. Mirrors the on-chain `PopCert<u32>`
/// shape with hex-encoded byte fields for FFI ergonomics.
#[flutter_rust_bridge::frb(sync)]
pub struct PopCertInfo {
	pub nullifier_hex: String,
	pub ttl_block: u32,
	pub adult: bool,
	pub seat_id: u16,
	pub minted_at: u32,
}

// ═══════════════════════════════════════════════════════════════════════════
// Dynamic Value helpers
// ═══════════════════════════════════════════════════════════════════════════

fn chain_anchor_value(block: u32, hash: [u8; 32]) -> Value {
	Value::named_composite([
		("block".to_string(), Value::u128(block as u128)),
		("hash".to_string(), Value::from_bytes(hash)),
	])
}

fn passport_inputs_value(f: &PassportInputsFields) -> Result<Value, String> {
	let nullifier = decode_hex_32(&f.nullifier_hex, "nullifier")?;
	let bound = AccountId32::from_str(&f.bound_account)
		.map_err(|e| format!("bound_account invalid SS58: {e}"))?;
	let anchor_hash = decode_hex_32(&f.anchor_hash_hex, "anchor_hash")?;
	let csca_root = decode_hex_32(&f.csca_root_hex, "csca_root")?;
	let seats_root = decode_hex_32(&f.seats_root_hex, "seats_root")?;
	let dg2 = decode_hex_32(&f.dg2_hash_hex, "dg2_hash")?;

	Ok(Value::named_composite([
		("nullifier".to_string(), Value::from_bytes(nullifier)),
		("bound_account".to_string(), Value::from_bytes(AsRef::<[u8]>::as_ref(&bound))),
		("ttl_block".to_string(), Value::u128(f.ttl_block as u128)),
		("adult".to_string(), Value::bool(f.adult)),
		("seat_id".to_string(), Value::u128(f.seat_id as u128)),
		("anchor".to_string(), chain_anchor_value(f.anchor_block, anchor_hash)),
		("csca_root".to_string(), Value::from_bytes(csca_root)),
		("seats_root".to_string(), Value::from_bytes(seats_root)),
		("dg2_hash".to_string(), Value::from_bytes(dg2)),
	]))
}

fn liveness_inputs_value(f: &LivenessInputsFields) -> Result<Value, String> {
	let dg2 = decode_hex_32(&f.dg2_hash_hex, "dg2_hash")?;
	let bound = AccountId32::from_str(&f.bound_account)
		.map_err(|e| format!("bound_account invalid SS58: {e}"))?;
	let anchor_hash = decode_hex_32(&f.anchor_hash_hex, "anchor_hash")?;

	Ok(Value::named_composite([
		("dg2_hash".to_string(), Value::from_bytes(dg2)),
		("bound_account".to_string(), Value::from_bytes(AsRef::<[u8]>::as_ref(&bound))),
		("liveness_passed".to_string(), Value::bool(f.liveness_passed)),
		("anchor".to_string(), chain_anchor_value(f.anchor_block, anchor_hash)),
	]))
}

/// Build `CanonicalHipProof::StrongBox(StrongBoxHipProof { ... })` as a
/// dynamic Value. Mirrors the `TypedStrongBoxHipProof` construction in
/// `submit_mint_cert_strongbox`.
fn strongbox_hip_proof_value(b: &StrongBoxCeremonyBundle) -> Result<Value, String> {
	let cert_ec_public = decode_hex_n::<65>(&b.cert_ec_public_sec1_hex, "cert_ec_public_sec1")?;
	let attest_ec_public =
		decode_hex_n::<65>(&b.attest_ec_public_sec1_hex, "attest_ec_public_sec1")?;
	let cert_ec_chain_leaf = decode_hex_bytes(&b.cert_ec_chain_leaf_hex, "cert_ec_chain_leaf")?;
	let attest_ec_chain_leaf =
		decode_hex_bytes(&b.attest_ec_chain_leaf_hex, "attest_ec_chain_leaf")?;
	let hmac_binding_output = decode_hex_32(&b.hmac_binding_output_hex, "hmac_binding_output")?;
	let hmac_binding_signature =
		decode_hex_bytes(&b.hmac_binding_signature_hex, "hmac_binding_signature")?;
	let integrity_blob = decode_hex_bytes(&b.integrity_blob_hex, "integrity_blob")?;
	let integrity_signature = decode_hex_bytes(&b.integrity_signature_hex, "integrity_signature")?;
	let nonce = decode_hex_32(&b.challenge_hex, "challenge")?;

	let inner = Value::named_composite([
		("cert_ec_public".to_string(), Value::from_bytes(cert_ec_public)),
		("attest_ec_public".to_string(), Value::from_bytes(attest_ec_public)),
		(
			"cert_ec_chain".to_string(),
			Value::unnamed_composite([Value::from_bytes(cert_ec_chain_leaf)]),
		),
		(
			"attest_ec_chain".to_string(),
			Value::unnamed_composite([Value::from_bytes(attest_ec_chain_leaf)]),
		),
		("hmac_binding_output".to_string(), Value::from_bytes(hmac_binding_output)),
		("hmac_binding_signature".to_string(), Value::from_bytes(hmac_binding_signature)),
		("binding_proof_context".to_string(), Value::from_bytes(BINDING_PROOF_CONTEXT.to_vec())),
		("integrity_blob".to_string(), Value::from_bytes(integrity_blob)),
		("integrity_signature".to_string(), Value::from_bytes(integrity_signature)),
		("nonce".to_string(), Value::from_bytes(nonce)),
	]);

	Ok(Value::unnamed_variant("StrongBox", [inner]))
}

// ═══════════════════════════════════════════════════════════════════════════
// Connect / sign / submit boilerplate (same shape as `submit_mint_cert_strongbox`)
// ═══════════════════════════════════════════════════════════════════════════

fn submit_personhood_call(
	call_name: &str,
	fields: Vec<(String, Value)>,
	phrase: &str,
	rpc_url: &str,
) -> Result<String, String> {
	let pair = sr25519::Pair::from_string(phrase, None)
		.map_err(|e| format!("Keypair error: {:?}", e))?;
	let rt = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.map_err(|e| e.to_string())?;
	rt.block_on(async {
		let (api, rpc) = connect_rostro_with_rpc(rpc_url).await?;
		let signer = Sr25519Signer(pair);
		let account =
			<Sr25519Signer as subxt::tx::Signer<RostroConfig>>::account_id(&signer);
		let nonce = fetch_best_nonce(&rpc, &account).await?;
		let tx = subxt::dynamic::tx("Personhood", call_name, fields);
		let tx_client = api.tx().await.map_err(|e| e.to_string())?;
		let mut signable = tx_client
			.create_signable(&tx, &account, rostro_tx_params(nonce))
			.await
			.map_err(|e| e.to_string())?;
		let signed = signable.sign(&signer).map_err(|e| e.to_string())?;
		let hash = signed.submit().await.map_err(|e| e.to_string())?;
		Ok(format!("{:?}", hash))
	})
}

// ═══════════════════════════════════════════════════════════════════════════
// Public extrinsic submitters
// ═══════════════════════════════════════════════════════════════════════════

/// Atomic single-extrinsic PoP mint. Caller signs with the same SS58
/// the proofs are bound to. The pallet enforces:
/// (a) no existing PoP cert for this account, (b) HIP attestation
/// fresh and AIK-bound, (c) cross-proof binding (matching dg2_hash and
/// anchor), (d) chain anchor freshness, (e) trust roots match current,
/// (f) passport not expired, (g) nullifier not consumed,
/// (h) both Groth16 proofs verify.
pub fn submit_mint_pop(
	passport_proof_hex: String,
	passport_inputs: PassportInputsFields,
	liveness_proof_hex: String,
	liveness_inputs: LivenessInputsFields,
	hw_cert_thumbprint_hex: String,
	hip_bundle: StrongBoxCeremonyBundle,
	phrase: String,
	rpc_url: String,
) -> Result<String, String> {
	let passport_proof = decode_hex_bytes(&passport_proof_hex, "passport_proof")?;
	let liveness_proof = decode_hex_bytes(&liveness_proof_hex, "liveness_proof")?;
	let hw_cert_thumbprint = decode_hex_32(&hw_cert_thumbprint_hex, "hw_cert_thumbprint")?;
	let passport_inputs_v = passport_inputs_value(&passport_inputs)?;
	let liveness_inputs_v = liveness_inputs_value(&liveness_inputs)?;
	let hip_proof = strongbox_hip_proof_value(&hip_bundle)?;

	submit_personhood_call(
		"mint_pop",
		vec![
			("passport_proof".to_string(), Value::from_bytes(passport_proof)),
			("passport_inputs".to_string(), passport_inputs_v),
			("liveness_proof".to_string(), Value::from_bytes(liveness_proof)),
			("liveness_inputs".to_string(), liveness_inputs_v),
			("hw_cert_thumbprint".to_string(), Value::from_bytes(hw_cert_thumbprint)),
			("hip_proof".to_string(), hip_proof),
		],
		&phrase,
		&rpc_url,
	)
}

/// Caller destroys their own PoP cert. Frees the nullifier so the same
/// passport may re-mint to a different SS58 (or after passport renewal
/// produces a new MRZ → new nullifier).
pub fn submit_discard_pop(phrase: String, rpc_url: String) -> Result<String, String> {
	submit_personhood_call("discard_pop", vec![], &phrase, &rpc_url)
}

/// SRT-only: rotate the CSCA bundle merkle root. Same extrinsic for
/// first-publish post-genesis, scheduled quarterly rotation, and
/// emergency rotation; SRT decides pacing operationally. Hard cutover
/// (no grace window) — see memory `feedback_dont_kick_can_with_grace_windows`.
pub fn submit_srt_set_csca_root(
	new_root_hex: String,
	phrase: String,
	rpc_url: String,
) -> Result<String, String> {
	let new_root = decode_hex_32(&new_root_hex, "new_root")?;
	submit_personhood_call(
		"srt_set_csca_root",
		vec![("new_root".to_string(), Value::from_bytes(new_root))],
		&phrase,
		&rpc_url,
	)
}

/// SRT-only: rotate the seats mapping merkle root. Existing PoP certs
/// grandfather their stored `seat_id`; only new mints see the new root.
pub fn submit_srt_set_seats_root(
	new_root_hex: String,
	phrase: String,
	rpc_url: String,
) -> Result<String, String> {
	let new_root = decode_hex_32(&new_root_hex, "new_root")?;
	submit_personhood_call(
		"srt_set_seats_root",
		vec![("new_root".to_string(), Value::from_bytes(new_root))],
		&phrase,
		&rpc_url,
	)
}

/// SRT-only: rotate the verifying key for one of the two circuits.
/// `which` is `"PassportAttest"` or `"LivenessFacematch"`. Strict
/// monotonic — `new_version` MUST equal `prev_version + 1` (rollback to
/// a known-good earlier set is performed by re-running the ceremony
/// with the desired bytes and the next monotonic version).
pub fn submit_srt_set_vk(
	which: String,
	new_vk_bytes_hex: String,
	new_version: u32,
	ceremony_hash_hex: String,
	phrase: String,
	rpc_url: String,
) -> Result<String, String> {
	if which != "PassportAttest" && which != "LivenessFacematch" {
		return Err(format!(
			"`which` must be 'PassportAttest' or 'LivenessFacematch', got '{which}'"
		));
	}
	let new_vk_bytes = decode_hex_bytes(&new_vk_bytes_hex, "new_vk_bytes")?;
	let ceremony_hash = decode_hex_32(&ceremony_hash_hex, "ceremony_hash")?;

	submit_personhood_call(
		"srt_set_vk",
		vec![
			("which".to_string(), Value::unnamed_variant(&which, [])),
			("new_vk_bytes".to_string(), Value::from_bytes(new_vk_bytes)),
			("new_version".to_string(), Value::u128(new_version as u128)),
			("ceremony_hash".to_string(), Value::from_bytes(ceremony_hash)),
		],
		&phrase,
		&rpc_url,
	)
}

// ═══════════════════════════════════════════════════════════════════════════
// Read-side: PopCerts storage map lookup
// ═══════════════════════════════════════════════════════════════════════════

/// Look up the PoP cert record for an account. Returns `Ok(None)` if
/// the account has no cert. Uses `rostro-client` (the read path that
/// replaced subxt for storage queries) — see `crate::rostro_client`.
pub fn query_pop_cert(account: String, rpc_url: String) -> Result<Option<PopCertInfo>, String> {
	use parity_scale_codec::Encode;
	let account_id = AccountId32::from_str(&account)
		.map_err(|e| format!("Invalid address: {e}"))?;
	let account_bytes: [u8; 32] = account_id.0;
	let key = account_bytes.encode();

	let rt = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.map_err(|e| e.to_string())?;
	rt.block_on(async {
		let (client, metadata) = crate::rostro_client::connect(&rpc_url).await?;
		let value = client
			.fetch_storage(&metadata, "Personhood", "PopCerts", &[&key])
			.await
			.map_err(|e| e.to_string())?;

		let v = match value {
			None => return Ok(None),
			Some(v) => v,
		};

		let nullifier = crate::rostro_client::field(&v, "nullifier")
			.and_then(crate::rostro_client::as_bytes)
			.ok_or_else(|| "PopCert.nullifier missing/invalid".to_string())?;
		let ttl_block = crate::rostro_client::field(&v, "ttl_block")
			.and_then(crate::rostro_client::as_u32)
			.ok_or_else(|| "PopCert.ttl_block missing/invalid".to_string())?;
		let adult = crate::rostro_client::field(&v, "adult")
			.and_then(crate::rostro_client::as_bool)
			.ok_or_else(|| "PopCert.adult missing/invalid".to_string())?;
		let seat_id_u128 = crate::rostro_client::field(&v, "seat_id")
			.and_then(crate::rostro_client::as_u128)
			.ok_or_else(|| "PopCert.seat_id missing/invalid".to_string())?;
		let seat_id: u16 = u16::try_from(seat_id_u128)
			.map_err(|_| "PopCert.seat_id exceeds u16 range".to_string())?;
		let minted_at = crate::rostro_client::field(&v, "minted_at")
			.and_then(crate::rostro_client::as_u32)
			.ok_or_else(|| "PopCert.minted_at missing/invalid".to_string())?;

		let mut nh = String::with_capacity(2 + nullifier.len() * 2);
		nh.push_str("0x");
		for b in &nullifier {
			use std::fmt::Write;
			let _ = write!(&mut nh, "{:02x}", b);
		}

		Ok(Some(PopCertInfo {
			nullifier_hex: nh,
			ttl_block,
			adult,
			seat_id,
			minted_at,
		}))
	})
}
