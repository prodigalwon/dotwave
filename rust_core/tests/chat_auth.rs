// Phase 2 cert-gated send: prove the dotwave auth-signing path against
// a live mixed topology (validator 9944 + relays 9954/9956).
//
// Both tests are provable against the CURRENT (pre-flip) node: when the
// auth_* params are present the node runs `verify_chat_auth` for real —
// the permissive arm only covers their total absence. After the node
// flip (component 3) these tests are unchanged; only the None-path
// tests need rework.
//
// Prereq: the R2 fabric — validator (--dev, 9944) + 3 relays
// (9954/9955/9956). Run:
//   cargo test --test chat_auth -- --nocapture --ignored --test-threads=1
//
// Accounts: //Eve mints the cert (Phase-1 tests own //Charlie + //Dave;
// keep signers disjoint so nonces never race across test binaries).

use std::time::Duration;

use rust_core::chat::{
    chat_fetch, chat_gen_content_key, chat_gen_identity, chat_read_content, chat_send,
};
use rust_core::chat_dr::{chat_dr_gen_prekeys, chat_dr_initiate};
use rust_core::core::{chat_mint_test_cert, dev_cert_seed_hex};

/// SPK-only DR bootstrap for transport tests (no RNS record / OPK
/// mailbox involved — those paths are exercised in the record-driven
/// tests). Returns (initiator_session_state_hex, x3dh_init_hex).
fn dr_bootstrap(sender_seed_hex: &str, recipient_seed_hex: &str) -> (String, String) {
    let pk = chat_dr_gen_prekeys(recipient_seed_hex.into(), 0, 0).expect("gen prekeys");
    let recipient_id = chat_gen_identity(recipient_seed_hex.into()).expect("recipient id");
    let init = chat_dr_initiate(
        sender_seed_hex.into(),
        recipient_id.ed25519_pubkey_hex,
        pk.spk_pubkey_hex,
        pk.spk_signature_hex,
        None,
        None,
    )
    .expect("x3dh initiate");
    (init.session_state_hex, init.x3dh_init_hex)
}

const VALIDATOR: &str = "ws://127.0.0.1:9944";
const RELAY_SEND: &str = "ws://127.0.0.1:9954";
const RELAY_FETCH: &str = "ws://127.0.0.1:9956";

/// Mint (idempotently) the cert for //Eve with its account-derived
/// seed; returns (thumbprint, cert_seed).
fn mint_eve_cert() -> (String, String) {
    let cert_seed = dev_cert_seed_hex("//Eve".into());
    let thumbprint = chat_mint_test_cert(
        VALIDATOR.into(),
        "//Eve".into(),
        cert_seed.clone(),
        600_000, // ttl_blocks — well under MaxRootTtlBlocks
    )
    .expect("mint test cert");
    (thumbprint, cert_seed)
}

/// Positive path: cert-holder's authed send is admitted, stripes, and
/// recovers cross-node.
#[test]
#[ignore = "requires the R2 fabric (validator 9944 + relays 9954/9956)"]
fn authed_send_lands() {
    let (thumbprint, cert_seed) = mint_eve_cert();
    println!("minted cert thumbprint: {thumbprint}");

    let seed_a = "55".repeat(32);
    let seed_b = "66".repeat(32);
    let id_a = chat_gen_identity(seed_a.clone()).expect("gen A");
    let id_b = chat_gen_identity(seed_b.clone()).expect("gen B");
    let b_content_seed = "77".repeat(32);
    let b_content_key = chat_gen_content_key(0, b_content_seed.clone()).expect("gen content key");
    let (mut session_state, x3dh_init) = dr_bootstrap(&seed_a, &seed_b);
    let body = "phase-2 authed hello".to_string();

    // Retry loop: fresh fabrics need chat-gossip subscription warmup.
    let mut outcome = None;
    let mut last_err = String::new();
    for attempt in 0..15 {
        match chat_send(
            RELAY_SEND.into(),
            seed_a.clone(),
            id_b.ed25519_pubkey_hex.clone(),
            b_content_key.clone(),
            body.clone(),
            String::new(),
            5,
            session_state.clone(),
            Some(x3dh_init.clone()),
            Some(thumbprint.clone()),
            Some(cert_seed.clone()),
        ) {
            Ok(o) => {
                println!("authed send OK: msg_id={}", o.message_id_hex);
                session_state = o.new_session_state_hex.clone();
                outcome = Some(o);
                break;
            }
            Err(e) => {
                // A SIGNATURE rejection is a real failure. "cert not
                // found" is transient on the mixed topology: the mint
                // confirms against the VALIDATOR's best block, and the
                // relay may not have imported it yet — retry.
                assert!(
                    !e.contains("signature verification failed"),
                    "authed send rejected by verify_chat_auth: {e}"
                );
                last_err = e;
                println!("send attempt {attempt} (transient): {last_err}");
                std::thread::sleep(Duration::from_secs(2));
            }
        }
    }
    let outcome = outcome.unwrap_or_else(|| panic!("send never succeeded: {last_err}"));

    let mut recovered = None;
    for _ in 0..20 {
        let msgs = chat_fetch(RELAY_FETCH.into(), seed_b.clone(), None).expect("fetch");
        if let Some(m) = msgs.into_iter().find(|m| m.message_id_hex == outcome.message_id_hex) {
            recovered = Some(m);
            break;
        }
        std::thread::sleep(Duration::from_secs(2));
    }
    let m = recovered.expect("authed message never recovered cross-node");
    assert_eq!(m.sender_pubkey_hex, id_a.ed25519_pubkey_hex);
    let read = chat_read_content(
        m.sealed_content_hex.clone(),
        0,
        b_content_seed,
        None, // new conversation — bootstrap from the carried X3DH
        seed_b.clone(),
        Vec::new(),
    )
    .expect("read");
    assert_eq!(read.plaintext, body);
    assert!(read.ratcheted, "1:1 content must be ratcheted");
    assert!(!read.new_session_state_hex.is_empty());
    let _ = session_state; // initiator state advanced; thread continuity tested in chat_dr_e2e
    println!("✅ cert-authed send admitted + recovered cross-node (DR-ratcheted)");
}

