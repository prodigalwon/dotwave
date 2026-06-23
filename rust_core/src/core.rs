use bip39::{Mnemonic, Language};
use sp_core::{sr25519, Pair};
use argon2::{Argon2, Algorithm, Version, Params};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce, aead::{Aead, KeyInit}};
use getrandom::fill as getrandom_fill;
use zeroize::Zeroize;
use zxcvbn::zxcvbn;
use subxt::{OnlineClient, Config};
use subxt::backend::{LegacyBackend, LegacyBackendBuilder};
use crate::rostro_config::RostroConfig;
use subxt::utils::{AccountId32, MultiAddress, MultiSignature};
use std::str::FromStr;
use std::sync::Arc;

/// Connect to a Rostro (gemini-node) RPC endpoint via the Legacy backend.
///
/// We avoid `OnlineClient::from_insecure_url` because that constructs
/// `CombinedBackend`, which tries `chainHead_v1_*` first. The gemini-node
/// RPC server doesn't serve those methods, so the CombinedBackend's
/// `latest_finalized_block_ref` silently hangs forever waiting for
/// `chainHead` events that never arrive.
async fn connect_rostro(rpc_url: &str) -> Result<OnlineClient<RostroConfig>, String> {
    connect_rostro_with_rpc(rpc_url).await.map(|(api, _)| api)
}

/// Same as `connect_rostro` but also returns the underlying RpcClient
/// handle. Needed when we want to make raw JSON-RPC calls (e.g.
/// `system_accountNextIndex` to dodge subxt's at-finalized nonce-fetch
/// model on stalled-finality dev nodes).
pub(crate) async fn connect_rostro_with_rpc(
    rpc_url: &str,
) -> Result<(OnlineClient<RostroConfig>, subxt::rpcs::RpcClient), String> {
    let rpc_client = subxt::rpcs::RpcClient::from_insecure_url(rpc_url)
        .await
        .map_err(|e| e.to_string())?;
    let backend: LegacyBackend<RostroConfig> =
        LegacyBackendBuilder::new().build(rpc_client.clone());
    let api = OnlineClient::from_backend(Arc::new(backend))
        .await
        .map_err(|e| e.to_string())?;
    Ok((api, rpc_client))
}

pub(crate) struct Sr25519Signer(pub(crate) sr25519::Pair);

impl subxt::tx::Signer<RostroConfig> for Sr25519Signer {
    fn account_id(&self) -> <RostroConfig as Config>::AccountId {
        AccountId32::from(self.0.public().0)
    }

    fn sign(&self, payload: &[u8]) -> <RostroConfig as Config>::Signature {
        let sig = <sr25519::Pair as Pair>::sign(&self.0, payload);
        MultiSignature::Sr25519(sig.0)
    }
}

/// Sign and submit a dynamic extrinsic. Used by all PNS extrinsic wrappers
/// to avoid repeating the keypair→signer→submit boilerplate.

/// Sign and submit a *typed* extrinsic built from the `polkadot::tx()` macro.
/// Typed counterpart to `submit_dynamic_tx`: the RNS wrappers use this because
/// the dynamic encoder is incompatible with Rostro's metadata lineage, whereas
/// the typed macro codegen produces byte-exact SCALE. `from_string` accepts
/// both BIP39 mnemonics and SURIs (`//Alice`).
fn submit_typed<Call: subxt::tx::Payload>(
    phrase: &str,
    rpc_url: &str,
    tx: Call,
) -> Result<String, String> {
    let pair = <sr25519::Pair as Pair>::from_string(phrase, None)
        .map_err(|e| format!("Keypair error: {:?}", e))?;
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        // Immortal era + best-block nonce (see send_dot): survives a chain that
        // isn't finalizing, where sign_and_submit_default's mortal era is ancient.
        let (api, rpc) = connect_rostro_with_rpc(rpc_url).await?;
        let signer = Sr25519Signer(pair);
        let account = <Sr25519Signer as subxt::tx::Signer<RostroConfig>>::account_id(&signer);
        let nonce = fetch_best_nonce(&rpc, &account).await?;
        let mut tx_client = api.tx().await.map_err(|e| e.to_string())?;
        let mut signable = tx_client
            .create_signable(&tx, &account, rostro_tx_params(nonce))
            .await
            .map_err(|e| e.to_string())?;
        let signed = signable.sign(&signer).map_err(|e| e.to_string())?;
        submit_signed_watched(signed).await
    })
}

/// Submit an already-signed transaction and wait until it is included in a best
/// block, then confirm it actually dispatched (`System.ExtrinsicSuccess` vs
/// `ExtrinsicFailed`). Unlike a bare `.submit()` — which returns the moment the
/// tx is accepted into the pool, so a failed dispatch looks identical to a
/// successful one — this surfaces the real `DispatchError`. Stops at
/// in-best-block (not finalization) so it does not hang on a chain that
/// finalizes slowly; 60s safety timeout so a stuck tx returns an error instead
/// of blocking the UI forever.
async fn submit_signed_watched(
    signed: subxt::tx::SubmittableTransaction<
        RostroConfig,
        subxt::client::OnlineClientAtBlockImpl<RostroConfig>,
    >,
) -> Result<String, String> {
    use subxt::tx::TransactionStatus;
    let mut progress = signed.submit_and_watch().await.map_err(|e| e.to_string())?;
    let watch = async {
        while let Some(status) = progress.next().await {
            match status.map_err(|e| e.to_string())? {
                TransactionStatus::InBestBlock(in_block)
                | TransactionStatus::InFinalizedBlock(in_block) => {
                    // Errors here carry the dispatch error (e.g. an insufficient
                    // deposit reserve) instead of a false success.
                    in_block.wait_for_success().await.map_err(|e| e.to_string())?;
                    return Ok(format!("{:?}", in_block.extrinsic_hash()));
                }
                TransactionStatus::Error { message } => {
                    return Err(format!("transaction error: {message}"))
                }
                TransactionStatus::Invalid { message } => {
                    return Err(format!("invalid transaction: {message}"))
                }
                TransactionStatus::Dropped { message } => {
                    return Err(format!("transaction dropped: {message}"))
                }
                _ => {} // Validated / Broadcasted / NoLongerInBestBlock — keep waiting
            }
        }
        Err("transaction stream ended before inclusion".to_string())
    };
    tokio::time::timeout(std::time::Duration::from_secs(60), watch)
        .await
        .map_err(|_| "timed out waiting for transaction inclusion (60s)".to_string())?
}

#[flutter_rust_bridge::frb(ignore)]
#[subxt::subxt(runtime_metadata_path = "src/polkadot_metadata.scale")]
pub mod polkadot {}

pub fn fetch_balance(address: String, rpc_url: String) -> anyhow::Result<String> {
    use parity_scale_codec::Encode;
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    rt.block_on(async {
        let (client, metadata) = crate::rostro_client::connect(&rpc_url).await
            .map_err(|e| anyhow::anyhow!(e))?;
        let account = AccountId32::from_str(&address)
            .map_err(|e| anyhow::anyhow!("Invalid address: {}", e))?;
        let account_bytes: [u8; 32] = account.0;
        let key = account_bytes.encode();

        let result = client
            .fetch_storage(&metadata, "System", "Account", &[&key])
            .await
            .map_err(|e| anyhow::anyhow!(e))?;

        let balance = match result {
            None => "0".to_string(),
            Some(v) => {
                let data = crate::rostro_client::field(&v, "data")
                    .ok_or_else(|| anyhow::anyhow!("AccountInfo missing 'data'"))?;
                let free = crate::rostro_client::field(data, "free")
                    .ok_or_else(|| anyhow::anyhow!("AccountInfo.data missing 'free'"))?;
                crate::rostro_client::as_u128(free)
                    .ok_or_else(|| anyhow::anyhow!("AccountInfo.data.free not u128"))?
                    .to_string()
            },
        };
        Ok(balance)
    })
}

#[flutter_rust_bridge::frb(sync)]
pub struct NameAvailability {
    pub available: bool,
    pub for_sale: bool,
}

pub fn check_name_availability(name: String, rpc_url: String) -> Result<NameAvailability, String> {
    use parity_scale_codec::Encode;
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let (client, metadata) = crate::rostro_client::connect(&rpc_url).await?;
        let args = name.into_bytes().encode();
        let value = client
            .call_runtime_api(&metadata, "PnsStorageApi", "resolve_name", &args)
            .await
            .map_err(|e| e.to_string())?;

        match crate::rostro_client::as_option(&value)? {
            None => Ok(NameAvailability { available: true, for_sale: false }),
            Some(record) => {
                let for_sale = crate::rostro_client::field(record, "for_sale")
                    .and_then(crate::rostro_client::as_bool)
                    .unwrap_or(false);
                Ok(NameAvailability { available: false, for_sale })
            },
        }
    })
}

/// Reverse lookup: address → name label.
/// Returns None because namehash is one-way (Keccak256). The pallet stores
/// DomainHash → NameRecord but never the raw label string. A future off-chain
/// indexer watching NameRegistered events could provide this mapping.
pub fn resolve_address_to_name(_address: String, _rpc_url: String) -> Result<Option<String>, String> {
    Ok(None)
}

/// Check whether an account owns a canonical .dot name via account_dashboard.
pub fn has_canonical_name(address: String, rpc_url: String) -> Result<bool, String> {
    use parity_scale_codec::Encode;
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let (client, metadata) = crate::rostro_client::connect(&rpc_url).await?;
        let account = AccountId32::from_str(&address)
            .map_err(|e| format!("Invalid address: {}", e))?;
        let account_bytes: [u8; 32] = account.0;
        let args = account_bytes.encode();
        let value = client
            .call_runtime_api(&metadata, "PnsStorageApi", "account_dashboard", &args)
            .await
            .map_err(|e| e.to_string())?;
        let primary = crate::rostro_client::field(&value, "primary_name")
            .ok_or_else(|| "AccountDashboard missing 'primary_name'".to_string())?;
        Ok(crate::rostro_client::as_option(primary)?.is_some())
    })
}

/// Vote on an OpenGov referendum via conviction_voting.vote.
/// Uses the dynamic subxt API so it works against any compatible node
/// (including Polkadot mainnet) regardless of the local metadata file.
/// balance_planck: amount to lock (e.g. "100000000000" = 0.1 DOT)
/// conviction: 0=None,1=Locked1x,2=Locked2x,...,6=Locked6x
pub fn vote_on_referendum(
    referendum_index: u32,
    aye: bool,
    balance_planck: String,
    conviction: u8,
    rpc_url: String,
    phrase: String,
) -> Result<String, String> {
    use subxt::dynamic::Value;

    let balance: u128 = balance_planck.parse().map_err(|_| "Invalid balance".to_string())?;
    let (pair, _) = sr25519::Pair::from_phrase(&phrase, None)
        .map_err(|e| format!("Keypair error: {:?}", e))?;

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;

    rt.block_on(async {
        let api = connect_rostro(&rpc_url).await?;

        let signer = Sr25519Signer(pair);

        // Vote byte: bit7 = aye(1)/nay(0), bits0-2 = conviction
        let vote_byte: u8 = if aye { 0x80 | conviction } else { conviction };

        // AccountVote::Standard { vote: Vote(u8), balance: u128 }
        let account_vote = Value::named_variant("Standard", [
            ("vote",    Value::unnamed_composite([Value::from(vote_byte)])),
            ("balance", Value::from(balance)),
        ]);

        let tx = subxt::dynamic::tx(
            "ConvictionVoting",
            "vote",
            vec![
                ("poll_index".to_string(), Value::from(referendum_index)),
                ("vote".to_string(),       account_vote),
            ],
        );

        let hash = api
            .tx()
            .await
            .map_err(|e| e.to_string())?
            .sign_and_submit_default(&tx, &signer)
            .await
            .map_err(|e| e.to_string())?;

        Ok(format!("{:?}", hash))
    })
}

#[flutter_rust_bridge::frb(sync)]
pub struct NameListing {
    pub price: String,  // planck as string
    pub seller: String, // SS58 address
}

pub fn get_name_listing(name: String, rpc_url: String) -> Result<Option<NameListing>, String> {
    use parity_scale_codec::Encode;
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let (client, metadata) = crate::rostro_client::connect(&rpc_url).await?;
        let args = name.into_bytes().encode();
        let value = client
            .call_runtime_api(&metadata, "PnsStorageApi", "get_listing", &args)
            .await
            .map_err(|e| e.to_string())?;

        match crate::rostro_client::as_option(&value)? {
            None => Ok(None),
            Some(listing) => {
                let price = crate::rostro_client::field(listing, "price")
                    .and_then(crate::rostro_client::as_u128)
                    .ok_or_else(|| "ListingInfo.price missing/invalid".to_string())?;
                let seller = crate::rostro_client::field(listing, "seller")
                    .and_then(crate::rostro_client::as_account_id)
                    .ok_or_else(|| "ListingInfo.seller missing/invalid".to_string())?;
                Ok(Some(NameListing {
                    price: price.to_string(),
                    seller: crate::rostro_client::account_to_ss58(&seller),
                }))
            },
        }
    })
}

#[flutter_rust_bridge::frb(sync)]
pub struct ResolvedName {
    pub owner: String,       // SS58 address
    pub last_block: u32,     // block where name was last registered/renewed
    pub block_hash: String,  // hex hash of that block (for verification)
}

