// PowerPoint-Datei (.pptx, 16:9) aus Folien-Markdown – ohne Abhängigkeiten.
// Öffnet sich in PowerPoint, Keynote, Google Slides und LibreOffice.

import 'dart:math' as math;
import 'dart:typed_data';

import 'design.dart';
import 'md_blocks.dart';
import 'office_read.dart';
import 'pdf_writer.dart' show ImageResolver, aiDisclaimer, textWidth;
import 'raster.dart';
import 'zip_writer.dart';

const _emu = 12700; // EMU pro Punkt
const _slideW = 12192000, _slideH = 6858000; // 960 × 540 pt

String _x(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

String _runs(String md, int size, {String color = '222628', bool bold = false, bool italic = false, bool major = false}) {
  final b = StringBuffer();
  for (final r in parseInline(md)) {
    if (r.text.isEmpty) continue;
    final attrs = [
      'lang="de-DE"',
      'sz="$size"',
      if (bold || r.bold) 'b="1"',
      if (italic || r.italic) 'i="1"',
      'dirty="0"',
    ].join(' ');
    b.write('<a:r><a:rPr $attrs><a:solidFill><a:srgbClr val="$color"/></a:solidFill>'
        '<a:latin typeface="${major ? '+mj-lt' : '+mn-lt'}"/></a:rPr><a:t>${_x(r.text)}</a:t></a:r>');
  }
  return b.toString();
}

String _textBox(int id, String name, int x, int y, int w, int h, String paragraphs, {String anchor = 't'}) =>
    '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="${_x(name)}"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>'
    '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$w" cy="$h"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>'
    '<a:noFill/></p:spPr><p:txBody><a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0" bIns="0" anchor="$anchor">'
    '<a:normAutofit/></a:bodyPr><a:lstStyle/>$paragraphs</p:txBody></p:sp>';

String _rect(int id, int x, int y, int w, int h, String color) =>
    '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="Fläche $id"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>'
    '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$w" cy="$h"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>'
    '<a:solidFill><a:srgbClr val="$color"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr></p:sp>';

/// Fläche mit Farbverlauf (Winkel in Grad).
String _gradRect(int id, int x, int y, int w, int h, String c1, String c2, {int angle = 45}) =>
    '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="Hintergrund $id"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>'
    '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$w" cy="$h"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>'
    '<a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:srgbClr val="$c1"/></a:gs><a:gs pos="100000"><a:srgbClr val="$c2"/></a:gs></a:gsLst>'
    '<a:lin ang="${angle * 60000}" scaled="0"/></a:gradFill><a:ln><a:noFill/></a:ln></p:spPr></p:sp>';

/// Vordefinierte Form (ellipse, wave, arc …) mit Füllung und/oder Linie.
String _shape(int id, String prst, int x, int y, int w, int h,
        {String? fill, String? line, int lineW = 12700, bool dashed = false, int alpha = 100000, String text = ''}) =>
    '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="Dekor $id"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>'
    '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$w" cy="$h"/></a:xfrm><a:prstGeom prst="$prst"><a:avLst/></a:prstGeom>'
    '${fill == null ? '<a:noFill/>' : '<a:solidFill><a:srgbClr val="$fill"><a:alpha val="$alpha"/></a:srgbClr></a:solidFill>'}'
    '${line == null ? '<a:ln><a:noFill/></a:ln>' : '<a:ln w="$lineW" cap="rnd"><a:solidFill><a:srgbClr val="$line"/></a:solidFill>${dashed ? '<a:prstDash val="dash"/>' : ''}</a:ln>'}'
    '</p:spPr><p:txBody><a:bodyPr lIns="0" tIns="0" rIns="0" bIns="0" anchor="ctr"/><a:lstStyle/>'
    '<a:p><a:pPr algn="ctr"/>${text.isEmpty ? '<a:endParaRPr lang="de-DE"/>' : text}</a:p></p:txBody></p:sp>';

/// Dekor je Motiv. [title]: Titelfolie (größer).
String _motif(SlideDesign d, int Function() nextId, {required bool title}) {
  final b = StringBuffer();
  int e(num v) => (v * _emu).round();
  switch (d.motif) {
    case DesignMotif.travel:
      if (title) {
        // gestrichelte Flugroute mit Zielpunkten und Flugzeug
        b.write(_shape(nextId(), 'arc', e(520), e(40), e(560), e(420), line: 'FFFFFF', lineW: 28575, dashed: true));
        b.write(_shape(nextId(), 'ellipse', e(785), e(52), e(16), e(16), fill: d.secondary));
        b.write(_shape(nextId(), 'ellipse', e(612), e(340), e(14), e(14), fill: 'FFFFFF', alpha: 85000));
        b.write(_textBox(nextId(), 'Flugzeug', e(860), e(118), e(60), e(60),
            '<a:p><a:pPr algn="ctr"/>${_runs('✈', 3600, color: 'FFFFFF')}</a:p>', anchor: 'ctr'));
        b.write(_shape(nextId(), 'wave', 0, e(470), _slideW, e(90), fill: 'FFFFFF', alpha: 16000));
      } else {
        b.write(_shape(nextId(), 'wave', 0, e(492), _slideW, e(60), fill: d.secondary, alpha: 18000));
        b.write(_textBox(nextId(), 'Flugzeug', e(892), e(18), e(40), e(40),
            '<a:p><a:pPr algn="ctr"/>${_runs('✈', 2000, color: d.secondary)}</a:p>', anchor: 'ctr'));
      }
    case DesignMotif.waves:
      b.write(_shape(nextId(), 'wave', 0, e(title ? 440 : 488), _slideW, e(title ? 120 : 70), fill: title ? 'FFFFFF' : d.secondary,
          alpha: title ? 14000 : 20000));
    case DesignMotif.dots:
      for (var i = 0; i < 5; i++) {
        for (var j = 0; j < 3; j++) {
          b.write(_shape(nextId(), 'ellipse', e(860 + i * 16), e(title ? 40 + j * 16 : 22 + j * 16), e(6), e(6),
              fill: title ? 'FFFFFF' : d.secondary, alpha: title ? 50000 : 70000));
        }
      }
    case DesignMotif.corners:
      b.write(_shape(nextId(), 'rtTriangle', e(title ? 760 : 880), e(title ? 340 : 460), e(title ? 200 : 80), e(title ? 200 : 80),
          fill: title ? 'FFFFFF' : d.secondary, alpha: title ? 15000 : 35000));
    case DesignMotif.lines:
    case DesignMotif.none:
      break;
  }
  return b.toString();
}

/// Reiseleiste (roter Faden): Stationen als Punkte, die aktuelle hervorgehoben.
String _journey(SlideDesign d, int Function() nextId, int index, int total) {
  if (total < 3) return '';
  int e(num v) => (v * _emu).round();
  final b = StringBuffer();
  const x0 = 300.0, x1 = 660.0, y = 520.0;
  b.write(_shape(nextId(), 'line', e(x0), e(y), e(x1 - x0), 0, line: d.muted, lineW: 9525, dashed: true));
  for (var i = 0; i < total; i++) {
    final x = x0 + (x1 - x0) * (total == 1 ? 0 : i / (total - 1));
    final cur = i == index;
    final r = cur ? 7.0 : 4.0;
    b.write(_shape(nextId(), 'ellipse', e(x - r), e(y - r), e(2 * r), e(2 * r),
        fill: cur ? d.secondary : (i < index ? d.primary : 'FFFFFF'), line: cur ? null : d.primary, lineW: 9525));
  }
  return b.toString();
}

String _pic(int id, String rid, int x, int y, int w, int h) =>
    '<p:pic><p:nvPicPr><p:cNvPr id="$id" name="Bild $id"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>'
    '<p:blipFill><a:blip r:embed="$rid"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
    '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$w" cy="$h"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>';

String _table(int id, int x, int y, int w, List<List<String>> rows, int size, SlideDesign d) {
  final cols = rows.first.length;
  final colW = w ~/ cols;
  final rowH = (size / 100 * 2.0 * _emu).round();
  final b = StringBuffer(
      '<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="$id" name="Tabelle $id"/><p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>'
      '<p:xfrm><a:off x="$x" y="$y"/><a:ext cx="${colW * cols}" cy="${rowH * rows.length}"/></p:xfrm>'
      '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl><a:tblPr firstRow="1" bandRow="1"/><a:tblGrid>');
  for (var i = 0; i < cols; i++) {
    b.write('<a:gridCol w="$colW"/>');
  }
  b.write('</a:tblGrid>');
  for (var r = 0; r < rows.length; r++) {
    b.write('<a:tr h="$rowH">');
    for (final cell in rows[r]) {
      final fill = r == 0 ? d.primary : (r.isEven ? d.lightColor : 'FFFFFF');
      final color = r == 0 ? 'FFFFFF' : d.text;
      b.write('<a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p>${_runs(cell, size, color: color, bold: r == 0)}'
          '<a:endParaRPr lang="de-DE" sz="$size"/></a:p></a:txBody>'
          '<a:tcPr marL="91440" marR="91440" marT="45720" marB="45720"><a:solidFill><a:srgbClr val="$fill"/></a:solidFill></a:tcPr></a:tc>');
    }
    b.write('</a:tr>');
  }
  b.write('</a:tbl></a:graphicData></a:graphic></p:graphicFrame>');
  return b.toString();
}

/// Schätzt die Höhe (pt) eines Textblocks bei Schriftgröße [pt] und Breite [widthPt].
double _estimateHeight(List<MdBlock> blocks, double pt, double widthPt) {
  var h = 0.0;
  for (final b in blocks) {
    final (text, indent) = switch (b) {
      MdListItem(:final text, :final depth) => (text, 24.0 + depth * 24),
      MdParagraph(:final text) => (text, 0.0),
      MdQuote(:final text) => (text, 12.0),
      MdHeading(:final text) => (text, 0.0),
      MdCode(:final text) => (text, 0.0),
      MdTable(:final rows) => ('', 0.0) ,
      _ => ('', 0.0),
    };
    if (b is MdTable) {
      h += b.rows.length * pt * 2.0;
      continue;
    }
    for (final part in text.split('\n')) {
      final w = textWidth(plainInline(part), pt);
      h += math.max(1, (w / (widthPt - indent)).ceil()) * pt * 1.25;
    }
    h += pt * 0.5;
  }
  return h;
}

/// Erzeugt die PPTX-Datei.
Uint8List buildPptx({
  required String title,
  String? subtitle,
  required List<SlideSpec> slides,
  ImageResolver? resolveImage,
  String author = 'Junels',
  SlideDesign design = const SlideDesign(id: 'standard', name: 'Standard', primary: '0E6B66', secondary: 'E07A2E', motif: DesignMotif.lines),
  PptxTemplate? template,
  bool agenda = false,
}) {
  final zip = ZipWriter();
  final d = design;
  final useTemplate = template != null && template.wide;
  final media = <String>[]; // Dateinamen in ppt/media
  final all = <({String xml, List<String> rels})>[];

  // Titelfolie
  {
    final sp = StringBuffer();
    var id = 2;
    int next() => id++;
    final onDark = !useTemplate;
    if (!useTemplate) {
      sp.write(_gradRect(next(), 0, 0, _slideW, _slideH, d.primary, mix(d.primary, d.secondary, d.motif == DesignMotif.travel ? 0.45 : 0.25),
          angle: 30));
      sp.write(_motif(d, next, title: true));
    }
    final tPt = 40, x = 80 * _emu;
    final tColor = onDark ? 'FFFFFF' : d.primary;
    sp.write(_textBox(next(), 'Titel', x, 150 * _emu, (useTemplate ? _slideW - 2 * x : 520 * _emu), 170 * _emu,
        '<a:p><a:pPr algn="l"/>${_runs(title, tPt * 100, color: tColor, bold: true, major: true)}</a:p>', anchor: 'b'));
    if (subtitle != null) {
      sp.write(_textBox(next(), 'Untertitel', x, 335 * _emu, (useTemplate ? _slideW - 2 * x : 520 * _emu), 110 * _emu,
          '<a:p>${_runs(subtitle, 2000, color: onDark ? mix('FFFFFF', d.secondary, 0.15) : d.muted)}</a:p>'));
    }
    sp.write(_textBox(next(), 'KI-Hinweis', x, 505 * _emu, _slideW - 2 * x, 20 * _emu,
        '<a:p>${_runs(aiDisclaimer, 900, color: onDark ? 'FFFFFF' : d.muted)}</a:p>'));
    all.add((xml: sp.toString(), rels: []));
  }

  // Ablauf-/Routenfolie (roter Faden): Stationen = Folientitel
  final stops = [for (final s in slides) if (s.title.trim().isNotEmpty) s.title];
  if (agenda && stops.length >= 3) {
    final sp = StringBuffer();
    var id = 2;
    int next() => id++;
    int e(num v) => (v * _emu).round();
    if (!useTemplate) {
      sp.write(_rect(next(), 0, 0, _slideW, _slideH, d.background));
      sp.write(_motif(d, next, title: false));
    }
    sp.write(_textBox(next(), 'Titel', e(60), e(40), e(840), e(70),
        '<a:p>${_runs(d.motif == DesignMotif.travel ? 'Die Reiseroute' : 'Ablauf', 3000, color: d.primary, bold: true, major: true)}</a:p>',
        anchor: 'b'));
    final shown = stops.take(8).toList();
    final rows = shown.length > 4 ? 2 : 1;
    final perRow = (shown.length / rows).ceil();
    for (var i = 0; i < shown.length; i++) {
      final r = i ~/ perRow, c = i % perRow;
      final cw = 840 / perRow;
      final cx = 60 + c * cw + cw / 2;
      final cy = rows == 1 ? 270.0 : 200.0 + r * 170;
      if (c > 0) {
        sp.write(_shape(next(), 'line', e(cx - cw + 22), e(cy), e(cw - 44), 0, line: d.muted, lineW: 15875, dashed: true));
      }
      sp.write(_shape(next(), 'ellipse', e(cx - 22), e(cy - 22), e(44), e(44),
          fill: i == 0 || i == shown.length - 1 ? d.secondary : d.primary,
          text: _runs('${i + 1}', 1800, color: 'FFFFFF', bold: true)));
      sp.write(_textBox(next(), 'Station', e(cx - cw / 2 + 6), e(cy + 30), e(cw - 12), e(70),
          '<a:p><a:pPr algn="ctr"/>${_runs(plainInline(shown[i]), shown.length > 5 ? 1300 : 1500, color: d.text)}</a:p>'));
    }
    all.add((xml: sp.toString(), rels: []));
  }

  for (var si = 0; si < slides.length; si++) {
    final s = slides[si];
    final sp = StringBuffer();
    final rels = <String>[];
    var id = 2;
    int next() => id++;
    if (!useTemplate) {
      if (d.background != 'FFFFFF') sp.write(_rect(next(), 0, 0, _slideW, _slideH, d.background));
      if (d.motif == DesignMotif.lines || d.motif == DesignMotif.none) {
        sp.write(_rect(next(), 0, 0, _slideW, 8 * _emu, d.primary));
      } else {
        sp.write(_rect(next(), 0, 0, 14 * _emu, _slideH, d.primary));
      }
      sp.write(_motif(d, next, title: false));
    }
    var top = 40;
    if (s.title.isNotEmpty) {
      sp.write(_textBox(next(), 'Titel', 60 * _emu, top * _emu, (960 - 120) * _emu, 70 * _emu,
          '<a:p>${_runs(s.title, 3000, color: d.primary, bold: true, major: true)}</a:p>', anchor: 'b'));
      if (d.motif == DesignMotif.travel && !useTemplate) {
        sp.write(_shape(next(), 'line', 60 * _emu, 114 * _emu, 120 * _emu, 0, line: d.secondary, lineW: 28575, dashed: true));
      }
      top = 125;
    }
    final images = s.blocks.whereType<MdImage>().toList();
    final textBlocks = s.blocks.where((b) => b is! MdImage && b is! MdTable).toList();
    final tables = s.blocks.whereType<MdTable>().toList();
    var textW = 960.0 - 120;
    final bottom = 500;

    if (images.isNotEmpty) {
      final bytes = resolveImage?.call(images.first.src);
      int? iw, ih;
      String ext = 'png';
      if (bytes != null) {
        if (isPng(bytes)) {
          iw = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
          ih = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
        } else if (isJpeg(bytes)) {
          final info = jpegInfo(bytes);
          iw = info?.width;
          ih = info?.height;
          ext = 'jpeg';
        }
      }
      if (bytes != null && iw != null && ih != null && iw > 0 && ih > 0) {
        final fname = 'junels_bild${media.length + 1}.$ext';
        media.add(fname);
        zip.add('ppt/media/$fname', bytes);
        final rid = 'rId${rels.length + 2}';
        rels.add('<Relationship Id="$rid" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/$fname"/>');
        final hasText = textBlocks.isNotEmpty || tables.isNotEmpty;
        final boxW = hasText ? (960 - 120) * 0.45 : 960.0 - 120;
        final boxH = (bottom - top).toDouble();
        var w = boxW, h = boxW * ih / iw;
        if (h > boxH) {
          h = boxH;
          w = h * iw / ih;
        }
        final x = hasText ? 960 - 60 - w : (960 - w) / 2;
        sp.write(_pic(next(), rid, (x * _emu).round(), (top * _emu).round(), (w * _emu).round(), (h * _emu).round()));
        if (hasText) textW = (960 - 120) * 0.52;
      }
    }

    var y = top.toDouble();
    if (textBlocks.isNotEmpty) {
      var pt = 22.0;
      final avail = (bottom - top) - tables.fold<double>(0, (a, t) => a + t.rows.length * 30 + 10);
      while (pt > 12 && _estimateHeight(textBlocks, pt, textW) > avail) {
        pt -= 2;
      }
      final paras = StringBuffer();
      for (final b in textBlocks) {
        final sz = (pt * 100).round();
        switch (b) {
          case MdListItem(:final text, :final depth, :final number):
            final indent = (24 + depth * 24) * _emu;
            final bullet = number != null
                ? '<a:buFont typeface="+mj-lt"/><a:buAutoNum type="arabicPeriod" startAt="$number"/>'
                : '<a:buFont typeface="Arial"/><a:buChar char="${depth == 0 ? '•' : '–'}"/>';
            paras.write('<a:p><a:pPr marL="$indent" indent="-${18 * _emu}"><a:spcBef><a:spcPts val="${(pt * 30).round()}"/></a:spcBef>'
                '<a:buClr><a:srgbClr val="${d.primary}"/></a:buClr>$bullet</a:pPr>${_runs(text, sz, color: d.text)}</a:p>');
          case MdParagraph(:final text):
            paras.write('<a:p><a:pPr><a:spcBef><a:spcPts val="${(pt * 40).round()}"/></a:spcBef></a:pPr>${_runs(text, sz, color: d.text)}</a:p>');
          case MdQuote(:final text):
            paras.write('<a:p><a:pPr marL="${12 * _emu}"/>${_runs(text, sz, color: d.muted, italic: true)}</a:p>');
          case MdHeading(:final text):
            paras.write('<a:p>${_runs(text, sz, bold: true, color: d.primary)}</a:p>');
          case MdCode(:final text):
            for (final l in text.split('\n')) {
              paras.write('<a:p><a:r><a:rPr lang="de-DE" sz="${(pt * 80).round()}"><a:latin typeface="Courier New"/></a:rPr><a:t>${_x(l)}</a:t></a:r></a:p>');
            }
          default:
            break;
        }
      }
      final h = math.min(_estimateHeight(textBlocks, pt, textW) + 20, (bottom - top).toDouble());
      sp.write(_textBox(next(), 'Inhalt', 60 * _emu, (y * _emu).round(), (textW * _emu).round(), (h * _emu).round(), paras.toString()));
      y += h + 10;
    }
    for (final t in tables) {
      if (t.rows.isEmpty) continue;
      final size = t.rows.length > 8 ? 1100 : 1400;
      sp.write(_table(next(), 60 * _emu, (y * _emu).round(), (textW * _emu).round(), t.rows, size, d));
      y += t.rows.length * size / 100 * 2.0 + 10;
    }
    sp.write(_textBox(next(), 'Foliennummer', (960 - 100) * _emu, 510 * _emu, 60 * _emu, 20 * _emu,
        '<a:p><a:pPr algn="r"/>${_runs('${all.length + 1}', 1000, color: d.muted)}</a:p>'));
    if (d.journey && !useTemplate) sp.write(_journey(d, next, si, slides.length));
    sp.write(_textBox(next(), 'KI-Hinweis', 60 * _emu, 512 * _emu, (d.journey ? 230 : 600) * _emu, 18 * _emu,
        '<a:p>${_runs(aiDisclaimer, d.journey ? 650 : 800, color: d.muted)}</a:p>'));
    all.add((xml: sp.toString(), rels: rels));
  }

  // --- Paketteile ---
  final n = all.length;
  final ct = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Default Extension="png" ContentType="image/png"/>'
      '<Default Extension="jpeg" ContentType="image/jpeg"/>'
      '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>'
      '${useTemplate ? '' : '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>'
          '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>'
          '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>'}'
      '<Override PartName="/ppt/presProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presProps+xml"/>'
      '<Override PartName="/ppt/viewProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml"/>'
      '<Override PartName="/ppt/tableStyles.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml"/>'
      '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
      '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>');
  for (var i = 1; i <= n; i++) {
    ct.write('<Override PartName="/ppt/slides/slide$i.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>');
  }
  if (useTemplate) {
    // Inhaltstypen der übernommenen Teile (Master, Layouts, Design) und ihrer Bildformate
    final exts = <String>{};
    for (final part in template.parts.keys) {
      final t = template.contentTypes['/$part'];
      if (t != null) ct.write('<Override PartName="/$part" ContentType="$t"/>');
      final ext = part.split('.').last.toLowerCase();
      if (!const {'xml', 'rels', 'png', 'jpeg'}.contains(ext)) exts.add(ext);
    }
    for (final ext in exts) {
      final t = template.contentTypes[ext] ??
          switch (ext) {
            'jpg' => 'image/jpeg',
            'gif' => 'image/gif',
            'svg' => 'image/svg+xml',
            'emf' => 'image/x-emf',
            'wmf' => 'image/x-wmf',
            'tif' || 'tiff' => 'image/tiff',
            _ => 'application/octet-stream',
          };
      ct.write('<Default Extension="$ext" ContentType="$t"/>');
    }
  }
  ct.write('</Types>');
  zip.addString('[Content_Types].xml', ct.toString());

  zip.addString('_rels/.rels', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
      '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>'
      '</Relationships>');

  final now = DateTime.now().toUtc().toIso8601String().split('.').first;
  zip.addString('docProps/core.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
      'xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
      '<dc:title>${_x(plainInline(title))}</dc:title><dc:creator>${_x(author)}</dc:creator>'
      '<dcterms:created xsi:type="dcterms:W3CDTF">${now}Z</dcterms:created>'
      '<dcterms:modified xsi:type="dcterms:W3CDTF">${now}Z</dcterms:modified></cp:coreProperties>');
  zip.addString('docProps/app.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" '
      'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">'
      '<Application>Junels</Application><Slides>$n</Slides><PresentationFormat>Breitbild</PresentationFormat></Properties>');

  final sldIds = StringBuffer();
  final presRels = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="${useTemplate ? template.masterPath.substring(4) : 'slideMasters/slideMaster1.xml'}"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="${useTemplate ? (template.parts.keys.firstWhere((k) => k.startsWith('ppt/theme/') && k.endsWith('.xml'), orElse: () => 'ppt/theme/theme1.xml')).substring(4) : 'theme/theme1.xml'}"/>'
      '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/presProps" Target="presProps.xml"/>'
      '<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/viewProps" Target="viewProps.xml"/>'
      '<Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/tableStyles" Target="tableStyles.xml"/>');
  for (var i = 1; i <= n; i++) {
    sldIds.write('<p:sldId id="${255 + i}" r:id="rId${5 + i}"/>');
    presRels.write('<Relationship Id="rId${5 + i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide$i.xml"/>');
  }
  presRels.write('</Relationships>');
  zip.addString('ppt/_rels/presentation.xml.rels', presRels.toString());
  zip.addString('ppt/presentation.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:presentation xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP" saveSubsetFonts="1">'
      '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
      '<p:sldIdLst>$sldIds</p:sldIdLst>'
      '<p:sldSz cx="$_slideW" cy="$_slideH"/><p:notesSz cx="6858000" cy="9144000"/>'
      '<p:defaultTextStyle><a:defPPr><a:defRPr lang="de-DE"/></a:defPPr></p:defaultTextStyle></p:presentation>');
  zip.addString('ppt/presProps.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:presentationPr xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP"/>');
  zip.addString('ppt/viewProps.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:viewPr xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP"><p:normalViewPr><p:restoredLeft sz="15620"/><p:restoredTop sz="94660"/></p:normalViewPr>'
      '<p:gridSpacing cx="76200" cy="76200"/></p:viewPr>');
  zip.addString('ppt/tableStyles.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<a:tblStyleLst xmlns:a="$_nsA" def="{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"/>');

  if (useTemplate) {
    template.parts.forEach(zip.add);
  } else {
  zip.addString('ppt/slideMasters/slideMaster1.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:sldMaster xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP"><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>'
      '<p:spTree>$_grpHeader</p:spTree></p:cSld>'
      '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>'
      '<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>'
      '<p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz="3200"/></a:lvl1pPr></p:titleStyle>'
      '<p:bodyStyle><a:lvl1pPr><a:defRPr sz="2000"/></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:otherStyle></p:txStyles>'
      '</p:sldMaster>');
  zip.addString('ppt/slideMasters/_rels/slideMaster1.xml.rels', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>'
      '</Relationships>');
  zip.addString('ppt/slideLayouts/slideLayout1.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:sldLayout xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP" type="blank" preserve="1"><p:cSld name="Leer"><p:spTree>$_grpHeader</p:spTree></p:cSld>'
      '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>');
  zip.addString('ppt/slideLayouts/_rels/slideLayout1.xml.rels', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>'
      '</Relationships>');
  zip.addString('ppt/theme/theme1.xml', d.themeXml());
  }

  for (var i = 0; i < n; i++) {
    final s = all[i];
    zip.addString('ppt/slides/slide${i + 1}.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<p:sld xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP"><p:cSld><p:spTree>$_grpHeader${s.xml}</p:spTree></p:cSld>'
        '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>');
    zip.addString('ppt/slides/_rels/slide${i + 1}.xml.rels', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../${useTemplate ? template.layoutPath.substring(4) : 'slideLayouts/slideLayout1.xml'}"/>'
        '${s.rels.join()}</Relationships>');
  }
  return zip.build();
}

const _nsA = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _nsR = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _nsP = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const _grpHeader = '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
    '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>';


