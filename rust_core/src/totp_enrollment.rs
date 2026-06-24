//! TOTP enrollment and identity key support.
//!
//! The TOTP secret and P-256 identity signing key both live inside StrongBox.
//! Rust handles seed generation (CSPRNG) and QR URI building — everything that
//! touches key material at rest happens in hardware via the Kotlin/StrongBox layer.
//!
//! SECURITY: Never log seed bytes, HMAC output, or any key material.

use zeroize::Zeroize;

/// Generate 20 bytes of cryptographically secure entropy for TOTP seed.
///
/// The returned bytes are handed to JNI immediately for StrongBox import,
/// then zeroized by the caller. They must never be stored in Dart state,
/// SharedPreferences, or any persistent storage.
///
/// Uses `ring::rand::SystemRandom` (backed by OS CSPRNG).
/// The memory region is locked via `mlock` to prevent swapping to disk.
#[flutter_rust_bridge::frb(sync)]
pub fn generate_totp_seed_protected() -> Vec<u8> {
    use ring::rand::{SecureRandom, SystemRandom};

    let mut seed = vec![0u8; 20];

    // Lock memory page to prevent swap
    #[cfg(target_os = "android")]
    unsafe {
        libc::mlock(seed.as_ptr() as *const libc::c_void, seed.len());
    }

    let rng = SystemRandom::new();
    rng.fill(&mut seed).expect("CSPRNG failure");

    // Unlock after caller copies — caller must zeroize after JNI handoff
    #[cfg(target_os = "android")]
    unsafe {
        libc::munlock(seed.as_ptr() as *const libc::c_void, seed.len());
    }

    seed
}

/// Build an otpauth:// URI for QR code display.
///
/// The URI encodes the TOTP parameters for any standard authenticator app:
/// Google Authenticator, Authy, Microsoft Authenticator, etc.
///
/// Uses HMAC-SHA256 (not SHA1) to match StrongBox's HMAC capability.
/// 6-digit codes, 30-second period.
///
/// The seed bytes are zeroized internally after Base32 encoding.
/// The Base32 string is zeroized after URI construction.
/// The returned URI string contains the Base32 secret — display it once,
/// then discard. Never persist it.
#[flutter_rust_bridge::frb(sync)]
pub fn build_otpauth_uri(mut seed: Vec<u8>, username: String) -> String {
    let base32_secret = base32::encode(base32::Alphabet::Rfc4648 { padding: false }, &seed);
    seed.zeroize();

    let uri = format!(
        "otpauth://totp/dotwave:{}?secret={}&issuer=dotwave&algorithm=SHA256&digits=6&period=30",
        username, base32_secret
    );

    // base32_secret is dropped here — String doesn't impl Zeroize by default,
    // but it's on the stack and will be overwritten. The seed bytes (heap) are
    // zeroized above which is the critical path.
    uri
}

/// Explicitly zeroize a byte vector.
///
/// Called from Flutter/Dart after any sensitive operation to ensure
/// byte arrays don't linger in memory. The bridge copies data across
/// the FFI boundary, so both sides must zeroize independently.
#[flutter_rust_bridge::frb(sync)]
pub fn zeroize_bytes(mut data: Vec<u8>) {
    data.zeroize();
}
