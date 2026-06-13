// Phase 4 slice 1c: one-hop onion proof on the live fabric.
//
//   phone → chat_send_onion(guard = relay-alice) → guard PEELS the layer
//   addressed to it → Deliver → injects the recipient-sealed envelope
//   into the normal stripe-and-distribute → recipient fetches from
//   relay-charlie (cross-node) → reads (Plain content).
//
// This proves the RPC + the isolated peeler + the Deliver path end to
// end on real nodes. The full who-from-where split needs the 2-hop
// relay-2 hand-off (slice 2); here the guard both peels and delivers.
//
// Prereq: the R2 fabric on the FLIPPED + onion gemini-node
// (validator 9944 + relays 9954/9955/9956). Run:
//   cargo test --test chat_onion_e2e -- --nocapture --ignored --test-threads=1

use std::time::Duration;

use rust_core::chat::{
    chat_fetch, chat_gen_content_key, chat_gen_identity, chat_node_info, chat_read_content,
    chat_send_onion,
};
use rust_core::core::{chat_mint_test_cert, dev_cert_seed_hex};

const VALIDATOR: &str = "ws://127.0.0.1:9944";
const GUARD: &str = "ws://127.0.0.1:9954"; // relay-alice — the node the phone connects to
const FETCH: &str = "ws://127.0.0.1:9956"; // relay-charlie — recipient fetches here (cross-node)

#[test]
#[ignore = "requires the R2 fabric on the flipped+onion gemini-node"]
fn onion_1hop_delivers() {
    // Sender cert (//Ferdie — disjoint from the other suites' signers).
    let cert_seed = dev_cert_seed_hex("//Ferdie".into());
    let thumbprint =
        chat_mint_test_cert(VALIDATOR.into(), "//Ferdie".into(), cert_seed.clone(), 600_000)
            .expect("mint test cert");

    // Recipient identity + (software) P-256 content key.
    let recipient_seed = "33".repeat(32);
    let recipient_id = chat_gen_identity(recipient_seed.clone()).expect("recipient id");
    let recipient_content_seed = "34".repeat(32);
    let recipient_content_key =
        chat_gen_content_key(0, recipient_content_seed.clone()).expect("content key");

    // Discover the guard's identity the realistic way — ask the node.
    let guard_pubkey = chat_node_info(GUARD.into()).expect("guard chat_nodeInfo");
    assert_eq!(guard_pubkey.len(), 64, "guard pubkey should be 32 bytes hex");
    println!("guard identity: {guard_pubkey}");

    let sender_seed = "44".repeat(32);
    let body = "onion 1-hop hello".to_string();

    // Send via a 1-hop onion to the guard. Retry past fabric warmup;
    // a peel/auth failure is fatal (not transient).
    let mut outcome = None;
    let mut last_err = String::new();
    for attempt in 0..15 {
        match chat_send_onion(
            GUARD.into(),
            guard_pubkey.clone(),
            sender_seed.clone(),
            recipient_id.ed25519_pubkey_hex.clone(),
            recipient_content_key.clone(),
            body.clone(),
            String::new(),
            5,
            Some(thumbprint.clone()),
            Some(cert_seed.clone()),
        ) {
            Ok(o) => {
                println!("onion send OK: msg_id={}", o.message_id_hex);
                outcome = Some(o);
                break;
            }
            Err(e) => {
                assert!(
                    !e.contains("signature verification failed")
                        && !e.contains("peel failed")
                        && !e.contains("requires cert auth"),
                    "onion send hard-failed: {e}"
                );
                last_err = e;
                println!("send attempt {attempt} (transient): {last_err}");
                std::thread::sleep(Duration::from_secs(2));
            }
        }
    }
    let outcome = outcome.unwrap_or_else(|| panic!("onion send never succeeded: {last_err}"));

    // Recipient fetches cross-node + reads (Plain content).
    let mut got = None;
    for _ in 0..20 {
        let msgs = chat_fetch(FETCH.into(), recipient_seed.clone(), None).expect("fetch");
        if let Some(m) = msgs.into_iter().find(|m| m.message_id_hex == outcome.message_id_hex) {
            got = Some(m);
            break;
        }
        std::thread::sleep(Duration::from_secs(2));
    }
    let m = got.expect("onion-delivered message never recovered cross-node");

    let read = chat_read_content(
        m.sealed_content_hex,
        0,
        recipient_content_seed,
        None,
        recipient_seed,
        Vec::new(),
    )
    .expect("content read");
    assert_eq!(read.plaintext, body, "decrypted plaintext mismatch");
    assert!(!read.ratcheted, "this proof uses Plain content");
    println!(
        "✅ 1-hop onion: phone → guard peels → delivers → recipient read '{}' cross-node",
        read.plaintext
    );
}
