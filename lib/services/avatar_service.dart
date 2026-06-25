import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores and serves the tiny chat icons (avatars).
///
/// Own avatar: per-account, set by the user (pick → WebP-compress → store).
/// Contact avatars (Phase B): per-pubkey, learned from the first message in a
/// conversation. Everything is kept small: a ~96px WebP is ~1–2 KB, cheap to
/// embed in that first sealed message. Dead drops never carry avatars.
class AvatarService extends ChangeNotifier {
  AvatarService._();
  static final AvatarService instance = AvatarService._();

  static const _storage = FlutterSecureStorage();

  // Stored/display copy: crisp. Displayed up to 160px (the "Your Icon" screen),
  // so we keep a 256px master — it's local-only, so the bytes are cheap.
  static const int _displayEdge = 256;
  static const int _displayQuality = 90;

  // Wire copy (Phase B): the tiny ≤1 KB version embedded in the first sealed
  // message, sharded across relays. The circular mask leaves the corners
  // transparent so WebP's alpha sheds ~21% of the square; a shrinking
  // edge/quality step keeps it under budget. Shown only in small (~48px) list
  // rows on the receiving side, where the smaller image still reads sharp.
  static const int _targetBytes = 1024; // ≤ 1 KB

  String _ownKey(String address) => 'chat_avatar_$address';
  String _contactKey(String pubkeyHex) => 'chat_contact_avatar_$pubkeyHex';

  // In-memory cache so list rows don't hit secure storage on every rebuild.
  final Map<String, Uint8List?> _cache = {};

  /// This account's avatar bytes (WebP), or null if none is set.
  Future<Uint8List?> ownAvatar(String address) =>
      _read(_ownKey(address));

  /// A contact's avatar bytes (WebP) learned from their first message, or null.
  Future<Uint8List?> contactAvatar(String pubkeyHex) =>
      _read(_contactKey(pubkeyHex));

  /// Own avatar as lowercase hex (for embedding in the first sealed message).
  /// Empty string if none is set.
  Future<String> ownAvatarHex(String address) async {
    final bytes = await ownAvatar(address);
    return bytes == null ? '' : _hex(bytes);
  }

  /// Pick an image from the device, compress it to a tiny WebP, and store it as
  /// this account's avatar. Returns the stored bytes, or null if the user
  /// cancelled or the image couldn't be processed.
  Future<Uint8List?> pickAndSetOwn(String address) async {
    final res = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = res?.files.single.path;
    if (path == null) return null;
    final src = await File(path).readAsBytes();
    final webp = await _displayWebp(src);
    if (webp == null) return null;
    await _write(_ownKey(address), webp);
    notifyListeners();
    return webp;
  }

  // ── compression: circular mask → WebP ─────────────────────────────────

  /// Crisp circular WebP for local display/storage. A 256px master, so the
  /// 160px icon screen and the small list avatars all downscale (never upscale)
  /// → sharp. Bytes are cheap here; this copy never goes on the wire.
  Future<Uint8List?> _displayWebp(Uint8List src) async {
    final image = (await (await ui.instantiateImageCodec(src)).getNextFrame()).image;
    try {
      final png = await _circularPng(image, _displayEdge);
      final webp = await FlutterImageCompress.compressWithList(
        png,
        minWidth: _displayEdge,
        minHeight: _displayEdge,
        quality: _displayQuality,
        format: CompressFormat.webp,
      );
      return webp.isEmpty ? null : Uint8List.fromList(webp);
    } finally {
      image.dispose();
    }
  }

