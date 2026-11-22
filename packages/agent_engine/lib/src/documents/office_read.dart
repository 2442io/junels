// Office-Dateien lesen (ohne Fremdbibliothek): ZIP entpacken, Text aus Word/Excel/PowerPoint,
// Farben und Schriften aus dem Office-Design (theme1.xml) und PowerPoint-Vorlagen.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Entpackt ein ZIP (gespeichert oder Deflate) – Pfad → Inhalt.
Map<String, Uint8List> readZip(Uint8List data) {
  final out = <String, Uint8List>{};
  final bd = ByteData.sublistView(data);
  // Ende des zentralen Verzeichnisses suchen
  var eocd = -1;
  for (var i = data.length - 22; i >= 0 && i >= data.length - 65557; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw const FormatException('Keine ZIP-Datei');
  final count = bd.getUint16(eocd + 10, Endian.little);
  var p = bd.getUint32(eocd + 16, Endian.little);
  for (var n = 0; n < count; n++) {
    if (bd.getUint32(p, Endian.little) != 0x02014b50) break;
    final method = bd.getUint16(p + 10, Endian.little);
    final csize = bd.getUint32(p + 20, Endian.little);
    final nameLen = bd.getUint16(p + 28, Endian.little);
    final extraLen = bd.getUint16(p + 30, Endian.little);
    final commentLen = bd.getUint16(p + 32, Endian.little);
    final local = bd.getUint32(p + 42, Endian.little);
    final name = utf8.decode(data.sublist(p + 46, p + 46 + nameLen), allowMalformed: true);
    p += 46 + nameLen + extraLen + commentLen;
    if (name.endsWith('/')) continue;
    final lNameLen = bd.getUint16(local + 26, Endian.little);
    final lExtraLen = bd.getUint16(local + 28, Endian.little);
    final start = local + 30 + lNameLen + lExtraLen;
    final raw = Uint8List.sublistView(data, start, start + csize);
    try {
      out[name] = switch (method) {
        0 => Uint8List.fromList(raw),
        8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(raw)),
        _ => throw FormatException('Packverfahren $method'),
      };
    } catch (_) {
      // einzelne Datei unlesbar – Rest trotzdem
    }
  }
  return out;
}

String _xmlText(String xml) => xml
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String _s(Map<String, Uint8List> z, String name) => z[name] == null ? '' : utf8.decode(z[name]!, allowMalformed: true);

int _num(String path) => int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(path)?.group(1) ?? '') ?? 0;

/// Text aus .docx, .xlsx oder .pptx (für Anhänge). [ext] ohne Punkt.
String officeText(Uint8List bytes, String ext) {
  final z = readZip(bytes);
  switch (ext.toLowerCase()) {
    case 'docx':
      final xml = _s(z, 'word/document.xml');
      final paras = <String>[];
      for (final p in RegExp(r'<w:p[ >].*?</w:p>', dotAll: true).allMatches(xml)) {
        final ps = p.group(0)!;
        final t = RegExp(r'<w:t[^>]*>(.*?)</w:t>', dotAll: true).allMatches(ps).map((m) => _xmlText(m.group(1)!)).join();
        final style = RegExp(r'<w:pStyle w:val="([^"]+)"').firstMatch(ps)?.group(1) ?? '';
        final h = RegExp(r'(?:Heading|berschrift)(\d)').firstMatch(style)?.group(1);
        final list = ps.contains('<w:numPr>');
        if (t.trim().isEmpty) continue;
        paras.add(h != null ? '${'#' * int.parse(h).clamp(1, 4)} $t' : (list ? '- $t' : t));
      }
      return paras.join('\n\n');
    case 'xlsx':
      final shared = [
        for (final si in RegExp(r'<si>(.*?)</si>', dotAll: true).allMatches(_s(z, 'xl/sharedStrings.xml')))
          RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true).allMatches(si.group(1)!).map((m) => _xmlText(m.group(1)!)).join()
      ];
      final names = [
        for (final m in RegExp(r'<sheet [^>]*name="([^"]+)"').allMatches(_s(z, 'xl/workbook.xml'))) _xmlText(m.group(1)!)
      ];
      final sheets = z.keys.where((k) => RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(k)).toList()
        ..sort((a, b) => _num(a).compareTo(_num(b)));
      final out = StringBuffer();
      for (var i = 0; i < sheets.length; i++) {
        out.writeln('## ${i < names.length ? names[i] : 'Tabelle ${i + 1}'}');
        var rows = 0;
        for (final r in RegExp(r'<row[^>]*>(.*?)</row>', dotAll: true).allMatches(_s(z, sheets[i]))) {
          final cells = <String>[];
          for (final c in RegExp(r'<c ([^>]*?)(?:/>|>(.*?)</c>)', dotAll: true).allMatches(r.group(1)!)) {
            final attrs = c.group(1)!;
            final body = c.group(2) ?? '';
            final v = RegExp(r'<v>(.*?)</v>', dotAll: true).firstMatch(body)?.group(1) ??
                RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true).firstMatch(body)?.group(1) ??
                '';
            final isShared = attrs.contains('t="s"');
            cells.add(isShared ? (shared.elementAtOrNull(int.tryParse(v) ?? -1) ?? '') : _xmlText(v));
          }
          if (cells.every((x) => x.trim().isEmpty)) continue;
          out.writeln(cells.join(';'));
          if (++rows >= 2000) break;
        }
        out.writeln();
      }
      return out.toString().trim();
    case 'pptx':
      final slides = z.keys.where((k) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(k)).toList()
        ..sort((a, b) => _num(a).compareTo(_num(b)));
      final out = StringBuffer();
      for (final s in slides) {
        final xml = _s(z, s);
        final paras = [
          for (final p in RegExp(r'<a:p>.*?</a:p>', dotAll: true).allMatches(xml))
            RegExp(r'<a:t>(.*?)</a:t>', dotAll: true).allMatches(p.group(0)!).map((m) => _xmlText(m.group(1)!)).join()
        ].where((t) => t.trim().isNotEmpty).toList();
        if (paras.isEmpty) continue;
        out.writeln('# ${paras.first}');
        for (final t in paras.skip(1)) {
          out.writeln('- $t');
        }
        out.writeln();
      }
      return out.toString().trim();
  }
  return '';
}

