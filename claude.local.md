cat > CLAUDE.md << 'EOF'
# Dotwave — Claude Code Context

## What This Is
Dotwave is a mobile app (Android first, iOS later) that gives normies access to Polkadot ecosystem apps and products without knowing they're using a blockchain. Think WeChat — one app, everything inside it. Built with Flutter + Rust via flutter_rust_bridge.

## Dev Environment
- OS: Ubuntu 22.04 WSL2 on Windows (machine name: Lucy, user: coder)
- All tooling lives inside WSL at /home/coder/ — nothing on the Windows side
- Flutter: /home/coder/flutter (stable channel, 3.41.4)
- Android SDK: /home/coder/android
- Android NDK: /home/coder/android/ndk/27.0.12077973
- Rust: installed via rustup inside WSL

## Environment Variables (in /home/coder/.bashrc)
export ANDROID_HOME=/home/coder/android
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/27.0.12077973
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools
export PATH="/home/coder/flutter/bin:$PATH"

## Rust Targets Installed
aarch64-linux-android
armv7-linux-androideabi
x86_64-linux-android
i686-linux-android

## Project Structure
/home/coder/Polkadot/dotwave/
├── lib/
│   ├── main.dart                          # All Flutter UI currently
│   └── bridge/
│       └── bridge_generated.dart/         # THIS IS A DIRECTORY not a file
│           ├── frb_generated.dart         # Main import target
│           ├── frb_generated.io.dart
│           ├── frb_generated.web.dart
│           └── core.dart
├── android/
├── rust_core/
│   ├── src/
│   │   ├── lib.rs                         # just: pub mod core;
│   │   └── core.rs                        # All Rust logic
│   ├── .cargo/
│   │   └── config.toml                    # NDK linker config
│   └── Cargo.toml
└── flutter_rust_bridge.yaml

## CRITICAL: bridge_generated.dart is a DIRECTORY
The codegen outputs a directory not a file. Import like this:
import 'bridge/bridge_generated.dart/frb_generated.dart';

## flutter_rust_bridge.yaml
rust_input: "crate::core"
rust_root: rust_core/
dart_output: lib/bridge/bridge_generated.dart

## Dart Function Names (generated)
RustLib.instance.api.crateCoreGenerateAccount()  -> (DotAccount, String)
RustLib.instance.api.crateCoreRestoreAccount(phrase: String) -> DotAccount
RustLib must be initialized before use: await RustLib.init();

## IMPORTANT: Do not expose &mut String across the bridge
The zeroize_phrase function was removed because &mut String causes flutter_rust_bridge
to generate a shadowing String type that breaks Dart's core String. Zeroize internally
in Rust only, never expose mutable string refs across the bridge.

## Rust Dependencies (rust_core/Cargo.toml)
- bip39
- sp-core (full_crypto feature)
- zeroize (used internally, not exposed to bridge)
- rand
- flutter_rust_bridge

## NDK Linker Config (rust_core/.cargo/config.toml)
[target.aarch64-linux-android]
linker = "aarch64-linux-android-clang"
[target.armv7-linux-androideabi]
linker = "armv7a-linux-androideabi-clang"
[target.x86_64-linux-android]
linker = "x86_64-linux-android-clang"

## Current App State
Splash screen → checks secure storage for existing account → routes to
OnboardingScreen (new user) or HomeScreen (returning user).
OnboardingScreen has two buttons: Create Account and I already have an account.
CreateAccountScreen calls crateCoreGenerateAccount() and displays the phrase.
HomeScreen shows the account address.
Phrase display is NOT yet screenshot-blocked — must fix before any real users.

## Next Steps
1. Screenshot-block the phrase display screen (Android FLAG_SECURE)
2. Wire up cloud backup (Google Drive / OneDrive / iCloud)
3. Recovery passphrase encryption layer
4. Home screen shell with app launcher grid
5. DNS name registration screen with debounced RPC search
6. Governance feed

## Key Architecture Decisions
- Sr25519 keys, Polkadot native. Quantum resistance is Parity's future problem.
- Entropy generated via bip39 secure generation, never raw in app memory
- Seed phrase displayed ONCE in screenshot-blocked view then dropped
- Cloud backup = encrypted blob, NOT plaintext seed phrase
- Two-layer protection: device Keystore + recovery passphrase
- Recovery: cloud blob + recovery passphrase = restore on new device
- Seed phrase optionally exposable for power users (Talisman/Nova compat)
- zeroize used internally in Rust, never exposed across the bridge

## Full Product Scope
- Self-custody wallet normies don't know is a wallet
- WeChat-style home screen launching Polkadot ecosystem apps
- DNS name registration (Tony's DNS pallet integration)
- Governance feed with in-app voting
- Token send/receive
- Exchange integrations with referral revenue
- Zero-metadata encrypted messaging (in design, separate project)
- In-app browser opens Android Custom Tabs for the rare web things

## Related Projects
- DNS Pallet (Dot Naming Service) — separate Polkadot native pallet Tony is building
- Encrypted messaging protocol — zero metadata, in design
EOF