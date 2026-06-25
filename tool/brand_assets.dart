// One-shot brand-asset generator. Run from the project root:
//   dart run tool/brand_assets.dart
//
// Input  : assets/branding/src/rostro-lockup-black.png  (black mark+wordmark on
//          a transparent background — the designer's "Recurso 39").
// Output : white-on-transparent derivatives used by the app + icon/splash tools.
//
// We work from the raster (no SVG rasteriser available here). Recolouring keeps
// each pixel's alpha and only forces RGB→white, so anti-aliased edges survive.
import 'dart:io';
import 'package:image/image.dart' as img;

const _src = 'assets/branding/src/rostro-lockup-black.png';
const _outDir = 'assets/branding';

void main() {
  final src = img.decodePng(File(_src).readAsBytesSync());
  if (src == null) {
    stderr.writeln('could not decode $_src');
    exit(1);
  }
  print('source: ${src.width}x${src.height}');

  // Row occupancy: does a row contain any meaningfully-opaque pixel?
  bool rowHasInk(int y) {
    for (var x = 0; x < src.width; x++) {
      if (src.getPixel(x, y).a > 32) return true;
    }
    return false;
  }

  // Split into vertical clusters separated by blank gaps. The lockup is the
  // mark (top cluster) above the ROSTRO wordmark (bottom cluster).
  final clusters = <List<int>>[]; // [yStart, yEnd] inclusive
  int? start;
  for (var y = 0; y < src.height; y++) {
    final ink = rowHasInk(y);
    if (ink && start == null) start = y;
    if (!ink && start != null) {
      clusters.add([start, y - 1]);
      start = null;
    }
  }
  if (start != null) clusters.add([start, src.height - 1]);
  print('clusters (y-bands): $clusters');
  if (clusters.isEmpty) {
    stderr.writeln('no ink found');
    exit(1);
  }

  final mark = _crop(src, clusters.first); // top cluster = the R mark
  _write('rostro-mark-white.png', _toWhite(mark));
  _write('rostro-lockup-white.png', _toWhite(_crop(src, [0, src.height - 1])));

  // Square, padded foreground for the Android adaptive icon. The maskable
  // safe-zone is the inner ~66%, so we inset the mark to ~62% of the square.
  // Upscaled to 1024 so the icon tooling has a comfortable master.
  _write('icon-foreground.png', _to1024(_squarePadded(_toWhite(mark), 0.62)));
  // A plain square mark on the brand near-black, for the legacy/iOS icon.
  _write('icon-mark-on-dark.png',
      _to1024(_squarePadded(_toWhite(mark), 0.66, bg: img.ColorRgb8(13, 13, 13))));
  print('done.');
}

// Bounding-box crop within a y-band: trims blank columns too, with a margin.
img.Image _crop(img.Image src, List<int> band) {
  var minX = src.width, maxX = 0;
  var minY = band[0], maxY = band[1];
  for (var y = band[0]; y <= band[1]; y++) {
    for (var x = 0; x < src.width; x++) {
      if (src.getPixel(x, y).a > 32) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }
    }
  }
  const m = 6;
  minX = (minX - m).clamp(0, src.width - 1);
  maxX = (maxX + m).clamp(0, src.width - 1);
  minY = (minY - m).clamp(0, src.height - 1);
  maxY = (maxY + m).clamp(0, src.height - 1);
  return img.copyCrop(src,
      x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1);
}

// Force RGB→white, keep alpha (mono recolour that preserves AA edges).
img.Image _toWhite(img.Image src) {
  final out = src.convert(numChannels: 4);
  for (final p in out) {
    p.r = 255;
    p.g = 255;
    p.b = 255;
  }
  return out;
}

// Place [fg] centred on a transparent (or [bg]) square, scaled to [frac] of it.
img.Image _squarePadded(img.Image fg, double frac, {img.Color? bg}) {
  final side = (fg.width > fg.height ? fg.width : fg.height) ~/ frac;
  final canvas = img.Image(width: side, height: side, numChannels: 4);
  if (bg != null) img.fill(canvas, color: bg);
  final scale = (side * frac) / (fg.width > fg.height ? fg.width : fg.height);
  final scaled = img.copyResize(fg,
      width: (fg.width * scale).round(),
      height: (fg.height * scale).round(),
      interpolation: img.Interpolation.cubic);
  img.compositeImage(canvas, scaled,
      dstX: (side - scaled.width) ~/ 2, dstY: (side - scaled.height) ~/ 2);
  return canvas;
}

img.Image _to1024(img.Image im) => img.copyResize(im,
    width: 1024, height: 1024, interpolation: img.Interpolation.cubic);

void _write(String name, img.Image im) {
  final path = '$_outDir/$name';
  File(path).writeAsBytesSync(img.encodePng(im));
  print('wrote $path  (${im.width}x${im.height})');
}
