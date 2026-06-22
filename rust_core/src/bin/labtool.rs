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
    chat_fetch, chat_gen_content_key, chat_gen_identity, chat_node_info, chat_read_content,
    chat_send_onion_2hop,
};
use rust_core::core::{
    chat_mint_test_cert, chat_resolve_identity, chat_setup_messaging, dev_cert_seed_hex,
    fetch_balance, send_dot,
};

const FERDIE_CHAT_SEED: &str = "f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1";
const FERDIE_CONTENT_SEED: &str = "f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2";
const CURVE_P256: u8 = 0;
const DEFAULT_RPC: &str = "ws://127.0.0.1:9944";

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
                        println!(
                            "  [fetch {i}] text='{}'  from_pubkey={}  composed_at={}  self={}  prev={}",
                            r.plaintext,
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
        _ => {
            eprintln!("usage: labtool <ferdie-keys|ferdie-setup [rpc]|fund <ss58> [amount] [rpc]|ferdie-read [rpc]|ferdie-send [count] [start] ...|ferdie-send-to <pubkey> <content_key> [count] [start] ...>");
            std::process::exit(2);
        }
    }
}