pub fn resolve_name_verified(name: String, rpc_url: String) -> Result<Option<ResolvedName>, String> {
    use parity_scale_codec::Encode;
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let (client, metadata) = crate::rostro_client::connect(&rpc_url).await?;

        let label = name.trim_end_matches(".dot").to_string();
        let args = label.into_bytes().encode();
        let value = client
            .call_runtime_api(&metadata, "PnsStorageApi", "resolve_name", &args)
            .await
            .map_err(|e| e.to_string())?;

        let record = match crate::rostro_client::as_option(&value)? {
            None => return Ok(None),
            Some(r) => r,
        };

        let owner = crate::rostro_client::field(record, "owner")
            .and_then(crate::rostro_client::as_account_id)
            .ok_or_else(|| "NameRecord.owner missing/invalid".to_string())?;
        let last_block = crate::rostro_client::field(record, "last_block")
            .and_then(crate::rostro_client::as_u32)
            .ok_or_else(|| "NameRecord.last_block missing/invalid".to_string())?;

        // Fetch the block hash at the registration block via System.BlockHash storage.
        // Returns empty string if the block is too old for the on-chain System
        // BlockHash retention window (typically 256 blocks back).
        let block_key = last_block.encode();
        let block_hash = match client
            .fetch_storage(&metadata, "System", "BlockHash", &[&block_key])
            .await
            .map_err(|e| e.to_string())?
        {
            Some(v) => crate::rostro_client::as_bytes(&v)
                .map(|b| format!("0x{}", hex_encode_lower(&b)))
                .unwrap_or_default(),
            None => String::new(),
        };

        Ok(Some(ResolvedName {
            owner: crate::rostro_client::account_to_ss58(&owner),
            last_block,
            block_hash,
        }))
    })
}

fn hex_encode_lower(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(char::from_digit((b >> 4) as u32, 16).unwrap());
        out.push(char::from_digit((b & 0x0f) as u32, 16).unwrap());
    }
    out
}

pub fn verify_name_ownership(
    name: String,
    block_hash_hex: String,
    expected_owner: String,
    rpc_url: String,
) -> Result<bool, String> {
    use parity_scale_codec::Encode;
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let _ = block_hash_hex;
        let (client, metadata) = crate::rostro_client::connect(&rpc_url).await?;
        let label = name.trim_end_matches(".dot").to_string();
        let args = label.into_bytes().encode();
        let value = client
            .call_runtime_api(&metadata, "PnsStorageApi", "resolve_name", &args)
            .await
            .map_err(|e| e.to_string())?;

        match crate::rostro_client::as_option(&value)? {
            None => Ok(false),
            Some(record) => {
                let owner = crate::rostro_client::field(record, "owner")
                    .and_then(crate::rostro_client::as_account_id)
                    .ok_or_else(|| "NameRecord.owner missing/invalid".to_string())?;
                Ok(crate::rostro_client::account_to_ss58(&owner) == expected_owner)
            },
        }
    })
}

pub fn send_dot(
    to_address: String,
    amount_planck: String,
    phrase: String,
    rpc_url: String,
) -> Result<String, String> {
    let amount: u128 = amount_planck
        .parse()
        .map_err(|_| "Invalid amount".to_string())?;
    // `from_string` (not `from_phrase`) so this accepts a BIP39 mnemonic AND
    // dev-derivation suris (e.g. `//Ferdie`) — consistent with `submit_typed`.
    let pair = sr25519::Pair::from_string(&phrase, None)
        .map_err(|e| format!("Keypair error: {:?}", e))?;
    let dest = AccountId32::from_str(&to_address)
        .map_err(|e| format!("Invalid address: {}", e))?;

    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        // Immortal era + best-block nonce (via system_accountNextIndex), the same
        // pattern as chat_mint_test_cert. `sign_and_submit_default` builds a MORTAL
        // era anchored at the finalized head; on a chain that isn't finalizing
        // (e.g. a small validator set) that era reads as ancient -> Invalid
        // Transaction (1010). This path avoids both that and the at-finalized nonce.
        let (api, rpc) = connect_rostro_with_rpc(&rpc_url).await?;
        let signer = Sr25519Signer(pair);
        let account = <Sr25519Signer as subxt::tx::Signer<RostroConfig>>::account_id(&signer);
        let nonce = fetch_best_nonce(&rpc, &account).await?;
        let tx = polkadot::tx()
            .balances()
            .transfer_keep_alive(MultiAddress::Id(dest), amount);
        let mut tx_client = api.tx().await.map_err(|e| e.to_string())?;
        let mut signable = tx_client
            .create_signable(&tx, &account, rostro_tx_params(nonce))
            .await
            .map_err(|e| e.to_string())?;
        let signed = signable.sign(&signer).map_err(|e| e.to_string())?;
        submit_signed_watched(signed).await
    })
}

/// Fetch the balance of an Assets-pallet asset (e.g. USDT=1984, USDC=1337) on
/// Polkadot Asset Hub.  Returns the raw balance as a decimal string ("0" if the
/// account has no entry for that asset).  Uses subxt's dynamic API so no
/// Asset Hub .scale metadata file is required.
pub fn fetch_asset_balance(
    address: String,
    asset_hub_rpc: String,
    asset_id: u32,
) -> anyhow::Result<String> {
    use parity_scale_codec::Encode;
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    rt.block_on(async {
        let (client, metadata) = crate::rostro_client::connect(&asset_hub_rpc).await
            .map_err(|e| anyhow::anyhow!(e))?;
        let account = AccountId32::from_str(&address)
            .map_err(|e| anyhow::anyhow!("Invalid address: {}", e))?;

        let key1 = asset_id.encode();
        let account_bytes: [u8; 32] = account.0;
        let key2 = account_bytes.encode();

        let result = client
            .fetch_storage(&metadata, "Assets", "Account", &[&key1, &key2])
            .await
            .map_err(|e| anyhow::anyhow!(e))?;

        match result {
            None => Ok("0".to_string()),
            Some(v) => {
                let bal = crate::rostro_client::field(&v, "balance")
                    .ok_or_else(|| anyhow::anyhow!("AssetAccount missing 'balance'"))?;
                Ok(crate::rostro_client::as_u128(bal)
                    .ok_or_else(|| anyhow::anyhow!("balance not u128"))?
                    .to_string())
            },
        }
    })
}

/// Buy a listed name from the PNS marketplace (direct purchase, no gift).
pub fn buy_name(name: String, phrase: String, rpc_url: String) -> Result<String, String> {
    submit_typed(&phrase, &rpc_url,
        polkadot::tx().rns_marketplace().buy_name(name.into_bytes(), None))
}

/// Buy a listed name and gift it to a recipient. The recipient must call
/// accept_offered_name within 90 days to activate it.
pub fn buy_name_for(
    name: String,
    recipient: String,
    phrase: String,
    rpc_url: String,
) -> Result<String, String> {
    let dest = AccountId32::from_str(&recipient)
        .map_err(|e| format!("Invalid recipient: {}", e))?;
    submit_typed(&phrase, &rpc_url,
        polkadot::tx().rns_marketplace().buy_name(name.into_bytes(), Some(dest)))
}

/// Register a name on behalf of someone else — the signer pays, but `recipient` is set as owner.
pub fn register_name_for(_name: String, _phrase: String, _recipient: String, _rpc_url: String) -> Result<String, String> {
    // The Rostro RnsRegistrar.register extrinsic dropped its `owner` argument:
    // a registration is now always owned by the signer. There is no single-call
    // way to register a fresh name directly into someone else's account. The
    // equivalent flow is register-then-transfer (RnsRegistrar.transfer) or, for
    // a listed name, the marketplace gift path (buy_name with a recipient).
    Err("register_name_for is unsupported: RnsRegistrar.register no longer takes \
         an owner. Register to yourself then transfer, or use the marketplace \
         gift flow to place a name in another account.".to_string())
}

/// Query the on-chain RnsPriceOracle for the registration fee.
/// BasePrice is an [u128; 11] array indexed by label length (1-char → idx 0, 11+ → idx 10).
pub fn get_name_price(name: String, rpc_url: String) -> Result<String, String> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let (client, metadata) = crate::rostro_client::connect(&rpc_url).await?;
        let result = client
            .fetch_storage(&metadata, "RnsPriceOracle", "BasePrice", &[])
            .await
            .map_err(|e| e.to_string())?;

        let idx = (name.chars().count().max(1) - 1).min(10);

        match result {
            None => Err("BasePrice storage not found — is RnsPriceOracle in the metadata?".to_string()),
            Some(v) => {
                let elem = crate::rostro_client::at(&v, idx)
                    .ok_or_else(|| format!("BasePrice[{idx}] missing"))?;
                Ok(crate::rostro_client::as_u128(elem)
                    .ok_or_else(|| "BasePrice element not u128".to_string())?
                    .to_string())
            },
        }
    })
}

pub fn register_name(name: String, phrase: String, rpc_url: String) -> Result<String, String> {
    // RnsRegistrar.register(name, reject_offer): owner is always the signer now
    // (the runtime dropped the explicit-owner arg). `None` = don't reject any
    // pending offered name first.
    //
    // Routes through `submit_typed` like every other RNS write (buy_name, etc.):
    // it uses the immortal-era + best-block-nonce path. The old
    // `sign_and_submit_default` here built a MORTAL era anchored at the finalized
    // head, which reads as ancient on a chain that isn't finalizing (the lab rig's
    // small validator set) -> Invalid Transaction (1010), so registration failed
    // on-device while reads worked fine.
    submit_typed(&phrase, &rpc_url,
        polkadot::tx().rns_registrar().register(name.into_bytes(), None))
}

// ─── Phase 1: chat-identity records (typed RNS CHAT + MESSAGE) ───────────────
//
// The chat identity is TWO typed, chain-owned records (rns-chat-v0, the chain
// migration that retired the opaque PUBKEY1 single-record convention):
//   * CHAT    (RecordType index 15) — the Ed25519 *mail address* (outer /
//     sealed-sender layer). Exactly 32 raw bytes; the chain validates the
//     length (InvalidChatKey). Required to be chat-reachable. Published
//     EXPLICITLY because an SS58 is scheme-agnostic and may not be Ed25519.
//   * MESSAGE (RecordType index 16) — the curve-tagged `ContentPublicKey`
//     (inner / content-at-rest layer). On by default; omit for dead-drop.
//
// The X3DH signed prekey (SPK) the OLD PUBKEY1 record bundled has NO home in
// the 32-byte CHAT record. Forward secrecy (the SPK) is deferred to F2, which
// owns the decision of where the SPK lives in the typed-records world. F1
// publishes CHAT + MESSAGE only.

/// IANA private-use codes for the typed chat records.
const RT_CHAT_IANA: u32 = 65293;
const RT_MESSAGE_IANA: u32 = 65294;

/// FRB-facing resolved chat identity for a `.rst` name.
pub struct ResolvedChatIdentity {
    pub found: bool,
    /// Outer Ed25519 mail address (CHAT record), hex. The sealed-sender target.
    pub ed25519_pubkey_hex: String,
    /// Inner content key (MESSAGE record), hex of the curve-tagged
    /// `ContentPublicKey`. Empty if the name is dead-drop (no MESSAGE record).
    pub inner_content_key_hex: String,
    /// True if a MESSAGE record is present (content sealing possible); false =
    /// dead-drop (content key exchanged out-of-band).
    pub has_message_key: bool,
}

/// Publish this device's chat identity under `name` (which the signer must own)
/// as the typed CHAT + MESSAGE records. `identity_seed_hex` is the device's
/// chat-identity Ed25519 seed; its public key becomes the CHAT mail address.
/// `inner_content_key_hex` is the device's silicon content key (hex of the
/// SCALE curve-tagged `ContentPublicKey` from `chat::chat_gen_content_key`) —
/// published as MESSAGE. An empty content key publishes CHAT only (dead-drop).
///
/// Two extrinsics (CHAT then MESSAGE); returns both tx hashes joined by `;`.
pub fn chat_publish_identity(
    name: String,
    phrase: String,
    rpc_url: String,
    identity_seed_hex: String,
    inner_content_key_hex: String,
) -> Result<String, String> {
    let seed: [u8; 32] = hex::decode(identity_seed_hex.trim_start_matches("0x"))
        .map_err(|e| format!("bad identity seed hex: {e}"))?
        .try_into()
        .map_err(|_| "identity seed must be 32 bytes".to_string())?;
    let signing = ed25519_zebra::SigningKey::from(seed);
    let outer_ed25519: [u8; 32] = ed25519_zebra::VerificationKey::from(&signing).into();

    // 1. CHAT — the 32-byte Ed25519 mail address (required).
    let chat_tx = submit_typed(
        &phrase,
        &rpc_url,
        polkadot::tx().rns_resolvers().set_record(
            name.clone().into_bytes(),
            polkadot::runtime_types::rns_types::ddns::codec_type::RecordType::CHAT,
            polkadot::runtime_types::bounded_collections::bounded_vec::BoundedVec(
                outer_ed25519.to_vec(),
            ),
        ),
    )?;

    // 2. MESSAGE — the curve-tagged content key (on by default; omit = dead-drop).
    let inner_content_key = hex::decode(inner_content_key_hex.trim_start_matches("0x"))
        .map_err(|e| format!("bad content key hex: {e}"))?;
    if inner_content_key.is_empty() {
        return Ok(chat_tx); // dead-drop: CHAT only
    }
    let message_tx = submit_typed(
        &phrase,
        &rpc_url,
        polkadot::tx().rns_resolvers().set_record(
            name.into_bytes(),
            polkadot::runtime_types::rns_types::ddns::codec_type::RecordType::MESSAGE,
            polkadot::runtime_types::bounded_collections::bounded_vec::BoundedVec(inner_content_key),
        ),
    )?;
    Ok(format!("{chat_tx};{message_tx}"))
}

