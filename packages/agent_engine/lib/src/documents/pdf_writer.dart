// PDF-Erzeugung ohne Abhängigkeiten: Dokumente (A4) und Folien (16:9) aus Markdown.
// Schriften: PDF-Standardschriften (Helvetica, Courier) in WinAnsi-Kodierung.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'md_blocks.dart';
import 'raster.dart';
import 'winansi.dart';

/// Liefert die Bytes eines Bildes (PNG/JPEG) zu einem Namen/Pfad aus dem Markdown.
typedef ImageResolver = Uint8List? Function(String src);

/// Farbschema für Dokumente und Folien.
class DocTheme {
  const DocTheme({
    this.accent = const [0.05, 0.42, 0.40],
    this.text = const [0.13, 0.15, 0.17],
    this.muted = const [0.42, 0.46, 0.50],
    this.light = const [0.92, 0.96, 0.95],
  });
  final List<double> accent;
  final List<double> text;
  final List<double> muted;
  final List<double> light;
}

enum _Font { regular, bold, italic, mono }

String _fontName(_Font f) => switch (f) {
      _Font.regular => 'F1',
      _Font.bold => 'F2',
      _Font.italic => 'F3',
      _Font.mono => 'F4',
    };

double _charWidth(_Font f, int code) => switch (f) {
      _Font.mono => 600,
      _Font.bold => helveticaBoldWidths[code].toDouble(),
      _ => helveticaWidths[code].toDouble(),
    };

double textWidth(String s, double size, {bool bold = false}) => _width(s, bold ? _Font.bold : _Font.regular, size);

double _width(String s, _Font f, double size) {
  var w = 0.0;
  for (final c in winAnsiEncode(s)) {
    w += _charWidth(f, c);
  }
  return w * size / 1000;
}

String _pdfString(String s) {
  final b = StringBuffer('(');
  for (final c in winAnsiEncode(s)) {
    if (c == 0x28 || c == 0x29 || c == 0x5C) {
      b.write('\\${String.fromCharCode(c)}');
    } else if (c < 0x20 || c > 0x7E) {
      b.write('\\${c.toRadixString(8).padLeft(3, '0')}');
    } else {
      b.writeCharCode(c);
    }
  }
  b.write(')');
  return b.toString();
}

String _n(double v) => v.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '');

/// Niedrige Ebene: Objekte, Seiten, Bilder, Schriften.
class _PdfCore {
  final _objects = <Uint8List?>[]; // Index = Objektnummer - 1
  final _pages = <({int contentObj, double w, double h, Set<String> images})>[];
  final _imageObjs = <String, int>{};

  int reserve() {
    _objects.add(null);
    return _objects.length;
  }

  void set(int obj, String body, [Uint8List? stream]) {
    final b = BytesBuilder(copy: false);
    b.add(latin1.encode('$obj 0 obj\n'));
    if (stream != null) {
      b.add(latin1.encode(body.replaceFirst('>>', '/Length ${stream.length} >>', body.lastIndexOf('>>'))));
      b.add(latin1.encode('\nstream\n'));
      b.add(stream);
      b.add(latin1.encode('\nendstream'));
    } else {
      b.add(latin1.encode(body));
    }
    b.add(latin1.encode('\nendobj\n'));
    _objects[obj - 1] = b.takeBytes();
  }

  int add(String body, [Uint8List? stream]) {
    final o = reserve();
    set(o, body, stream);
    return o;
  }

  /// Bild registrieren; liefert den Ressourcennamen (z. B. "Im3") und die Pixelgröße.
  ({String name, int w, int h})? image(Uint8List bytes, String key) {
    try {
      if (isJpeg(bytes)) {
        final info = jpegInfo(bytes);
        if (info == null) return null;
        final cs = switch (info.components) { 1 => '/DeviceGray', 4 => '/DeviceCMYK', _ => '/DeviceRGB' };
        final o = _imageObjs[key] ??= add(
            '<< /Type /XObject /Subtype /Image /Width ${info.width} /Height ${info.height} '
            '/ColorSpace $cs /BitsPerComponent 8 /Filter /DCTDecode >>',
            bytes);
        return (name: 'Im$o', w: info.width, h: info.height);
      }
      final img = isPng(bytes) ? decodePng(bytes) : null;
      if (img == null) return null;
      return raster(img, key);
    } catch (_) {
      return null;
    }
  }

