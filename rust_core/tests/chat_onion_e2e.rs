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
    chat_send_onion, chat_send_onion_2hop,
};
use rust_core::core::{chat_mint_test_cert, dev_cert_seed_hex};

const VALIDATOR: &str = "ws://127.0.0.1:9944";
const GUARD: &str = "ws://127.0.0.1:9954"; // relay-alice — the node the phone connects to
const RELAY2: &str = "ws://127.0.0.1:9955"; // relay-bob — the forward target (distinct from guard)
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

// Phase 4 slice 2: TWO-hop onion proof — the real who-from-where split.
//
//   phone → chat_send_onion_2hop(guard = alice, relay-2 = bob) →
//   guard PEELS its layer → Forward → sends inner DIRECTLY to relay-2
//   over /rostro/chat-onion-forward/1 → relay-2 PEELS → Deliver →
//   injects the recipient-sealed envelope into stripe → recipient
//   fetches from charlie (cross-node) → reads.
//
// The guard sees the sender (cert+IP) and next hop = relay-2, but NOT
// the recipient. relay-2 sees the recipient bucket but NOT the sender
// (it saw the guard, a canonical-gated peer). Neither relay alone links
// sender→bucket. Confirm in the logs: the GUARD (alice) log shows the
// onion-forward send; the RELAY-2 (bob) log shows `chat distribute` from
// the forward handler (admitted via is_passed). The 1-hop guard would
// instead show `chat distribute` itself.
//
// Prereq: same R2 fabric (validator 9944 + relays 9954/9955/9956). Run:
//   cargo test --test chat_onion_e2e onion_2hop -- --nocapture --ignored --test-threads=1
#[test]
#[ignore = "requires the R2 fabric on the flipped+onion gemini-node"]
fn onion_2hop_delivers() {
    // Sender cert (//Eve — disjoint from the 1-hop suite's //Ferdie).
    let cert_seed = dev_cert_seed_hex("//Eve".into());
    let thumbprint =
        chat_mint_test_cert(VALIDATOR.into(), "//Eve".into(), cert_seed.clone(), 600_000)
            .expect("mint test cert");

    // Recipient identity + (software) P-256 content key.
    let recipient_seed = "55".repeat(32);
    let recipient_id = chat_gen_identity(recipient_seed.clone()).expect("recipient id");
    let recipient_content_seed = "56".repeat(32);
    let recipient_content_key =
        chat_gen_content_key(0, recipient_content_seed.clone()).expect("content key");

    // Discover guard (alice) AND relay-2 (bob) identities from their nodes.
    let guard_pubkey = chat_node_info(GUARD.into()).expect("guard chat_nodeInfo");
    let relay2_pubkey = chat_node_info(RELAY2.into()).expect("relay-2 chat_nodeInfo");
    assert_eq!(guard_pubkey.len(), 64, "guard pubkey should be 32 bytes hex");
    assert_eq!(relay2_pubkey.len(), 64, "relay-2 pubkey should be 32 bytes hex");
    assert_ne!(guard_pubkey, relay2_pubkey, "guard and relay-2 must be distinct nodes");
    println!("guard={guard_pubkey}\nrelay2={relay2_pubkey}");

    let sender_seed = "66".repeat(32);
    let body = "onion 2-hop hello".to_string();

    // Send via a 2-hop onion. Retry past fabric warmup; a peel/auth/cap
    // failure is fatal (not transient).
    let mut outcome = None;
    let mut last_err = String::new();
    for attempt in 0..15 {
        match chat_send_onion_2hop(
            GUARD.into(),
            guard_pubkey.clone(),
            relay2_pubkey.clone(),
            sender_seed.clone(),
            recipient_id.ed25519_pubkey_hex.clone(),
            recipient_content_key.clone(),
            body.clone(),
            String::new(),
            5,
            Some(thumbprint.clone()),
            Some(cert_seed.clone()),
            None, // first message in this conversation → no chain predecessor
            0,    // composed_at unused by this transport-only assertion
            None, // no avatar in this transport-only assertion
        ) {
            Ok(o) => {
                println!("2-hop onion send OK: msg_id={}", o.message_id_hex);
                outcome = Some(o);
                break;
            }
            Err(e) => {
                assert!(
                    !e.contains("signature verification failed")
                        && !e.contains("peel failed")
                        && !e.contains("requires cert auth")
                        && !e.contains("2-hop limit"),
                    "2-hop onion send hard-failed: {e}"
                );
                last_err = e;
                println!("send attempt {attempt} (transient): {last_err}");
                std::thread::sleep(Duration::from_secs(2));
            }
        }
    }
    let outcome =
        outcome.unwrap_or_else(|| panic!("2-hop onion send never succeeded: {last_err}"));

    // Recipient fetches cross-node (charlie) + reads.
    let mut got = None;
    for _ in 0..20 {
        let msgs = chat_fetch(FETCH.into(), recipient_seed.clone(), None).expect("fetch");
        if let Some(m) = msgs.into_iter().find(|m| m.message_id_hex == outcome.message_id_hex) {
            got = Some(m);
            break;
        }
        std::thread::sleep(Duration::from_secs(2));
    }
    let m = got.expect("2-hop onion-delivered message never recovered cross-node");

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
        "✅ 2-hop onion: phone → guard(alice) forwards → relay-2(bob) delivers → \
         recipient read '{}' cross-node",
        read.plaintext
    );
}