/// Resolve `name` → its published chat identity (typed CHAT + MESSAGE records).
/// Forward resolution — the recipient's name-display is "resolve the claimed
/// name, verify the key matches the signed sender," never a reverse lookup.
/// Built on the existing `lookup_records` machinery (no duplicate runtime-API
/// call): one query for both typed records, picked out by IANA code.
pub fn chat_resolve_identity(name: String, rpc_url: String) -> Result<ResolvedChatIdentity, String> {
    let records = lookup_records(name, vec![RT_CHAT_IANA, RT_MESSAGE_IANA], rpc_url)?;

    let chat = records.iter().find(|r| r.record_type == RT_CHAT_IANA);
    let message = records.iter().find(|r| r.record_type == RT_MESSAGE_IANA);

    match chat {
        Some(c) if c.content.len() == 32 => Ok(ResolvedChatIdentity {
            found: true,
            ed25519_pubkey_hex: hex::encode(&c.content),
            inner_content_key_hex: message.map(|m| hex::encode(&m.content)).unwrap_or_default(),
            has_message_key: message.is_some_and(|m| !m.content.is_empty()),
        }),
        Some(_) => Err("CHAT record is not a 32-byte Ed25519 key".to_string()),
        None => Ok(ResolvedChatIdentity {
            found: false,
            ed25519_pubkey_hex: String::new(),
            inner_content_key_hex: String::new(),
            has_message_key: false,
        }),
    }
}

/// FRB-facing onboarding result.
pub struct ChatSetupOutcome {
    pub name: String,
    pub registered: bool,
    pub published: bool,
    pub register_tx: String,
    pub publish_tx: String,
}

/// One-step "set up messaging": register `name` and publish this device's chat
/// identity (outer key + Phase-3 content key) under it. Tolerant — if the name
/// is already registered to the signer, registration is effectively a no-op and
/// publish proceeds.
pub fn chat_setup_messaging(
    name: String,
    phrase: String,
    rpc_url: String,
    identity_seed_hex: String,
    inner_content_key_hex: String,
) -> Result<ChatSetupOutcome, String> {
    use std::time::Duration;
    // 1. Register the name (submit). A dispatch failure (e.g. already owned) is
    //    tolerated — step 2 confirms via on-chain state.
    let register_tx = submit_typed(
        &phrase,
        &rpc_url,
        polkadot::tx().rns_registrar().register(name.clone().into_bytes(), None),
    )
    .unwrap_or_default();
    // 2. Wait until the name is registered.
    let mut registered = false;
    for _ in 0..40 {
        std::thread::sleep(Duration::from_secs(1));
        if let Ok(a) = check_name_availability(name.clone(), rpc_url.clone()) {
            if !a.available {
                registered = true;
                break;
            }
        }
    }
    if !registered {
        return Err(format!(
            "'{name}' did not register — taken by another, or the chain isn't producing blocks"
        ));
    }
    // 3. Publish the chat identity (retry past the back-to-back nonce race).
    let mut publish_tx = String::new();
    let mut published = false;
    for _ in 0..12 {
        match chat_publish_identity(
            name.clone(),
            phrase.clone(),
            rpc_url.clone(),
            identity_seed_hex.clone(),
            inner_content_key_hex.clone(),
        ) {
            Ok(tx) => {
                publish_tx = tx;
                published = true;
                break;
            }
            Err(_) => std::thread::sleep(Duration::from_secs(2)),
        }
    }
    // 4. Wait until the chat key resolves.
    if published {
        for _ in 0..30 {
            std::thread::sleep(Duration::from_secs(1));
            if chat_resolve_identity(name.clone(), rpc_url.clone())
                .map(|r| r.found)
                .unwrap_or(false)
            {
                break;
            }
        }
    }
    Ok(ChatSetupOutcome { name, registered, published, register_tx, publish_tx })
}

// ═══════════════════════════════════════════════════════════════════════════
// New return types for PNS queries
// ═══════════════════════════════════════════════════════════════════════════

#[flutter_rust_bridge::frb(sync)]
pub struct AccountDashboardInfo {
    pub has_primary_name: bool,
    /// Hex-encoded DomainHash (H256) of the primary name, e.g. "0xabc…"
    pub primary_name_hash: Option<String>,
    pub subname_hashes: Vec<String>,
    pub pending_subname_offers: Vec<String>,
    pub pending_name_offers: Vec<String>,
}

#[flutter_rust_bridge::frb(sync)]
pub struct DnsRecord {
    /// IANA code: 65280=SS58, 65281=RPC, 65285=PUBKEY1, 65286=AVATAR, etc.
    pub record_type: u32,
    pub content: Vec<u8>,
}

// ═══════════════════════════════════════════════════════════════════════════
// PNS queries: account_dashboard, lookup_records
// ═══════════════════════════════════════════════════════════════════════════

/// Fetch the full PNS portfolio for an account: primary name, subnames,
/// pending offers. Returns hashes (H256 hex) — label strings are not stored
/// on-chain due to one-way namehashing.
pub fn account_dashboard(address: String, rpc_url: String) -> Result<AccountDashboardInfo, String> {
    use parity_scale_codec::Encode;
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let (client, metadata) = crate::rostro_client::connect(&rpc_url).await?;
        let account = AccountId32::from_str(&address)
            .map_err(|e| format!("Invalid address: {}", e))?;
        let account_bytes: [u8; 32] = account.0;
        let args = account_bytes.encode();
        let value = client
            .call_runtime_api(&metadata, "PnsStorageApi", "account_dashboard", &args)
            .await
            .map_err(|e| e.to_string())?;

        let primary = crate::rostro_client::field(&value, "primary_name")
            .ok_or_else(|| "AccountDashboard missing 'primary_name'".to_string())?;
        let primary_hash = match crate::rostro_client::as_option(primary)? {
            None => None,
            Some(h) => Some(format!(
                "0x{}",
                hex_encode_lower(
                    &crate::rostro_client::as_bytes(h)
                        .ok_or_else(|| "primary_name not byte-shaped".to_string())?
                )
            )),
        };

        let collect_hashes = |field_name: &str| -> Result<Vec<String>, String> {
            let v = crate::rostro_client::field(&value, field_name)
                .ok_or_else(|| format!("AccountDashboard missing '{field_name}'"))?;
            let scale_value::ValueDef::Composite(scale_value::Composite::Unnamed(items)) = &v.value else {
                return Err(format!("'{field_name}' not an unnamed composite"));
            };
            items
                .iter()
                .map(|h| {
                    crate::rostro_client::as_bytes(h)
                        .map(|b| format!("0x{}", hex_encode_lower(&b)))
                        .ok_or_else(|| format!("'{field_name}' element not byte-shaped"))
                })
                .collect()
        };

        Ok(AccountDashboardInfo {
            has_primary_name: primary_hash.is_some(),
            primary_name_hash: primary_hash,
            subname_hashes: collect_hashes("subnames")?,
            pending_subname_offers: collect_hashes("pending_subname_offers")?,
            pending_name_offers: collect_hashes("pending_name_offers")?,
        })
    })
}

/// Fetch DNS records for a name. Pass IANA record-type codes (e.g. [65285, 65288]
/// for PUBKEY1 + PUBKEY2). SS58 (65280) and ORIGIN (65290) are always included
/// automatically by the pallet.
///
/// NOTE: The type path `polkadot::runtime_types::pns_types::ddns::codec_type::RecordType`
/// depends on the metadata file. If it doesn't compile, regenerate metadata from the node.
pub fn lookup_records(name: String, record_types: Vec<u32>, rpc_url: String) -> Result<Vec<DnsRecord>, String> {
    use parity_scale_codec::{Compact, Encode};
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let (client, metadata) = crate::rostro_client::connect(&rpc_url).await?;

        // Encode the record_types as `Vec<RecordType>`. Each variant is a single
        // index byte; `Unknown(u16)` carries a 2-byte LE payload.
        let mut record_types_encoded = Vec::new();
        Compact(record_types.len() as u32).encode_to(&mut record_types_encoded);
        for code in &record_types {
            encode_record_type(*code, &mut record_types_encoded);
        }

        let mut args = Vec::new();
        name.into_bytes().encode_to(&mut args);
        args.extend_from_slice(&record_types_encoded);

        let value = client
            .call_runtime_api(&metadata, "PnsStorageApi", "lookup_by_name", &args)
            .await
            .map_err(|e| e.to_string())?;

        let scale_value::ValueDef::Composite(scale_value::Composite::Unnamed(items)) = &value.value
        else {
            return Err("lookup_by_name return shape is not a sequence".to_string());
        };

        items
            .iter()
            .map(|tuple| {
                let scale_value::ValueDef::Composite(scale_value::Composite::Unnamed(parts)) = &tuple.value else {
                    return Err("lookup_by_name tuple shape unexpected".to_string());
                };
                if parts.len() != 2 {
                    return Err(format!("lookup_by_name tuple has {} parts, expected 2", parts.len()));
                }
                let code = decode_record_type_to_iana(&parts[0])?;
                let content = crate::rostro_client::as_bytes(&parts[1])
                    .ok_or_else(|| "lookup_by_name content not byte-shaped".to_string())?;
                Ok(DnsRecord { record_type: code, content })
            })
            .collect()
    })
}

/// SCALE-encode a single `rns_types::ddns::codec_type::RecordType` value
/// from an IANA private-use record-type code, appending to `out`. The
/// variant indices below mirror the enum declaration order in
/// `substrate/frame/rns-types/src/ddns.rs`. If the chain enum's
/// declaration order ever changes, this table must move with it.
fn encode_record_type(iana_code: u32, out: &mut Vec<u8>) {
    let idx: u8 = match iana_code {
        65280 => 0,  // SS58
        65281 => 1,  // RPC
        65282 => 2,  // VALIDATOR
        65285 => 3,  // PUBKEY1
        65286 => 4,  // AVATAR
        65287 => 5,  // CONTRACT
        65288 => 6,  // PUBKEY2
        65289 => 7,  // PUBKEY3
        65290 => 8,  // ORIGIN
        65291 => 9,  // IPFS
        65292 => 10, // CONTENT
        // 11=A, 12=AAAA, 13=CNAME, 14=TXT have no IANA private-use code.
        65293 => 15, // CHAT    (Ed25519 mail address, 32 bytes)
        65294 => 16, // MESSAGE (curve-tagged ContentPublicKey)
        _ => {
            out.push(17); // Unknown(u16) — index 17 after CHAT(15)/MESSAGE(16)
            out.extend_from_slice(&(iana_code as u16).to_le_bytes());
            return;
        },
    };
    out.push(idx);
}

/// Map a decoded RecordType variant back to an IANA private-use code.
fn decode_record_type_to_iana(value: &scale_value::Value<()>) -> Result<u32, String> {
    let scale_value::ValueDef::Variant(var) = &value.value else {
        return Err("RecordType not a variant".to_string());
    };
    Ok(match var.name.as_str() {
        "SS58" => 65280,
        "RPC" => 65281,
        "VALIDATOR" => 65282,
        "PUBKEY1" => 65285,
        "AVATAR" => 65286,
        "CONTRACT" => 65287,
        "PUBKEY2" => 65288,
        "PUBKEY3" => 65289,
        "ORIGIN" => 65290,
        "IPFS" => 65291,
        "CONTENT" => 65292,
        "CHAT" => 65293,
        "MESSAGE" => 65294,
        "Unknown" => match &var.values {
            scale_value::Composite::Unnamed(items) if items.len() == 1 => {
                crate::rostro_client::as_u32(&items[0])
                    .ok_or_else(|| "Unknown variant payload not u16-shaped".to_string())?
            },
            _ => return Err("Unknown variant has unexpected payload".to_string()),
        },
        // A / AAAA / CNAME / TXT have no IANA private-use code; surface as 0.
        _ => 0,
    })
}

// ═══════════════════════════════════════════════════════════════════════════
// PNS extrinsics: name lifecycle
// ═══════════════════════════════════════════════════════════════════════════

/// Release (burn) the caller's canonical name. Fails if the name has active
/// subdomains — revoke them first.
pub fn release_name(phrase: String, rpc_url: String) -> Result<String, String> {
    submit_typed(&phrase, &rpc_url, polkadot::tx().rns_registrar().release_name())
}

/// Renew the caller's canonical name. Resets expiry to now + 365 days.
/// Must be called before the 30-day grace period ends.
pub fn renew_name(phrase: String, rpc_url: String) -> Result<String, String> {
    submit_typed(&phrase, &rpc_url, polkadot::tx().rns_registrar().renew())
}

/// Transfer the caller's canonical name to another account.
/// The recipient must not already own a name or hold a subdomain.
pub fn transfer_name(to_address: String, phrase: String, rpc_url: String) -> Result<String, String> {
    let dest = AccountId32::from_str(&to_address)
        .map_err(|e| format!("Invalid address: {}", e))?;
    submit_typed(&phrase, &rpc_url,
        polkadot::tx().rns_registrar().transfer(MultiAddress::Id(dest)))
}

// ═══════════════════════════════════════════════════════════════════════════
// PNS extrinsics: marketplace
// ═══════════════════════════════════════════════════════════════════════════

/// List the caller's canonical name for sale.
/// price_planck: asking price in planck (string to avoid u128 overflow in Dart).
/// expires_at_ms: unix millisecond timestamp when the listing expires.
pub fn create_listing(
    price_planck: String,
    expires_at_ms: u64,
    phrase: String,
    rpc_url: String,
) -> Result<String, String> {
    let price: u128 = price_planck.parse().map_err(|_| "Invalid price".to_string())?;
    submit_typed(&phrase, &rpc_url,
        polkadot::tx().rns_marketplace().create_listing(price, expires_at_ms))
}

/// Cancel the caller's active marketplace listing.
pub fn cancel_listing(phrase: String, rpc_url: String) -> Result<String, String> {
    submit_typed(&phrase, &rpc_url, polkadot::tx().rns_marketplace().cancel_listing())
}