/// Farben und Schriften eines Office-Designs (theme1.xml).
class OfficeTheme {
  const OfficeTheme({required this.colors, this.majorFont, this.minorFont, this.name});

  /// dk1, lt1, dk2, lt2, accent1…6 als Hex ohne #
  final Map<String, String> colors;
  final String? majorFont;
  final String? minorFont;
  final String? name;

  String? operator [](String k) => colors[k];

  static OfficeTheme? parse(String xml) {
    if (!xml.contains('clrScheme')) return null;
    final colors = <String, String>{};
    for (final k in const ['dk1', 'lt1', 'dk2', 'lt2', 'accent1', 'accent2', 'accent3', 'accent4', 'accent5', 'accent6']) {
      final m = RegExp('<a:$k>(.*?)</a:$k>', dotAll: true).firstMatch(xml);
      if (m == null) continue;
      final inner = m.group(1)!;
      final v = RegExp(r'srgbClr val="([0-9A-Fa-f]{6})"').firstMatch(inner)?.group(1) ??
          RegExp(r'lastClr="([0-9A-Fa-f]{6})"').firstMatch(inner)?.group(1);
      if (v != null) colors[k] = v.toUpperCase();
    }
    String? font(String tag) {
      final m = RegExp('<a:$tag>.*?<a:latin typeface="([^"]*)"', dotAll: true).firstMatch(xml);
      final f = m?.group(1);
      return f == null || f.isEmpty ? null : f;
    }

    return OfficeTheme(
      colors: colors,
      majorFont: font('majorFont'),
      minorFont: font('minorFont'),
      name: RegExp(r'<a:theme [^>]*name="([^"]*)"').firstMatch(xml)?.group(1),
    );
  }

  /// Design aus .pptx/.docx/.xlsx (erstes theme1.xml).
  static OfficeTheme? fromOffice(Map<String, Uint8List> zip) {
    for (final k in const ['ppt/theme/theme1.xml', 'word/theme/theme1.xml', 'xl/theme/theme1.xml']) {
      if (zip.containsKey(k)) return parse(_s(zip, k));
    }
    final any = zip.keys.where((k) => RegExp(r'theme/theme\d+\.xml$').hasMatch(k)).firstOrNull;
    return any == null ? null : parse(_s(zip, any));
  }
}

/// PowerPoint-Vorlage: Master, Layouts, Design und Bilder werden in neue Präsentationen übernommen.
class PptxTemplate {
  PptxTemplate._(this.parts, this.contentTypes, this.masterPath, this.layoutPath, this.theme, this.width, this.height);

  /// Teile, die übernommen werden (Pfad im Paket → Inhalt), inkl. .rels
  final Map<String, Uint8List> parts;

  /// Inhaltstypen dieser Teile ('/ppt/…' → MIME) und Endungen ('png' → MIME)
  final Map<String, String> contentTypes;
  final String masterPath;

