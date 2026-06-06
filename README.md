# Dotwave

Dotwave is a mobile app that gives everyday users access to the Polkadot ecosystem without needing to understand blockchain. Think of it as a WeChat-style super app — one interface, every Polkadot product and service inside it.

## What It Does

- **Self-custody wallet** — generates and manages a Polkadot account entirely on-device. No seed phrases shoved in your face, no blockchain jargon.
- **App launcher** — access Polkadot ecosystem apps, tools, and products from one place.
- **Name registration** — claim a human-readable name on the Polkadot network.
- **Governance** — view and vote on active referenda directly in-app.
- **Token operations** — send, receive, and eventually purchase DOT and ecosystem tokens.
- **Encrypted messaging** — zero-metadata peer-to-peer messaging (in development).

## Tech Stack

- **Flutter** — cross-platform UI (Android first, iOS coming)
- **Rust** — all cryptography, RPC calls, and business logic via `rust_core`
- **flutter_rust_bridge** — bridge between Flutter and Rust
- **Polkadot/Substrate** — Sr25519 keypairs, on-chain name resolution, governance

## Security Architecture

Dotwave is built with a security-first approach. Key material never exists in plaintext in application memory longer than necessary.

- Keypair generation via BIP39 with Sr25519 (Polkadot native)
- Seed phrase displayed once in a screenshot-blocked window, then dropped
- Android Keystore (StrongBox/TEE) for hardware-backed on-device key protection
- Backup encryption: **Argon2id + ChaCha20-Poly1305** with hardened parameters (256MB memory cost, 4 iterations)
- Biometric/PIN authentication gate for returning users
- Recovery: encrypted cloud backup + user passphrase — no Dotwave servers involved
- Passphrase entropy enforcement via zxcvbn with live strength meter
- Paste-friendly passphrase fields with autofill hint support for password managers

## Cloud Backup Providers

- Google Drive
- OneDrive
- WebDAV (Proton Drive, Nextcloud, iCloud, and any WebDAV-compatible service)
- Local file export (advanced option with explicit user warning)

## Project Structure

```
dotwave/
├── lib/
│   ├── main.dart                    # App entry, all screens and navigation
│   ├── keystore.dart                # Android Keystore platform channel
│   ├── cloud_backup.dart            # CloudBackupProvider abstract interface
│   ├── backup_provider_screen.dart  # Provider picker UI for backup
│   ├── restore_provider_screen.dart # Provider picker UI for restore
│   └── providers/
│       ├── google_drive_provider.dart
│       ├── onedrive_provider.dart
│       ├── webdav_provider.dart
│       └── local_backup_provider.dart
├── android/
│   └── app/src/main/kotlin/com/dotwave/dotwave/
│       └── MainActivity.kt          # Android Keystore + biometric platform code
├── rust_core/
│   ├── src/
│   │   ├── lib.rs
│   │   └── core.rs                  # Keypair gen, encrypt, decrypt, entropy check
│   └── Cargo.toml
└── flutter_rust_bridge.yaml
```

## Building

### Prerequisites

- Ubuntu 22.04 (WSL2 supported)
- Flutter SDK (stable channel)
- Rust via rustup
- Android SDK + NDK 27.0.12077973
- Java 17

### Android targets

```bash
rustup target add aarch64-linux-android
rustup target add armv7-linux-androideabi
rustup target add x86_64-linux-android
```

### Build

```bash
flutter pub get
flutter_rust_bridge_codegen generate
flutter build apk --debug
```

## Onboarding Flow

**New user:** Generate account → view seed phrase (screenshot blocked) → set recovery passphrase (entropy enforced) → choose cloud backup provider → upload encrypted backup → home screen

**Returning user:** Biometric/PIN authentication → home screen

**Account recovery:** Enter passphrase → choose backup provider → download encrypted blob → decrypt → restore keypair → home screen

## Android Screen Lock Requirement