// ═══════════════════════════════════════════════════════════════════════════
// PNS extrinsics: DNS records (resolvers pallet)
// ═══════════════════════════════════════════════════════════════════════════

/// Set a DNS record on a name you own.
/// record_type: variant name exactly as in the pallet enum — "RPC", "PUBKEY1",
///   "AVATAR", "VALIDATOR", "PARA", "PROXY", "CONTRACT", "PUBKEY2", "PUBKEY3",
///   "IPFS", "CONTENT". SS58 and ORIGIN are chain-managed (will be rejected).
/// content: raw bytes (e.g. UTF-8 for RPC endpoint, raw pubkey for PUBKEY1).
/// name: plain label ("alice") or dotted subdomain ("sub.alice").
pub fn set_record(
    name: String,
    record_type: String,
    content: Vec<u8>,
    phrase: String,
    rpc_url: String,
) -> Result<String, String> {
    use polkadot::runtime_types::rns_types::ddns::codec_type::RecordType;
    use polkadot::runtime_types::bounded_collections::bounded_vec::BoundedVec;
    let rt = match record_type.as_str() {
        "SS58" => RecordType::SS58,
        "RPC" => RecordType::RPC,
        "VALIDATOR" => RecordType::VALIDATOR,
        "PUBKEY1" => RecordType::PUBKEY1,
        "AVATAR" => RecordType::AVATAR,
        "CONTRACT" => RecordType::CONTRACT,
        "PUBKEY2" => RecordType::PUBKEY2,
        "PUBKEY3" => RecordType::PUBKEY3,
        "ORIGIN" => RecordType::ORIGIN,
        "IPFS" => RecordType::IPFS,
        "CONTENT" => RecordType::CONTENT,
        "A" => RecordType::A,
        "AAAA" => RecordType::AAAA,
        "CNAME" => RecordType::CNAME,
        "TXT" => RecordType::TXT,
        other => return Err(format!("unknown record_type: {other}")),
    };
    submit_typed(&phrase, &rpc_url,
        polkadot::tx().rns_resolvers().set_record(name.into_bytes(), rt, BoundedVec(content)))
}

/// Set a text metadata record on a name you own.
/// kind: "Email", "Url", "Avatar", "Description", "Notice", "Keywords",
///   "Twitter", "Github", or "Ipfs".
/// content: UTF-8 text value.
/// name: plain label ("alice") or dotted subdomain ("sub.alice").
pub fn set_text(
    name: String,
    kind: String,
    content: String,
    phrase: String,
    rpc_url: String,
) -> Result<String, String> {
    use polkadot::runtime_types::pallet_rns_resolvers::resolvers::pallet::TextKind;
    use polkadot::runtime_types::bounded_collections::bounded_vec::BoundedVec;
    let k = match kind.as_str() {
        "Email" => TextKind::Email,
        "Url" => TextKind::Url,
        "Avatar" => TextKind::Avatar,
        "Description" => TextKind::Description,
        "Notice" => TextKind::Notice,
        "Keywords" => TextKind::Keywords,
        "Twitter" => TextKind::Twitter,
        "Github" => TextKind::Github,
        "Ipfs" => TextKind::Ipfs,
        other => return Err(format!("unknown text kind: {other}")),
    };
    submit_typed(&phrase, &rpc_url,
        polkadot::tx().rns_resolvers().set_text(name.into_bytes(), k, BoundedVec(content.into_bytes())))
}

// ═══════════════════════════════════════════════════════════════════════════
// PNS extrinsics: subdomain management
// ═══════════════════════════════════════════════════════════════════════════

/// Offer a subdomain to another account. Caller must own a canonical name
/// (the parent). Target must not already own a name or subdomain.
/// label: the subdomain part, e.g. "sally" to create sally.alice.dot
pub fn offer_subdomain(
    label: String,
    target_address: String,
    phrase: String,
    rpc_url: String,
) -> Result<String, String> {
    let target = AccountId32::from_str(&target_address)
        .map_err(|e| format!("Invalid target address: {}", e))?;
    submit_typed(&phrase, &rpc_url,
        polkadot::tx().rns_registrar().offer_subdomain(label.into_bytes(), MultiAddress::Id(target)))
}

/// Accept a subdomain offer. Caller must be the target of the offer.
/// parent: the parent domain label (e.g. "alice")
/// label: the subdomain label (e.g. "sally")
pub fn accept_subdomain(
    parent: String,
    label: String,
    phrase: String,
    rpc_url: String,
) -> Result<String, String> {
    submit_typed(&phrase, &rpc_url,
        polkadot::tx().rns_registrar().accept_subdomain(parent.into_bytes(), label.into_bytes()))
}

/// Reject a subdomain offer. Caller must be the target of the offer.
pub fn reject_subdomain(
    parent: String,
    label: String,
    phrase: String,
    rpc_url: String,
) -> Result<String, String> {
    submit_typed(&phrase, &rpc_url,
        polkadot::tx().rns_registrar().reject_subdomain(parent.into_bytes(), label.into_bytes()))
}

/// Revoke a subdomain you issued. Caller must own the parent name.
pub fn revoke_subdomain(label: String, phrase: String, rpc_url: String) -> Result<String, String> {
    submit_typed(&phrase, &rpc_url,
        polkadot::tx().rns_registrar().revoke_subdomain(label.into_bytes()))
}

/// Release a subdomain you hold. Caller must be the subdomain holder.
pub fn release_subdomain(
    parent: String,
    label: String,
    phrase: String,
    rpc_url: String,
) -> Result<String, String> {
    submit_typed(&phrase, &rpc_url,
        polkadot::tx().rns_registrar().release_subdomain(parent.into_bytes(), label.into_bytes()))
}

// ═══════════════════════════════════════════════════════════════════════════
// PNS extrinsics: gift acceptance
// ═══════════════════════════════════════════════════════════════════════════

/// Accept a name that was bought for you via buy_name_for (gift purchase).
/// Must be called within 90 days of the purchase. Sets the name as your
/// canonical name.
pub fn accept_offered_name(name: String, phrase: String, rpc_url: String) -> Result<String, String> {
    submit_typed(&phrase, &rpc_url,
        polkadot::tx().rns_registrar().accept_offered_name(name.into_bytes()))
}

// ═══════════════════════════════════════════════════════════════════════════
// DevicePublicKey construction for on-chain submission
// ═══════════════════════════════════════════════════════════════════════════

/// Build a dynamic Value representing DevicePublicKey::EcdsaP256 for subxt submission.
/// Takes raw P-256 public key bytes from StrongBox (SEC1 format, typically 65 bytes uncompressed).
/// Returns the Value that can be used as the `device_pubkey` parameter in ZK-PKI extrinsics.
#[flutter_rust_bridge::frb(sync)]
pub fn build_device_pubkey_p256(raw_pubkey: Vec<u8>) -> Vec<u8> {
    // SCALE encoding of DevicePublicKey { algorithm: KeyAlgorithm::EcdsaP256, key_bytes: BoundedVec }
    // KeyAlgorithm is an enum: EcdsaP256 = index 0, EcdsaP521 = index 1, MlDsa65 = index 2, MlDsa87 = index 3
    // The struct encodes as: algorithm_index (1 byte) + SCALE compact length + raw bytes
    let mut encoded = Vec::new();
    encoded.push(0u8); // KeyAlgorithm::EcdsaP256 = variant index 0

    // SCALE compact encoding of the byte vec length
    let len = raw_pubkey.len();
    if len < 64 {
        encoded.push((len as u8) << 2);
    } else if len < 16384 {
        let compact = ((len as u16) << 2) | 0x01;
        encoded.extend_from_slice(&compact.to_le_bytes());
    } else {
        let compact = ((len as u32) << 2) | 0x02;
        encoded.extend_from_slice(&compact.to_le_bytes());
    }
    encoded.extend_from_slice(&raw_pubkey);
    encoded
}

/// Build SCALE-encoded DevicePublicKey::EcdsaP521 from raw P-521 public key bytes.
#[flutter_rust_bridge::frb(sync)]
pub fn build_device_pubkey_p521(raw_pubkey: Vec<u8>) -> Vec<u8> {
    let mut encoded = Vec::new();
    encoded.push(1u8); // KeyAlgorithm::EcdsaP521 = variant index 1
    let len = raw_pubkey.len();
    if len < 64 {
        encoded.push((len as u8) << 2);
    } else if len < 16384 {
        let compact = ((len as u16) << 2) | 0x01;
        encoded.extend_from_slice(&compact.to_le_bytes());
    } else {
        let compact = ((len as u32) << 2) | 0x02;
        encoded.extend_from_slice(&compact.to_le_bytes());
    }
    encoded.extend_from_slice(&raw_pubkey);
    encoded
}

// ═══════════════════════════════════════════════════════════════════════════

