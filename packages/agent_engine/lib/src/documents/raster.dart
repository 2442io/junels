// Kleine Bild-Helfer ohne Abhängigkeiten: PNG lesen/schreiben, JPEG-Größe,
// CRC32. Reicht für das Einbetten in PDF/PPTX.

import 'dart:io';
import 'dart:typed_data';

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

int crc32(List<int> data, [int crc = 0]) {
  var c = crc ^ 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Entpacktes Bild: RGB-Pixel und optional Alpha.
class RasterImage {
  RasterImage(this.width, this.height, this.rgb, [this.alpha]);
  final int width;
  final int height;
  final Uint8List rgb; // width*height*3
  final Uint8List? alpha; // width*height oder null

  /// Aus RGBA-Pixeln (z. B. von dart:ui).
  factory RasterImage.fromRgba(int w, int h, Uint8List rgba) {
    final rgb = Uint8List(w * h * 3);
    final a = Uint8List(w * h);
    var opaque = true;
    for (var i = 0, j = 0; i < w * h; i++, j += 4) {
      rgb[i * 3] = rgba[j];
      rgb[i * 3 + 1] = rgba[j + 1];
      rgb[i * 3 + 2] = rgba[j + 2];
      a[i] = rgba[j + 3];
      if (rgba[j + 3] != 255) opaque = false;
    }
    return RasterImage(w, h, rgb, opaque ? null : a);
  }
}

/// Größe und Farbkanäle eines JPEG (für direktes Einbetten in PDF).
({int width, int height, int components})? jpegInfo(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = b[i + 1];
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    final len = (b[i + 2] << 8) | b[i + 3];
    final isSof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
    if (isSof) {
      final h = (b[i + 5] << 8) | b[i + 6];
      final w = (b[i + 7] << 8) | b[i + 8];
      return (width: w, height: h, components: b[i + 9]);
    }
    i += 2 + len;
  }
  return null;
}

bool isPng(Uint8List b) =>
    b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;

bool isJpeg(Uint8List b) => b.length > 3 && b[0] == 0xFF && b[1] == 0xD8;

/// Liest ein PNG (8/16 Bit, alle Farbtypen, ohne Interlacing).
RasterImage decodePng(Uint8List b) {
  if (!isPng(b)) throw const FormatException('kein PNG');
  var p = 8;
  int? w, h, depth, ctype, interlace;
  Uint8List? palette;
  Uint8List? trns;
  final idat = BytesBuilder(copy: false);
  int u32(int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  while (p + 8 <= b.length) {
    final len = u32(p);
    final type = String.fromCharCodes(b.sublist(p + 4, p + 8));
    final data = Uint8List.sublistView(b, p + 8, p + 8 + len);
    switch (type) {
      case 'IHDR':
        w = u32(p + 8);
        h = u32(p + 12);
        depth = data[8];
        ctype = data[9];
        interlace = data[12];
      case 'PLTE':
        palette = Uint8List.fromList(data);
      case 'tRNS':
        trns = Uint8List.fromList(data);
      case 'IDAT':
        idat.add(data);
    }
    if (type == 'IEND') break;
    p += 12 + len;
  }
  if (w == null || h == null || depth == null || ctype == null) throw const FormatException('PNG ohne IHDR');
  if (interlace != 0) throw const FormatException('Interlaced PNG wird nicht unterstützt');
  if (depth != 8 && depth != 16 && !(ctype == 3 && depth <= 8) && !(ctype == 0 && depth < 8)) {
    throw FormatException('PNG-Bittiefe $depth wird nicht unterstützt');
  }
  final channels = switch (ctype) { 0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4, _ => throw const FormatException('PNG-Farbtyp') };
  final raw = Uint8List.fromList(ZLibDecoder().convert(idat.takeBytes()));
  final bitsPerPixel = channels * depth;
  final bpp = (bitsPerPixel + 7) ~/ 8;
  final stride = (w * bitsPerPixel + 7) ~/ 8;
  final cur = Uint8List(stride);
  var prev = Uint8List(stride);
  final rgb = Uint8List(w * h * 3);
  final alpha = (ctype == 4 || ctype == 6 || trns != null) ? Uint8List(w * h) : null;
  var off = 0;
  for (var y = 0; y < h; y++) {
    final filter = raw[off++];
    for (var x = 0; x < stride; x++) {
      final a = x >= bpp ? cur[x - bpp] : 0;
      final up = prev[x];
      final c = x >= bpp ? prev[x - bpp] : 0;
      final v = raw[off + x];
      cur[x] = switch (filter) {
        0 => v,
        1 => v + a,
        2 => v + up,
        3 => v + ((a + up) >> 1),
        4 => v + _paeth(a, up, c),
        _ => v,
      } & 0xFF;
    }
    off += stride;
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      int sample(int ch) {
        if (depth == 16) return cur[(x * channels + ch) * 2];
        if (depth == 8) return cur[x * channels + ch];
        final bitPos = x * depth!;
        final byte = cur[bitPos >> 3];
        final shift = 8 - depth - (bitPos & 7);
        return (byte >> shift) & ((1 << depth) - 1);
      }

      switch (ctype) {
        case 0:
          var g = sample(0);
          if (depth < 8) g = g * 255 ~/ ((1 << depth) - 1);
          rgb[i * 3] = rgb[i * 3 + 1] = rgb[i * 3 + 2] = g;
          if (alpha != null) alpha[i] = 255;
        case 2:
          rgb[i * 3] = sample(0);
          rgb[i * 3 + 1] = sample(1);
          rgb[i * 3 + 2] = sample(2);
          if (alpha != null) alpha[i] = 255;
        case 3:
          final idx = sample(0);
          final pal = palette!;
          rgb[i * 3] = idx * 3 < pal.length ? pal[idx * 3] : 0;
          rgb[i * 3 + 1] = idx * 3 + 1 < pal.length ? pal[idx * 3 + 1] : 0;
          rgb[i * 3 + 2] = idx * 3 + 2 < pal.length ? pal[idx * 3 + 2] : 0;
          if (alpha != null) alpha[i] = idx < trns!.length ? trns[idx] : 255;
        case 4:
          rgb[i * 3] = rgb[i * 3 + 1] = rgb[i * 3 + 2] = sample(0);
          alpha![i] = sample(1);
        case 6:
          rgb[i * 3] = sample(0);
          rgb[i * 3 + 1] = sample(1);
          rgb[i * 3 + 2] = sample(2);
          alpha![i] = sample(3);
      }
    }
    final t = prev;
    prev = Uint8List.fromList(cur);
    t.fillRange(0, 0);
  }
  var opaque = alpha == null;
  if (alpha != null) {
    opaque = true;
    for (final a in alpha) {
      if (a != 255) {
        opaque = false;
        break;
      }
    }
  }
  return RasterImage(w, h, rgb, opaque ? null : alpha);
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

/// Schreibt RGBA-Pixel als PNG.
Uint8List encodePngRgba(int w, int h, Uint8List rgba) {
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < h; y++) {
    raw.addByte(0);
    raw.add(Uint8List.sublistView(rgba, y * w * 4, (y + 1) * w * 4));
  }
  final out = BytesBuilder(copy: false)..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final t = type.codeUnits;
    out.add(_u32(data.length));
    out.add(t);
    out.add(data);
    out.add(_u32(crc32(data, crc32(t))));
  }

  chunk('IHDR', [..._u32(w), ..._u32(h), 8, 6, 0, 0, 0]);
  chunk('IDAT', ZLibEncoder(level: 6).convert(raw.takeBytes()));
  chunk('IEND', const []);
  return out.takeBytes();
}

List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
