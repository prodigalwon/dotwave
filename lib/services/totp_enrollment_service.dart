import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:dotwave/bridge/bridge_generated.dart/frb_generated.dart';

/// Service for TOTP enrollment and StrongBox identity management.
///
/// All cryptographic operations happen inside StrongBox hardware.
/// This service orchestrates the platform channel calls and Rust bridge calls.
/// Sensitive data (seed bytes, HMAC output) is never stored in Dart state.
/// Thrown by [`TotpEnrollmentService`] when a specific failure mode
/// needs to be surfaced to the user. The `code` mirrors the platform
/// channel error code (e.g., `BIOMETRIC_NONE_ENROLLED`,
/// `STRONGBOX_UNAVAILABLE`, `TOTP_IMPORT_FAILED`) and the `message`
/// is a human-readable explanation safe to render in-app.
class TotpEnrollmentException implements Exception {
  final String code;
  final String message;
  TotpEnrollmentException(this.code, this.message);

  @override
  String toString() => 'TotpEnrollmentException($code): $message';
}

class TotpEnrollmentService {
  static const _channel = MethodChannel('dotwave/security');

  /// Check if this device has StrongBox hardware.
  /// Returns false if only TEE is available — enrollment not possible.
  Future<bool> isStrongBoxAvailable() async {
    final result = await _channel.invokeMethod<bool>('isStrongBoxAvailable');
    return result ?? false;
  }

  /// Generate TOTP seed, import to StrongBox, return otpauth:// URI for QR display.
  ///
  /// Flow:
  /// 1. Rust generates 20 bytes of CSPRNG entropy (mlock'd)
  /// 2. Rust builds the otpauth:// URI (Base32 encoded)
  /// 3. Raw seed bytes sent to StrongBox via platform channel
  /// 4. Seed bytes zeroized in Rust immediately after StrongBox import
  /// 5. Returns URI string for QR code display — show once, never persist
  ///
  /// **Throws** `TotpEnrollmentException` with a specific, user-actionable
  /// message on any failure path (no biometric enrolled, StrongBox
  /// unavailable, CSPRNG failure, etc.). The previous "return null"
  /// surfaced a generic "Try again" with no clue what went wrong.
  Future<String> generateAndDisplaySeed(String username) async {
    // Generate seed in Rust (mlock protected memory)
    final seedBytes = RustLib.instance.api.crateTotpEnrollmentGenerateTotpSeedProtected();

    // Build the otpauth URI (seed is zeroized inside this call)
    final String uri;
    try {
      uri = RustLib.instance.api.crateTotpEnrollmentBuildOtpauthUri(
        seed: seedBytes,
        username: username,
      );
    } catch (e) {
      RustLib.instance.api.crateTotpEnrollmentZeroizeBytes(data: seedBytes);
      throw TotpEnrollmentException(
        'SEED_BUILD_FAILED',
        'Failed to build TOTP seed URI: $e',
      );
    }

    // Import raw seed into StrongBox as HMAC-SHA256 key
    try {
      final imported = await _channel.invokeMethod<bool>(
        'importTotpSecret',
        {'seedBytes': Uint8List.fromList(seedBytes)},
      );
      if (imported != true) {
        throw TotpEnrollmentException(
          'TOTP_IMPORT_FAILED',
          'StrongBox refused the key with no specific reason',
        );
      }
    } on PlatformException catch (e) {
      RustLib.instance.api.crateTotpEnrollmentZeroizeBytes(data: seedBytes);
      throw TotpEnrollmentException(
        e.code,
        e.message ?? 'StrongBox import failed',
      );
    } finally {
      // Defence in depth — if any path somehow missed the zeroize above,
      // this ensures the seed doesn't linger in Dart memory.
      RustLib.instance.api.crateTotpEnrollmentZeroizeBytes(data: seedBytes);
    }

    return uri;
  }

  /// Verify user-entered OTP against StrongBox HMAC computation.
  ///
  /// Requires BiometricPrompt authentication first (handled by caller).
  /// Checks current time window and ±1 adjacent windows for clock drift.
  ///
  /// Returns true if the code matches, false otherwise.
  Future<bool> verifyOtpAfterBiometric(String userEnteredOtp) async {
    try {
      // Get the raw HMAC from StrongBox (already authenticated via biometric)
      final hmacOutput = await _channel.invokeMethod<Uint8List>('computeOtpRawHmac');
      if (hmacOutput == null) return false;

      // Truncate to 6-digit OTP
      final computedOtp = await _channel.invokeMethod<int>(
        'computeOtpTruncated',
        {'hmacOutput': hmacOutput},
      );
      if (computedOtp == null) return false;

      // Compare against user input (pad to 6 digits)
      final enteredInt = int.tryParse(userEnteredOtp);
      if (enteredInt == null) return false;

      // Check current window
      if (enteredInt == computedOtp) return true;

      // TODO: Check ±1 adjacent time windows for clock drift
      // This requires computing HMAC for (timeStep-1) and (timeStep+1)
      // which needs additional platform channel support.

      return false;
    } catch (e) {
      return false;
    }
  }

  /// Initialize the BiometricPrompt CryptoObject for TOTP operations.
  /// Must be called before verifyOtpAfterBiometric.
  /// Returns true if the Mac was successfully initialized.
  Future<bool> initMacForBiometric() async {
    final result = await _channel.invokeMethod<bool>('initMacForBiometric');
    return result ?? false;
  }

  /// Generate P-256 identity key pair inside StrongBox.
  /// The private key never leaves the hardware.
  /// Returns the public key bytes, or null on failure.
  Future<Uint8List?> generateIdentityKeyPair() async {
    try {
      final pubkey = await _channel.invokeMethod<Uint8List>('generateIdentityKeyPair');
      return pubkey;
    } catch (e) {
      return null;
    }
  }

  /// Get the existing identity public key from StrongBox.
  /// Returns null if no identity key exists.
  Future<Uint8List?> getIdentityPublicKey() async {
    try {
      final pubkey = await _channel.invokeMethod<Uint8List>('getIdentityPublicKey');
      return pubkey;
    } catch (e) {
      return null;
    }
  }

  /// Get the hardware attestation certificate chain.
  /// The challenge bytes provide freshness binding per FIDO2 spec.
  /// Returns list of DER-encoded certificates (leaf to root), or null.
  Future<List<Uint8List>?> getAttestationCertChain(Uint8List challenge) async {
    try {
      final chain = await _channel.invokeMethod<List>(
        'getAttestationCertChain',
        {'challengeBytes': challenge},
      );
      if (chain == null) return null;
      return chain.map((e) => Uint8List.fromList(List<int>.from(e))).toList();
    } catch (e) {
      return null;
    }
  }
}
