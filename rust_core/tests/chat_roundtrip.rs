// Phase 0 local validation: drive dotwave's chat.rs send/recover path
// against a running local Rostro chat relay fabric (no phone needed).
//
// Prereq: a local non-validator chat relay fabric, e.g.
//   Rostro/scripts/run-chat-local.sh  (alice 9954, bob 9955, charlie 9956)
//
// Override endpoints via env: CHAT_SEND_RPC / CHAT_FETCH_RPC.
// Run:  cargo test --test chat_roundtrip -- --nocapture --ignored

use std::time::Duration;

use rust_core::chat::{
    chat_fetch, chat_gen_content_key, chat_gen_identity, chat_read_content, chat_send,
};
use rust_core::chat_dr::{chat_dr_gen_prekeys, chat_dr_initiate};
use rust_core::core::{chat_mint_test_cert, dev_cert_seed_hex};

fn send_rpc() -> String {
    std::env::var("CHAT_SEND_RPC").unwrap_or_else(|_| "ws://127.0.0.1:9954".into()) // alice
}
fn fetch_rpc() -> String {
    // charlie by default — a DIFFERENT node than send, to exercise the
    // cross-node share-distribution path.
    std::env::var("CHAT_FETCH_RPC").unwrap_or_else(|_| "ws://127.0.0.1:9956".into())
}
fn validator_rpc() -> String {
    std::env::var("CHAT_CHAIN_RPC").unwrap_or_else(|_| "ws://127.0.0.1:9944".into())
}

