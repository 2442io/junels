// Word-Datei (.docx) aus Markdown – ohne Abhängigkeiten.
// Öffnet sich in Word, Pages, Google Docs und LibreOffice. Echte Formatvorlagen (Überschrift 1–3,
// Listen, Zitat, Tabellen), damit das Dokument in Word normal weiterbearbeitet werden kann.

import 'dart:typed_data';

import 'design.dart';
import 'md_blocks.dart';
import 'pdf_writer.dart' show ImageResolver, aiDisclaimer;
import 'raster.dart';
import 'zip_writer.dart';

/// Für XML-Text: Sonderzeichen maskieren, ungültige Steuerzeichen entfernen.
String xmlEscape(String s) => s
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Breite × Höhe eines PNG/JPEG, sonst null.
(int, int)? imagePixelSize(Uint8List b) {
  if (isPng(b) && b.length > 24) {
    return ((b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19], (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23]);
  }
  if (isJpeg(b)) {
    final i = jpegInfo(b);
    if (i != null) return (i.width, i.height);
  }
  return null;
}

/// Erzeugt den Inhalt von word/document.xml (nur der Körper) und sammelt Bilder und Listen.
/// Wird auch beim Ändern fremder Word-Dateien genutzt (neue Absätze einfügen).
class DocxBody {
  DocxBody({this.resolveImage, this.headingStyle = _defaultHeading, this.imageRel, this.firstNumId = 3});

  final ImageResolver? resolveImage;

  /// Stil-Id je Überschriftenebene (fremde Dokumente nutzen z. B. „berschrift1“)
  final String? Function(int level) headingStyle;

  /// Bild registrieren → Beziehungs-Id (rId…); null = Bilder weglassen
  final String Function(Uint8List bytes, String ext)? imageRel;

  /// Nummerierte Listen: jede Liste bekommt eine eigene Nummerierung (beginnt bei 1)
  final int firstNumId;
  final orderedNums = <int>[];
  var _imageCount = 0;

  static String? _defaultHeading(int level) => 'Heading${level.clamp(1, 3)}';

  static String runs(String text, {bool bold = false, bool italic = false, String? color, bool mono = false}) {
    final b = StringBuffer();
    for (final r in parseInline(text)) {
      if (r.text.isEmpty) continue;
      final pr = StringBuffer();
      if (mono) pr.write('<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/>');
      if (bold || r.bold) pr.write('<w:b/>');
      if (italic || r.italic) pr.write('<w:i/>');
      if (color != null) pr.write('<w:color w:val="$color"/>');
      b.write('<w:r>${pr.isEmpty ? '' : '<w:rPr>$pr</w:rPr>'}<w:t xml:space="preserve">${xmlEscape(r.text)}</w:t></w:r>');
    }
    return b.toString();
  }

  static String para(String inner, {String? style, String extraPr = ''}) =>
      '<w:p>${style != null || extraPr.isNotEmpty ? '<w:pPr>${style != null ? '<w:pStyle w:val="$style"/>' : ''}$extraPr</w:pPr>' : ''}$inner</w:p>';

