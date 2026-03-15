use bip39::{Mnemonic, Language};
use sp_core::{sr25519, Pair};
use argon2::{Argon2, Algorithm, Version, Params};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce, aead::{Aead, KeyInit}};
use getrandom::fill as getrandom_fill;
use zeroize::Zeroize;
use zxcvbn::zxcvbn;
use subxt::{OnlineClient, PolkadotConfig, Config};
use subxt::utils::{AccountId32, MultiAddress, MultiSignature};
use std::str::FromStr;

struct Sr25519Signer(sr25519::Pair);

impl subxt::tx::Signer<PolkadotConfig> for Sr25519Signer {
    fn account_id(&self) -> <PolkadotConfig as Config>::AccountId {
        AccountId32::from(self.0.public().0)
    }

    fn sign(&self, payload: &[u8]) -> <PolkadotConfig as Config>::Signature {
        let sig = <sr25519::Pair as Pair>::sign(&self.0, payload);
        MultiSignature::Sr25519(sig.0)
    }
}

#[flutter_rust_bridge::frb(ignore)]
#[subxt::subxt(runtime_metadata_path = "src/polkadot_metadata.scale")]
pub mod polkadot {}

pub fn fetch_balance(address: String, rpc_url: String) -> anyhow::Result<String> {
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    rt.block_on(async {
        let api = OnlineClient::<PolkadotConfig>::from_insecure_url(&rpc_url).await?;
        let account = AccountId32::from_str(&address)
            .map_err(|e| anyhow::anyhow!("Invalid address: {}", e))?;

        let storage_query = polkadot::storage()
            .system()
            .account();

        let block = api.at_current_block().await?;
        let result = block
            .storage()
            .entry(storage_query)?
            .try_fetch((account,))
            .await?;

        let balance = match result {
            Some(sv) => {
                let info = sv.decode()?;
                info.data.free.to_string()
            }
            None => "0".to_string(),
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
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let api = OnlineClient::<PolkadotConfig>::from_insecure_url(&rpc_url)
            .await
            .map_err(|e| e.to_string())?;

        let name_bytes = name.as_bytes().to_vec();

        let block = api.at_current_block().await.map_err(|e| e.to_string())?;

        let resolve_payload = polkadot::runtime_apis()
            .pns_storage_api()
            .resolve_name(name_bytes.clone());

        let record: Option<_> = block
            .runtime_apis()
            .call(resolve_payload)
            .await
            .map_err(|e| e.to_string())?;

        let available = record.is_none();
        let for_sale = record.map(|r| r.for_sale).unwrap_or(false);

        Ok(NameAvailability { available, for_sale })
    })
}

pub fn resolve_address_to_name(_address: String, _rpc_url: String) -> Result<Option<String>, String> {
    // The current PNS runtime API does not store or expose the label string in any
    // on-chain structure. OwnerToPrimaryName returns a DomainHash (one-way hash),
    // and neither NameRecord nor RegistrarInfo contain the original label bytes.
    //
    // To implement this, the pallet needs one of:
    //   - A new storage map:   DomainHash → Vec<u8> (label bytes)
    //   - A new runtime API:   fn reverse_lookup(owner: AccountId) -> Option<Vec<u8>>
    //   - An off-chain indexer listening to registration events
    Ok(None)
}

#[flutter_rust_bridge::frb(sync)]
pub struct NameListing {
    pub price: String,  // planck as string
    pub seller: String, // SS58 address
}

pub fn get_name_listing(name: String, rpc_url: String) -> Result<Option<NameListing>, String> {
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let api = OnlineClient::<PolkadotConfig>::from_insecure_url(&rpc_url)
            .await
            .map_err(|e| e.to_string())?;

        let block = api.at_current_block().await.map_err(|e| e.to_string())?;

        let payload = polkadot::runtime_apis()
            .pns_storage_api()
            .get_listing(name.into_bytes());

        let result: Option<_> = block
            .runtime_apis()
            .call(payload)
            .await
            .map_err(|e| e.to_string())?;

        match result {
            None => Ok(None),
            Some(listing) => Ok(Some(NameListing {
                price: listing.price.to_string(),
                seller: format!("{}", listing.seller),
            })),
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
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let api = OnlineClient::<PolkadotConfig>::from_insecure_url(&rpc_url)
            .await
            .map_err(|e| e.to_string())?;

        let label = name.trim_end_matches(".dot").to_string();
        let block = api.at_current_block().await.map_err(|e| e.to_string())?;

        let payload = polkadot::runtime_apis()
            .pns_storage_api()
            .resolve_name(label.into_bytes());

        let record: Option<_> = block
            .runtime_apis()
            .call(payload)
            .await
            .map_err(|e| e.to_string())?;

        let record = match record {
            None => return Ok(None),
            Some(r) => r,
        };

        // Fetch the block hash at the registration block via System.BlockHash storage
        let block_hash = block
            .storage()
            .entry(polkadot::storage().system().block_hash())
            .map_err(|e| e.to_string())?
            .try_fetch((record.last_block,))
            .await
            .map_err(|e| e.to_string())?
            .and_then(|sv| sv.decode().ok())
            .map(|h: subxt::utils::H256| format!("{h:?}"))
            .unwrap_or_default(); // empty string if block too old for System storage

        Ok(Some(ResolvedName {
            owner: format!("{}", record.owner),
            last_block: record.last_block,
            block_hash,
        }))
    })
}

