// Bestehende Word-Dateien gezielt ändern, ohne ihr Layout zu verlieren: Abschnitte (nach Überschriften)
// anzeigen, ersetzen, einfügen, löschen und Text suchen/ersetzen. Unbeteiligte Absätze bleiben Byte für Byte gleich.

import 'dart:convert';
import 'dart:typed_data';

import 'docx_writer.dart';
import 'md_blocks.dart';
import 'office_read.dart';
import 'pdf_writer.dart' show ImageResolver;
import 'zip_writer.dart';

/// Ein Element direkt im Dokumentkörper (Absatz, Tabelle …)
class DocxElement {
  DocxElement(this.xml);
  String xml;

  bool get isParagraph => xml.startsWith('<w:p>') || xml.startsWith('<w:p ');
  bool get isTable => xml.startsWith('<w:tbl');

  String get text => RegExp(r'<w:t(?:\s[^>]*)?>(.*?)</w:t>', dotAll: true)
      .allMatches(xml)
      .map((m) => _unxml(m.group(1)!))
      .join(isTable ? ' ' : '');

  /// Überschriften-Ebene (1–9) oder null
  int? headingLevel(Map<String, int> headingStyles) {
    if (!isParagraph) return null;
    final st = RegExp(r'<w:pStyle w:val="([^"]+)"').firstMatch(xml)?.group(1);
    if (st != null) {
      if (headingStyles[st] case final l?) return l;
      final m = RegExp(r'(?:Heading|berschrift|Überschrift)\s*(\d)', caseSensitive: false).firstMatch(st);
      if (m != null) return int.parse(m.group(1)!);
      if (st.toLowerCase() == 'title' || st.toLowerCase() == 'titel') return 0;
    }
    final ol = RegExp(r'<w:outlineLvl w:val="(\d)"').firstMatch(xml)?.group(1);
    return ol == null ? null : int.parse(ol) + 1;
  }

  static String _unxml(String x) =>
      x.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&apos;', "'").replaceAll('&amp;', '&');
}

class DocxDocument {
  DocxDocument._(this.files, this._before, this.elements, this._after);

  factory DocxDocument.open(Uint8List bytes) {
    final files = readZip(bytes);
    final xml = files['word/document.xml'] == null ? '' : utf8.decode(files['word/document.xml']!, allowMalformed: true);
    final bodyStart = RegExp(r'<w:body\b[^>]*>').firstMatch(xml);
    final bodyEnd = xml.lastIndexOf('</w:body>');
    if (bodyStart == null || bodyEnd < 0) throw const FormatException('Keine Word-Datei');
    var inner = xml.substring(bodyStart.end, bodyEnd);
    // Seiteneinstellungen am Ende behalten
    final sect = inner.lastIndexOf('<w:sectPr');
    var tail = '';
    if (sect >= 0 && !inner.substring(sect).contains('<w:p')) {
      tail = inner.substring(sect);
      inner = inner.substring(0, sect);
    }
    return DocxDocument._(files, xml.substring(0, bodyStart.end), _split(inner), tail + xml.substring(bodyEnd));
  }

  final Map<String, Uint8List> files;
  final String _before;
  final String _after;
  final List<DocxElement> elements;

  /// Oberste Elemente des Körpers trennen (verschachtelte Absätze in Tabellen bleiben im Element)
  static List<DocxElement> _split(String inner) {
    final out = <DocxElement>[];
    var i = 0;
    while (i < inner.length) {
      final lt = inner.indexOf('<', i);
      if (lt < 0) break;
      final nameM = RegExp(r'<([\w:]+)').matchAsPrefix(inner, lt);
      if (nameM == null) {
        i = lt + 1;
        continue;
      }
      final name = nameM.group(1)!;
      final gt = inner.indexOf('>', lt);
      if (gt < 0) break;
      if (inner[gt - 1] == '/') {
        out.add(DocxElement(inner.substring(lt, gt + 1)));
        i = gt + 1;
        continue;
      }
      // passendes Ende mit Verschachtelung
      var depth = 1;
      var j = gt + 1;
      final open = RegExp('<$name(?=[\\s>/])');
      final close = '</$name>';
      while (depth > 0 && j < inner.length) {
        final o = open.firstMatch(inner.substring(j));
        final c = inner.indexOf(close, j);
        if (c < 0) {
          j = inner.length;
          break;
        }
        final oAt = o == null ? -1 : j + o.start;
        if (oAt >= 0 && oAt < c) {
          final oGt = inner.indexOf('>', oAt);
          if (inner[oGt - 1] != '/') depth++;
          j = oGt + 1;
        } else {
          depth--;
          j = c + close.length;
        }
      }
      out.add(DocxElement(inner.substring(lt, j)));
      i = j;
    }
    return out;
  }

