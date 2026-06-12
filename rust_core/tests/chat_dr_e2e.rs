// Phase 5 end-to-end on the live fabric: one-time-prekey mailbox +
// full X3DH + Double Ratchet thread, with sessions carried ONLY as
// persisted state strings (every step is an implicit app restart).
//
// Prereq: the R2 fabric — validator (--dev, 9944) + 3 relays
// (9954/9955/9956). Run:
//   cargo test --test chat_dr_e2e -- --nocapture --ignored --test-threads=1

use std::time::Duration;

use rust_core::chat::{chat_fetch, chat_gen_content_key, chat_gen_identity, chat_read_content, chat_send};
use rust_core::chat_dr::{
    chat_dr_fetch_opk, chat_dr_gen_prekeys, chat_dr_initiate, chat_dr_publish_opks, DrOpkSecret,
};
use rust_core::core::{chat_mint_test_cert, dev_cert_seed_hex};

const VALIDATOR: &str = "ws://127.0.0.1:9944";
const RELAY_SEND: &str = "ws://127.0.0.1:9954";
const RELAY_FETCH: &str = "ws://127.0.0.1:9956";

fn fetch_one(
    rpc: &str,
    seed: &str,
    message_id: &str,
) -> rust_core::chat::AtRestMessage {
    for _ in 0..20 {
        let msgs = chat_fetch(rpc.into(), seed.into(), None).expect("fetch");
        if let Some(m) = msgs.into_iter().find(|m| m.message_id_hex == message_id) {
            return m;
        }
        std::thread::sleep(Duration::from_secs(2));
    }
    panic!("message {message_id} never recovered");
}