  /// Tiny ≤[_targetBytes] circular WebP for the wire (Phase B): derived from a
  /// stored display avatar when embedding it in a first message.
  ///
  /// The avatar is masked to a circle first, so the corners are transparent and
  /// WebP's alpha sheds them almost for free — that ~21% of the square isn't
  /// spent on pixels nobody sees, it's headroom that buys QUALITY. So we hold
  /// full resolution (96px ≈ 2× the ~48px the recipient renders) and scan
  /// quality top-down, returning the FIRST (highest) quality whose output still
  /// fits the budget. Edge only drops if even the lowest quality won't fit.
  Future<Uint8List?> tinyWireWebp(Uint8List src) async {
    final image = (await (await ui.instantiateImageCodec(src)).getNextFrame()).image;
    try {
      for (final edge in const [96, 72]) {
        final masked = await _circularPng(image, edge);
        for (final q in const [92, 86, 80, 74, 68, 62, 56, 50, 44, 38, 32]) {
          final webp = await FlutterImageCompress.compressWithList(
            masked,
            minWidth: edge,
            minHeight: edge,
            quality: q,
            format: CompressFormat.webp,
          );
          if (webp.isNotEmpty && webp.length <= _targetBytes) {
            return Uint8List.fromList(webp);
          }
        }
      }
      // Last resort (rare for a circular thumbnail): smallest we can make.
      final masked = await _circularPng(image, 64);
      final webp = await FlutterImageCompress.compressWithList(
        masked, minWidth: 64, minHeight: 64, quality: 30, format: CompressFormat.webp);
      return webp.isEmpty ? null : Uint8List.fromList(webp);
    } finally {
      image.dispose();
    }
  }

  /// Render [image] cover-cropped + circle-clipped into an [edge]×[edge] PNG
  /// (RGBA, so the corners stay transparent for the WebP encoder to shed).
  Future<Uint8List> _circularPng(ui.Image image, int edge) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final size = edge.toDouble();
    final dst = ui.Rect.fromLTWH(0, 0, size, size);
    canvas.clipPath(ui.Path()..addOval(dst));
    // Centre-square crop so the circle isn't distorted by a non-square source.
    final s = math.min(image.width, image.height).toDouble();
    final srcRect =
        ui.Rect.fromLTWH((image.width - s) / 2, (image.height - s) / 2, s, s);
    canvas.drawImageRect(
        image, srcRect, dst, ui.Paint()..filterQuality = ui.FilterQuality.high);
    final picture = recorder.endRecording();
    final out = await picture.toImage(edge, edge);
    try {
      final data = await out.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      out.dispose();
      picture.dispose();
    }
  }

  /// Store a contact's avatar (Phase B: from the first message of a thread).
  Future<void> setContactAvatar(String pubkeyHex, Uint8List webp) async {
    await _write(_contactKey(pubkeyHex), webp);
    notifyListeners();
  }

  /// Hex of the ≤1 KB wire avatar to embed in a FIRST message, or '' if the
  /// user hasn't set an icon. Derived on demand from the stored display copy.
  Future<String> firstMessageAvatarHex(String address) async {
    final own = await ownAvatar(address);
    if (own == null) return '';
    final tiny = await tinyWireWebp(own);
    return tiny == null ? '' : _hex(tiny);
  }

  /// Cache a contact's avatar from a received first message (hex WebP). No-op
  /// for an empty/odd/invalid hex (e.g. a follow-up message carrying none).
  Future<void> setContactAvatarHex(String pubkeyHex, String webpHex) async {
    final bytes = _fromHex(webpHex);
    if (bytes != null) await setContactAvatar(pubkeyHex, bytes);
  }

  // ── storage helpers ───────────────────────────────────────────────

  Future<Uint8List?> _read(String key) async {
    if (_cache.containsKey(key)) return _cache[key];
    final b64 = await _storage.read(key: key);
    final bytes = (b64 == null || b64.isEmpty) ? null : base64Decode(b64);
    _cache[key] = bytes;
    return bytes;
  }

  Future<void> _write(String key, Uint8List bytes) async {
    await _storage.write(key: key, value: base64Encode(bytes));
    _cache[key] = bytes;
  }

  static String _hex(Uint8List b) {
    final sb = StringBuffer();
    for (final x in b) {
      sb.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static Uint8List? _fromHex(String hex) {
    final h = hex.startsWith('0x') ? hex.substring(2) : hex;
    if (h.isEmpty || h.length.isOdd) return null;
    final out = Uint8List(h.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final b = int.tryParse(h.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      out[i] = b;
    }
    return out;
  }
}
