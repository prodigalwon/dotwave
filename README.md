# Dotwave

<img width="471" height="1025" alt="image" src="https://github.com/user-attachments/assets/c8060738-9049-4e0d-b234-5ac13abeb04b" />



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

## Project Structure

```
dotwave/
├── lib/                        # Flutter/Dart UI
│   ├── main.dart               # App entry, screens, navigation
│   └── keystore.dart           # Android Keystore platform channel
├── android/                    # Android project files
├── rust_core/                  # Rust core library
│   ├── src/
│   │   ├── lib.rs
│   │   └── core.rs             # Crypto, keypair, RPC logic
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

## Status

Early development. Security foundation is complete. Feature buildout in progress.

## License

Private. All rights reserved.