// 1b — relay-2 liveness fallback. If the sender's chosen relay-2 is NOT a live
// chat-fabric member (absent from the guard's chat-gossip bucket cache), the
// guard must return RELAY_UNAVAILABLE_CODE (-32050) FAST so the app can re-roll
// — never attempt the forward, never hang the 120s forward timeout. Proven with
// a phantom relay-2: a valid ed25519 pubkey for a node that isn't connected.
#[test]
#[ignore = "requires the R2 fabric on the flipped+onion gemini-node"]
fn onion_2hop_relay_unavailable() {
    let cert_seed = dev_cert_seed_hex("//Dave".into());
    let thumbprint =
        chat_mint_test_cert(VALIDATOR.into(), "//Dave".into(), cert_seed.clone(), 600_000)
            .expect("mint test cert");

    let recipient_seed = "77".repeat(32);
    let recipient_id = chat_gen_identity(recipient_seed.clone()).expect("recipient id");
    let recipient_content_seed = "78".repeat(32);
    let recipient_content_key =
        chat_gen_content_key(0, recipient_content_seed).expect("content key");

    let guard_pubkey = chat_node_info(GUARD.into()).expect("guard chat_nodeInfo");
    // A valid ed25519 pubkey for a node that is NOT connected → absent from the
    // guard's bucket cache → must trip 1b.
    let phantom_relay2 =
        chat_gen_identity("ab".repeat(32)).expect("phantom id").ed25519_pubkey_hex;
    assert_ne!(guard_pubkey, phantom_relay2, "phantom must differ from the guard");
    println!("guard={guard_pubkey}\nphantom relay-2 (offline)={phantom_relay2}");

    let res = chat_send_onion_2hop(
        GUARD.into(),
        guard_pubkey,
        phantom_relay2,
        "79".repeat(32),
        recipient_id.ed25519_pubkey_hex,
        recipient_content_key,
        "should never deliver".to_string(),
        String::new(),
        5,
        Some(thumbprint),
        Some(cert_seed),
        None, // first message in this conversation → no chain predecessor
        0,    // composed_at unused by this transport-only assertion
        None, // no avatar in this transport-only assertion
    );
    match res {
        Ok(o) => panic!("expected relay-unavailable, but the send succeeded: {}", o.message_id_hex),
        Err(e) => {
            println!("got expected error: {e}");
            assert!(
                e.contains("relay unavailable") && e.contains("-32050"),
                "expected 1b relay-unavailable (-32050), got: {e}"
            );
            println!(
                "✅ 1b: offline relay-2 → guard returned relay-unavailable (-32050) fast, \
                 no forward attempted, no 120s hang"
            );
        }
    }
}