  String build(List<MdBlock> blocks, {String headerFill = '1F4E79', String lightFill = 'EAF1F8'}) {
    final out = StringBuffer();
    MdBlock? prev;
    int? currentNum;
    for (final bl in blocks) {
      switch (bl) {
        case MdHeading(:final level, :final text):
          final st = headingStyle(level);
          out.write(para(runs(text, bold: st == null), style: st));
        case MdParagraph(:final text):
          final lines = text.split('\n');
          out.write(para([for (final l in lines) runs(l)].join('<w:r><w:br/></w:r>')));
        case MdListItem(:final text, :final depth, :final number):
          int numId;
          if (number == null) {
            numId = 1;
          } else {
            if (currentNum == null || prev is! MdListItem) {
              currentNum = firstNumId + orderedNums.length;
              orderedNums.add(currentNum);
            }
            numId = currentNum!;
          }
          out.write(para(runs(text),
              style: 'ListParagraph', extraPr: '<w:numPr><w:ilvl w:val="${depth.clamp(0, 4)}"/><w:numId w:val="$numId"/></w:numPr>'));
        case MdTable(:final rows):
          if (rows.isEmpty) break;
          final cols = rows.map((r) => r.length).fold<int>(0, (a, b) => a > b ? a : b);
          final w = (9000 / (cols == 0 ? 1 : cols)).floor();
          out.write('<w:tbl><w:tblPr><w:tblStyle w:val="JunelsTabelle"/><w:tblW w:w="5000" w:type="pct"/>'
              '<w:tblBorders><w:top w:val="single" w:sz="4" w:color="BFBFBF"/><w:bottom w:val="single" w:sz="4" w:color="BFBFBF"/>'
              '<w:insideH w:val="single" w:sz="4" w:color="D9D9D9"/></w:tblBorders>'
              '<w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" w:firstColumn="0" w:lastColumn="0" w:noHBand="0" w:noVBand="1"/></w:tblPr>'
              '<w:tblGrid>${'<w:gridCol w:w="$w"/>' * cols}</w:tblGrid>');
          for (var r = 0; r < rows.length; r++) {
            final head = r == 0;
            out.write('<w:tr>${head ? '<w:trPr><w:tblHeader/></w:trPr>' : ''}');
            for (var c = 0; c < cols; c++) {
              final cell = c < rows[r].length ? rows[r][c] : '';
              final fill = head ? headerFill : (r.isEven ? lightFill : null);
              out.write('<w:tc><w:tcPr><w:tcW w:w="$w" w:type="dxa"/>${fill != null ? '<w:shd w:val="clear" w:color="auto" w:fill="$fill"/>' : ''}</w:tcPr>'
                  '${para(runs(cell, bold: head, color: head ? 'FFFFFF' : null), extraPr: '<w:spacing w:before="40" w:after="40"/>')}</w:tc>');
            }
            out.write('</w:tr>');
          }
          out.write('</w:tbl>${para('')}');
        case MdImage(:final src, :final caption):
          final bytes = resolveImage?.call(src);
          final size = bytes == null ? null : imagePixelSize(bytes);
          if (bytes == null || size == null || imageRel == null) break;
          final rid = imageRel!(bytes, isPng(bytes) ? 'png' : 'jpeg');
          // max. 16 cm breit, 12 cm hoch
          var cx = size.$1 * 9525.0, cy = size.$2 * 9525.0;
          final scale = [1.0, 5760000 / cx, 4320000 / cy].reduce((a, b) => a < b ? a : b);
          cx *= scale;
          cy *= scale;
          _imageCount++;
          out.write(para(
              '<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="${cx.round()}" cy="${cy.round()}"/>'
              '<wp:docPr id="$_imageCount" name="Bild $_imageCount" descr="${xmlEscape(caption)}"/>'
              '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
              '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="$_imageCount" name="Bild $_imageCount"/><pic:cNvPicPr/></pic:nvPicPr>'
              '<pic:blipFill><a:blip r:embed="$rid"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
              '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="${cx.round()}" cy="${cy.round()}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
              '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>',
              extraPr: '<w:jc w:val="center"/>'));
          if (caption.trim().isNotEmpty) out.write(para(runs(caption), style: 'Caption'));
        case MdQuote(:final text):
          out.write(para(runs(text), style: 'Quote'));
        case MdCode(:final text):
          out.write(para([for (final l in text.split('\n')) runs(l, mono: true)].join('<w:r><w:br/></w:r>'), style: 'Code'));
        case MdRule():
          out.write(para('', extraPr: '<w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="BFBFBF"/></w:pBdr>'));
      }
      if (bl is! MdListItem) currentNum = null;
      prev = bl;
    }
    return out.toString();
  }
}

/// Nummerierungsdefinitionen: 1 = Aufzählung, 2 = Zahlen (Vorlage), ab 3 = je Liste eine eigene Zählung.
String docxNumbering(List<int> orderedNums) {
  String lvl(int i, bool bullet) => bullet
      ? '<w:lvl w:ilvl="$i"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="${['•', '◦', '▪', '•', '◦'][i]}"/><w:lvlJc w:val="left"/>'
          '<w:pPr><w:ind w:left="${720 + 360 * i}" w:hanging="360"/></w:pPr></w:lvl>'
      : '<w:lvl w:ilvl="$i"><w:start w:val="1"/><w:numFmt w:val="${['decimal', 'lowerLetter', 'lowerRoman', 'decimal', 'lowerLetter'][i]}"/>'
          '<w:lvlText w:val="%${i + 1}."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="${720 + 360 * i}" w:hanging="360"/></w:pPr></w:lvl>';
  final b = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>${[for (var i = 0; i < 5; i++) lvl(i, true)].join()}</w:abstractNum>'
      '<w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>${[for (var i = 0; i < 5; i++) lvl(i, false)].join()}</w:abstractNum>'
      '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>');
  for (final n in orderedNums) {
    b.write('<w:num w:numId="$n"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/></w:lvlOverride></w:num>');
  }
  b.write('</w:numbering>');
  return b.toString();
}

