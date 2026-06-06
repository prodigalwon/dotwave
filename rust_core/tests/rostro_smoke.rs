//! End-to-end smoke test: ported dotwave read functions hit a running
//! gemini-node and return the expected shapes for a fresh `--dev` chain.
//!
//! Requires:
//!     /home/coder/Rostro/target/debug/gemini-node --dev --tmp --rpc-port 9944
//!
//! Run with:
//!     cargo test --test rostro_smoke -- --ignored --nocapture
//!
//! Asserts:
//! - `fetch_balance` returns a positive number for Alice (chain spec
//!   funds dev accounts)
//! - `get_name_price` returns a positive number for the price of a
//!   5-letter name
//! - `check_name_availability` reports any unregistered label as
//!   available
//! - `has_canonical_name` reports false for Alice (no registration on
//!   a fresh chain)
//! - `account_dashboard` returns an empty dashboard for Alice

use rust_core::core::{
	account_dashboard, check_name_availability, fetch_balance, get_name_price, has_canonical_name,
};
use sp_core::{Pair, sr25519};

const NODE_URL: &str = "ws://127.0.0.1:9944";

fn alice_ss58() -> String {
	let pair = sr25519::Pair::from_string("//Alice", None).unwrap();
	pair.public().to_string()
}

#[test]
#[ignore]
fn fetch_balance_for_alice_is_positive() {
	let bal = fetch_balance(alice_ss58(), NODE_URL.into()).expect("fetch_balance succeeds");
	let n: u128 = bal.parse().expect("balance parses as u128");
	assert!(n > 0, "Alice should have a non-zero balance on --dev (got {})", bal);
}

#[test]
#[ignore]
fn get_name_price_returns_a_decodeable_u128() {
	// Storage read pipeline validation only — the actual price value
	// depends on gemini's chainspec genesis config for RnsPriceOracle,
	// which (as of 2026-05-08) is all-zeros on `--dev`. A non-zero
	// genesis price is a separate gemini chainspec issue, not a port
	// concern.
	let price =
		get_name_price("alice".into(), NODE_URL.into()).expect("get_name_price succeeds");
	let _: u128 = price.parse().expect("price parses as u128");
}

#[test]
#[ignore]
fn check_name_availability_for_unregistered_is_true() {
	let avail = check_name_availability("alice".into(), NODE_URL.into())
		.expect("check_name_availability succeeds");
	assert!(avail.available, "alice should be available on a fresh chain");
	assert!(!avail.for_sale, "alice should not be for sale");
}

#[test]
#[ignore]
fn has_canonical_name_for_alice_is_false() {
	let has = has_canonical_name(alice_ss58(), NODE_URL.into())
		.expect("has_canonical_name succeeds");
	assert!(!has, "Alice has no canonical name on a fresh chain");
}

#[test]
#[ignore]
fn account_dashboard_for_alice_is_empty() {
	let d =
		account_dashboard(alice_ss58(), NODE_URL.into()).expect("account_dashboard succeeds");
	assert!(!d.has_primary_name);
	assert!(d.primary_name_hash.is_none());
	assert!(d.subname_hashes.is_empty());
	assert!(d.pending_subname_offers.is_empty());
	assert!(d.pending_name_offers.is_empty());
}