#[flutter_rust_bridge::frb(sync)]
pub struct DotAccount {
    pub address: String,
    pub public_key: Vec<u8>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn generate_account() -> (DotAccount, String) {
    let mnemonic = Mnemonic::generate_in(Language::English, 24)
        .expect("Failed to generate mnemonic");
    let phrase = mnemonic.to_string();
    let (pair, _) = sr25519::Pair::from_phrase(&phrase, None)
        .expect("Failed to derive keypair");
    let account = DotAccount {
        address: format!("{}", pair.public()),
        public_key: pair.public().to_vec(),
    };
    (account, phrase)
}

#[flutter_rust_bridge::frb(sync)]
pub fn restore_account(phrase: String) -> Result<DotAccount, String> {
    let (pair, _) = sr25519::Pair::from_phrase(&phrase, None)
        .map_err(|e| format!("Invalid phrase: {:?}", e))?;
    Ok(DotAccount {
        address: format!("{}", pair.public()),
        public_key: pair.public().to_vec(),
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn encrypt_phrase(phrase: String, passphrase: String) -> Result<Vec<u8>, String> {
    let mut salt = [0u8; 32];
    getrandom_fill(&mut salt).map_err(|e| format!("RNG failed: {:?}", e))?;

    let params = Params::new(262144, 4, 1, Some(32))
        .map_err(|e| format!("Argon2 params failed: {:?}", e))?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);

    let mut key_bytes = [0u8; 32];
    argon2
        .hash_password_into(passphrase.as_bytes(), &salt, &mut key_bytes)
        .map_err(|e| format!("Key derivation failed: {:?}", e))?;

    let mut nonce_bytes = [0u8; 12];
    getrandom_fill(&mut nonce_bytes).map_err(|e| format!("RNG failed: {:?}", e))?;

    let key = Key::from_slice(&key_bytes);
    let cipher = ChaCha20Poly1305::new(key);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, phrase.as_bytes())
        .map_err(|e| format!("Encryption failed: {:?}", e))?;

    key_bytes.zeroize();

    let mut result = Vec::new();
    result.extend_from_slice(&salt);
    result.extend_from_slice(&nonce_bytes);
    result.extend_from_slice(&ciphertext);
    Ok(result)
}

#[flutter_rust_bridge::frb(sync)]
pub fn decrypt_phrase(blob: Vec<u8>, passphrase: String) -> Result<String, String> {
    if blob.len() < 44 {
        return Err("Invalid blob: too short".to_string());
    }

    let salt = &blob[..32];
    let nonce_bytes = &blob[32..44];
    let ciphertext = &blob[44..];

    let params = Params::new(262144, 4, 1, Some(32))
        .map_err(|e| format!("Argon2 params failed: {:?}", e))?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);

    let mut key_bytes = [0u8; 32];
    argon2
        .hash_password_into(passphrase.as_bytes(), salt, &mut key_bytes)
        .map_err(|e| format!("Key derivation failed: {:?}", e))?;

    let key = Key::from_slice(&key_bytes);
    let cipher = ChaCha20Poly1305::new(key);
    let nonce = Nonce::from_slice(nonce_bytes);

    let plaintext = cipher
        .decrypt(nonce, ciphertext)
        .map_err(|_| "Decryption failed: wrong passphrase or corrupted data".to_string())?;

    key_bytes.zeroize();

    String::from_utf8(plaintext).map_err(|_| "Invalid UTF-8 in decrypted phrase".to_string())
}

#[flutter_rust_bridge::frb(sync)]
pub fn check_passphrase_strength(passphrase: String) -> PassphraseStrength {
    let estimate = zxcvbn(&passphrase, &[]);
    PassphraseStrength {
        score: estimate.score() as u8,
        warning: estimate.feedback()
            .and_then(|f| f.warning())
            .map(|w| format!("{}", w)),
        suggestions: estimate.feedback()
            .map(|f| f.suggestions().iter().map(|s| format!("{}", s)).collect())
            .unwrap_or_default(),
        guesses_log10: estimate.guesses_log10(),
    }
}

#[flutter_rust_bridge::frb(sync)]
pub struct PassphraseStrength {
    pub score: u8,
    pub warning: Option<String>,
    pub suggestions: Vec<String>,
    pub guesses_log10: f64,
}

// ═══════════════════════════════════════════════════════════════════════════
// ZK-PKI pallet on-chain queries
// ═══════════════════════════════════════════════════════════════════════════
//
// Thin subxt wrappers mirroring `fetch_balance` above. Used by the production
// mint-cert flow in Dart to obtain the offer nonce that the Kotlin ceremony
// will feed into `setAttestationChallenge()` on both EC keys.
//
// The offer nonce IS the attestation challenge — the same 32 bytes the
// issuer wrote at `offer_contract` time, the same bytes the ceremony
// embeds in the KeyDescription extension, the same bytes the pallet
// accepts as `contract_nonce` in `mint_cert`. Freshness and offer
// binding hang off this value.

/// Fetch the 32-byte offer nonce for a given (user, issuer) pair from the
/// ZK-PKI pallet's `ContractOffers` storage map.
///
/// **STUB.** The ZK-PKI pallet is not yet deployed to any chain that
/// Dotwave can reach, and `rust_core` does not yet embed ZK-PKI pallet
/// metadata for subxt to type-check against. Until both land, this
/// function returns a fixed 32-byte zero value so the production
/// mint-cert flow's callsite can be wired and exercised ahead of chain
/// availability.
///
/// # TODO — replace stub with real subxt storage query
///
/// When the pallet is live:
///
/// 1. Add the ZK-PKI pallet's SCALE metadata blob alongside
///    `polkadot_metadata.scale` and a `subxt::subxt(...)` module decl
///    matching the `polkadot` module at the top of this file.
/// 2. Replace the stub body with a pattern mirroring [`fetch_balance`]:
///
///    ```ignore
///    let api = connect_rostro(&rpc_url).await.map_err(|e| anyhow::anyhow!(e))?;
///    let user_id = AccountId32::from_str(&user)?;
///    let issuer_id = AccountId32::from_str(&issuer)?;
///    let query = zkpki::storage().zk_pki().contract_offers(user_id, issuer_id);
///    let block = api.at_current_block().await?;
///    let offer = block.storage().entry(query)?.try_fetch(()).await?
///        .ok_or_else(|| anyhow!("no offer for (user, issuer)"))?
///        .decode()?;
///    Ok(offer.nonce.to_vec())
///    ```
///
/// 3. Exact storage item name follows the pallet's final layout — the
///    `UserIssuerKey` newtype wrapper referenced in `pki/CLAUDE.md`
///    means the actual query may take a single composite key.
///
/// Returning a `Vec<u8>` (rather than `[u8; 32]`) matches the rest of
/// this file's byte-vector convention; callers should assert `len() == 32`.
pub fn fetch_zkpki_offer_nonce(
    _user: String,
    _issuer: String,
    _rpc_url: String,
) -> Result<Vec<u8>, String> {
    // TODO(zkpki-pallet-deployment): replace with real subxt storage query.
    // See the doc comment above for the exact shape.
    Ok(vec![0u8; 32])
}

// ═══════════════════════════════════════════════════════════════════════════
// Runtime OS attestation — cross-platform spoof defense
//
// Dotwave is cross-platform by design. Different platforms produce different
// HIP proof shapes (StrongBox attestation chains vs TPM2 quote-certify pairs).
// Without a hard runtime check, an attacker could compile a dotwave variant
// that submits an Android-tagged HIP proof from a Linux box (or vice versa),
// exploiting the pallet verifier's dispatch on `HipPlatform`.
//
// This helper is layer #2 of the five-layer spoof defense described in memory
// `project_dotwave_cross_platform_spoof_defense.md`. It cross-checks multiple
// independent signals that the process is actually running on the platform it
// claims to be. Callers must invoke this before any platform-specific
// ceremony (StrongBox key generation, TPM2 quote, etc.) and abort cleanly on
// error — a failure here means one of the signals disagreed, which is
// either a misconfigured build or active spoof.
//
// Layer #1 (compile-time cfg-gating) prevents cross-platform code from
// linking into a single binary. Layers #3–#5 (cryptographic platform-tag
// match, on-chain `PlatformTag`, client-side PopAssertion enforcement) are
// pki-side responsibilities. This layer is the dotwave-runtime-refuses-to-
// produce-cross-platform-proofs guarantee.
// ═══════════════════════════════════════════════════════════════════════════

/// Result of a successful OS attestation. `signals_checked` is the count of
/// independent signals consulted; all must have agreed to produce this
/// value (disagreement yields `Err`). `evidence` is a semicolon-joined
/// description of the signals that fired, intended for logs and
/// Fagan-inspection audit trails rather than programmatic use.
#[derive(Debug)]
pub struct OsAttestation {
    pub expected: String,
    pub runtime_os: String,
    pub signals_checked: u32,
    pub evidence: String,
}

/// Verify at runtime that the caller is running on the platform they
/// expect. `expected` is a lowercase platform token — one of `"android"`,
/// `"linux"`, `"windows"`, `"macos"`, `"ios"`.
///
/// Signals consulted:
///
/// | Expected  | Signals                                                  |
/// |-----------|----------------------------------------------------------|
/// | `android` | `std::env::consts::OS` + `/system/build.prop` +          |
/// |           | `/system/bin/linker[64]` + `/apex` (modern Android)      |
/// | `linux`   | `std::env::consts::OS` + `/proc/version` + absence of    |
/// |           | `/system/build.prop` + absence of `/apex`                |
/// | `windows` | `std::env::consts::OS` + `C:\Windows\System32`           |
/// | `macos`   | `std::env::consts::OS` + `/System/Library/CoreServices`  |
/// | `ios`     | `std::env::consts::OS` only (no robust runtime probe)    |
///
/// All signals for a given platform must agree. Any disagreement returns
/// `Err(String)` describing which signals mismatched. Callers should
/// treat the error as a hard stop — do not proceed with platform-specific
/// ceremony work.
///
/// `std::env::consts::OS` is a compile-time constant baked into the
/// target binary; it cannot be spoofed at runtime without modifying the
/// binary itself. Filesystem signals catch the case where someone took a
/// genuine Android-built binary and ran it in a Linux chroot or
/// Docker-on-Android situation where the OS identity is ambiguous.
pub fn attest_runtime_os(expected: String) -> Result<OsAttestation, String> {
    let runtime_os = std::env::consts::OS.to_string();
    let expected = expected.to_ascii_lowercase();

    if runtime_os != expected {
        return Err(format!(
            "runtime_os mismatch: binary was compiled for '{}' but caller expected '{}'",
            runtime_os, expected
        ));
    }

    let mut signals_checked: u32 = 1;
    let mut evidence: Vec<String> = vec![format!("std::env::consts::OS={}", runtime_os)];

    match expected.as_str() {
        "android" => {
            // build.prop is the canonical Android marker. Absent → not Android.
            if !std::path::Path::new("/system/build.prop").exists() {
                return Err(format!(
                    "expected android but /system/build.prop absent. evidence: [{}]",
                    evidence.join("; ")
                ));
            }
            signals_checked += 1;
            evidence.push("/system/build.prop exists".to_string());

            // Linker presence confirms userspace ABI is Android.
            let linker_present = std::path::Path::new("/system/bin/linker64").exists()
                || std::path::Path::new("/system/bin/linker").exists();
            if !linker_present {
                return Err(format!(
                    "expected android but /system/bin/linker(64) absent. evidence: [{}]",
                    evidence.join("; ")
                ));
            }
            signals_checked += 1;
            evidence.push("/system/bin/linker[64] exists".to_string());

            // APEX is present on Android 10+ (Q and above). Its absence on a
            // modern device is a strong spoof indicator.
            if std::path::Path::new("/apex").exists() {
                signals_checked += 1;
                evidence.push("/apex exists (Android ≥ 10)".to_string());
            } else {
                // Older Android (pre-Q) is a legitimate absence, but not a
                // target we expect to run on. Log rather than fail.
                evidence.push("/apex absent (pre-Q Android or spoof)".to_string());
            }
        }
        "linux" => {
            if !std::path::Path::new("/proc/version").exists() {
                return Err(format!(
                    "expected linux but /proc/version absent. evidence: [{}]",
                    evidence.join("; ")
                ));
            }
            signals_checked += 1;
            evidence.push("/proc/version exists".to_string());

            // Negative signal: /system/build.prop on a 'linux' target means
            // we're actually on Android (which kernels report as linux via
            // uname). Refuse.
            if std::path::Path::new("/system/build.prop").exists() {
                return Err(format!(
                    "expected linux but /system/build.prop is present (looks like Android). evidence: [{}]",
                    evidence.join("; ")
                ));
            }
            signals_checked += 1;
            evidence.push("/system/build.prop absent (not Android)".to_string());

            if std::path::Path::new("/apex").exists() {
                return Err(format!(
                    "expected linux but /apex is present (looks like Android). evidence: [{}]",
                    evidence.join("; ")
                ));
            }
            signals_checked += 1;
            evidence.push("/apex absent (not Android)".to_string());
        }
        "windows" => {
            if !std::path::Path::new(r"C:\Windows\System32").exists() {
                return Err(format!(
                    r"expected windows but C:\Windows\System32 absent. evidence: [{}]",
                    evidence.join("; ")
                ));
            }
            signals_checked += 1;
            evidence.push(r"C:\Windows\System32 exists".to_string());
        }
        "macos" => {
            if !std::path::Path::new("/System/Library/CoreServices").exists() {
                return Err(format!(
                    "expected macos but /System/Library/CoreServices absent. evidence: [{}]",
                    evidence.join("; ")
                ));
            }
            signals_checked += 1;
            evidence.push("/System/Library/CoreServices exists".to_string());
        }
        "ios" => {
            // iOS application sandboxing restricts filesystem probes. We
            // rely on target_os alone here and pick up additional signals
            // at the platform channel layer (Swift/Obj-C side).
            evidence.push("ios: no robust runtime probe; relies on target_os".to_string());
        }
        other => {
            return Err(format!(
                "unknown expected platform '{}' — valid: android|linux|windows|macos|ios",
                other
            ));
        }
    }

    Ok(OsAttestation {
        expected,
        runtime_os,
        signals_checked,
        evidence: evidence.join("; "),
    })
}

// ═══════════════════════════════════════════════════════════════════════════
// Stage 5e: ZK-PKI integrated-pallet extrinsics (StrongBox / MimeWrap)
// ═══════════════════════════════════════════════════════════════════════════
//
// Wrappers around the integrated `ZkPki` pallet on rostro-node. The mime-wrap
// surface is now folded into the cert lifecycle: commitments are recorded at
// `mint_cert` time and consumed at PoP-assertion time.
//
// Replaces the Stage 4c `ZkPkiMimeWrap` standalone-pallet wrappers
// (register_commitment / verify_and_record / sudo set_verifying_key); those
// extrinsics no longer exist on-chain. Mapping:
//
//   register_commitment(ec_key_pub, c)
//      → mint_cert(... commitment_c=Some(c), ec_key_pub_claimed=Some(ec_key_pub))
//   verify_and_record(ec_key_pub, bucket, nonce, otp, proof)
//      → self_discard_cert(thumbprint, Some(PopAssertion::MimeWrap{...}))
//        (or any future PoP-gated relying-party extrinsic)
//   Sudo.sudo(set_verifying_key(vk))
//      → set_mime_wrap_vk(vk)   [signed; PoC trust model, governance-routed
//                                in production]

// Convenience type aliases over the metadata-generated typed surface.
use polkadot::runtime_types::zk_pki_tpm::verify::AttestationPayloadV3 as TypedAttestationPayload;
use polkadot::runtime_types::zk_pki_primitives::hip::CanonicalHipProof as TypedCanonicalHipProof;
use polkadot::runtime_types::zk_pki_primitives::hip::StrongBoxHipProof as TypedStrongBoxHipProof;
use polkadot::runtime_types::zk_pki_primitives::pop::PopAssertion as TypedPopAssertion;
use polkadot::runtime_types::bounded_collections::bounded_vec::BoundedVec as TypedBoundedVec;
use subxt::config::transaction_extensions::{
    ChargeTransactionPaymentParams, CheckMortalityParams, CheckNonceParams,
};

pub(crate) const BINDING_PROOF_CONTEXT: &[u8] = b"zkpki-binding-proof-v1";

/// Fetch an account's nonce at the chain's BEST block (not finalized) via
/// `system_accountNextIndex`. subxt's default `sign_and_submit_default`
/// queries at the finalized head, which on dev nodes with stalled GRANDPA
/// finality is block 0 — so it returns 0 instead of the real best-block
/// nonce. On real Rostro testnet with multi-validator finality keeping pace,
/// the default path would work; this helper is robust for both.
pub(crate) async fn fetch_best_nonce(
    rpc: &subxt::rpcs::RpcClient,
    account: &AccountId32,
) -> Result<u64, String> {
    let ss58 = format!("{account}");
    let nonce: u64 = rpc
        .request("system_accountNextIndex", subxt::rpcs::rpc_params![ss58])
        .await
        .map_err(|e| format!("system_accountNextIndex: {}", e))?;
    Ok(nonce)
}

/// Build the full 11-tuple TransactionExtensions::Params matching the Rostro
/// (gemini-runtime) TxExtension order. Immortal era + explicit nonce so we don't
/// depend on subxt's at-finalized model on stalled-finality dev nodes.
pub(crate) fn rostro_tx_params(nonce: u64) -> (
    (), (), (), (),
    CheckMortalityParams<RostroConfig>,
    CheckNonceParams,
    (),
    ChargeTransactionPaymentParams,
    (),
) {
    // 9-element params, matching RostroConfig::TransactionExtensions (gemini rig).
    (
        (), // CheckNonZeroSenderShim
        (), // CheckSpecVersion
        (), // CheckTxVersion
        (), // CheckGenesis
        CheckMortalityParams::<RostroConfig>::immortal(),
        CheckNonceParams::with_nonce(nonce),
        (), // CheckWeightShim
        ChargeTransactionPaymentParams::no_tip(),
        (), // CheckMetadataHash
    )
}

/// Install the mime-wrap Groth16 verifying key on-chain via `zkPki.set_mime_wrap_vk`.
/// Signed extrinsic (no sudo needed in the integrated pallet's PoC trust model).
/// Production wiring routes this through a governance origin.
pub fn submit_set_mime_wrap_vk(
    vk_bytes_hex: String,
    phrase: String,
    rpc_url: String,
) -> Result<String, String> {
    let vk_bytes = decode_hex_bytes(&vk_bytes_hex, "vk_bytes")?;
    if vk_bytes.is_empty() {
        return Err("vk_bytes is empty".to_string());
    }
    let pair = sr25519::Pair::from_string(&phrase, None)
        .map_err(|e| format!("Keypair error: {:?}", e))?;
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let (api, rpc) = connect_rostro_with_rpc(&rpc_url).await?;
        let signer = Sr25519Signer(pair);
        let account = <Sr25519Signer as subxt::tx::Signer<RostroConfig>>::account_id(&signer);
        let nonce = fetch_best_nonce(&rpc, &account).await?;
        let tx = polkadot::tx().zk_pki().set_mime_wrap_vk(vk_bytes);
        let mut tx_client = api.tx().await.map_err(|e| e.to_string())?;
        let mut signable = tx_client
            .create_signable(&tx, &account, rostro_tx_params(nonce))
            .await.map_err(|e| e.to_string())?;
        let signed = signable.sign(&signer).map_err(|e| e.to_string())?;
        submit_signed_watched(signed).await
    })
}