  String _s(String p) => files[p] == null ? '' : utf8.decode(files[p]!, allowMalformed: true);
  void _put(String p, String xml) => files[p] = Uint8List.fromList(utf8.encode(xml));

  /// Stil-Id → Ebene aus styles.xml (heading 1 … heading 9, auch übersetzte Namen)
  late final Map<String, int> headingStyles = () {
    final out = <String, int>{};
    for (final m in RegExp(r'<w:style\b[^>]*w:styleId="([^"]+)"[^>]*>(.*?)</w:style>', dotAll: true).allMatches(_s('word/styles.xml'))) {
      final name = RegExp(r'<w:name w:val="([^"]+)"').firstMatch(m.group(2)!)?.group(1)?.toLowerCase() ?? '';
      final l = RegExp(r'^(?:heading|überschrift)\s*(\d)$').firstMatch(name)?.group(1);
      if (l != null) out[m.group(1)!] = int.parse(l);
    }
    return out;
  }();

  String? _styleIdFor(int level) {
    for (final e in headingStyles.entries) {
      if (e.value == level.clamp(1, 9)) return e.key;
    }
    return null;
  }

  bool _hasStyle(String id) => _s('word/styles.xml').contains('w:styleId="$id"');

  /// Abschnitte: Index der Überschrift + Ende (exklusiv)
  List<({int start, int end, int level, String title})> get sections {
    final heads = <(int, int)>[];
    for (var i = 0; i < elements.length; i++) {
      final l = elements[i].headingLevel(headingStyles);
      if (l != null && l > 0 && elements[i].text.trim().isNotEmpty) heads.add((i, l));
    }
    return [
      for (var k = 0; k < heads.length; k++)
        (
          start: heads[k].$1,
          end: heads.skip(k + 1).where((h) => h.$2 <= heads[k].$2).firstOrNull?.$1 ?? elements.length,
          level: heads[k].$2,
          title: elements[heads[k].$1].text.trim(),
        ),
    ];
  }

  String overview() {
    final s = sections;
    if (s.isEmpty) {
      final paras = elements.where((e) => e.text.trim().isNotEmpty).length;
      return 'Keine Überschriften – $paras Absätze. Ändern mit suchen/inhalt (Text ersetzen) oder einfuegen (am Ende).';
    }
    return 'Abschnitte: ${[for (var i = 0; i < s.length; i++) '${i + 1}. ${'  ' * (s[i].level - 1)}${s[i].title}'].join(' · ')}';
  }

  /// Abschnitt nach Nummer oder Überschrift
  ({int start, int end, int level, String title}) section(String which) {
    final s = sections;
    final n = int.tryParse(which.trim());
    if (n != null && n >= 1 && n <= s.length) return s[n - 1];
    final w = which.trim().toLowerCase();
    return s.where((x) => x.title.toLowerCase() == w).firstOrNull ??
        s.where((x) => x.title.toLowerCase().contains(w)).firstOrNull ??
        (throw FormatException('Abschnitt „$which“ gibt es nicht. ${overview()}'));
  }

  /// Inhalt als lesbarer Text (Überschriften mit #)
  String textOf(int start, int end) => [
        for (var i = start; i < end; i++)
          if (elements[i].text.trim().isNotEmpty)
            switch (elements[i].headingLevel(headingStyles)) {
              final int l when l > 0 => '${'#' * l.clamp(1, 6)} ${elements[i].text.trim()}',
              _ => elements[i].isTable ? '[Tabelle] ${elements[i].text.trim()}' : elements[i].text.trim(),
            }
      ].join('\n\n');