pub fn verify_name_ownership(
    name: String,
    block_hash_hex: String,
    expected_owner: String,
    rpc_url: String,
) -> Result<bool, String> {
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let api = OnlineClient::<PolkadotConfig>::from_insecure_url(&rpc_url)
            .await
            .map_err(|e| e.to_string())?;

        // Re-resolve the name at the current block and confirm the owner
        // still matches. block_hash_hex is returned to the caller for
        // independent out-of-band verification if required.
        let _ = block_hash_hex;

        let block = api.at_current_block().await.map_err(|e| e.to_string())?;

        let label = name.trim_end_matches(".dot").to_string();
        let payload = polkadot::runtime_apis()
            .pns_storage_api()
            .resolve_name(label.into_bytes());

        let record: Option<_> = block
            .runtime_apis()
            .call(payload)
            .await
            .map_err(|e| e.to_string())?;

        match record {
            None => Ok(false),
            Some(r) => Ok(format!("{}", r.owner) == expected_owner),
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
    let (pair, _) = sr25519::Pair::from_phrase(&phrase, None)
        .map_err(|e| format!("Keypair error: {:?}", e))?;
    let dest = AccountId32::from_str(&to_address)
        .map_err(|e| format!("Invalid address: {}", e))?;

    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let api = OnlineClient::<PolkadotConfig>::from_insecure_url(&rpc_url)
            .await
            .map_err(|e| e.to_string())?;

        let signer = Sr25519Signer(pair);
        let tx = polkadot::tx()
            .balances()
            .transfer_keep_alive(MultiAddress::Id(dest), amount);

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

pub fn buy_name(name: String, phrase: String, rpc_url: String) -> Result<String, String> {
    let (_pair, _) = sr25519::Pair::from_phrase(&phrase, None)
        .map_err(|e| format!("Keypair error: {:?}", e))?;

    // TODO: construct and submit the marketplace purchase extrinsic, e.g.:
    // let tx = polkadot::tx().pns_marketplace().buy(name.into_bytes());
    // let signer = Sr25519Signer(pair);
    // let api = OnlineClient::<PolkadotConfig>::from_insecure_url(&rpc_url).await?;
    // let hash = api.tx().await?.sign_and_submit_default(&tx, &signer).await?;
    // Ok(format!("{:?}", hash))
    let _ = rpc_url;
    Err("Name purchase extrinsic not yet implemented".to_string())
}

pub fn get_name_price(name: String, _rpc_url: String) -> Result<String, String> {
    let planck: u128 = match name.chars().count() {
        1 => 1_000 * 1_000_000_000_000,
        2 => 100  * 1_000_000_000_000,
        3 => 45   * 1_000_000_000_000,
        4 => 25   * 1_000_000_000_000,
        5 => 10   * 1_000_000_000_000,
        _ => 500_000_000_000, // 0.5 DOT
    };
    Ok(planck.to_string())
}

pub fn register_name(name: String, phrase: String, rpc_url: String) -> Result<String, String> {
    let (pair, _) = sr25519::Pair::from_phrase(&phrase, None)
        .map_err(|e| format!("Keypair error: {:?}", e))?;

    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let api = OnlineClient::<PolkadotConfig>::from_insecure_url(&rpc_url)
            .await
            .map_err(|e| e.to_string())?;

        let signer = Sr25519Signer(pair);
        let owner = MultiAddress::Id(AccountId32::from(signer.0.public().0));
        let name_bytes = name.into_bytes();

        let tx = polkadot::tx()
            .pns_registrar()
            .register(name_bytes, owner);

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