import 'package:flutter/services.dart';

/// StrongBox-backed P-256 content (decrypt) key — the inner-envelope silicon
/// seam (Phase 3, "hardware-bound content").
///
/// A SEPARATE StrongBox key from the identity/signing key ([SigningService]):
/// StrongBox forbids one key doing both SIGN and AGREE_KEY, and the chat
/// architecture splits node-admission (sign) from content decrypt (ECDH) by
/// design. The private scalar is born in StrongBox with PURPOSE_AGREE_KEY and
/// never leaves; decryption is the in-chip ECDH in [ecdhHex], biometric-gated.
///
/// All methods degrade to null when StrongBox / API-31 is unavailable (e.g. the
/// dev box, the emulator), which the caller reads as "fall back to the software
/// content seed".
class ContentKeyService {
  static const _channel = MethodChannel('dotwave/security');

  /// Generate the StrongBox content key (idempotent at the alias level —
  /// regenerating rotates it). Returns the public key as raw SEC1 uncompressed
  /// hex (65 bytes, 0x04‖X‖Y), or null if unavailable.
  Future<String?> generateHex() async {
    final bytes = await _invokeBytes('generateContentKeyPair');
    return bytes == null ? null : _toHex(bytes);
  }

  /// The content key's public half (raw SEC1 uncompressed hex), or null if not
  /// generated / unavailable.
  Future<String?> publicKeyHex() async {
    final bytes = await _invokeBytes('getContentPublicKey');
    return bytes == null ? null : _toHex(bytes);
  }

  /// In-chip ECDH against the sender's per-message ephemeral public key
  /// ([ephemeralSec1UncompressedHex], 65-byte SEC1 hex from rust_core's
  /// `chat_content_ephemeral_of`), behind a BIOMETRIC_STRONG prompt. Returns
  /// the 32-byte shared-secret hex (the X-coordinate), or null on failure /
  /// user cancel.
  Future<String?> ecdhHex(String ephemeralSec1UncompressedHex) async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>(
        'contentEcdh',
        {'ephemeralSec1': _fromHex(ephemeralSec1UncompressedHex)},
      );
      return bytes == null ? null : _toHex(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _invokeBytes(String method) async {
    try {
      return await _channel.invokeMethod<Uint8List>(method);
    } catch (_) {
      return null;
    }
  }

  static String _toHex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _fromHex(String hex) {
    final s = hex.startsWith('0x') ? hex.substring(2) : hex;
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
