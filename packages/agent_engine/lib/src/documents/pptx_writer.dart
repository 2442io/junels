// PowerPoint-Datei (.pptx, 16:9) aus Folien-Markdown – ohne Abhängigkeiten.
// Öffnet sich in PowerPoint, Keynote, Google Slides und LibreOffice.

import 'dart:math' as math;
import 'dart:typed_data';

import 'md_blocks.dart';
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

String _runs(String md, int size, {String color = '222628', bool bold = false, bool italic = false}) {
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
        '<a:latin typeface="+mn-lt"/></a:rPr><a:t>${_x(r.text)}</a:t></a:r>');
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

String _pic(int id, String rid, int x, int y, int w, int h) =>
    '<p:pic><p:nvPicPr><p:cNvPr id="$id" name="Bild $id"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>'
    '<p:blipFill><a:blip r:embed="$rid"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
    '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$w" cy="$h"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>';

String _table(int id, int x, int y, int w, List<List<String>> rows, int size) {
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
      final fill = r == 0 ? '0E6B66' : (r.isEven ? 'EEF5F4' : 'FFFFFF');
      final color = r == 0 ? 'FFFFFF' : '222628';
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
}) {
  final zip = ZipWriter();
  final media = <String>[]; // Dateinamen in ppt/media
  final all = <({String xml, List<String> rels})>[];

  // Titelfolie
  {
    final sp = StringBuffer();
    sp.write(_rect(2, 0, 0, _slideW, _slideH, '0E6B66'));
    final tPt = 40, x = 80 * _emu;
    sp.write(_textBox(3, 'Titel', x, 150 * _emu, _slideW - 2 * x, 160 * _emu,
        '<a:p><a:pPr algn="l"/>${_runs(title, tPt * 100, color: 'FFFFFF', bold: true)}</a:p>', anchor: 'b'));
    if (subtitle != null) {
      sp.write(_textBox(4, 'Untertitel', x, 330 * _emu, _slideW - 2 * x, 120 * _emu,
          '<a:p>${_runs(subtitle, 2000, color: 'D9F2EE')}</a:p>'));
    }
    sp.write(_textBox(5, 'KI-Hinweis', x, 505 * _emu, _slideW - 2 * x, 20 * _emu,
        '<a:p>${_runs(aiDisclaimer, 900, color: 'D9F2EE')}</a:p>'));
    all.add((xml: sp.toString(), rels: []));
  }

  for (var si = 0; si < slides.length; si++) {
    final s = slides[si];
    final sp = StringBuffer();
    final rels = <String>[];
    var id = 2;
    sp.write(_rect(id++, 0, 0, _slideW, 8 * _emu, '0E6B66'));
    var top = 40;
    if (s.title.isNotEmpty) {
      sp.write(_textBox(id++, 'Titel', 60 * _emu, top * _emu, (960 - 120) * _emu, 70 * _emu,
          '<a:p>${_runs(s.title, 3000, color: '0E6B66', bold: true)}</a:p>', anchor: 'b'));
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
        final fname = 'image${media.length + 1}.$ext';
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
        sp.write(_pic(id++, rid, (x * _emu).round(), (top * _emu).round(), (w * _emu).round(), (h * _emu).round()));
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
                '<a:buClr><a:srgbClr val="0E6B66"/></a:buClr>$bullet</a:pPr>${_runs(text, sz)}</a:p>');
          case MdParagraph(:final text):
            paras.write('<a:p><a:pPr><a:spcBef><a:spcPts val="${(pt * 40).round()}"/></a:spcBef></a:pPr>${_runs(text, sz)}</a:p>');
          case MdQuote(:final text):
            paras.write('<a:p><a:pPr marL="${12 * _emu}"/>${_runs(text, sz, color: '6B757F', italic: true)}</a:p>');
          case MdHeading(:final text):
            paras.write('<a:p>${_runs(text, sz, bold: true)}</a:p>');
          case MdCode(:final text):
            for (final l in text.split('\n')) {
              paras.write('<a:p><a:r><a:rPr lang="de-DE" sz="${(pt * 80).round()}"><a:latin typeface="Courier New"/></a:rPr><a:t>${_x(l)}</a:t></a:r></a:p>');
            }
          default:
            break;
        }
      }
      final h = math.min(_estimateHeight(textBlocks, pt, textW) + 20, (bottom - top).toDouble());
      sp.write(_textBox(id++, 'Inhalt', 60 * _emu, (y * _emu).round(), (textW * _emu).round(), (h * _emu).round(), paras.toString()));
      y += h + 10;
    }
    for (final t in tables) {
      if (t.rows.isEmpty) continue;
      final size = t.rows.length > 8 ? 1100 : 1400;
      sp.write(_table(id++, 60 * _emu, (y * _emu).round(), (textW * _emu).round(), t.rows, size));
      y += t.rows.length * size / 100 * 2.0 + 10;
    }
    sp.write(_textBox(id++, 'Foliennummer', (960 - 100) * _emu, 510 * _emu, 60 * _emu, 20 * _emu,
        '<a:p><a:pPr algn="r"/>${_runs('${si + 2}', 1000, color: '6B757F')}</a:p>'));
    sp.write(_textBox(id++, 'KI-Hinweis', 60 * _emu, 512 * _emu, 600 * _emu, 18 * _emu,
        '<a:p>${_runs(aiDisclaimer, 800, color: '8A939C')}</a:p>'));
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
      '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>'
      '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>'
      '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>'
      '<Override PartName="/ppt/presProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presProps+xml"/>'
      '<Override PartName="/ppt/viewProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml"/>'
      '<Override PartName="/ppt/tableStyles.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml"/>'
      '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
      '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>');
  for (var i = 1; i <= n; i++) {
    ct.write('<Override PartName="/ppt/slides/slide$i.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>');
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
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>'
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
  zip.addString('ppt/theme/theme1.xml', _theme);

  for (var i = 0; i < n; i++) {
    final s = all[i];
    zip.addString('ppt/slides/slide${i + 1}.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<p:sld xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP"><p:cSld><p:spTree>$_grpHeader${s.xml}</p:spTree></p:cSld>'
        '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>');
    zip.addString('ppt/slides/_rels/slide${i + 1}.xml.rels', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>'
        '${s.rels.join()}</Relationships>');
  }
  return zip.build();
}