When Dotwave is first installed on Android, the system may prompt the
user to configure device security (PIN, pattern, biometric, or none).
If the user selects no screen lock, the StrongBox ceremony can still
complete technically — StrongBox keypair generation does not require
screen lock to be set. However the security objective is weakened:

- Without screen lock, physical access to an unlocked device is
  sufficient to use the `cert_ec` keypair for signing operations
- The TOTP secret in the authenticator app is also accessible without
  screen lock
- The hardware guarantee (private key never leaves StrongBox) is
  preserved — screen lock does not affect key exportability
- What is lost is the **user presence guarantee** — the assumption
  that a signing operation requires a live human to authenticate

Dotwave **SHOULD** enforce that a screen lock is configured before
allowing the ZK-PKI genesis ceremony to proceed. The Android
`KeyguardManager` API can check whether a secure screen lock (PIN,
pattern, or biometric) is set:

```kotlin
val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE)
    as KeyguardManager
val isSecure = keyguardManager.isDeviceSecure
```

If `isDeviceSecure` returns false, Dotwave should block the ceremony
and present a clear explanation: *"A PIN, pattern, or biometric lock
is required to use ZK-PKI. Please configure device security in your
Android settings before continuing."*

This is a **Dotwave client enforcement** — not a pallet enforcement.
The pallet cannot detect screen lock status from the attestation
chain. Screen lock state is not attested in the Android Key
Attestation `AuthorizationList` for StrongBox keys unless the key
was created with `userAuthenticationRequired = true`. Dotwave should
create the `cert_ec` key with `userAuthenticationRequired = true`
and an appropriate `userAuthenticationValidityDurationSeconds`,
ensuring that the OS enforces authentication before each signing
operation.

Selecting "none" for screen lock at app install time is a user
operational risk, not a protocol flaw. The hardware binding
guarantee is intact. The user presence guarantee is weakened.

### FAQ — What happens if I set up my phone with no PIN or biometric?

Your ZK-PKI certificate is still hardware-bound — your private key
never leaves your device's secure hardware regardless of screen lock
settings. However without a screen lock anyone with physical access
to your unlocked phone could use your certificate to sign
transactions. Dotwave requires a PIN, pattern, or biometric to be
configured before the certificate ceremony. If you later remove
your screen lock, your certificate remains valid but we strongly
recommend re-enabling device security.

## Known Limitations & TODOs

### Name Registration Pricing

Name registration fees are currently **hardcoded** in `rust_core/src/core.rs` (`get_name_price`) using a tiered length-based table (e.g. 1-char = 1000 DOT, 6+ chars = 0.5 DOT). This is a temporary stand-in.

**Before production:** replace with a live query to the on-chain `price_oracle` pallet. Governance can update the price schedule at any time via referendum, so hardcoding will silently go stale. The correct approach is to call the oracle at registration time and display whatever the chain currently reports.

### PNS Reverse Lookup (Address → Display Name)

The home screen is wired to show an owned name (e.g. `frank`) instead of the truncated SS58 address, but `resolve_address_to_name` currently returns `None` always. The PNS pallet does not store the label string in any on-chain structure accessible from the client — `OwnerToPrimaryName` returns a `DomainHash` (one-way hash), and neither `NameRecord` nor `RegistrarInfo` contain the original label bytes. Requires one of: a new `DomainHash → Vec<u8>` storage map, a new `reverse_lookup(AccountId)` runtime API, or an off-chain indexer.

### Name Registration Extrinsic

The `register_name` function in Rust connects to the node and derives the keypair, but the actual PNS registration extrinsic submission is stubbed pending confirmation of the pallet call name and parameters.

## Status

Security foundation complete. Account lifecycle (create, backup, restore, authenticate) fully implemented. Name search, availability checking, and marketplace listing detection live. Transaction confirmation blade (reusable for all TX types) in place. Name registration extrinsic and price oracle integration pending.

## License

Private. All rights reserved.