/// Bundle of S20 ceremony bytes for a StrongBox-tier `mint_cert`. All
/// hex strings are 0x-prefix tolerant. The dotwave Stage 4c panel emits
/// these via the "Raw bytes for mint_cert payload" log block.
pub struct StrongBoxCeremonyBundle {
    /// 65-byte SEC1 (uncompressed P-256) public key of the cert_ec key.
    /// Strip the 26-byte SPKI envelope from the ceremony's 91-byte DER
    /// before passing.
    pub cert_ec_public_sec1_hex: String,
    /// 65-byte SEC1 public key of the attest_ec key. Extract from the
    /// attest_ec_chain leaf cert via `openssl x509 -pubkey`.
    pub attest_ec_public_sec1_hex: String,
    /// `attest_ec_chain[0]` DER bytes — the leaf certificate. The chain
    /// only checks non-empty here in v1; full chain-to-Google-root
    /// verification is deferred.
    pub cert_ec_chain_leaf_hex: String,
    pub attest_ec_chain_leaf_hex: String,
    /// 32-byte HMAC binding output emitted by the StrongBox HMAC key.
    pub hmac_binding_output_hex: String,
    /// DER-ECDSA signature by `attest_ec` over
    /// `SHA-256(blake2_256(hmac_binding_output || nonce))`.
    pub hmac_binding_signature_hex: String,
    /// Gate-2 integrity blob (SCALE-encoded `IntegrityAttestation`).
    pub integrity_blob_hex: String,
    /// DER-ECDSA signature by `cert_ec` over `SHA-256(blake2_256(integrity_blob))`.
    pub integrity_signature_hex: String,
    /// 32-byte ceremony challenge — baked into both EC keys'
    /// setAttestationChallenge AND the input the binding signature
    /// signed over. Goes into `StrongBoxHipProof.nonce`. NOT the
    /// mime-wrap-replay-map nonce.
    pub challenge_hex: String,
}

/// `mint_cert` for a StrongBox / MimeWrap template. Called by the user
/// (cert recipient) after an issuer has called `offer_contract` for them.
///
/// The chain re-derives `ec_key_pub` from the verified `cert_ec` SEC1
/// pubkey and asserts equality with `ec_key_pub_claimed_hex` (Rostro
/// tripwire / option B). On mainnet, the same value will be chain-derived
/// only.
///
/// `attestation_payload.integrity_blob` is the SCALE-encoded `MockVerdict::Tpm{...}`
/// blob the testnet `NoopBindingProofVerifier` decodes. `bundle.integrity_blob_hex`
/// is the real Gate-2 `IntegrityAttestation` blob the StrongBox HIP signature
/// commits to. They serve different layers and are kept distinct.
pub fn submit_mint_cert_strongbox(
    contract_nonce_hex: String,
    offer_created_at_block: u32,
    integrity_blob_for_mock_verdict_hex: String,
    bundle: StrongBoxCeremonyBundle,
    commitment_c_hex: String,
    ec_key_pub_claimed_hex: String,
    phrase: String,
    rpc_url: String,
) -> Result<String, String> {
    let contract_nonce = decode_hex_32(&contract_nonce_hex, "contract_nonce")?;
    let cert_ec_public_sec1 = decode_hex_n::<65>(
        &bundle.cert_ec_public_sec1_hex, "cert_ec_public_sec1")?;
    let attest_ec_public_sec1 = decode_hex_n::<65>(
        &bundle.attest_ec_public_sec1_hex, "attest_ec_public_sec1")?;
    let cert_ec_chain_leaf = decode_hex_bytes(
        &bundle.cert_ec_chain_leaf_hex, "cert_ec_chain_leaf")?;
    let attest_ec_chain_leaf = decode_hex_bytes(
        &bundle.attest_ec_chain_leaf_hex, "attest_ec_chain_leaf")?;
    let hmac_binding_output = decode_hex_32(
        &bundle.hmac_binding_output_hex, "hmac_binding_output")?;
    let hmac_binding_signature = decode_hex_bytes(
        &bundle.hmac_binding_signature_hex, "hmac_binding_signature")?;
    let real_integrity_blob = decode_hex_bytes(
        &bundle.integrity_blob_hex, "integrity_blob")?;
    let integrity_signature = decode_hex_bytes(
        &bundle.integrity_signature_hex, "integrity_signature")?;
    let challenge = decode_hex_32(&bundle.challenge_hex, "challenge")?;
    let mock_verdict_blob = decode_hex_bytes(
        &integrity_blob_for_mock_verdict_hex, "integrity_blob_for_mock_verdict")?;
    let commitment_c = decode_hex_32(&commitment_c_hex, "commitment_c")?;
    let ec_key_pub_claimed =
        decode_hex_32(&ec_key_pub_claimed_hex, "ec_key_pub_claimed")?;

    let attestation = TypedAttestationPayload {
        cert_ec_chain: vec![cert_ec_chain_leaf.clone()],
        attest_ec_chain: vec![attest_ec_chain_leaf.clone()],
        hmac_binding_output,
        binding_signature: vec![],
        integrity_blob: mock_verdict_blob,
        integrity_signature: vec![],
    };
    let hip_proof = TypedCanonicalHipProof::StrongBox(TypedStrongBoxHipProof {
        cert_ec_public: cert_ec_public_sec1,
        attest_ec_public: attest_ec_public_sec1,
        cert_ec_chain: TypedBoundedVec(vec![TypedBoundedVec(cert_ec_chain_leaf)]),
        attest_ec_chain: TypedBoundedVec(vec![TypedBoundedVec(attest_ec_chain_leaf)]),
        hmac_binding_output,
        hmac_binding_signature: TypedBoundedVec(hmac_binding_signature),
        binding_proof_context: TypedBoundedVec(BINDING_PROOF_CONTEXT.to_vec()),
        integrity_blob: TypedBoundedVec(real_integrity_blob),
        integrity_signature: TypedBoundedVec(integrity_signature),
        nonce: challenge,
    });

    let pair = sr25519::Pair::from_string(&phrase, None)
        .map_err(|e| format!("Keypair error: {:?}", e))?;
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let (api, rpc) = connect_rostro_with_rpc(&rpc_url).await?;
        let signer = Sr25519Signer(pair);
        let account = <Sr25519Signer as subxt::tx::Signer<RostroConfig>>::account_id(&signer);
        let nonce = fetch_best_nonce(&rpc, &account).await?;
        let tx = polkadot::tx().zk_pki().mint_cert(
            contract_nonce,
            attestation,
            offer_created_at_block,
            Some(hip_proof),
            Some(commitment_c),
            Some(ec_key_pub_claimed),
        );
        let mut tx_client = api.tx().await.map_err(|e| e.to_string())?;
        let mut signable = tx_client
            .create_signable(&tx, &account, rostro_tx_params(nonce))
            .await.map_err(|e| e.to_string())?;
        let signed = signable.sign(&signer).map_err(|e| e.to_string())?;
        submit_signed_watched(signed).await
    })
}

/// `self_discard_cert` with `PopAssertion::MimeWrap`. Cert holder asserts
/// PoP via a fresh Groth16 proof bound to the (bucket, nonce) replay-map
/// key. The hip_proof must reproduce the exact bytes recorded at mint
/// time (cert_ec / attest_ec hashes match the genesis fingerprint), which
/// in practice means re-running the StrongBox ceremony against the same
/// cert_ec / attest_ec keys.
pub fn submit_self_discard_cert_mime_wrap(
    cert_thumbprint_hex: String,
    bucket: u64,
    mime_wrap_nonce_hex: String,
    user_otp: u32,
    proof_bytes_hex: String,
    bundle: StrongBoxCeremonyBundle,
    phrase: String,
    rpc_url: String,
) -> Result<String, String> {
    let cert_thumbprint = decode_hex_32(&cert_thumbprint_hex, "cert_thumbprint")?;
    let mime_wrap_nonce = decode_hex_32(&mime_wrap_nonce_hex, "mime_wrap_nonce")?;
    let proof_bytes = decode_hex_bytes(&proof_bytes_hex, "proof_bytes")?;
    if proof_bytes.len() != 128 {
        return Err(format!(
            "proof must be 128 bytes (got {}); Groth16 compressed BN254 is fixed-size",
            proof_bytes.len()
        ));
    }
    let cert_ec_public_sec1 = decode_hex_n::<65>(
        &bundle.cert_ec_public_sec1_hex, "cert_ec_public_sec1")?;
    let attest_ec_public_sec1 = decode_hex_n::<65>(
        &bundle.attest_ec_public_sec1_hex, "attest_ec_public_sec1")?;
    let cert_ec_chain_leaf = decode_hex_bytes(
        &bundle.cert_ec_chain_leaf_hex, "cert_ec_chain_leaf")?;
    let attest_ec_chain_leaf = decode_hex_bytes(
        &bundle.attest_ec_chain_leaf_hex, "attest_ec_chain_leaf")?;
    let hmac_binding_output = decode_hex_32(
        &bundle.hmac_binding_output_hex, "hmac_binding_output")?;
    let hmac_binding_signature = decode_hex_bytes(
        &bundle.hmac_binding_signature_hex, "hmac_binding_signature")?;
    let real_integrity_blob = decode_hex_bytes(
        &bundle.integrity_blob_hex, "integrity_blob")?;
    let integrity_signature = decode_hex_bytes(
        &bundle.integrity_signature_hex, "integrity_signature")?;
    let challenge = decode_hex_32(&bundle.challenge_hex, "challenge")?;

    let hip_proof = TypedCanonicalHipProof::StrongBox(TypedStrongBoxHipProof {
        cert_ec_public: cert_ec_public_sec1,
        attest_ec_public: attest_ec_public_sec1,
        cert_ec_chain: TypedBoundedVec(vec![TypedBoundedVec(cert_ec_chain_leaf)]),
        attest_ec_chain: TypedBoundedVec(vec![TypedBoundedVec(attest_ec_chain_leaf)]),
        hmac_binding_output,
        hmac_binding_signature: TypedBoundedVec(hmac_binding_signature),
        binding_proof_context: TypedBoundedVec(BINDING_PROOF_CONTEXT.to_vec()),
        integrity_blob: TypedBoundedVec(real_integrity_blob),
        integrity_signature: TypedBoundedVec(integrity_signature),
        nonce: challenge,
    });
    let pop = TypedPopAssertion::MimeWrap {
        cert_thumbprint,
        bucket,
        nonce: mime_wrap_nonce,
        user_otp,
        proof: TypedBoundedVec(proof_bytes),
        hip_proof,
    };

    let pair = sr25519::Pair::from_string(&phrase, None)
        .map_err(|e| format!("Keypair error: {:?}", e))?;
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let (api, rpc) = connect_rostro_with_rpc(&rpc_url).await?;
        let signer = Sr25519Signer(pair);
        let account = <Sr25519Signer as subxt::tx::Signer<RostroConfig>>::account_id(&signer);
        let nonce = fetch_best_nonce(&rpc, &account).await?;
        let tx = polkadot::tx().zk_pki().self_discard_cert(
            cert_thumbprint,
            Some(pop),
        );
        let mut tx_client = api.tx().await.map_err(|e| e.to_string())?;
        let mut signable = tx_client
            .create_signable(&tx, &account, rostro_tx_params(nonce))
            .await.map_err(|e| e.to_string())?;
        let signed = signable.sign(&signer).map_err(|e| e.to_string())?;
        submit_signed_watched(signed).await
    })
}

/// Deterministic P-256 cert seed for a dev account phrase. One seed
/// per account, always: `chat_mint_test_cert` is idempotent against
/// the on-chain `Roots` entry, so re-minting the same account with a
/// *different* seed would silently return a thumbprint bound to the
/// old pubkey and every subsequent auth signature would fail. Deriving
/// the seed from the phrase makes that mismatch unrepresentable.
pub fn dev_cert_seed_hex(phrase: String) -> String {
    hex::encode(sp_core::hashing::blake2_256(
        format!("rostro-dev-chat-cert/{phrase}").as_bytes(),
    ))
}