const _nsA = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _nsR = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _nsP = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const _grpHeader = '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
    '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>';

const _theme = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Junels">'
    '<a:themeElements><a:clrScheme name="Junels">'
    '<a:dk1><a:srgbClr val="222628"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>'
    '<a:dk2><a:srgbClr val="0E3B39"/></a:dk2><a:lt2><a:srgbClr val="EEF5F4"/></a:lt2>'
    '<a:accent1><a:srgbClr val="0E6B66"/></a:accent1><a:accent2><a:srgbClr val="E07A2E"/></a:accent2>'
    '<a:accent3><a:srgbClr val="3E7CB1"/></a:accent3><a:accent4><a:srgbClr val="8A6BB8"/></a:accent4>'
    '<a:accent5><a:srgbClr val="5BA05B"/></a:accent5><a:accent6><a:srgbClr val="C9504E"/></a:accent6>'
    '<a:hlink><a:srgbClr val="0E6B66"/></a:hlink><a:folHlink><a:srgbClr val="5E7472"/></a:folHlink></a:clrScheme>'
    '<a:fontScheme name="Junels"><a:majorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>'
    '<a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>'
    '<a:fmtScheme name="Junels"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
    '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>'
    '<a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
    '<a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
    '<a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>'
    '<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle>'
    '<a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>'
    '<a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
    '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements>'
    '<a:objectDefaults/><a:extraClrSchemeLst/></a:theme>';
