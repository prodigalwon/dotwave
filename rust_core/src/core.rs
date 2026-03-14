use bip39::{Mnemonic, Language};
use sp_core::{sr25519, Pair};
use aes_gcm::{Aes256Gcm, Key, Nonce, aead::{Aead, KeyInit}};
use argon2::{Argon2, password_hash::SaltString};

use getrandom::fill as getrandom_fill;

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
    // Derive a 32-byte key from passphrase using Argon2
    let mut salt_bytes = [0u8; 16];
    getrandom_fill(&mut salt_bytes).map_err(|e| format!("RNG failed: {:?}", e))?;
    let salt = SaltString::encode_b64(&salt_bytes).map_err(|e| format!("Salt encoding failed: {:?}", e))?;
    let argon2 = Argon2::default();
    let mut key_bytes = [0u8; 32];
    argon2
        .hash_password_into(passphrase.as_bytes(), salt.as_str().as_bytes(), &mut key_bytes)
        .map_err(|e| format!("Key derivation failed: {:?}", e))?;

    // Encrypt with AES-256-GCM
    let key = Key::<Aes256Gcm>::from_slice(&key_bytes);
    let cipher = Aes256Gcm::new(key);
    let mut nonce_bytes = [0u8; 12];
    getrandom_fill(&mut nonce_bytes).map_err(|e| format!("RNG failed: {:?}", e))?;
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, phrase.as_bytes())
        .map_err(|e| format!("Encryption failed: {:?}", e))?;

    // Return salt + nonce + ciphertext as single blob
    let mut result = Vec::new();
    result.extend_from_slice(salt.as_str().as_bytes());
    result.push(0u8); // null separator for salt string
    result.extend_from_slice(&nonce_bytes);
    result.extend_from_slice(&ciphertext);
    Ok(result)
}

#[flutter_rust_bridge::frb(sync)]
pub fn decrypt_phrase(blob: Vec<u8>, passphrase: String) -> Result<String, String> {
    // Split out salt string (null terminated)
    let salt_end = blob
        .iter()
        .position(|&b| b == 0)
        .ok_or("Invalid blob: no salt terminator")?;
    let salt_str = std::str::from_utf8(&blob[..salt_end])
        .map_err(|_| "Invalid salt encoding")?;
    let rest = &blob[salt_end + 1..];

    if rest.len() < 12 {
        return Err("Invalid blob: too short".to_string());
    }

    let nonce_bytes = &rest[..12];
    let ciphertext = &rest[12..];

    // Re-derive key
    let argon2 = Argon2::default();
    let mut key_bytes = [0u8; 32];
    argon2
        .hash_password_into(passphrase.as_bytes(), salt_str.as_bytes(), &mut key_bytes)
        .map_err(|e| format!("Key derivation failed: {:?}", e))?;

    let key = Key::<Aes256Gcm>::from_slice(&key_bytes);
    let cipher = Aes256Gcm::new(key);
    let nonce = Nonce::from_slice(nonce_bytes);

    let plaintext = cipher
        .decrypt(nonce, ciphertext)
        .map_err(|_| "Decryption failed: wrong passphrase or corrupted data")?;

    String::from_utf8(plaintext).map_err(|_| "Invalid UTF-8 in decrypted phrase".to_string())
}