/// Phase-2 chat-auth dev mint: register a software P-256 device key as
/// a root cert via `register_root` and return the cert thumbprint the
/// chat-auth layer signs under.
///
/// Dev-box stand-in for the real StrongBox/TPM mint: gemini wires
/// `TpmTestAttestationVerifier` (ignores the attestation bytes) and
/// `NoopProxyValidator` (proxy check always passes), so one extrinsic
/// from a funded dev account mints an Active cert whose
/// `cert_ec_pubkey` is exactly the P-256 key `chat_send` signs with.
///
/// Idempotent: an account can hold at most one root, so if `Roots`
/// already has an entry for the signer the existing thumbprint is
/// returned instead of re-submitting.
pub fn chat_mint_test_cert(
    rpc_url: String,
    phrase: String,
    cert_seed_hex: String,
    ttl_blocks: u32,
) -> Result<String, String> {
    use polkadot::runtime_types::bounded_collections::bounded_vec::BoundedVec;
    use polkadot::runtime_types::zk_pki_primitives::crypto::{
        DevicePublicKey as TypedDevicePublicKey, KeyAlgorithm as TypedKeyAlgorithm,
    };

    let sec1 = hex::decode(crate::chat::chat_cert_pubkey(cert_seed_hex)?)
        .map_err(|e| format!("cert pubkey hex: {e}"))?;
    let pair = sr25519::Pair::from_string(&phrase, None)
        .map_err(|e| format!("Keypair error: {:?}", e))?;
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let (api, rpc) = connect_rostro_with_rpc(&rpc_url).await?;
        let signer = Sr25519Signer(pair);
        let account = <Sr25519Signer as subxt::tx::Signer<RostroConfig>>::account_id(&signer);

        if let Some(tp) = fetch_root_thumbprint(&rpc_url, &account).await? {
            return Ok(hex::encode(tp));
        }

        let nonce = fetch_best_nonce(&rpc, &account).await?;
        let device_pubkey = TypedDevicePublicKey {
            algorithm: TypedKeyAlgorithm::EcdsaP256,
            key_bytes: BoundedVec(sec1),
        };
        let tx = polkadot::tx().zk_pki().register_root(
            account.clone(), // proxy — NoopProxyValidator admits any value
            device_pubkey,
            BoundedVec(b"dev-test-attestation".to_vec()), // ignored by the test verifier
            ttl_blocks,
            BoundedVec(vec![]), // no capability EKUs
        );
        let mut tx_client = api.tx().await.map_err(|e| e.to_string())?;
        let mut signable = tx_client
            .create_signable(&tx, &account, rostro_tx_params(nonce))
            .await.map_err(|e| e.to_string())?;
        let signed = signable.sign(&signer).map_err(|e| e.to_string())?;
        signed.submit().await.map_err(|e| e.to_string())?;

        // Poll until the mint lands in best state (dev chain: ~1 block).
        for _ in 0..30 {
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            if let Some(tp) = fetch_root_thumbprint(&rpc_url, &account).await? {
                return Ok(hex::encode(tp));
            }
        }
        Err("register_root submitted but Roots entry never appeared (30 polls)".into())
    })
}

/// Read `ZkPki::Roots(account).cert_thumbprint` from chain storage, or
/// `None` if the account holds no root cert.
async fn fetch_root_thumbprint(
    rpc_url: &str,
    account: &AccountId32,
) -> Result<Option<[u8; 32]>, String> {
    use parity_scale_codec::Encode;
    let (client, metadata) = crate::rostro_client::connect(rpc_url).await?;
    let key = account.0.encode();
    let record = client
        .fetch_storage(&metadata, "ZkPki", "Roots", &[&key])
        .await
        .map_err(|e| format!("ZkPki.Roots fetch: {e}"))?;
    match record {
        None => Ok(None),
        Some(v) => {
            let tp = crate::rostro_client::field(&v, "cert_thumbprint")
                .and_then(crate::rostro_client::as_bytes)
                .ok_or("RootRecord missing cert_thumbprint bytes")?;
            let tp: [u8; 32] = tp
                .try_into()
                .map_err(|_| "cert_thumbprint is not 32 bytes".to_string())?;
            Ok(Some(tp))
        }
    }
}

/// Extract the 65-byte SEC1 P-256 public key from an X.509 leaf cert's
/// SubjectPublicKeyInfo. The Stage 4c ceremony emits `attest_ec_chain[0]`
/// as DER but doesn't separately surface the SEC1 attest pubkey; this
/// helper searches the leaf DER for the standard P-256 ECDSA SPKI prefix
/// and returns the next 65 bytes (which begin with the `0x04`
/// uncompressed-point marker). Used by the Stage 5e mint-cert UI.
pub fn extract_sec1_from_x509_leaf(leaf_der: Vec<u8>) -> Result<Vec<u8>, String> {
    const P256_SPKI_PREFIX: &[u8] = &[
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D,
        0x02, 0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01,
        0x07, 0x03, 0x42, 0x00,
    ];
    let pos = leaf_der
        .windows(P256_SPKI_PREFIX.len())
        .position(|w| w == P256_SPKI_PREFIX)
        .ok_or_else(|| "P-256 SPKI prefix not found in leaf cert DER".to_string())?;
    let sec1_start = pos + P256_SPKI_PREFIX.len();
    let sec1_end = sec1_start + 65;
    if sec1_end > leaf_der.len() {
        return Err("leaf cert too short for SEC1 pubkey after SPKI prefix".to_string());
    }
    if leaf_der[sec1_start] != 0x04 {
        return Err(format!(
            "SEC1 pubkey at offset {} doesn't start with 0x04 (got 0x{:02x})",
            sec1_start, leaf_der[sec1_start]
        ));
    }
    Ok(leaf_der[sec1_start..sec1_end].to_vec())
}

pub(crate) fn decode_hex_n<const N: usize>(hex: &str, label: &str) -> Result<[u8; N], String> {
    let bytes = decode_hex_bytes(hex, label)?;
    if bytes.len() != N {
        return Err(format!("{label} must be {N} bytes (got {})", bytes.len()));
    }
    let mut out = [0u8; N];
    out.copy_from_slice(&bytes);
    Ok(out)
}

