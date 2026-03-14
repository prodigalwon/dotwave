use bip39::{Mnemonic, Language};
use sp_core::{sr25519, Pair};
use argon2::{Argon2, Algorithm, Version, Params};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce, aead::{Aead, KeyInit}};
use getrandom::fill as getrandom_fill;
use zeroize::Zeroize;

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
    // Generate random salt
    let mut salt = [0u8; 32];
    getrandom_fill(&mut salt).map_err(|e| format!("RNG failed: {:?}", e))?;

    // Argon2id with hardened parameters
    // m_cost: 256MB, t_cost: 4 iterations, p_cost: 1
    let params = Params::new(262144, 4, 1, Some(32))
        .map_err(|e| format!("Argon2 params failed: {:?}", e))?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);

    let mut key_bytes = [0u8; 32];
    argon2
        .hash_password_into(passphrase.as_bytes(), &salt, &mut key_bytes)
        .map_err(|e| format!("Key derivation failed: {:?}", e))?;

    // Generate random nonce
    let mut nonce_bytes = [0u8; 12];
    getrandom_fill(&mut nonce_bytes).map_err(|e| format!("RNG failed: {:?}", e))?;

    // Encrypt with ChaCha20-Poly1305
    let key = Key::from_slice(&key_bytes);
    let cipher = ChaCha20Poly1305::new(key);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, phrase.as_bytes())
        .map_err(|e| format!("Encryption failed: {:?}", e))?;

    // Zero out key material
    key_bytes.zeroize();

    // Format: [32 bytes salt][12 bytes nonce][ciphertext]
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

    // Re-derive key with same hardened parameters
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