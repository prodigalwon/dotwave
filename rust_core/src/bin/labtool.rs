//! Lab-only box-side helper for the dotwave chat send-test.
//!
//! Impersonates "Ferdie" as a chat recipient using the SAME engine the app
//! uses, so a single phone can send to a named recipient and we can read it
//! back. Also funds a phone's fresh account from the genesis-endowed //Ferdie.
//!
//! Subcommands (rpc defaults to ws://127.0.0.1:9944 — a VALIDATOR, for chain
//! ops; chat send/fetch can target a relay):
//!   ferdie-keys                         print Ferdie's chat address + content key
//!   ferdie-setup   [rpc]                register ferdie.rst + publish CHAT/MESSAGE
//!   fund <ss58> [amount] [rpc]          transfer ROS from //Ferdie to an address
//!   ferdie-read    [rpc]                fetch + read messages addressed to Ferdie
//!
//! Ferdie's chat identity is derived from fixed seeds so setup and read-back
//! agree across runs. These are LAB seeds — never used anywhere real.

use rust_core::chat::{
    chat_deaddrop_pickup, chat_fetch, chat_fetch_at_pickup, chat_fetch_deaddrop,
    chat_gen_content_key, chat_gen_identity, chat_mint_return_pickup, chat_node_info,
    chat_read_content, chat_read_deaddrop, chat_send_deaddrop, chat_send_onion_2hop,
    chat_send_to_pickup,
};
use rust_core::core::{
    chat_mint_test_cert, chat_resolve_identity, chat_setup_messaging, dev_cert_seed_hex,
    fetch_balance, send_dot,
};
use rust_core::dead_drop::DeadDropThread;

const FERDIE_CHAT_SEED: &str = "f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1";
const FERDIE_CONTENT_SEED: &str = "f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2";
// Bob: a second lab identity (Alice = Ferdie) for the ping-pong gate.
const BOB_CHAT_SEED: &str = "b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1";
const BOB_CONTENT_SEED: &str = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";
const CURVE_P256: u8 = 0;
const DEFAULT_RPC: &str = "ws://127.0.0.1:9944";

/// Decode a 32-byte hex pickup key into the array the state machine uses.
fn decode32(h: &str) -> [u8; 32] {
    hex::decode(h.trim_start_matches("0x"))
        .expect("pickup hex")
        .try_into()
        .expect("pickup must be 32 bytes")
}

fn ferdie_content_key() -> String {
    chat_gen_content_key(CURVE_P256, FERDIE_CONTENT_SEED.to_string())
        .expect("derive Ferdie content key")
}