/// Phase-2 gate criterion: a drop with NO auth at all is rejected.
/// Only passes against a flipped (component-3) node — the pre-flip
/// node warns and admits.
#[test]
#[ignore = "requires the R2 fabric with the FLIPPED gemini-node"]
fn unauthed_send_rejected() {
    let seed_a = "55".repeat(32);
    let seed_b = "66".repeat(32);
    let id_b = chat_gen_identity(seed_b.clone()).expect("gen B");
    let b_content_key = chat_gen_content_key(0, "77".repeat(32)).expect("gen content key");
    let (session_state, x3dh_init) = dr_bootstrap(&seed_a, &seed_b);
    match chat_send(
        RELAY_SEND.into(),
        seed_a,
        id_b.ed25519_pubkey_hex,
        b_content_key,
        "this must not be admitted".into(),
        String::new(),
        5,
        session_state,
        Some(x3dh_init),
        None,
        None,
    ) {
        Ok(o) => panic!(
            "UNAUTHENTICATED send was ADMITTED (msg {}) — the gate is open",
            o.message_id_hex
        ),
        Err(e) => {
            assert!(
                e.contains("requires cert auth"),
                "expected the cert-auth requirement error, got: {e}"
            );
            println!("✅ unauthenticated send rejected: {e}");
        }
    }
}

/// Negative path: a signature from the WRONG key under a real, Active
/// cert thumbprint is rejected by `verify_chat_auth` — proving the node
/// actually verifies (already true pre-flip when params are present).
#[test]
#[ignore = "requires the R2 fabric (validator 9944 + relays 9954/9956)"]
fn wrong_key_auth_rejected() {
    let (thumbprint, _cert_seed) = mint_eve_cert();

    // Valid thumbprint, but sign with a DIFFERENT P-256 key.
    let wrong_seed = "7777777777777777777777777777777777777777777777777777777777777777";
    let seed_a = "55".repeat(32);
    let seed_b = "66".repeat(32);
    let id_b = chat_gen_identity(seed_b.clone()).expect("gen B");
    let b_content_key = chat_gen_content_key(0, "77".repeat(32)).expect("gen content key");
    let (session_state, x3dh_init) = dr_bootstrap(&seed_a, &seed_b);

    let err = match chat_send(
        RELAY_SEND.into(),
        seed_a,
        id_b.ed25519_pubkey_hex,
        b_content_key,
        "this must not be admitted".into(),
        String::new(),
        5,
        session_state,
        Some(x3dh_init),
        Some(thumbprint),
        Some(wrong_seed.into()),
    ) {
        Ok(o) => panic!(
            "send with wrong cert key was ADMITTED (msg {})",
            o.message_id_hex
        ),
        Err(e) => e,
    };
    assert!(
        err.contains("signature verification failed"),
        "expected chat-auth signature failure, got: {err}"
    );
    println!("✅ wrong-key auth rejected: {err}");
}
