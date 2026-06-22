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

use rust_core::chat::{chat_fetch, chat_gen_content_key, chat_gen_identity, chat_read_content};
use rust_core::core::{chat_setup_messaging, fetch_balance, send_dot};

const FERDIE_CHAT_SEED: &str = "f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1";
const FERDIE_CONTENT_SEED: &str = "f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2";
const CURVE_P256: u8 = 0;
const DEFAULT_RPC: &str = "ws://127.0.0.1:9944";

fn ferdie_content_key() -> String {
    chat_gen_content_key(CURVE_P256, FERDIE_CONTENT_SEED.to_string())
        .expect("derive Ferdie content key")
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
            let rpc = args.get(2).map(String::as_str).unwrap_or(DEFAULT_RPC).to_string();
            let msgs = chat_fetch(rpc, FERDIE_CHAT_SEED.to_string(), None).expect("fetch");
            println!("fetched {} message(s) for Ferdie", msgs.len());
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
                        "[{i}] id={} from='{}' text='{}'",
                        m.message_id_hex, r.claimed_sender_name, r.plaintext
                    ),
                    Err(e) => println!("[{i}] id={} READ FAILED: {e}", m.message_id_hex),
                }
            }
        }
        _ => {
            eprintln!("usage: labtool <ferdie-keys|ferdie-setup [rpc]|fund <ss58> [amount] [rpc]|ferdie-read [rpc]>");
            std::process::exit(2);
        }
    }
}