pub(crate) fn decode_hex_32(hex: &str, label: &str) -> Result<[u8; 32], String> {
    let bytes = decode_hex_bytes(hex, label)?;
    if bytes.len() != 32 {
        return Err(format!("{label} must be 32 bytes (got {})", bytes.len()));
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

pub(crate) fn decode_hex_bytes(hex: &str, label: &str) -> Result<Vec<u8>, String> {
    let s = hex.trim_start_matches("0x");
    if s.len() % 2 != 0 {
        return Err(format!("{label} has odd hex length: {}", s.len()));
    }
    let mut out = Vec::with_capacity(s.len() / 2);
    for i in (0..s.len()).step_by(2) {
        let byte = u8::from_str_radix(&s[i..i + 2], 16)
            .map_err(|_| format!("{label} contains non-hex chars at offset {i}"))?;
        out.push(byte);
    }
    Ok(out)
}

#[cfg(test)]
mod os_attestation_tests {
    use super::*;

    /// On the Linux dev box where this test suite runs, the `linux`
    /// attestation path must succeed — std::env::consts::OS is "linux",
    /// /proc/version exists, and /system/build.prop + /apex should both
    /// be absent on a normal Linux install. Skipped under CI matrix
    /// runs targeting other OSes.
    #[test]
    #[cfg(target_os = "linux")]
    fn linux_attestation_succeeds_on_linux_host() {
        let r = attest_runtime_os("linux".to_string())
            .expect("linux attestation must pass on linux host");
        assert_eq!(r.runtime_os, "linux");
        assert!(r.signals_checked >= 3, "at least 3 signals expected");
    }

    /// Attempting to attest as Android from a Linux host must fail at
    /// the std::env::consts::OS check (first gate). This is the primary
    /// defense: a Linux-compiled binary cannot claim Android by lying
    /// about target_os, because target_os is compile-time.
    #[test]
    #[cfg(target_os = "linux")]
    fn android_attestation_fails_on_linux_host() {
        let err = attest_runtime_os("android".to_string())
            .expect_err("android attestation must fail on linux host");
        assert!(
            err.contains("runtime_os mismatch"),
            "expected runtime_os mismatch error, got: {}",
            err,
        );
    }

    /// Same for claiming Windows / macOS / iOS on a Linux host.
    #[test]
    #[cfg(target_os = "linux")]
    fn non_linux_platforms_all_rejected_on_linux_host() {
        for bogus in ["android", "windows", "macos", "ios"] {
            let err = attest_runtime_os(bogus.to_string())
                .expect_err(&format!("{} attestation must fail on linux host", bogus));
            assert!(
                err.contains("runtime_os mismatch"),
                "expected mismatch for '{}', got: {}",
                bogus,
                err,
            );
        }
    }

    /// Unknown platform names are rejected with a distinctive error
    /// that mentions the valid alternatives, so caller mistakes are
    /// legible.
    #[test]
    fn unknown_platform_rejected_with_valid_options() {
        // std::env::consts::OS will mismatch whatever this is, so we
        // still hit the first gate rather than the unknown-platform
        // gate in the match. That's fine — the first gate is the
        // stronger check and returns first. The unknown-platform
        // branch is reachable only if someone hacks std::env to
        // report "frobnicator" as the OS, which isn't a realistic
        // scenario.
        let err = attest_runtime_os("frobnicator".to_string())
            .expect_err("bogus platform must fail");
        // Either "runtime_os mismatch" or "unknown expected platform"
        // is acceptable; both paths mean we refused.
        assert!(
            err.contains("runtime_os mismatch") || err.contains("unknown expected platform"),
            "expected refusal error, got: {}",
            err,
        );
    }

    /// Case-insensitive match on the expected-platform argument: "ANDROID"
    /// and "Android" and "android" are treated identically.
    #[test]
    #[cfg(target_os = "linux")]
    fn expected_platform_is_case_insensitive() {
        let r1 = attest_runtime_os("linux".to_string()).expect("lowercase");
        let r2 = attest_runtime_os("LINUX".to_string()).expect("uppercase");
        let r3 = attest_runtime_os("Linux".to_string()).expect("mixed case");
        assert_eq!(r1.expected, r2.expected);
        assert_eq!(r2.expected, r3.expected);
        assert_eq!(r1.expected, "linux");
    }
}

/// End-to-end proof that the typed write path lands on a live `gemini-node --dev`.
/// Drives the same `submit_typed` + `polkadot::tx()` codegen path the app uses,
/// seeded from `//Alice` (genesis-funded). Requires a block-producing node on
/// ws://127.0.0.1:9944. Run: `cargo test typed_writes -- --ignored --nocapture`.
#[cfg(test)]
mod typed_writes {
    use super::*;

    const NODE: &str = "ws://127.0.0.1:9944";

    #[test]
    #[ignore]
    fn alice_transfer_to_bob_lands() {
        const AMOUNT: u128 = 1_000_000_000_000;
        let bob = AccountId32::from(sr25519::Pair::from_string("//Bob", None).unwrap().public().0);
        let bob_ss58 = bob.to_string();
        let before: u128 = fetch_balance(bob_ss58.clone(), NODE.into()).unwrap().parse().unwrap();

        let hash = submit_typed("//Alice", NODE,
            polkadot::tx().balances().transfer_keep_alive(MultiAddress::Id(bob), AMOUNT))
            .expect("transfer submitted");
        println!("transfer tx: {hash}");

        let mut after = before;
        for _ in 0..40 {
            std::thread::sleep(std::time::Duration::from_secs(1));
            after = fetch_balance(bob_ss58.clone(), NODE.into()).unwrap().parse().unwrap();
            if after > before { break; }
        }
        assert_eq!(after - before, AMOUNT, "Bob should receive exactly AMOUNT");
        println!("Bob +{AMOUNT} confirmed on-chain");
    }

    /// R1 end-to-end: `register` must EXECUTE now that genesis initializes the
    /// RNS registry (Official + minted base node). Before R1 this failed
    /// OfficialNotInitiated → NotExist. Uses the same typed
    /// `rns_registrar().register(name, None)` path the app uses, signed by
    /// genesis-funded `//Alice`. Requires a block-producing R1 dev validator.
    #[test]
    #[ignore]
    fn alice_register_name_lands() {
        let name = "rostdemo";
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let outcome: Result<String, String> = rt.block_on(async {
            // Register as //Bob — a normal genesis-funded user. (//Alice is the
            // registry Official who OWNS the base node, so registering a subname
            // as Alice trips CannotOwnSubnameUnderOwnDomain — itself proof the
            // base node exists + is owned, i.e. R1 init ran.)
            let api = connect_rostro(NODE).await?;
            let pair = sr25519::Pair::from_string("//Charlie", None).map_err(|e| format!("{e:?}"))?;
            let signer = Sr25519Signer(pair);
            let tx = polkadot::tx().rns_registrar().register(name.as_bytes().to_vec(), None);
            let progress = api
                .tx()
                .await
                .map_err(|e| e.to_string())?
                .sign_and_submit_then_watch_default(&tx, &signer)
                .await
                .map_err(|e| e.to_string())?;
            // Err here carries the DECODED dispatch error (pallet::Error name).
            match progress.wait_for_finalized_success().await {
                Ok(_ev) => Ok("finalized OK".to_string()),
                Err(e) => Err(format!("{e}")),
            }
        });
        match outcome {
            Ok(loc) => println!("✅ register EXECUTED ({loc}). R1 end-to-end CONFIRMED."),
            Err(e) => panic!("register dispatch FAILED: {e}"),
        }
    }

    /// Phase 1+3: publish a chat-identity (outer key + content key) under a
    /// name and resolve both back.
    /// Charlie owns "rostdemo" (from the register test), so he can set its record.
    #[test]
    #[ignore]
    fn chat_identity_publish_resolve() {
        let name = "rostdemo";
        let identity_seed = "11".repeat(32);
        let expected_pubkey = crate::chat::chat_gen_identity(identity_seed.clone())
            .expect("derive identity")
            .ed25519_pubkey_hex;
        let content_key = crate::chat::chat_gen_content_key(0, "77".repeat(32))
            .expect("gen content key");
        let hash = chat_publish_identity(
            name.into(),
            "//Charlie".into(),
            NODE.into(),
            identity_seed.clone(),
            content_key.clone(),
        )
        .expect("publish chat identity");
        println!("published chat identity: {hash}");
        for i in 0..30 {
            std::thread::sleep(std::time::Duration::from_secs(1));
            let r = chat_resolve_identity(name.into(), NODE.into()).expect("resolve");
            if r.found {
                assert_eq!(r.ed25519_pubkey_hex, expected_pubkey, "resolved key mismatch");
                assert_eq!(r.inner_content_key_hex, content_key, "resolved content key mismatch");
                assert!(r.has_message_key, "MESSAGE content key should be present");
                // F1: the typed CHAT record is 32-byte-locked, so the X3DH
                // signed prekey is NO LONGER in the resolved identity. Where
                // the SPK lives in the typed-records world is F2's decision;
                // forward-secret send (which needs it) is F2 too.
                println!(
                    "✅ resolved {name} → CHAT key + MESSAGE content key (~{i}s). Typed CHAT+MESSAGE records work."
                );
                return;
            }
        }
        panic!("chat identity never resolved");
    }

    /// Phase 1 end-to-end: NAME-ADDRESSED messaging. Bob's account (//Dave)
    /// registers "bobchat" and publishes his chat key; Alice resolves the NAME
    /// (no hex), sends to the resolved key via the relays, Bob recovers it.
    /// Chain ops via the validator (9944); chat via the relays (9954/9956).
    #[test]
    #[ignore]
    fn name_addressed_message_lands() {
        use crate::chat::{
            chat_fetch, chat_gen_content_key, chat_gen_identity, chat_read_content, chat_send,
        };
        let validator = "ws://127.0.0.1:9944";
        let relay_send = "ws://127.0.0.1:9954";
        let relay_fetch = "ws://127.0.0.1:9956";
        let name = "bobchat";
        let bob_seed = "22".repeat(32);
        let alice_seed = "11".repeat(32);
        let bob_id = chat_gen_identity(bob_seed.clone()).expect("bob identity");
        // Phase 3: Bob's (software) P-256 content key, published in the record.
        let bob_content_seed = "88".repeat(32);
        let bob_content_key =
            chat_gen_content_key(0, bob_content_seed.clone()).expect("gen content key");

        // 1. Bob's account (//Dave) registers the name.
        submit_typed(
            "//Dave",
            validator,
            polkadot::tx().rns_registrar().register(name.as_bytes().to_vec(), None),
        )
        .expect("register submitted");
        let mut registered = false;
        for _ in 0..40 {
            std::thread::sleep(std::time::Duration::from_secs(1));
            if !check_name_availability(name.into(), validator.into()).unwrap().available {
                registered = true;
                break;
            }
        }
        assert!(registered, "name never registered");
        println!("registered {name}");

        // 2. Publish Bob's chat key under the name. Retry past the transient
        // back-to-back-tx nonce race (register→publish from one account).
        let mut published = false;
        for _ in 0..12 {
            if chat_publish_identity(
                name.into(),
                "//Dave".into(),
                validator.into(),
                bob_seed.clone(),
                bob_content_key.clone(),
            )
            .is_ok()
            {
                published = true;
                break;
            }
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
        assert!(published, "publish never submitted");
        let mut resolved = None;
        for _ in 0..40 {
            std::thread::sleep(std::time::Duration::from_secs(1));
            let r = chat_resolve_identity(name.into(), validator.into()).unwrap();
            if r.found {
                resolved = Some(r);
                break;
            }
        }
        let resolved = resolved.expect("chat identity never resolved");
        assert_eq!(resolved.ed25519_pubkey_hex, bob_id.ed25519_pubkey_hex, "resolved key mismatch");
        println!("resolved {name} → {}", resolved.ed25519_pubkey_hex);

        // 3. Alice sends to the RESOLVED key — no hex pasted, derived from
        // the name. Phase 2: the send is cert-gated; mint (idempotent)
        // //Dave's dev cert.
        let cert_seed = dev_cert_seed_hex("//Dave".into());
        let thumbprint =
            chat_mint_test_cert(validator.into(), "//Dave".into(), cert_seed.clone(), 600_000)
                .expect("mint test cert");
        let body = "name-addressed hello".to_string();
        // Phase 3: content sealed to the RESOLVED record's content key (MESSAGE).
        // F1/F2: the SPK is no longer in the resolved typed records (CHAT is
        // 32-byte-locked). Until F2 decides the SPK's on-chain home, the DR
        // bootstrap derives Bob's SPK from his seed locally (the test holds it);
        // the rest of the path is still record-driven (CHAT key + MESSAGE key).
        let bob_prekeys = crate::chat_dr::chat_dr_gen_prekeys(bob_seed.clone(), 0, 0)
            .expect("bob prekeys");
        let init = crate::chat_dr::chat_dr_initiate(
            alice_seed.clone(),
            resolved.ed25519_pubkey_hex.clone(),
            bob_prekeys.spk_pubkey_hex,
            bob_prekeys.spk_signature_hex,
            None,
            None,
        )
        .expect("x3dh initiate");
        let outcome = chat_send(
            relay_send.into(),
            alice_seed.clone(),
            resolved.ed25519_pubkey_hex.clone(),
            resolved.inner_content_key_hex.clone(),
            body.clone(),
            String::new(), // sender_name — item-2 test exercises this separately
            5,
            init.session_state_hex,
            Some(init.x3dh_init_hex),
            Some(thumbprint),
            Some(cert_seed),
        )
        .expect("send");
        println!("sent via name → msg {}", outcome.message_id_hex);

        // 4. Bob recovers it cross-node — at rest, then explicit read.
        let mut got = None;
        for _ in 0..20 {
            std::thread::sleep(std::time::Duration::from_secs(2));
            let msgs = chat_fetch(relay_fetch.into(), bob_seed.clone(), None).expect("fetch");
            if let Some(m) = msgs.into_iter().find(|m| m.message_id_hex == outcome.message_id_hex) {
                got = Some(m);
                break;
            }
        }
        let m = got.expect("message never recovered");
        let alice_id = chat_gen_identity(alice_seed).unwrap();
        assert_eq!(m.sender_pubkey_hex, alice_id.ed25519_pubkey_hex, "sender mismatch");
        let read = chat_read_content(
            m.sealed_content_hex.clone(),
            0,
            bob_content_seed,
            None, // new conversation — X3DH bootstrap from the message
            bob_seed.clone(),
            Vec::new(),
        )
        .expect("content read");
        assert_eq!(read.plaintext, body, "plaintext mismatch");
        assert!(read.ratcheted, "1:1 content must be ratcheted");
        println!(
            "✅ alice → resolve('{name}') → record-driven X3DH → send → bob read '{}'. Phase-1+3+5 name-addressed send works.",
            read.plaintext
        );
    }

    /// Phase 1 item 2: SENDER NAME on receive via forward-resolve-and-verify.
    /// Alice (//Eve) registers "alicechat" + publishes her chat key, then sends
    /// to Bob WITH her name claim inside the signed inner. Bob recovers, reads
    /// the claimed name, forward-resolves it, and verifies its published key
    /// equals the verified sender pubkey. No reverse directory lookup.
    #[test]
    #[ignore]
    fn sender_name_verified_on_receive() {
        use crate::chat::{chat_fetch, chat_gen_identity, chat_send};
        use std::time::Duration;
        let validator = "ws://127.0.0.1:9944";
        let relay_send = "ws://127.0.0.1:9954";
        let relay_fetch = "ws://127.0.0.1:9956";
        let alice_name = "alicechat";
        let alice_seed = "33".repeat(32);
        let bob_seed = "44".repeat(32);
        let alice_id = chat_gen_identity(alice_seed.clone()).expect("alice id");
        let bob_id = chat_gen_identity(bob_seed.clone()).expect("bob id");
        // Phase 3 CROSS-PLATFORM: Bob is the "TPM laptop" — his content
        // key is P-384 (curve tag 1, 48-byte seed); the sender follows
        // the recipient's curve. The other chat tests use P-256, so the
        // live fabric exercises both curves end-to-end.
        let alice_content_key = crate::chat::chat_gen_content_key(0, "99".repeat(32))
            .expect("alice content key");
        let bob_content_seed = "aa".repeat(48);
        let bob_content_key = crate::chat::chat_gen_content_key(1, bob_content_seed.clone())
            .expect("bob P-384 content key");

        // Alice's account (//Eve) registers the name + publishes her chat key.
        submit_typed(
            "//Eve",
            validator,
            polkadot::tx().rns_registrar().register(alice_name.as_bytes().to_vec(), None),
        )
        .expect("register submitted");
        let mut reg = false;
        for _ in 0..40 {
            std::thread::sleep(Duration::from_secs(1));
            if !check_name_availability(alice_name.into(), validator.into()).unwrap().available {
                reg = true;
                break;
            }
        }
        assert!(reg, "alicechat not registered");
        let mut pubd = false;
        for _ in 0..12 {
            if chat_publish_identity(alice_name.into(), "//Eve".into(), validator.into(), alice_seed.clone(), alice_content_key.clone()).is_ok() {
                pubd = true;
                break;
            }
            std::thread::sleep(Duration::from_secs(2));
        }
        assert!(pubd, "publish failed");
        let mut resolvable = false;
        for _ in 0..40 {
            std::thread::sleep(Duration::from_secs(1));
            if chat_resolve_identity(alice_name.into(), validator.into()).unwrap().found {
                resolvable = true;
                break;
            }
        }
        assert!(resolvable, "alicechat key not resolvable");

        // Alice sends to Bob WITH her name claim in the signed inner.
        // Phase 2: the send is cert-gated; mint (idempotent) //Eve's dev cert.
        let cert_seed = dev_cert_seed_hex("//Eve".into());
        let thumbprint =
            chat_mint_test_cert(validator.into(), "//Eve".into(), cert_seed.clone(), 600_000)
                .expect("mint test cert");
        let body = "hi from a named sender".to_string();
        // Phase 5: SPK-only bootstrap (Bob has no published record in
        // this test; the record-driven X3DH is covered by
        // name_addressed_message_lands).
        let bob_prekeys = crate::chat_dr::chat_dr_gen_prekeys(bob_seed.clone(), 0, 0)
            .expect("bob prekeys");
        let init = crate::chat_dr::chat_dr_initiate(
            alice_seed.clone(),
            bob_id.ed25519_pubkey_hex.clone(),
            bob_prekeys.spk_pubkey_hex,
            bob_prekeys.spk_signature_hex,
            None,
            None,
        )
        .expect("x3dh initiate");
        let outcome = chat_send(
            relay_send.into(),
            alice_seed.clone(),
            bob_id.ed25519_pubkey_hex.clone(),
            bob_content_key,
            body.clone(),
            alice_name.to_string(),
            5,
            init.session_state_hex,
            Some(init.x3dh_init_hex),
            Some(thumbprint),
            Some(cert_seed),
        )
        .expect("send");

        // Bob recovers (at rest) + reads via his P-384 key.
        let mut got = None;
        for _ in 0..20 {
            std::thread::sleep(Duration::from_secs(2));
            let msgs = chat_fetch(relay_fetch.into(), bob_seed.clone(), None).expect("fetch");
            if let Some(m) = msgs.into_iter().find(|m| m.message_id_hex == outcome.message_id_hex) {
                got = Some(m);
                break;
            }
        }
        let m = got.expect("not recovered");
        let read = crate::chat::chat_read_content(
            m.sealed_content_hex.clone(),
            1,
            bob_content_seed,
            None,
            bob_seed.clone(),
            Vec::new(),
        )
        .expect("P-384 content read");
        assert_eq!(read.plaintext, body, "plaintext mismatch");
        assert_eq!(read.claimed_sender_name, alice_name, "claimed name not carried");

        // FORWARD-RESOLVE-AND-VERIFY: the claimed name's published key must equal
        // the verified sender pubkey, else it's an impersonation attempt.
        let resolved = chat_resolve_identity(read.claimed_sender_name.clone(), validator.into())
            .expect("resolve claimed name");
        assert!(resolved.found, "claimed name does not resolve");
        assert_eq!(
            resolved.ed25519_pubkey_hex, m.sender_pubkey_hex,
            "claimed name's key != signed sender — IMPERSONATION"
        );
        println!(
            "✅ message from '{}' verified + read via P-384 content key (cross-curve). Phase-1+3 sender-name works.",
            read.claimed_sender_name
        );
    }

    /// Phase 1 item 3: one-step onboarding — register a name AND publish the chat
    /// identity in a single call (//Ferdie, fresh + endowed).
    #[test]
    #[ignore]
    fn chat_setup_messaging_onboards() {
        use crate::chat::{chat_gen_content_key, chat_gen_identity};
        let validator = "ws://127.0.0.1:9944";
        let name = "ferdiechat";
        let seed = "55".repeat(32);
        let id = chat_gen_identity(seed.clone()).expect("identity");
        let content_key = chat_gen_content_key(0, "bb".repeat(32)).expect("content key");
        let out = chat_setup_messaging(
            name.into(),
            "//Ferdie".into(),
            validator.into(),
            seed.clone(),
            content_key.clone(),
        )
        .expect("setup");
        assert!(out.registered, "name not registered");
        assert!(out.published, "chat identity not published");
        let r = chat_resolve_identity(name.into(), validator.into()).expect("resolve");
        assert!(r.found, "chat key not resolvable after onboarding");
        assert_eq!(r.ed25519_pubkey_hex, id.ed25519_pubkey_hex);
        assert_eq!(r.inner_content_key_hex, content_key, "content key not in record");
        println!(
            "✅ onboarded '{name}' → registered + published chat key {}. Phase-1 onboarding works.",
            r.ed25519_pubkey_hex
        );
    }
}