String _styles(SlideDesign d) {
  final font = xmlEscape(d.font);
  final head = xmlEscape(d.headFont ?? d.font);
  final accent = d.primary;
  String hs(int n, int size, {bool caps = false}) =>
      '<w:style w:type="paragraph" w:styleId="Heading$n"><w:name w:val="heading $n"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>'
      '<w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="${n == 1 ? 360 : 240}" w:after="120"/><w:outlineLvl w:val="${n - 1}"/></w:pPr>'
      '<w:rPr><w:rFonts w:ascii="$head" w:hAnsi="$head" w:cs="$head"/><w:b/><w:color w:val="$accent"/><w:sz w:val="$size"/><w:szCs w:val="$size"/></w:rPr></w:style>';
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="$font" w:hAnsi="$font" w:eastAsia="$font" w:cs="$font"/><w:sz w:val="22"/><w:szCs w:val="22"/>'
      '<w:lang w:val="de-DE"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="140" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/><w:rPr><w:color w:val="${d.dark ? '222628' : d.text}"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>'
      '<w:pPr><w:spacing w:after="240"/><w:pBdr><w:bottom w:val="single" w:sz="12" w:space="4" w:color="$accent"/></w:pBdr></w:pPr>'
      '<w:rPr><w:rFonts w:ascii="$head" w:hAnsi="$head" w:cs="$head"/><w:b/><w:color w:val="$accent"/><w:sz w:val="52"/><w:szCs w:val="52"/></w:rPr></w:style>'
      '${hs(1, 32)}${hs(2, 27)}${hs(3, 24)}'
      '<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/>'
      '<w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/>'
      '<w:pPr><w:ind w:left="567" w:right="567"/><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="$accent"/></w:pBdr></w:pPr>'
      '<w:rPr><w:i/><w:color w:val="${d.muted}"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/>'
      '<w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F3F4F6"/><w:spacing w:after="140" w:line="240" w:lineRule="auto"/></w:pPr>'
      '<w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/><w:sz w:val="19"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/><w:basedOn w:val="Normal"/><w:qFormat/>'
      '<w:pPr><w:jc w:val="center"/></w:pPr><w:rPr><w:i/><w:color w:val="${d.muted}"/><w:sz w:val="18"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Footer"><w:name w:val="footer"/><w:basedOn w:val="Normal"/><w:rPr><w:color w:val="${d.muted}"/><w:sz w:val="16"/></w:rPr></w:style>'
      '<w:style w:type="table" w:styleId="JunelsTabelle"><w:name w:val="Junels Tabelle"/><w:tblPr><w:tblBorders>'
      '<w:top w:val="single" w:sz="4" w:color="BFBFBF"/><w:bottom w:val="single" w:sz="4" w:color="BFBFBF"/>'
      '<w:insideH w:val="single" w:sz="4" w:color="D9D9D9"/></w:tblBorders><w:tblCellMar><w:left w:w="100" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>'
      '</w:styles>';
}

const _docNs = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"';

/// Word-Dokument aus Markdown. Beginnt der Markdown nicht mit derselben Überschrift, wird [title] als Titel gesetzt.
Uint8List buildDocx({required String title, required String markdown, ImageResolver? resolveImage, SlideDesign? design}) {
  final d = design ?? designById('klar');
  var blocks = parseMarkdown(markdown);
  final first = blocks.firstOrNull;
  final sameTitle = first is MdHeading && first.level == 1 && plainInline(first.text).trim().toLowerCase() == title.trim().toLowerCase();
  if (sameTitle) blocks = blocks.sublist(1);
  final zip = ZipWriter();
  final media = <String>[];
  final rels = <String>[
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>',
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>',
    '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>',
  ];
  final body = DocxBody(
    resolveImage: resolveImage,
    imageRel: (bytes, ext) {
      final name = 'bild${media.length + 1}.$ext';
      media.add(name);
      zip.add('word/media/$name', bytes);
      final rid = 'rId${rels.length + 1}';
      rels.add('<Relationship Id="$rid" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/$name"/>');
      return rid;
    },
  );
  final content = body.build(blocks, headerFill: d.primary, lightFill: d.lightColor);
  final doc = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document $_docNs><w:body>'
      '${title.trim().isEmpty ? '' : DocxBody.para(DocxBody.runs(title), style: 'Title')}'
      '$content'
      '<w:sectPr><w:footerReference w:type="default" r:id="rId3"/><w:pgSz w:w="11906" w:h="16838"/>'
      '<w:pgMar w:top="1417" w:right="1417" w:bottom="1134" w:left="1417" w:header="708" w:footer="567" w:gutter="0"/></w:sectPr>'
      '</w:body></w:document>';
  final footer = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:ftr $_docNs>'
      '<w:p><w:pPr><w:pStyle w:val="Footer"/><w:tabs><w:tab w:val="right" w:pos="9072"/></w:tabs></w:pPr>'
      '<w:r><w:t xml:space="preserve">${xmlEscape(aiDisclaimer)}</w:t></w:r><w:r><w:tab/></w:r>'
      '<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>'
      '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p></w:ftr>';
  final now = DateTime.now().toUtc().toIso8601String().split('.').first;
  zip
    ..addString('[Content_Types].xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
        '<Default Extension="png" ContentType="image/png"/><Default Extension="jpeg" ContentType="image/jpeg"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
        '<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>'
        '<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>'
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>')
    ..addString('_rels/.rels',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>')
    ..addString('docProps/core.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
        '<dc:title>${xmlEscape(title)}</dc:title><dc:creator>Junels (KI)</dc:creator><dc:description>${xmlEscape(aiDisclaimer)}</dc:description>'
        '<dcterms:created xsi:type="dcterms:W3CDTF">${now}Z</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">${now}Z</dcterms:modified></cp:coreProperties>')
    ..addString('docProps/app.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Junels</Application></Properties>')
    ..addString('word/document.xml', doc)
    ..addString('word/styles.xml', _styles(d))
    ..addString('word/numbering.xml', docxNumbering(body.orderedNums))
    ..addString('word/footer1.xml', footer)
    ..addString('word/_rels/document.xml.rels',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${rels.join()}</Relationships>');
  return zip.build();
}
