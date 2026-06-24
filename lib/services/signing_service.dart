import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Service for signing operations using the StrongBox-backed P-256 identity key.
///
/// Every signing operation requires:
/// 1. BiometricPrompt authentication (unlocks the StrongBox key)
/// 2. TOTP verification (proves human presence)
/// 3. StrongBox performs the signature internally (key never leaves hardware)
///
/// The private key is born inside StrongBox and dies inside StrongBox.
/// No software memory exposure. No pass-the-hash surface.
class SigningService {
  static const _channel = MethodChannel('dotwave/security');

  /// Sign a challenge using the StrongBox identity key.
  ///
  /// The caller must have already:
  /// 1. Called initMacForBiometric() to prepare the CryptoObject
  /// 2. Presented BiometricPrompt to the user (authenticates the StrongBox key)
  /// 3. Verified the TOTP code (human liveness proof)
  ///
  /// The actual signing happens inside StrongBox. The private key never
  /// exists in application memory.
  ///
  /// Returns DER-encoded ECDSA P-256 signature, or null on failure.
  Future<Uint8List?> signChallenge(Uint8List challenge) async {
    try {
      final signature = await _channel.invokeMethod<Uint8List>(
        'signWithIdentityKey',
        {'data': challenge},
      );
      return signature;
    } catch (e) {
      return null;
    }
  }

  /// Get the identity public key for on-chain submission.
  /// This is the key that goes into the PKI cert as DevicePublicKey::EcdsaP256.
  Future<Uint8List?> getPublicKey() async {
    try {
      return await _channel.invokeMethod<Uint8List>('getIdentityPublicKey');
    } catch (e) {
      return null;
    }
  }
}