/// The full Phase-5 story: Bob publishes prekeys (SPK implicit via
/// gen + OPK batch to his public mailbox); Alice fetches an OPK, runs
/// full X3DH, sends a forward-secret first message; Bob bootstraps
/// his session from the carried init + his stored OPK secret; a
/// multi-message two-way thread then ratchets, with both sessions
/// surviving as persisted strings only.
#[test]
#[ignore = "requires the R2 fabric (validator 9944 + relays 9954/9956)"]
fn full_x3dh_opk_thread_on_fabric() {
    let alice_seed = "a1".repeat(32);
    let bob_seed = "b2".repeat(32);
    let alice_id = chat_gen_identity(alice_seed.clone()).expect("alice id");
    let bob_id = chat_gen_identity(bob_seed.clone()).expect("bob id");
    let alice_content_seed = "a3".repeat(32);
    let bob_content_seed = "b4".repeat(32);
    let alice_content_key = chat_gen_content_key(0, alice_content_seed.clone()).unwrap();
    let bob_content_key = chat_gen_content_key(0, bob_content_seed.clone()).unwrap();

    let cert_seed = dev_cert_seed_hex("//Ferdie".into());
    let thumbprint =
        chat_mint_test_cert(VALIDATOR.into(), "//Ferdie".into(), cert_seed.clone(), 600_000)
            .expect("mint cert");
    let auth = (Some(thumbprint), Some(cert_seed));

    // 1. Bob generates + publishes a 4-OPK batch to his public mailbox.
    let bob_prekeys = chat_dr_gen_prekeys(bob_seed.clone(), 100, 4).expect("gen prekeys");
    let bob_opk_secrets: Vec<DrOpkSecret> = bob_prekeys.opk_secrets;
    let mut published = false;
    for attempt in 0..15 {
        match chat_dr_publish_opks(
            RELAY_SEND.into(),
            bob_seed.clone(),
            bob_prekeys.opk_bundle_hex.clone(),
            5,
            auth.0.clone(),
            auth.1.clone(),
        ) {
            Ok(o) => {
                println!("OPK batch published: msg {}", o.message_id_hex);
                published = true;
                break;
            }
            Err(e) => {
                println!("publish attempt {attempt}: {e}");
                std::thread::sleep(Duration::from_secs(2));
            }
        }
    }
    assert!(published, "OPK batch never published");

    // 2. Alice fetches an OPK from Bob's mailbox (cross-node).
    let mut opk = None;
    for _ in 0..20 {
        let f = chat_dr_fetch_opk(
            RELAY_FETCH.into(),
            bob_id.ed25519_pubkey_hex.clone(),
            Vec::new(),
        )
        .expect("fetch opk");
        if f.found {
            opk = Some(f);
            break;
        }
        std::thread::sleep(Duration::from_secs(2));
    }
    let opk = opk.expect("no OPK found in Bob's mailbox");
    println!("alice picked OPK id={}", opk.id);

    // 3. Full X3DH with the OPK (Bob's SPK comes from his prekey
    //    derivation — record-driven variant covered elsewhere).
    let init = chat_dr_initiate(
        alice_seed.clone(),
        bob_id.ed25519_pubkey_hex.clone(),
        bob_prekeys.spk_pubkey_hex.clone(),
        bob_prekeys.spk_signature_hex.clone(),
        Some(opk.id),
        Some(opk.pubkey_hex.clone()),
    )
    .expect("x3dh initiate with OPK");
    let mut alice_session = init.session_state_hex.clone();

    // 4. Alice → Bob, first message (forward-secret before any reply).
    let m1_body = "first message, forward-secret, OPK-bound".to_string();
    let m1 = chat_send(
        RELAY_SEND.into(),
        alice_seed.clone(),
        bob_id.ed25519_pubkey_hex.clone(),
        bob_content_key.clone(),
        m1_body.clone(),
        String::new(),
        5,
        alice_session.clone(),
        Some(init.x3dh_init_hex.clone()),
        auth.0.clone(),
        auth.1.clone(),
    )
    .expect("alice m1");
    alice_session = m1.new_session_state_hex.clone();

    // 5. Bob reads it: responder bootstrap consumes his stored OPK
    //    secret matching the carried opk_id.
    let m1_at_rest = fetch_one(RELAY_FETCH, &bob_seed, &m1.message_id_hex);
    let m1_read = chat_read_content(
        m1_at_rest.sealed_content_hex,
        0,
        bob_content_seed.clone(),
        None,
        bob_seed.clone(),
        bob_opk_secrets,
    )
    .expect("bob reads m1");
    assert_eq!(m1_read.plaintext, m1_body);
    assert!(m1_read.ratcheted);
    let mut bob_session = m1_read.new_session_state_hex.clone();

    // 6. Two-way thread: each leg uses only the persisted state from
    //    the previous step (implicit restart every message).
    let legs: [(&str, bool); 3] = [
        ("bob: got it, ratcheting back", false), // bob → alice (DH ratchet)
        ("alice: chain two", true),              // alice → bob
        ("bob: chain three", false),             // bob → alice
    ];
    for (body, alice_sends) in legs {
        let (sender_seed, recipient_id, recipient_ckey, session) = if alice_sends {
            (&alice_seed, &bob_id, &bob_content_key, &mut alice_session)
        } else {
            (&bob_seed, &alice_id, &alice_content_key, &mut bob_session)
        };
        let out = chat_send(
            RELAY_SEND.into(),
            sender_seed.clone(),
            recipient_id.ed25519_pubkey_hex.clone(),
            recipient_ckey.clone(),
            body.to_string(),
            String::new(),
            5,
            session.clone(),
            None,
            auth.0.clone(),
            auth.1.clone(),
        )
        .unwrap_or_else(|e| panic!("send '{body}': {e}"));
        *session = out.new_session_state_hex.clone();

        let (reader_seed, reader_cseed, reader_session) = if alice_sends {
            (&bob_seed, &bob_content_seed, &mut bob_session)
        } else {
            (&alice_seed, &alice_content_seed, &mut alice_session)
        };
        let at_rest = fetch_one(RELAY_FETCH, reader_seed, &out.message_id_hex);
        let read = chat_read_content(
            at_rest.sealed_content_hex,
            0,
            reader_cseed.clone(),
            Some(reader_session.clone()),
            reader_seed.clone(),
            Vec::new(),
        )
        .unwrap_or_else(|e| panic!("read '{body}': {e}"));
        assert_eq!(read.plaintext, body);
        *reader_session = read.new_session_state_hex.clone();
        println!("leg OK: {body}");
    }

    println!(
        "✅ Phase-5 e2e: OPK mailbox → full X3DH → forward-secret first message → \
         4-leg ratcheting thread, sessions persisted as state strings throughout"
    );
}