  /// Markdown → neue Elemente im Stil dieses Dokuments
  List<DocxElement> fromMarkdown(String md, {ImageResolver? resolveImage}) {
    final listStyle = _hasStyle('ListParagraph') ? 'ListParagraph' : null;
    final blocks = <MdBlock>[];
    // Listen ohne fremde Nummerierung: als Absatz mit Zeichen davor
    for (final b in parseMarkdown(md)) {
      if (b is MdListItem) {
        blocks.add(MdParagraph('${'    ' * b.depth}${b.number != null ? '${b.number}.' : '•'} ${b.text}'));
      } else {
        blocks.add(b);
      }
    }
    final body = DocxBody(
      resolveImage: resolveImage,
      headingStyle: (l) => _styleIdFor(l),
      imageRel: (bytes, ext) => _addImage(bytes, ext),
    );
    var xml = body.build(blocks, headerFill: 'D9E2F3', lightFill: 'F2F2F2');
    if (listStyle != null) xml = xml.replaceAll('<w:p><w:r><w:t xml:space="preserve">•', '<w:p><w:pPr><w:pStyle w:val="$listStyle"/></w:pPr><w:r><w:t xml:space="preserve">•');
    // fremde Dokumente kennen „Quote“/„Code“/„Caption“ evtl. nicht – dann Standardabsatz
    for (final st in const ['Quote', 'Code', 'Caption']) {
      if (!_hasStyle(st)) xml = xml.replaceAll('<w:pStyle w:val="$st"/>', '');
    }
    xml = xml.replaceAll('<w:tblStyle w:val="JunelsTabelle"/>', _hasStyle('TableGrid') ? '<w:tblStyle w:val="TableGrid"/>' : '');
    xml = xml.replaceAll('<w:pPr></w:pPr>', '');
    return _split(xml);
  }

  int _img = 0;
  String _addImage(Uint8List bytes, String ext) {
    var name = 'junels${++_img}.$ext';
    while (files.containsKey('word/media/$name')) {
      name = 'junels${++_img}.$ext';
    }
    files['word/media/$name'] = bytes;
    var rels = _s('word/_rels/document.xml.rels');
    var n = 1;
    while (rels.contains('Id="rId$n"')) {
      n++;
    }
    rels = rels.replaceFirst('</Relationships>',
        '<Relationship Id="rId$n" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/$name"/></Relationships>');
    _put('word/_rels/document.xml.rels', rels);
    var ct = _s('[Content_Types].xml');
    if (!ct.contains('Extension="$ext"')) {
      ct = ct.replaceFirst('<Default ', '<Default Extension="$ext" ContentType="image/$ext"/><Default ');
      _put('[Content_Types].xml', ct);
    }
    // Namensräume für Bilder sicherstellen
    return 'rId$n';
  }

  /// Text in Absätzen ersetzen (über Formatierungsgrenzen hinweg). Rückgabe: Anzahl Absätze.
  int replaceText(String find, String replacement) {
    if (find.isEmpty) return 0;
    var count = 0;
    for (final e in elements) {
      // auch Absätze in Tabellen
      e.xml = e.xml.replaceAllMapped(RegExp(r'<w:p\b[^>]*?(?:/>|>.*?</w:p>)', dotAll: true), (pm) {
        final p = pm.group(0)!;
        final ts = RegExp(r'(<w:t(?:\s[^>]*)?>)(.*?)(</w:t>)', dotAll: true).allMatches(p).toList();
        final full = ts.map((m) => DocxElement._unxml(m.group(2)!)).join();
        if (!full.contains(find)) return p;
        count++;
        // im selben Lauf? Dann nur dort ersetzen (Formatierung bleibt genau)
        for (final m in ts) {
          final t = DocxElement._unxml(m.group(2)!);
          if (t.contains(find)) {
            return p.replaceRange(m.start, m.end, '<w:t xml:space="preserve">${xmlEscape(t.replaceAll(find, replacement))}</w:t>');
          }
        }
        // über mehrere Läufe: Text in den ersten Lauf, übrige leeren
        final newText = xmlEscape(full.replaceAll(find, replacement));
        var out = p;
        for (var k = ts.length - 1; k >= 0; k--) {
          final m = ts[k];
          out = out.replaceRange(m.start, m.end, '<w:t xml:space="preserve">${k == 0 ? newText : ''}</w:t>');
        }
        return out;
      });
    }
    return count;
  }

  Uint8List save() {
    final doc = '$_before${elements.map((e) => e.xml).join()}$_after';
    var d = doc;
    // Bild-Namensräume ergänzen, falls das Dokument sie nicht deklariert
    const ns = {
      'xmlns:wp=': 'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
      'xmlns:r=': 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"',
    };
    final rootEnd = d.indexOf('>', d.indexOf('<w:document'));
    var root = d.substring(0, rootEnd);
    for (final e in ns.entries) {
      if (!root.contains(e.key)) root = '$root ${e.value}';
    }
    d = root + d.substring(rootEnd);
    _put('word/document.xml', d);
    final z = ZipWriter();
    final keys = files.keys.toList()..sort((a, b) => a == '[Content_Types].xml' ? -1 : (b == '[Content_Types].xml' ? 1 : 0));
    for (final k in keys) {
      z.add(k, files[k]!);
    }
    return z.build();
  }
}