  ({String name, int w, int h}) raster(RasterImage img, String key) {
    final existing = _imageObjs[key];
    if (existing != null) return (name: 'Im$existing', w: img.width, h: img.height);
    var smask = '';
    if (img.alpha != null) {
      final m = add(
          '<< /Type /XObject /Subtype /Image /Width ${img.width} /Height ${img.height} '
          '/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode >>',
          Uint8List.fromList(ZLibEncoder().convert(img.alpha!)));
      smask = ' /SMask $m 0 R';
    }
    final o = add(
        '<< /Type /XObject /Subtype /Image /Width ${img.width} /Height ${img.height} '
        '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode$smask >>',
        Uint8List.fromList(ZLibEncoder().convert(img.rgb)));
    _imageObjs[key] = o;
    return (name: 'Im$o', w: img.width, h: img.height);
  }

  void page(String content, double w, double h, Set<String> images) {
    final c = add('<< /Filter /FlateDecode >>', Uint8List.fromList(ZLibEncoder().convert(latin1.encode(content))));
    _pages.add((contentObj: c, w: w, h: h, images: images));
  }

  Uint8List build(String title) {
    final fonts = {
      'F1': add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>'),
      'F2': add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>'),
      'F3': add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Oblique /Encoding /WinAnsiEncoding >>'),
      'F4': add('<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>'),
    };
    final fontDict = fonts.entries.map((e) => '/${e.key} ${e.value} 0 R').join(' ');
    final pagesObj = reserve();
    final kids = <int>[];
    for (final p in _pages) {
      final xo = p.images.map((n) => '/$n ${n.substring(2)} 0 R').join(' ');
      kids.add(add('<< /Type /Page /Parent $pagesObj 0 R /MediaBox [0 0 ${_n(p.w)} ${_n(p.h)}] '
          '/Resources << /Font << $fontDict >>${xo.isEmpty ? '' : ' /XObject << $xo >>'} >> '
          '/Contents ${p.contentObj} 0 R >>'));
    }
    set(pagesObj, '<< /Type /Pages /Kids [${kids.map((k) => '$k 0 R').join(' ')}] /Count ${kids.length} >>');
    final info = add('<< /Title ${_pdfString(title)} /Producer (Junels) /Creator (Junels Offline-Agent) >>');
    final catalog = add('<< /Type /Catalog /Pages $pagesObj 0 R >>');

    final out = BytesBuilder(copy: false);
    out.add(latin1.encode('%PDF-1.4\n'));
    out.add(const [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);
    final offsets = <int>[];
    for (final o in _objects) {
      offsets.add(out.length);
      out.add(o!);
    }
    final xref = out.length;
    final x = StringBuffer('xref\n0 ${_objects.length + 1}\n0000000000 65535 f \n');
    for (final off in offsets) {
      x.write('${off.toString().padLeft(10, '0')} 00000 n \n');
    }
    x.write('trailer\n<< /Size ${_objects.length + 1} /Root $catalog 0 R /Info $info 0 R >>\nstartxref\n$xref\n%%EOF\n');
    out.add(latin1.encode(x.toString()));
    return out.takeBytes();
  }
}

/// Ein Wort mit Schrift für den Zeilenumbruch.
class _Word {
  _Word(this.text, this.font);
  final String text;
  final _Font font;
}

List<_Word> _words(String markdown, {_Font base = _Font.regular}) {
  final out = <_Word>[];
  for (final r in parseInline(markdown)) {
    final f = r.bold ? _Font.bold : (r.italic ? _Font.italic : base);
    for (final w in r.text.split(RegExp(r'\s+'))) {
      if (w.isNotEmpty) out.add(_Word(w, f));
    }
  }
  return out;
}

/// Bricht Wörter in Zeilen der Breite [maxW] um (zu lange Wörter werden geteilt).
List<List<_Word>> _wrap(List<_Word> words, double size, double maxW) {
  final lines = <List<_Word>>[];
  var line = <_Word>[];
  var w = 0.0;
  final space = _charWidth(_Font.regular, 32) * size / 1000;
  for (var word in words) {
    var ww = _width(word.text, word.font, size);
    while (ww > maxW && word.text.length > 1) {
      // sehr lange Wörter (URLs) zerlegen
      var cut = word.text.length - 1;
      while (cut > 1 && _width(word.text.substring(0, cut), word.font, size) > maxW) {
        cut--;
      }
      if (line.isNotEmpty) {
        lines.add(line);
        line = [];
        w = 0;
      }
      lines.add([_Word(word.text.substring(0, cut), word.font)]);
      word = _Word(word.text.substring(cut), word.font);
      ww = _width(word.text, word.font, size);
    }
    final add = line.isEmpty ? ww : space + ww;
    if (line.isNotEmpty && w + add > maxW) {
      lines.add(line);
      line = [word];
      w = ww;
    } else {
      line.add(word);
      w += add;
    }
  }
  if (line.isNotEmpty) lines.add(line);
  return lines;
}

String _rgb(List<double> c, {bool stroke = false}) =>
    '${_n(c[0])} ${_n(c[1])} ${_n(c[2])} ${stroke ? 'RG' : 'rg'}';

/// Zeichnet eine umbrochene Zeile ab (x, y) – Grundlinie y.
String _drawLine(List<_Word> line, double x, double y, double size, List<double> color) {
  final b = StringBuffer('BT ${_rgb(color)} ');
  var cx = x;
  _Font? cur;
  final space = _charWidth(_Font.regular, 32) * size / 1000;
  for (var i = 0; i < line.length; i++) {
    final w = line[i];
    if (w.font != cur) {
      b.write('/${_fontName(w.font)} ${_n(size)} Tf ');
      cur = w.font;
    }
    b.write('1 0 0 1 ${_n(cx)} ${_n(y)} Tm ${_pdfString(w.text)} Tj ');
    cx += _width(w.text, w.font, size) + space;
  }
  b.write('ET\n');
  return b.toString();
}

/// Erzeugt ein A4-Dokument aus Markdown.
Uint8List buildPdfDocument({
  required String title,
  required String markdown,
  ImageResolver? resolveImage,
  DocTheme theme = const DocTheme(),
}) {
  const pw = 595.28, ph = 841.89, ml = 56.0, mr = 56.0, mt = 64.0, mb = 64.0;
  const cw = pw - ml - mr;
  final core = _PdfCore();
  final pages = <(StringBuffer, Set<String>)>[];
  late StringBuffer c;
  late Set<String> imgs;
  var y = 0.0;

  void newPage() {
    c = StringBuffer();
    imgs = <String>{};
    pages.add((c, imgs));
    y = ph - mt;
  }

  void need(double h) {
    if (y - h < mb) newPage();
  }

  newPage();
  // Titel
  final titleLines = _wrap(_words(title, base: _Font.bold), 24, cw);
  for (final l in titleLines) {
    need(30);
    y -= 26;
    c.write(_drawLine(l, ml, y, 24, theme.accent));
  }
  y -= 10;
  c.write('${_rgb(theme.accent, stroke: true)} 1.5 w ${_n(ml)} ${_n(y)} m ${_n(pw - mr)} ${_n(y)} l S\n');
  y -= 18;

  void paragraph(String md, {double size = 11, double indent = 0, List<double>? color, _Font base = _Font.regular, String? marker}) {
    final lines = _wrap(_words(md, base: base), size, cw - indent);
    final lh = size * 1.45;
    for (var i = 0; i < lines.length; i++) {
      need(lh);
      y -= lh;
      if (i == 0 && marker != null) {
        c.write(_drawLine([_Word(marker, _Font.regular)], ml + indent - _width(marker, _Font.regular, size) - 5, y, size, theme.accent));
      }
      c.write(_drawLine(lines[i], ml + indent, y, size, color ?? theme.text));
    }
  }

  for (final b in parseMarkdown(markdown)) {
    switch (b) {
      case MdHeading(:final level, :final text):
        final size = switch (level) { 1 => 18.0, 2 => 15.0, 3 => 13.0, _ => 12.0 };
        y -= level <= 2 ? 10 : 6;
        need(size * 3); // Überschrift nicht allein am Seitenende
        paragraph(text, size: size, base: _Font.bold, color: level <= 2 ? theme.accent : theme.text);
        y -= 4;
      case MdParagraph(:final text):
        paragraph(text);
        y -= 7;
      case MdListItem(:final text, :final depth, :final number):
        final indent = 16.0 + depth * 16;
        paragraph(text, indent: indent, marker: number != null ? '$number.' : (depth == 0 ? '•' : '–'));
        y -= 3;
      case MdQuote(:final text):
        final top = y;
        paragraph(text, indent: 14, base: _Font.italic, color: theme.muted);
        c.write('${_rgb(theme.accent)} ${_n(ml + 2)} ${_n(y - 2)} 3 ${_n(top - y)} re f\n');
        y -= 8;
      case MdCode(:final text):
        for (final raw in text.split('\n')) {
          final lines = _wrap([_Word(raw.isEmpty ? ' ' : raw, _Font.mono)], 9, cw - 16);
          for (final l in lines) {
            need(13);
            y -= 13;
            c.write('${_rgb(theme.light)} ${_n(ml)} ${_n(y - 3)} ${_n(cw)} 13 re f\n');
            c.write(_drawLine(l, ml + 8, y, 9, theme.text));
          }
        }
        y -= 8;
      case MdRule():
        need(16);
        y -= 8;
        c.write('${_rgb(theme.muted, stroke: true)} 0.5 w ${_n(ml)} ${_n(y)} m ${_n(pw - mr)} ${_n(y)} l S\n');
        y -= 8;
      case MdImage(:final src, :final caption):
        final bytes = resolveImage?.call(src);
        final im = bytes == null ? null : core.image(bytes, src);
        if (im == null) {
          paragraph('[Bild nicht gefunden: $src]', color: theme.muted, base: _Font.italic);
          break;
        }
        var w = math.min(cw, im.w * 0.75);
        var h = w * im.h / im.w;
        final maxH = ph - mt - mb - 40;
        if (h > maxH) {
          h = maxH;
          w = h * im.w / im.h;
        }
        need(h + 24);
        y -= h;
        final x = ml + (cw - w) / 2;
        imgs.add(im.name);
        c.write('q ${_n(w)} 0 0 ${_n(h)} ${_n(x)} ${_n(y)} cm /${im.name} Do Q\n');
        if (caption.isNotEmpty) {
          final cl = _wrap(_words(caption, base: _Font.italic), 9, cw);
          for (final l in cl) {
            y -= 13;
            final lw = l.fold<double>(0, (a, w) => a + _width(w.text, w.font, 9) + 2.5);
            c.write(_drawLine(l, ml + (cw - lw) / 2, y, 9, theme.muted));
          }
        }
        y -= 12;
      case MdTable(:final rows):
        _table(rows, ml, cw, () => y, (v) => y = v, need, () => c, theme);
        y -= 10;
    }
  }

  // Seitenzahlen
  for (var i = 0; i < pages.length; i++) {
    final (buf, im) = pages[i];
    final label = 'Seite ${i + 1} von ${pages.length}';
    buf.write(_drawLine([_Word(label, _Font.regular)], pw - mr - _width(label, _Font.regular, 8), 34, 8, theme.muted));
    final t = plainInline(title);
    final short = t.length > 70 ? '${t.substring(0, 67)}…' : t;
    buf.write(_drawLine([_Word(short, _Font.regular)], ml, 34, 8, theme.muted));
    core.page(buf.toString(), pw, ph, im);
  }
  return core.build(plainInline(title));
}

void _table(List<List<String>> rows, double x0, double cw, double Function() getY, void Function(double) setY,
    void Function(double) need, StringBuffer Function() content, DocTheme theme) {
  if (rows.isEmpty) return;
  const size = 9.5, pad = 5.0;
  final cols = rows.first.length;
  // Spaltenbreiten nach Textlänge, mindestens 10 %
  final lens = List<double>.filled(cols, 1);
  for (final r in rows) {
    for (var i = 0; i < cols; i++) {
      lens[i] = math.max(lens[i], math.min(40, plainInline(r[i]).length.toDouble()));
    }
  }
  final total = lens.reduce((a, b) => a + b);
  final widths = [for (final l in lens) math.max(cw * 0.1, cw * l / total)];
  final scale = cw / widths.reduce((a, b) => a + b);
  for (var i = 0; i < cols; i++) {
    widths[i] *= scale;
  }
  for (var r = 0; r < rows.length; r++) {
    final header = r == 0;
    final cells = [
      for (var i = 0; i < cols; i++) _wrap(_words(rows[r][i], base: header ? _Font.bold : _Font.regular), size, widths[i] - 2 * pad)
    ];
    final lines = cells.map((c) => math.max(1, c.length)).reduce(math.max);
    final h = lines * size * 1.35 + 2 * pad;
    need(h);
    final c = content();
    final top = getY();
    if (header) c.write('${_rgb(theme.light)} ${_n(x0)} ${_n(top - h)} ${_n(cw)} ${_n(h)} re f\n');
    var x = x0;
    for (var i = 0; i < cols; i++) {
      var ly = top - pad;
      for (final l in cells[i]) {
        ly -= size * 1.35;
        c.write(_drawLine(l, x + pad, ly + 2, size, theme.text));
      }
      x += widths[i];
    }
    c.write('${_rgb(theme.muted, stroke: true)} 0.4 w ${_n(x0)} ${_n(top - h)} m ${_n(x0 + cw)} ${_n(top - h)} l S\n');
    if (header) c.write('${_rgb(theme.accent, stroke: true)} 1 w ${_n(x0)} ${_n(top - h)} m ${_n(x0 + cw)} ${_n(top - h)} l S\n');
    setY(top - h);
  }
}

/// Folien als PDF (16:9, eine Folie pro Seite).
Uint8List buildSlidesPdf({
  required String title,
  String? subtitle,
  required List<SlideSpec> slides,
  ImageResolver? resolveImage,
  DocTheme theme = const DocTheme(),
}) {
  const pw = 960.0, ph = 540.0;
  final core = _PdfCore();

  // Titelfolie
  {
    final c = StringBuffer();
    c.write('${_rgb(theme.accent)} 0 0 ${_n(pw)} ${_n(ph)} re f\n');
    final lines = _wrap(_words(title, base: _Font.bold), 40, pw - 160);
    var y = ph / 2 + lines.length * 24;
    for (final l in lines) {
      y -= 48;
      c.write(_drawLine(l, 80, y, 40, const [1, 1, 1]));
    }
    if (subtitle != null) {
      for (final l in _wrap(_words(subtitle), 20, pw - 160)) {
        y -= 30;
        c.write(_drawLine(l, 80, y - 6, 20, const [0.85, 0.95, 0.93]));
      }
    }
    core.page(c.toString(), pw, ph, {});
  }

  var n = 1;
  for (final s in slides) {
    n++;
    final c = StringBuffer();
    final imgs = <String>{};
    c.write('${_rgb(theme.accent)} 0 ${_n(ph - 8)} ${_n(pw)} 8 re f\n');
    var y = ph - 40.0;
    if (s.title.isNotEmpty) {
      for (final l in _wrap(_words(s.title, base: _Font.bold), 30, pw - 120)) {
        y -= 34;
        c.write(_drawLine(l, 60, y, 30, theme.accent));
      }
      y -= 18;
    }
    final images = s.blocks.whereType<MdImage>().toList();
    final textBlocks = s.blocks.where((b) => b is! MdImage).toList();
    var textW = pw - 120;
    // Bild rechts (mit Text) oder mittig (ohne Text)
    if (images.isNotEmpty) {
      final bytes = resolveImage?.call(images.first.src);
      final im = bytes == null ? null : core.image(bytes, images.first.src);
      if (im != null) {
        final boxW = textBlocks.isEmpty ? pw - 120 : (pw - 120) * 0.45;
        final boxH = y - 40;
        var w = boxW, h = boxW * im.h / im.w;
        if (h > boxH) {
          h = boxH;
          w = h * im.w / im.h;
        }
        final x = textBlocks.isEmpty ? (pw - w) / 2 : pw - 60 - w;
        imgs.add(im.name);
        c.write('q ${_n(w)} 0 0 ${_n(h)} ${_n(x)} ${_n(y - h)} cm /${im.name} Do Q\n');
        if (textBlocks.isNotEmpty) textW = (pw - 120) * 0.52;
      }
    }
    // Schriftgröße so wählen, dass der Text passt
    for (final size in [22.0, 20.0, 18.0, 16.0, 14.0, 12.0]) {
      final buf = StringBuffer();
      var cy = y;
      var fits = true;
      for (final b in textBlocks) {
        final (md, indent, marker, base) = switch (b) {
          MdListItem(:final text, :final depth, :final number) =>
            (text, 24.0 + depth * 24, number != null ? '$number.' : (depth == 0 ? '•' : '–'), _Font.regular),
          MdParagraph(:final text) => (text, 0.0, null, _Font.regular),
          MdQuote(:final text) => (text, 12.0, null, _Font.italic),
          MdHeading(:final text) => (text, 0.0, null, _Font.bold),
          MdCode(:final text) => (text, 0.0, null, _Font.mono),
          MdTable(:final rows) => (rows.map((r) => r.join('  |  ')).join('\n'), 0.0, null, _Font.regular),
          _ => ('', 0.0, null, _Font.regular),
        };
        if (md.isEmpty) continue;
        for (final part in md.split('\n')) {
          final lines = _wrap(_words(part, base: base), size, textW - indent);
          for (var i = 0; i < lines.length; i++) {
            cy -= size * 1.4;
            if (i == 0 && marker != null) {
              buf.write(_drawLine([_Word(marker, _Font.regular)], 60 + indent - 18, cy, size, theme.accent));
            }
            buf.write(_drawLine(lines[i], 60 + indent, cy, size, theme.text));
          }
        }
        cy -= size * 0.5;
        if (cy < 36) {
          fits = false;
          break;
        }
      }
      if (fits || size == 12) {
        c.write(buf);
        break;
      }
    }
    final label = '$n';
    c.write(_drawLine([_Word(label, _Font.regular)], pw - 40 - _width(label, _Font.regular, 10), 18, 10, theme.muted));
    core.page(c.toString(), pw, ph, imgs);
  }
  return core.build(plainInline(title));
}