#[test]
#[ignore = "requires a local chat relay fabric on 9954/9955/9956"]
fn pairwise_roundtrip_cross_node() {
    let seed_a = "11".repeat(32); // Alice chat-identity seed (64 hex)
    let seed_b = "22".repeat(32); // Bob chat-identity seed
    let id_a = chat_gen_identity(seed_a.clone()).expect("gen A identity");
    let id_b = chat_gen_identity(seed_b.clone()).expect("gen B identity");
    let body = "phase-0 hello from alice".to_string();

    // Phase 2: every send is cert-gated. Mint (idempotent) //Bob's
    // dev cert via the validator.
    let cert_seed = dev_cert_seed_hex("//Bob".into());
    let thumbprint =
        chat_mint_test_cert(validator_rpc(), "//Bob".into(), cert_seed.clone(), 600_000)
            .expect("mint test cert");

    // Phase 3: content sealed to B's (software) P-256 content key. This
    // transport test passes the key directly; the name-addressed tests
    // exercise the RNS-record path.
    let b_content_seed = "77".repeat(32);
    let b_content_key = chat_gen_content_key(0, b_content_seed.clone()).expect("gen content key");
    // Alice's content key — Bob's DR reply gets sealed to it.
    let a_content_seed = "78".repeat(32);
    let a_content_key = chat_gen_content_key(0, a_content_seed.clone()).expect("gen content key");

    // Phase 5: SPK-only X3DH bootstrap (the OPK mailbox path is
    // exercised in chat_dr_e2e / the record-driven tests).
    let b_prekeys = chat_dr_gen_prekeys(seed_b.clone(), 0, 0).expect("gen prekeys");
    let init = chat_dr_initiate(
        seed_a.clone(),
        id_b.ed25519_pubkey_hex.clone(),
        b_prekeys.spk_pubkey_hex.clone(),
        b_prekeys.spk_signature_hex.clone(),
        None,
        None,
    )
    .expect("x3dh initiate");
    let mut alice_session = init.session_state_hex.clone();

    // Send A -> B via alice. Retry: the entry node stripes to bucket
    // peers, which requires chat-gossip to have advertised their
    // subscriptions, so a freshly-booted fabric may need a moment.
    let mut outcome = None;
    let mut last_err = String::new();
    for attempt in 0..15 {
        match chat_send(
            send_rpc(),
            seed_a.clone(),
            id_b.ed25519_pubkey_hex.clone(),
            b_content_key.clone(),
            body.clone(),
            String::new(), // sender_name (none in this transport test)
            5,
            alice_session.clone(),
            Some(init.x3dh_init_hex.clone()),
            Some(thumbprint.clone()),
            Some(cert_seed.clone()),
        ) {
            Ok(o) => { println!("sent: msg_id={} shares={}", o.message_id_hex, o.share_count); alice_session = o.new_session_state_hex.clone(); outcome = Some(o); break; }
            Err(e) => { last_err = e; println!("send attempt {attempt} failed: {last_err}"); std::thread::sleep(Duration::from_secs(2)); }
        }
    }
    let outcome = outcome.unwrap_or_else(|| panic!("send never succeeded: {last_err}"));

    // Fetch as B from charlie (cross-node) until the message reassembles.
    let mut recovered = None;
    for attempt in 0..20 {
        let msgs = chat_fetch(fetch_rpc(), seed_b.clone(), None).expect("fetch");
        if let Some(m) = msgs.into_iter().find(|m| m.message_id_hex == outcome.message_id_hex) {
            recovered = Some(m);
            break;
        }
        println!("fetch attempt {attempt}: not yet reassembled");
        std::thread::sleep(Duration::from_secs(2));
    }
    let m = recovered.expect("message never recovered cross-node");

    // Phase 3 at-rest property: the fetched blob is NOT plaintext.
    assert_eq!(m.sender_pubkey_hex, id_a.ed25519_pubkey_hex, "sender verify mismatch");
    assert!(
        !hex::decode(&m.sealed_content_hex)
            .unwrap()
            .windows(body.len())
            .any(|w| w == body.as_bytes()),
        "at-rest blob leaks plaintext"
    );

    // Explicit read (the biometric/silicon seam, software on the dev
    // box). Bob has no session — bootstraps from the carried X3DH.
    let read = chat_read_content(
        m.sealed_content_hex.clone(),
        0,
        b_content_seed.clone(),
        None,
        seed_b.clone(),
        Vec::new(),
    )
    .expect("content decrypt");
    println!("recovered: plaintext={:?} sender={}", read.plaintext, m.sender_pubkey_hex);
    assert_eq!(read.plaintext, body, "decrypted plaintext mismatch");
    assert!(read.ratcheted);
    let bob_session = read.new_session_state_hex.clone();
    assert!(!bob_session.is_empty(), "responder session must be established");

    // Phase 5 reply leg: Bob replies THROUGH THE FABRIC with his
    // session ("app restart" simulated on both sides by using only
    // the persisted state strings). The reply triggers Alice's DH
    // ratchet — post-compromise security in motion.
    let reply = "phase-5 ratcheted reply from bob".to_string();
    let reply_outcome = chat_send(
        send_rpc(),
        seed_b.clone(),
        id_a.ed25519_pubkey_hex.clone(),
        a_content_key,
        reply.clone(),
        String::new(),
        5,
        bob_session,
        None, // established session — no X3DH attach
        Some(thumbprint.clone()),
        Some(cert_seed.clone()),
    )
    .expect("bob reply send");

    let mut got_reply = None;
    for _ in 0..20 {
        let msgs = chat_fetch(fetch_rpc(), seed_a.clone(), None).expect("fetch A");
        if let Some(m) = msgs.into_iter().find(|m| m.message_id_hex == reply_outcome.message_id_hex) {
            got_reply = Some(m);
            break;
        }
        std::thread::sleep(Duration::from_secs(2));
    }
    let rm = got_reply.expect("reply never recovered");
    let read_reply = chat_read_content(
        rm.sealed_content_hex,
        0,
        a_content_seed,
        Some(alice_session), // persisted initiator state
        seed_a.clone(),
        Vec::new(),
    )
    .expect("alice reads reply");
    assert_eq!(read_reply.plaintext, reply, "reply plaintext mismatch");
    println!(
        "✅ pairwise cross-node round-trip OK (sealed-sender + content-seal at rest + \
         DR forward-secret both directions, sessions persisted as state strings)"
    );
}