/// First 8 hex chars of a chain hash for compact display (or — if empty).
fn short(h: &str) -> String {
    if h.is_empty() {
        "—".to_string()
    } else {
        h.chars().take(8).collect()
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map(String::as_str).unwrap_or("");
    match cmd {
        "ferdie-keys" => {
            let id = chat_gen_identity(FERDIE_CHAT_SEED.to_string()).expect("gen identity");
            println!("ferdie chat address (ed25519): {}", id.ed25519_pubkey_hex);
            println!("ferdie content key:            {}", ferdie_content_key());
        }
        "ferdie-setup" => {
            let rpc = args.get(2).map(String::as_str).unwrap_or(DEFAULT_RPC).to_string();
            let id = chat_gen_identity(FERDIE_CHAT_SEED.to_string()).expect("gen identity");
            let ck = ferdie_content_key();
            println!("registering ferdie.rst on {rpc} ...");
            match chat_setup_messaging(
                "ferdie".to_string(),
                "//Ferdie".to_string(),
                rpc,
                FERDIE_CHAT_SEED.to_string(),
                ck.clone(),
            ) {
                Ok(o) => println!("setup ok: published={} name=ferdie.rst", o.published),
                Err(e) => {
                    eprintln!("setup FAILED: {e}");
                    std::process::exit(1);
                }
            }
            println!("--- paste these into the app's New Conversation if not resolving by name ---");
            println!("chat address: {}", id.ed25519_pubkey_hex);
            println!("content key:  {ck}");
        }
        "fund" => {
            let ss58 = args.get(2).expect("usage: fund <ss58> [amount] [rpc]").clone();
            let amount = args.get(3).cloned().unwrap_or_else(|| "1000000000000000".to_string()); // 1000 ROS @ 12dp
            let rpc = args.get(4).map(String::as_str).unwrap_or(DEFAULT_RPC).to_string();
            println!("funding {ss58} with {amount} planck from //Ferdie via {rpc} ...");
            match send_dot(ss58, amount, "//Ferdie".to_string(), rpc) {
                Ok(h) => println!("transfer submitted: {h}"),
                Err(e) => {
                    eprintln!("fund FAILED: {e}");
                    std::process::exit(1);
                }
            }
        }
        "balance" => {
            let ss58 = args.get(2).expect("usage: balance <ss58> [rpc]").clone();
            let rpc = args.get(3).map(String::as_str).unwrap_or(DEFAULT_RPC).to_string();
            match fetch_balance(ss58.clone(), rpc) {
                Ok(b) => println!("{ss58} balance: {b}"),
                Err(e) => {
                    eprintln!("balance FAILED: {e}");
                    std::process::exit(1);
                }
            }
        }
        "ferdie-read" => {
            use std::collections::{HashMap, HashSet};
            let rpc = args.get(2).map(String::as_str).unwrap_or(DEFAULT_RPC).to_string();
            let msgs = chat_fetch(rpc, FERDIE_CHAT_SEED.to_string(), None).expect("fetch");
            println!("fetched {} message(s) for Ferdie (FETCH order):", msgs.len());

            // Decode each, keeping the in-seal self-hash ordering chain.
            struct Rm {
                body: String,
                composed_at: u64,
                self_hash: String,
                prev: String,
            }
            let mut read: Vec<Rm> = Vec::new();
            for (i, m) in msgs.iter().enumerate() {
                match chat_read_content(
                    m.sealed_content_hex.clone(),
                    CURVE_P256,
                    FERDIE_CONTENT_SEED.to_string(),
                    None,
                    FERDIE_CHAT_SEED.to_string(),
                    vec![],
                ) {
                    Ok(r) => {
                        let from_name = if r.claimed_sender_name.is_empty() {
                            "(anonymous)".to_string()
                        } else {
                            format!("{}.rst", r.claimed_sender_name)
                        };
                        println!(
                            "  [fetch {i}] text='{}'  from={}  from_pubkey={}  composed_at={}  self={}  prev={}",
                            r.plaintext,
                            from_name,
                            m.sender_pubkey_hex,
                            r.composed_at,
                            short(&r.self_hash_hex),
                            short(&r.prev_self_hash_hex),
                        );
                        read.push(Rm {
                            body: r.plaintext,
                            composed_at: r.composed_at,
                            self_hash: r.self_hash_hex,
                            prev: r.prev_self_hash_hex,
                        });
                    }
                    Err(e) => println!("  [fetch {i}] id={} READ FAILED: {e}", m.message_id_hex),
                }
            }

            // Reconstruct send order from the chain — the same algorithm the
            // app's `orderThread` runs (single inbound sender here): segments
            // from prev->self links, ordered by head composed_at; gap/reset flagged.
            let by_self: HashMap<&str, ()> =
                read.iter().map(|r| (r.self_hash.as_str(), ())).collect();
            let mut next: HashMap<&str, usize> = HashMap::new();
            for (i, r) in read.iter().enumerate() {
                if !r.prev.is_empty() {
                    next.insert(r.prev.as_str(), i);
                }
            }
            let mut heads: Vec<usize> = (0..read.len())
                .filter(|&i| {
                    read[i].prev.is_empty() || !by_self.contains_key(read[i].prev.as_str())
                })
                .collect();
            heads.sort_by_key(|&i| read[i].composed_at);

            println!("\n--- RECONSTRUCTED send order (self-hash chain) ---");
            let mut seen: HashSet<usize> = HashSet::new();
            let mut pos = 1;
            for &h in &heads {
                let mut cur = Some(h);
                let mut first = true;
                while let Some(i) = cur {
                    if !seen.insert(i) {
                        break;
                    }
                    let r = &read[i];
                    let mark = if first
                        && !r.prev.is_empty()
                        && !by_self.contains_key(r.prev.as_str())
                    {
                        "   <- GAP (a predecessor didn't arrive)"
                    } else if first && r.prev.is_empty() && pos > 1 {
                        "   <- RESUMPTION (sender chain reset)"
                    } else {
                        ""
                    };
                    println!("  {pos:>2}. '{}'{mark}", r.body);
                    pos += 1;
                    first = false;
                    cur = next.get(r.self_hash.as_str()).copied();
                }
            }
        }
        "ferdie-send" => {
            // ferdie-send [count] [start] [guard_rpc] [relay2_rpc] [chain_rpc]
            // Replies to whoever last messaged Ferdie, sending `count` CHAINED
            // messages (bodies start..start+count) so the phone can prove
            // in-order RECEIVE. Defaults: 5 msgs from 21, guard 9954 / relay-2
            // 9955 / chain 9944.
            let count: u32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(5);
            let start: u32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(21);
            let guard = args.get(4).map(String::as_str).unwrap_or("ws://127.0.0.1:9954").to_string();
            let relay2 = args.get(5).map(String::as_str).unwrap_or("ws://127.0.0.1:9955").to_string();
            let chain = args.get(6).map(String::as_str).unwrap_or(DEFAULT_RPC).to_string();

            // 1. Auto-detect the recipient: reply to whoever last messaged Ferdie.
            let inbox = chat_fetch(guard.clone(), FERDIE_CHAT_SEED.to_string(), None).expect("fetch inbox");
            let mut recipient_name = String::new();
            let mut recipient_pubkey = String::new();
            for m in inbox.iter().rev() {
                if let Ok(r) = chat_read_content(
                    m.sealed_content_hex.clone(),
                    CURVE_P256,
                    FERDIE_CONTENT_SEED.to_string(),
                    None,
                    FERDIE_CHAT_SEED.to_string(),
                    vec![],
                ) {
                    if !r.claimed_sender_name.is_empty() {
                        recipient_name = r.claimed_sender_name;
                        recipient_pubkey = m.sender_pubkey_hex.clone();
                        break;
                    }
                }
            }
            if recipient_name.is_empty() {
                eprintln!("no named sender in Ferdie's inbox to reply to — have the phone \
                           send a message first (with a registered name)");
                std::process::exit(1);
            }
            println!("replying to '{recipient_name}' (pubkey {})", short(&recipient_pubkey));

            // 2. Resolve the recipient's published identity → content key.
            let resolved = chat_resolve_identity(recipient_name.clone(), chain.clone())
                .expect("resolve recipient");
            if !resolved.found || !resolved.has_message_key {
                eprintln!("recipient '{recipient_name}' has no published MESSAGE content key — \
                           can't seal to it");
                std::process::exit(1);
            }
            // Impersonation guard: the resolved CHAT key must equal the verified
            // sender pubkey of the message we're replying to.
            if resolved.ed25519_pubkey_hex != recipient_pubkey {
                eprintln!("resolved CHAT key != sender pubkey — refusing to send");
                std::process::exit(1);
            }

            // 3. Ensure Ferdie holds an Active admission cert (idempotent).
            let cert_seed = dev_cert_seed_hex("//Ferdie".to_string());
            let thumbprint =
                chat_mint_test_cert(chain.clone(), "//Ferdie".to_string(), cert_seed.clone(), 1_000_000)
                    .expect("mint ferdie cert");
            println!("ferdie cert thumbprint: {}", short(&thumbprint));

            // 4. Node identities for the 2-hop onion.
            let guard_pk = chat_node_info(guard.clone()).expect("guard node info");
            let relay2_pk = chat_node_info(relay2.clone()).expect("relay-2 node info");

            // 5. Send `count` CHAINED messages (prev = previous self_hash) so the
            //    phone reconstructs send-order from the chain.
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
            let mut prev: Option<String> = None;
            for k in 0..count {
                let body = format!("{}", start + k);
                let outcome = chat_send_onion_2hop(
                    guard.clone(),
                    guard_pk.clone(),
                    relay2_pk.clone(),
                    FERDIE_CHAT_SEED.to_string(),
                    resolved.ed25519_pubkey_hex.clone(),
                    resolved.inner_content_key_hex.clone(),
                    body.clone(),
                    "ferdie.rst".to_string(),
                    5,
                    Some(thumbprint.clone()),
                    Some(cert_seed.clone()),
                    prev.clone(),
                    now + k as u64,
                )
                .expect("send onion");
                println!(
                    "  sent '{body}' -> msg_id {} self={} prev={}",
                    short(&outcome.message_id_hex),
                    short(&outcome.new_self_hash_hex),
                    prev.as_deref().map(short).unwrap_or_else(|| "—".to_string()),
                );
                prev = Some(outcome.new_self_hash_hex);
            }
            println!("done — refresh the conversation in the app to receive these {count} message(s) from ferdie.rst");
        }
        "ferdie-say" => {
            // ferdie-say "<text>" [guard] [relay2] [chain]
            // Reply to the last NAMED sender with ONE custom-text message, sealed
            // to their resolved MESSAGE content key — the CHAT/MESSAGE record path
            // (vs ferdie-send-to's out-of-band key). Requires the phone to have
            // registered keys + sent a message carrying its .rst name.
            let text = args.get(2).expect("need \"<text>\"").to_string();
            let guard = args.get(3).map(String::as_str).unwrap_or("ws://127.0.0.1:9954").to_string();
            let relay2 = args.get(4).map(String::as_str).unwrap_or("ws://127.0.0.1:9955").to_string();
            let chain = args.get(5).map(String::as_str).unwrap_or(DEFAULT_RPC).to_string();

            // 1. Auto-detect the recipient: the last NAMED sender in Ferdie's inbox.
            let inbox = chat_fetch(guard.clone(), FERDIE_CHAT_SEED.to_string(), None).expect("fetch inbox");
            let mut recipient_name = String::new();
            let mut recipient_pubkey = String::new();
            for m in inbox.iter().rev() {
                if let Ok(r) = chat_read_content(
                    m.sealed_content_hex.clone(),
                    CURVE_P256,
                    FERDIE_CONTENT_SEED.to_string(),
                    None,
                    FERDIE_CHAT_SEED.to_string(),
                    vec![],
                ) {
                    if !r.claimed_sender_name.is_empty() {
                        recipient_name = r.claimed_sender_name;
                        recipient_pubkey = m.sender_pubkey_hex.clone();
                        break;
                    }
                }
            }
            if recipient_name.is_empty() {
                eprintln!("no NAMED sender in Ferdie's inbox — the phone must register its \
                           keys (Register Keys) and send a message so it carries its .rst name \
                           (or use ferdie-send-to with an out-of-band key)");
                std::process::exit(1);
            }
            println!("replying to '{recipient_name}.rst' (pubkey {})", short(&recipient_pubkey));

            // 2. Resolve the recipient's published CHAT + MESSAGE.
            let resolved = chat_resolve_identity(recipient_name.clone(), chain.clone())
                .expect("resolve recipient");
            if !resolved.found || !resolved.has_message_key {
                eprintln!("recipient '{recipient_name}' has no published MESSAGE content key");
                std::process::exit(1);
            }
            // Impersonation guard: resolved CHAT key must equal the sender we reply to.
            if resolved.ed25519_pubkey_hex != recipient_pubkey {
                eprintln!("resolved CHAT key != sender pubkey — refusing to send");
                std::process::exit(1);
            }

            // 3. Ferdie's admission cert (idempotent), then 2-hop onion identities.
            let cert_seed = dev_cert_seed_hex("//Ferdie".to_string());
            let thumbprint =
                chat_mint_test_cert(chain.clone(), "//Ferdie".to_string(), cert_seed.clone(), 1_000_000)
                    .expect("mint ferdie cert");
            let guard_pk = chat_node_info(guard.clone()).expect("guard node info");
            let relay2_pk = chat_node_info(relay2.clone()).expect("relay-2 node info");

            // 4. Send the one custom-text message (fresh chain).
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
            let outcome = chat_send_onion_2hop(
                guard.clone(),
                guard_pk,
                relay2_pk,
                FERDIE_CHAT_SEED.to_string(),
                resolved.ed25519_pubkey_hex.clone(),
                resolved.inner_content_key_hex.clone(),
                text.clone(),
                "ferdie".to_string(),
                5,
                Some(thumbprint),
                Some(cert_seed),
                None,
                now,
            )
            .expect("send onion");
            println!(
                "sent '{text}' -> '{recipient_name}.rst'  msg_id {} self={}",
                short(&outcome.message_id_hex),
                short(&outcome.new_self_hash_hex),
            );
            println!("refresh the conversation in the app to receive it.");
        }
        "ferdie-send-to" => {
            // ferdie-send-to <recipient_pubkey_hex> <content_key_hex> [count] [start]
            //                [guard_rpc] [relay2_rpc] [chain_rpc]
            // Out-of-band recipient (no published name needed): the phone's
            // "Your chat address" + "Your content key" from the app's identity
            // card. Sends `count` CHAINED messages (bodies start..start+count).
            let recipient_pubkey = args.get(2).expect("need <recipient_pubkey_hex>").trim_start_matches("0x").to_string();
            let content_key = args.get(3).expect("need <content_key_hex>").trim_start_matches("0x").to_string();
            let count: u32 = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(5);
            let start: u32 = args.get(5).and_then(|s| s.parse().ok()).unwrap_or(21);
            let guard = args.get(6).map(String::as_str).unwrap_or("ws://127.0.0.1:9954").to_string();
            let relay2 = args.get(7).map(String::as_str).unwrap_or("ws://127.0.0.1:9955").to_string();
            let chain = args.get(8).map(String::as_str).unwrap_or(DEFAULT_RPC).to_string();

            // Ferdie's admission cert (idempotent).
            let cert_seed = dev_cert_seed_hex("//Ferdie".to_string());
            let thumbprint =
                chat_mint_test_cert(chain.clone(), "//Ferdie".to_string(), cert_seed.clone(), 1_000_000)
                    .expect("mint ferdie cert");
            println!("ferdie cert thumbprint: {}", short(&thumbprint));

            let guard_pk = chat_node_info(guard.clone()).expect("guard node info");
            let relay2_pk = chat_node_info(relay2.clone()).expect("relay-2 node info");

            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
            let mut prev: Option<String> = None;
            for k in 0..count {
                let body = format!("{}", start + k);
                let outcome = chat_send_onion_2hop(
                    guard.clone(),
                    guard_pk.clone(),
                    relay2_pk.clone(),
                    FERDIE_CHAT_SEED.to_string(),
                    recipient_pubkey.clone(),
                    content_key.clone(),
                    body.clone(),
                    "ferdie.rst".to_string(),
                    5,
                    Some(thumbprint.clone()),
                    Some(cert_seed.clone()),
                    prev.clone(),
                    now + k as u64,
                )
                .expect("send onion");
                println!(
                    "  sent '{body}' -> msg_id {} self={} prev={}",
                    short(&outcome.message_id_hex),
                    short(&outcome.new_self_hash_hex),
                    prev.as_deref().map(short).unwrap_or_else(|| "—".to_string()),
                );
                prev = Some(outcome.new_self_hash_hex);
            }
            println!("done — refresh the conversation with ferdie.rst in the app to receive {count} message(s)");
        }
        "deaddrop-send-to" => {
            // deaddrop-send-to <label> <recipient_pubkey_hex> <content_key_hex>
            //                  [count] [start] [guard] [relay2] [chain]
            // A DEAD DROP: routed by `label` (callsign) instead of recipient
            // identity, sealed to the recipient's REAL out-of-band keys. The
            // recipient polls with `deaddrop-poll <label>`.
            let label = args.get(2).expect("need <label>").to_string();
            let recipient_pubkey = args.get(3).expect("need <recipient_pubkey_hex>").trim_start_matches("0x").to_string();
            let content_key = args.get(4).expect("need <content_key_hex>").trim_start_matches("0x").to_string();
            let count: u32 = args.get(5).and_then(|s| s.parse().ok()).unwrap_or(1);
            let start: u32 = args.get(6).and_then(|s| s.parse().ok()).unwrap_or(21);
            let guard = args.get(7).map(String::as_str).unwrap_or("ws://127.0.0.1:9954").to_string();
            let relay2 = args.get(8).map(String::as_str).unwrap_or("ws://127.0.0.1:9955").to_string();
            let chain = args.get(9).map(String::as_str).unwrap_or(DEFAULT_RPC).to_string();

            let cert_seed = dev_cert_seed_hex("//Ferdie".to_string());
            let thumbprint =
                chat_mint_test_cert(chain.clone(), "//Ferdie".to_string(), cert_seed.clone(), 1_000_000)
                    .expect("mint ferdie cert");
            println!("ferdie cert thumbprint: {}", short(&thumbprint));
            let guard_pk = chat_node_info(guard.clone()).expect("guard node info");
            let relay2_pk = chat_node_info(relay2.clone()).expect("relay-2 node info");

            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
            let mut prev: Option<String> = None;
            for k in 0..count {
                let body = format!("{}", start + k);
                let outcome = chat_send_deaddrop(
                    guard.clone(),
                    guard_pk.clone(),
                    relay2_pk.clone(),
                    FERDIE_CHAT_SEED.to_string(),
                    recipient_pubkey.clone(),
                    content_key.clone(),
                    label.clone(),
                    body.clone(),
                    "ferdie.rst".to_string(),
                    5,
                    Some(thumbprint.clone()),
                    Some(cert_seed.clone()),
                    prev.clone(),
                    now + k as u64,
                )
                .expect("send dead drop");
                println!(
                    "  dead-drop '{body}' -> label='{label}' msg_id {} self={} prev={}",
                    short(&outcome.message_id_hex),
                    short(&outcome.new_self_hash_hex),
                    prev.as_deref().map(short).unwrap_or_else(|| "—".to_string()),
                );
                prev = Some(outcome.new_self_hash_hex);
            }
            println!("done — poll with: labtool deaddrop-poll {label}");
        }
        "deaddrop-poll" => {
            // deaddrop-poll <label> [guard]
            // Poll a dead-drop label as Ferdie (the recipient), decrypting
            // with Ferdie's REAL seed — the label is only routing.
            let label = args.get(2).expect("need <label>").to_string();
            let guard = args.get(3).map(String::as_str).unwrap_or("ws://127.0.0.1:9954").to_string();
            let msgs = chat_fetch_deaddrop(guard, FERDIE_CHAT_SEED.to_string(), label.clone(), None)
                .expect("fetch dead drop");
            println!("fetched {} message(s) at dead-drop label='{label}':", msgs.len());
            for (i, m) in msgs.iter().enumerate() {
                match chat_read_content(
                    m.sealed_content_hex.clone(),
                    CURVE_P256,
                    FERDIE_CONTENT_SEED.to_string(),
                    None,
                    FERDIE_CHAT_SEED.to_string(),
                    vec![],
                ) {
                    Ok(r) => println!(
                        "  [{i}] text='{}'  from_pubkey={}  composed_at={}  self={}",
                        r.plaintext, m.sender_pubkey_hex, r.composed_at, short(&r.self_hash_hex),
                    ),
                    Err(e) => println!("  [{i}] id={} READ FAILED: {e}", m.message_id_hex),
                }
            }
        }
        "deaddrop-pingpong" => {
            // deaddrop-pingpong <label> [rounds] [guard] [relay2] [chain]
            // Alice (Ferdie) opens to callsign <label>; the conversation then
            // walks rotating return addresses for <rounds> turns each way,
            // driven by the dead_drop::DeadDropThread state machine. GATE:
            // the callsign bucket must hold EXACTLY ONE drop (the opener) at
            // the end — every reply rides a rotating return address.
            let label = args.get(2).expect("need <label>").to_string();
            let rounds: u32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(3);
            let guard = args.get(4).map(String::as_str).unwrap_or("ws://127.0.0.1:9954").to_string();
            let relay2 = args.get(5).map(String::as_str).unwrap_or("ws://127.0.0.1:9955").to_string();
            let chain = args.get(6).map(String::as_str).unwrap_or(DEFAULT_RPC).to_string();

            let alice = chat_gen_identity(FERDIE_CHAT_SEED.to_string()).expect("alice id");
            let alice_ck = ferdie_content_key();
            let bob = chat_gen_identity(BOB_CHAT_SEED.to_string()).expect("bob id");
            let bob_ck = chat_gen_content_key(CURVE_P256, BOB_CONTENT_SEED.to_string()).expect("bob ck");

            let alice_cert_seed = dev_cert_seed_hex("//Ferdie".to_string());
            let alice_thumb = chat_mint_test_cert(chain.clone(), "//Ferdie".to_string(), alice_cert_seed.clone(), 1_000_000).expect("alice cert");
            let bob_cert_seed = dev_cert_seed_hex("//Eve".to_string());
            let bob_thumb = chat_mint_test_cert(chain.clone(), "//Eve".to_string(), bob_cert_seed.clone(), 1_000_000).expect("bob cert");

            let guard_pk = chat_node_info(guard.clone()).expect("guard node info");
            let relay2_pk = chat_node_info(relay2.clone()).expect("relay2 node info");
            let base_ts = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();

            // Poll a set of buckets as `seed`/`content_seed` until one decodes;
            // returns (plaintext, advertised return_pickup_hex).
            let poll_first = |pickups: Vec<String>, seed: &str, content_seed: &str, who: &str| -> (String, String) {
                for _attempt in 0..12 {
                    for pk in &pickups {
                        let msgs = chat_fetch_at_pickup(guard.clone(), seed.to_string(), pk.clone(), None).unwrap_or_default();
                        for m in &msgs {
                            if let Ok(r) = chat_read_deaddrop(m.sealed_content_hex.clone(), CURVE_P256, content_seed.to_string()) {
                                return (r.plaintext, r.return_pickup_hex);
                            }
                        }
                    }
                    std::thread::sleep(std::time::Duration::from_secs(2));
                }
                panic!("{who}: no message at {} bucket(s) after retries", pickups.len());
            };
            let enc = |v: &[[u8; 32]]| v.iter().map(hex::encode).collect::<Vec<_>>();

            // OPENER: Alice -> for_deaddrop(label), advertising A1.
            let callsign_pickup = chat_deaddrop_pickup(label.clone());
            let a1 = chat_mint_return_pickup();
            let mut alice_t = DeadDropThread::open(decode32(&callsign_pickup), decode32(&a1));
            let mut bob_t = DeadDropThread::responder();
            chat_send_to_pickup(
                guard.clone(), guard_pk.clone(), relay2_pk.clone(),
                FERDIE_CHAT_SEED.to_string(), bob.ed25519_pubkey_hex.clone(), bob_ck.clone(),
                callsign_pickup.clone(), a1.clone(),
                "open".to_string(), "alice".to_string(), 5,
                Some(alice_thumb.clone()), Some(alice_cert_seed.clone()), None, base_ts,
            ).expect("opener");
            println!("opener: alice -> callsign '{label}' (bucket {}) advertising A1={}", short(&callsign_pickup), short(&a1));

            let mut ts = base_ts + 1;
            for round in 1..=rounds {
                // Bob's turn: receive (callsign on round 1, else his inbound+grace), reply.
                let bob_polls = if bob_t.inbound_current.is_none() { vec![callsign_pickup.clone()] } else { enc(&bob_t.poll_set()) };
                let (_btxt, alice_ret) = poll_first(bob_polls, BOB_CHAT_SEED, BOB_CONTENT_SEED, "bob");
                let b_new = chat_mint_return_pickup();
                bob_t.on_turn(decode32(&alice_ret), decode32(&b_new));
                let b_target = hex::encode(bob_t.outbound_target.unwrap());
                chat_send_to_pickup(
                    guard.clone(), guard_pk.clone(), relay2_pk.clone(),
                    BOB_CHAT_SEED.to_string(), alice.ed25519_pubkey_hex.clone(), alice_ck.clone(),
                    b_target.clone(), b_new.clone(),
                    format!("bob-{round}"), "bob".to_string(), 5,
                    Some(bob_thumb.clone()), Some(bob_cert_seed.clone()), None, ts,
                ).expect("bob reply");
                ts += 1;
                println!("  round {round}: bob recv A-ret={} -> reply to {} advertising B={}", short(&alice_ret), short(&b_target), short(&b_new));

                // Alice's turn: receive on her poll set (current + grace), reply.
                let (_atxt, bob_ret) = poll_first(enc(&alice_t.poll_set()), FERDIE_CHAT_SEED, FERDIE_CONTENT_SEED, "alice");
                let a_new = chat_mint_return_pickup();
                alice_t.on_turn(decode32(&bob_ret), decode32(&a_new));
                let a_target = hex::encode(alice_t.outbound_target.unwrap());
                chat_send_to_pickup(
                    guard.clone(), guard_pk.clone(), relay2_pk.clone(),
                    FERDIE_CHAT_SEED.to_string(), bob.ed25519_pubkey_hex.clone(), bob_ck.clone(),
                    a_target.clone(), a_new.clone(),
                    format!("alice-{round}"), "alice".to_string(), 5,
                    Some(alice_thumb.clone()), Some(alice_cert_seed.clone()), None, ts,
                ).expect("alice reply");
                ts += 1;
                println!("  round {round}: alice recv B-ret={} -> reply to {} advertising A={} (alice grace={})", short(&bob_ret), short(&a_target), short(&a_new), alice_t.grace.len());
            }

            // GATE: the callsign bucket holds exactly ONE drop (the opener).
            std::thread::sleep(std::time::Duration::from_secs(3));
            let callsign_msgs = chat_fetch_at_pickup(guard.clone(), BOB_CHAT_SEED.to_string(), callsign_pickup.clone(), None).unwrap_or_default();
            println!();
            println!("=== GATE: callsign '{label}' bucket holds {} drop(s) after {rounds} round(s) each way ===", callsign_msgs.len());
            if callsign_msgs.len() == 1 {
                println!(">>> PASS: the callsign saw exactly the opener; all replies rode rotating return addresses");
            } else {
                println!(">>> FAIL: expected exactly 1 drop in the callsign bucket, got {}", callsign_msgs.len());
                std::process::exit(1);
            }
        }
        _ => {
            eprintln!("usage: labtool <ferdie-keys|ferdie-setup [rpc]|fund <ss58> [amount] [rpc]|ferdie-read [rpc]|ferdie-send [count] [start] ...|ferdie-say \"<text>\" [guard] [relay2] [chain]|ferdie-send-to <pubkey> <content_key> [count] [start] ...|deaddrop-send-to <label> <pubkey> <content_key> [count] [start] ...|deaddrop-poll <label> [guard]|deaddrop-pingpong <label> [rounds] [guard] [relay2] [chain]>");
            std::process::exit(2);
        }
    }
}
