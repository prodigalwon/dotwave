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
  if (clusters.length < 2) {
    stderr.writeln('expected mark + wordmark clusters, got ${clusters.length}');
    exit(1);
  }
  final word = _toWhite(_crop(src, clusters[1])); // bottom cluster = ROSTRO
  _write('rostro-wordmark-white.png', word);

  // Splash-only assets. flutter_native_splash treats the source as the
  // xxxhdpi (4x) bucket, so px/4 = dp on screen. The Android-12 system
  // splash shows its icon canvas at 288dp with the mark at 0.50 of it
  // (144dp); the legacy splash mark is sized to the same 144dp so both OS
  // paths render the mark identically, and the Flutter splash's first
  // frame can pixel-match either.
  _write('splash-mark-legacy.png', _resizeH(_toWhite(mark), 576));
  // Bottom-centre branding strip (windowSplashScreenBrandingImage on 12+,
  // composed into the legacy layer-list below 12). The OS stretches the
  // drawable to fill its 200x80dp slot with no aspect preservation
  // (verified on One UI: a bare strip renders vertically stretched), so
  // the asset must BE 200x80dp (800x320 at 4x) with the 150dp-wide
  // wordmark centred on transparent padding.
  final brandCanvas = img.Image(width: 800, height: 320, numChannels: 4);
  final brandWord = _resizeW(word, 600);
  img.compositeImage(brandCanvas, brandWord,
      dstX: (800 - brandWord.width) ~/ 2,
      dstY: (320 - brandWord.height) ~/ 2);
  _write('splash-branding.png', brandCanvas);

  // The mark is taller than wide (372:456), so at scale `frac` its frame
  // corners sit frac*0.645 of the canvas side from centre. Every consumer
  // below must keep those corners inside its platform's mask circle,
  // otherwise the OS rounds off the angular corners of the R.
  //
  // Android adaptive icon: guaranteed-visible safe zone is a 66/108 circle
  // (radius 0.306 of the side) under any launcher mask shape,
  // so frac <= 0.47. Upscaled to 1024 for the icon tooling.
  _write('icon-foreground.png', _to1024(_squarePadded(_toWhite(mark), 0.47)));
  // Android 12+ system splash: the OS clips the icon to a circle 2/3 of the
  // canvas width (radius 0.333), so frac <= 0.516. Kept as its own file:
  // the splash and adaptive-icon masks differ, so their insets differ.
  _write('icon-splash-android12.png',
      _to1024(_squarePadded(_toWhite(mark), 0.50)));
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

img.Image _resizeH(img.Image im, int h) => img.copyResize(im,
    height: h,
    width: (im.width * h / im.height).round(),
    interpolation: img.Interpolation.cubic);

img.Image _resizeW(img.Image im, int w) => img.copyResize(im,
    width: w,
    height: (im.height * w / im.width).round(),
    interpolation: img.Interpolation.cubic);

void _write(String name, img.Image im) {
  final path = '$_outDir/$name';
  File(path).writeAsBytesSync(img.encodePng(im));
  print('wrote $path  (${im.width}x${im.height})');
}