  /// Leeres (oder schlichtestes) Layout für die neuen Folien
  final String layoutPath;
  final OfficeTheme? theme;
  final int width;
  final int height;

  bool get wide => (width / height - 16 / 9).abs() < 0.05;

  static String _resolve(String base, String target) {
    if (target.startsWith('/')) return target.substring(1);
    final parts = base.split('/')..removeLast();
    for (final seg in target.split('/')) {
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (seg != '.') {
        parts.add(seg);
      }
    }
    return parts.join('/');
  }

  static String _relsOf(String part) {
    final i = part.lastIndexOf('/');
    return '${part.substring(0, i)}/_rels/${part.substring(i + 1)}.rels';
  }

  static PptxTemplate? parse(Uint8List bytes) {
    final z = readZip(bytes);
    final pres = _s(z, 'ppt/presentation.xml');
    final presRels = _s(z, 'ppt/_rels/presentation.xml.rels');
    if (pres.isEmpty) return null;
    final masterRid = RegExp(r'<p:sldMasterId [^>]*r:id="([^"]+)"').firstMatch(pres)?.group(1);
    final masterTarget = masterRid == null
        ? null
        : RegExp('<Relationship [^>]*Id="$masterRid"[^>]*Target="([^"]+)"').firstMatch(presRels)?.group(1) ??
            RegExp('<Relationship [^>]*Target="([^"]+)"[^>]*Id="$masterRid"').firstMatch(presRels)?.group(1);
    final master = masterTarget == null ? 'ppt/slideMasters/slideMaster1.xml' : _resolve('ppt/presentation.xml', masterTarget);
    if (!z.containsKey(master)) return null;

    // Alle Teile einsammeln, auf die Master und Layouts verweisen (Bilder, Design, …)
    final keep = <String>{};
    final todo = [master];
    while (todo.isNotEmpty) {
      final part = todo.removeLast();
      if (!keep.add(part) || !z.containsKey(part)) continue;
      final rels = _relsOf(part);
      if (!z.containsKey(rels)) continue;
      keep.add(rels);
      for (final m in RegExp(r'<Relationship ([^>]*)/?>').allMatches(_s(z, rels))) {
        final a = m.group(1)!;
        if (a.contains('TargetMode="External"')) continue;
        final t = RegExp(r'Target="([^"]+)"').firstMatch(a)?.group(1);
        // keine Folien, Notizen oder Kommentare übernehmen
        if (t == null || RegExp(r'slides/|notesSlide|comments').hasMatch(t)) continue;
        todo.add(_resolve(part, t));
      }
    }
    final parts = {for (final k in keep) if (z.containsKey(k)) k: z[k]!};

    // Layout: „blank“, sonst das mit den wenigsten Platzhaltern
    final layouts = parts.keys.where((k) => RegExp(r'^ppt/slideLayouts/slideLayout\d+\.xml$').hasMatch(k)).toList()
      ..sort((a, b) => _num(a).compareTo(_num(b)));
    if (layouts.isEmpty) return null;
    String pick() {
      for (final l in layouts) {
        if (_s(z, l).contains('type="blank"')) return l;
      }
      layouts.sort((a, b) => '<p:ph'.allMatches(_s(z, a)).length.compareTo('<p:ph'.allMatches(_s(z, b)).length));
      return layouts.first;
    }

    final ct = _s(z, '[Content_Types].xml');
    final types = <String, String>{};
    for (final m in RegExp(r'<Override [^>]*PartName="([^"]+)"[^>]*ContentType="([^"]+)"').allMatches(ct)) {
      if (parts.containsKey(m.group(1)!.substring(1))) types[m.group(1)!] = m.group(2)!;
    }
    for (final m in RegExp(r'<Default [^>]*Extension="([^"]+)"[^>]*ContentType="([^"]+)"').allMatches(ct)) {
      types[m.group(1)!.toLowerCase()] = m.group(2)!;
    }
    final sz = RegExp(r'<p:sldSz [^>]*cx="(\d+)"[^>]*cy="(\d+)"').firstMatch(pres);
    final themePart = parts.keys.where((k) => RegExp(r'^ppt/theme/theme\d+\.xml$').hasMatch(k)).firstOrNull;
    return PptxTemplate._(
      parts,
      types,
      master,
      pick(),
      themePart == null ? null : OfficeTheme.parse(_s(z, themePart)),
      int.tryParse(sz?.group(1) ?? '') ?? 12192000,
      int.tryParse(sz?.group(2) ?? '') ?? 6858000,
    );
  }
}
