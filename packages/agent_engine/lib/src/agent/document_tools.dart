// Werkzeuge zum Erstellen von Dateien: PDF-Dokumente, Word, Excel, Präsentationen (PPTX + PDF),
// Diagramme und Bilder. Ergebnisse landen im Ausgabe-Ordner und als Artefakt im Chat.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../documents/md_blocks.dart';
import '../documents/pdf_writer.dart';
import '../documents/pptx_writer.dart';
import '../documents/design.dart';
import '../documents/design_library.dart';
import '../documents/office_read.dart';
import '../documents/docx_writer.dart';
import '../documents/xlsx_writer.dart';
import '../documents/office_edit.dart';
import 'design_resolver.dart';
import 'tool.dart';

/// Gemeinsame Umgebung für die Datei-Werkzeuge.
class OutputSpace {
  OutputSpace(this.dir,
      {this.extraImages, this.imageGenerator, this.maxAutoImages = 3, this.decodeImage, this.fetchBytes, this.attachedFiles});

  /// Angehängte Word-/Excel-Dateien (Name → Pfad), die edit_file als Kopie ändern darf.
  final Map<String, String> Function()? attachedFiles;

  /// Bilder dekodieren (für Farben aus Beispielbildern) – in der App über dart:ui.
  final ImageDecoder? decodeImage;

  /// Zum Testen austauschbar.
  final Future<(Uint8List, String)> Function(Uri)? fetchBytes;

  /// Bilder automatisch erzeugen (Stable Diffusion), wenn ein Bildmodell bereit ist – sonst null.
  final ImageGenerator? Function()? imageGenerator;

  /// Höchstens so viele Bilder je Dokument/Präsentation automatisch erzeugen (Handy: dauert je 1–3 min).
  final int maxAutoImages;

  /// Ordner für erzeugte Dateien.
  final Directory dir;

  /// Weitere Bilder, die im Markdown per Name referenziert werden dürfen (z. B. Anhänge).
  final Map<String, String> Function()? extraImages;

  /// Eindeutiger Dateiname aus einem Titel.
  File fileFor(String title, String ext) {
    dir.createSync(recursive: true);
    var base = title
        .replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (base.isEmpty) base = 'Dokument';
    if (base.length > 60) base = base.substring(0, 60).trim();
    var f = File('${dir.path}/$base.$ext');
    var i = 2;
    while (f.existsSync()) {
      f = File('${dir.path}/$base ($i).$ext');
      i++;
    }
    return f;
  }

  /// Sucht ein Bild: absoluter Pfad, Datei im Ausgabe-Ordner oder bekannter Anhang.
  Uint8List? resolveImage(String src) {
    final name = Uri.decodeFull(src.trim());
    final candidates = <String>[
      name,
      '${dir.path}/$name',
      '${dir.path}/${name.split('/').last}',
      if (extraImages != null) ...[
        for (final e in extraImages!().entries)
          if (e.key.toLowerCase() == name.toLowerCase() || e.key.toLowerCase() == name.split('/').last.toLowerCase()) e.value,
      ],
    ];
    for (final c in candidates) {
      final f = File(c);
      if (f.isAbsolute && f.existsSync()) return f.readAsBytesSync();
    }
    // ohne Endung angegeben?
    for (final ext in ['png', 'jpg', 'jpeg']) {
      final f = File('${dir.path}/$name.$ext');
      if (f.existsSync()) return f.readAsBytesSync();
    }
    return null;
  }

  List<String> missingImages(String markdown) => [
        for (final b in parseMarkdown(markdown))
          if (b is MdImage && resolveImage(b.src) == null) b.src,
      ];
}

/// Fehlende Bilder (![Beschreibung](name), die es nicht gibt) und Zeilen „Bild: …“ / „Bild-Idee: …“
/// automatisch mit dem Bildmodell erzeugen. Gibt den Markdown mit echten Dateinamen zurück.
Future<(String, int)> autoImages(OutputSpace out, String md, ToolContext ctx) async {
  final gen = out.imageGenerator?.call();
  if (gen == null) return (md, 0);
  // „Bild-Idee: …“ als Bild-Platzhalter
  var text = md.replaceAllMapped(
      RegExp(r'^[ \t]*[-*]?[ \t]*\**(?:Bild(?:-?Idee)?|Foto|Illustration|Image)\**[ \t]*:\**[ \t]*(.+)$', multiLine: true, caseSensitive: false),
      (m) => '![${m.group(1)!.replaceAll(RegExp(r'[\[\]*]'), '').trim()}](auto)');
  var made = 0;
  final cache = <String, String>{};
  final re = RegExp(r'!\[([^\]]*)\]\(([^)]*)\)');
  final buf = StringBuffer();
  var last = 0;
  for (final m in re.allMatches(text)) {
    buf.write(text.substring(last, m.start));
    last = m.end;
    final alt = m.group(1)!.trim();
    final src = m.group(2)!.trim();
    if (src.isNotEmpty && src != 'auto' && out.resolveImage(src) != null) {
      buf.write(m.group(0));
      continue;
    }
    final prompt = alt.isNotEmpty ? alt : src.replaceAll(RegExp(r'\.(png|jpe?g)$'), '').replaceAll(RegExp(r'[_-]'), ' ');
    if (prompt.trim().isEmpty || made >= out.maxAutoImages) {
      continue; // Platzhalter ohne Bild entfernen
    }
    try {
      final path = cache[prompt] ??= await gen('$prompt, high quality photo, detailed', 'landscape', '');
      made++;
      final f = File(path);
      if (!ctx.generatedImages.contains(f.path)) ctx.generatedImages.add(f.path);
      _artifact(ctx, f, 'image');
      buf.write('![${alt.isEmpty ? '' : alt}](${_ref(f.path)})');
    } catch (_) {
      // Bild ging nicht – Dokument trotzdem erstellen
    }
  }
  buf.write(text.substring(last));
  return (buf.toString(), made);
}

/// Dateiname für Markdown-Verweise (Leerzeichen kodiert, resolveImage dekodiert).
String _ref(String path) => path.split('/').last.replaceAll(' ', '%20');

final _wantsImagesRe = RegExp(r'(bild|bilder|bildern|foto|fotos|illustration|illustrationen|grafik|grafiken|image|images|picture|pictures|photo|photos)\b',
    caseSensitive: false);

/// Hat der Nutzer Bilder verlangt („… mit Bildern“)?
bool wantsImages(String request) => _wantsImagesRe.hasMatch(request);

/// Bilder in Folien bzw. Abschnitte einsetzen, die noch keines haben:
/// zuerst bereits erzeugte Bilder dieses Auftrags, dann (falls gewünscht) neue „auto“-Bilder.
/// [slides]: Folien beginnen mit „# “ (Präsentation), sonst Abschnitte mit „#“/„##“.
String placeImages(String md, {required List<String> files, required bool auto, required int maxAuto, bool slides = true}) {
  final unused = [
    for (final f in files)
      if (!md.contains(f.split('/').last) && !md.contains(_ref(f))) f
  ];
  if (unused.isEmpty && !auto) return md;
  final lines = md.split('\n');
  final heading = slides ? RegExp(r'^#\s+(.+)$') : RegExp(r'^#{1,2}\s+(.+)$');
  // Abschnitte bestimmen: [start, end)
  final starts = <int>[for (var i = 0; i < lines.length; i++) if (heading.hasMatch(lines[i])) i];
  if (starts.isEmpty) {
    // ohne Überschriften: alle unbenutzten Bilder ans Ende
    return [md, for (final f in unused) '\n![](${_ref(f)})'].join('\n');
  }
  final inserts = <int, String>{};
  var autoLeft = maxAuto;
  var fi = 0;
  for (var k = 0; k < starts.length; k++) {
    final a = starts[k], b = k + 1 < starts.length ? starts[k + 1] : lines.length;
    final body = lines.sublist(a + 1, b).join('\n');
    if (body.contains('![')) continue;
    // Abschluss-/Fragenfolien ohne Bild lassen
    final title = heading.firstMatch(lines[a])!.group(1)!.replaceAll(RegExp(r'[*_`]'), '').trim();
    if (RegExp(r'^(fragen|danke|vielen dank|quellen|kontakt|fazit|zusammenfassung|agenda|inhalt)', caseSensitive: false).hasMatch(title)) {
      continue;
    }
    if (fi < unused.length) {
      inserts[a] = '![$title](${_ref(unused[fi++])})';
    } else if (auto && autoLeft > 0) {
      inserts[a] = '![$title](auto)';
      autoLeft--;
    }
    if (fi >= unused.length && (!auto || autoLeft == 0)) break;
  }
  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    out.add(lines[i]);
    final ins = inserts[i];
    if (ins != null) {
      // nach den Stichpunkten der Folie einfügen (vor der nächsten Überschrift)
      var j = i + 1;
      while (j < lines.length && !heading.hasMatch(lines[j])) {
        out.add(lines[j]);
        j++;
      }
      out.add('');
      out.add(ins);
      i = j - 1;
    }
  }
  return out.join('\n');
}

void _artifact(ToolContext ctx, File f, String kind) =>
    ctx.onArtifact(Artifact(title: f.uri.pathSegments.last, kind: kind, content: f.path));

String _imagesHint(OutputSpace out, String md) {
  final missing = out.missingImages(md);
  return missing.isEmpty ? '' : ' Hinweis: Bilder nicht gefunden (${missing.join(', ')}) – erst mit generate_image oder create_chart erzeugen.';
}

class CreateDocumentTool extends AgentTool {
  CreateDocumentTool(this.out);
  final OutputSpace out;

  @override
  Duration? get timeout => const Duration(minutes: 15);

  @override
  String get name => 'create_document';
  @override
  String get keywords => 'pdf dokument bericht brief zusammenfassung datei';
  @override
  String get title => 'PDF-Dokument erstellen';
  @override
  String get description =>
      'Erstellt ein PDF-Dokument (Bericht, Brief, Zusammenfassung) aus Markdown: # Überschriften, Listen, '
      'Tabellen, **fett**, Bilder mit ![Titel](dateiname.png) – oder ![Bildbeschreibung auf Englisch](auto), dann wird das Bild erzeugt.';
  @override
  List<ToolParam> get params => const [
        ToolParam('title', ParamType.string, 'Titel des Dokuments'),
        ToolParam('content', ParamType.string, 'Inhalt in Markdown'),
        ToolParam('vorlage', ParamType.string, 'Design-Vorlagen des Nutzers: Links/Dateinamen (optional)'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final title = (args['title'] ?? '').toString().trim();
    if ((args['content'] ?? '').toString().trim().isEmpty) throw ToolException('content ist leer');
    final want = wantsImages(ctx.userRequest);
    final raw = placeImages((args['content'] ?? '').toString(),
        files: ctx.generatedImages, auto: want && out.imageGenerator?.call() != null, maxAuto: out.maxAutoImages, slides: false);
    final (content, _) = await autoImages(out, raw, ctx);
    final look = await resolveDesign(
      ctx: ctx,
      topic: '$title $content',
      reference: args['vorlage']?.toString(),
      decodeImage: out.decodeImage,
      readLocal: out.resolveImage,
      fetch: out.fetchBytes,
    );
    final bytes = buildPdfDocument(
        title: title.isEmpty ? 'Dokument' : title, markdown: content, resolveImage: out.resolveImage, theme: look.design.pdfTheme);
    final f = out.fileFor(title.isEmpty ? 'Dokument' : title, 'pdf');
    await f.writeAsBytes(bytes);
    await FileSource.save(f, type: 'pdf', title: title.isEmpty ? 'Dokument' : title, content: content, design: look.design);
    _artifact(ctx, f, 'pdf');
    return 'PDF erstellt: ${f.uri.pathSegments.last} (${(bytes.length / 1024).ceil()} KB). ${look.design.source != null ? '${look.summary}. ' : ''}'
        'Der Nutzer sieht die Datei im Chat.${_imagesHint(out, content)}';
  }
}

class CreateWordTool extends AgentTool {
  CreateWordTool(this.out);
  final OutputSpace out;

  @override
  Duration? get timeout => const Duration(minutes: 15);
  @override
  String get name => 'create_word';
  @override
  String get keywords => 'word docx dokument brief vorlage bericht bearbeitbar';
  @override
  String get title => 'Word-Dokument erstellen';
  @override
  String get description =>
      'Erstellt ein bearbeitbares Word-Dokument (.docx) aus Markdown: # Überschriften, Listen, Tabellen, **fett**, Zitate, '
      'Bilder mit ![Titel](dateiname.png) oder ![Bildbeschreibung auf Englisch](auto). Für Briefe, Berichte, Vorlagen, die man weiter bearbeitet.';
  @override
  List<ToolParam> get params => const [
        ToolParam('title', ParamType.string, 'Titel des Dokuments'),
        ToolParam('content', ParamType.string, 'Inhalt in Markdown'),
        ToolParam('vorlage', ParamType.string, 'Design-Vorlagen des Nutzers: Links/Dateinamen (optional)'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final title = (args['title'] ?? '').toString().trim();
    if ((args['content'] ?? '').toString().trim().isEmpty) throw ToolException('content ist leer');
    final want = wantsImages(ctx.userRequest);
    final raw = placeImages((args['content'] ?? '').toString(),
        files: ctx.generatedImages, auto: want && out.imageGenerator?.call() != null, maxAuto: out.maxAutoImages, slides: false);
    final (content, _) = await autoImages(out, raw, ctx);
    final look = await resolveDesign(
      ctx: ctx,
      topic: '$title $content',
      reference: args['vorlage']?.toString(),
      decodeImage: out.decodeImage,
      readLocal: out.resolveImage,
      fetch: out.fetchBytes,
    );
    final t = title.isEmpty ? 'Dokument' : title;
    final bytes = buildDocx(title: t, markdown: content, resolveImage: out.resolveImage, design: look.design);
    final f = out.fileFor(t, 'docx');
    await f.writeAsBytes(bytes);
    await FileSource.save(f, type: 'docx', title: t, content: content, design: look.design);
    _artifact(ctx, f, 'docx');
    return 'Word-Dokument erstellt: ${f.uri.pathSegments.last} (${(bytes.length / 1024).ceil()} KB). '
        '${look.design.source != null ? '${look.summary}. ' : ''}Der Nutzer sieht die Datei im Chat.${_imagesHint(out, content)}';
  }
}

class CreateExcelTool extends AgentTool {
  CreateExcelTool(this.out);
  final OutputSpace out;

  @override
  String get name => 'create_excel';
  @override
  String get keywords => 'excel xlsx tabelle tabellenkalkulation liste budget kalkulation auswertung spreadsheet';
  @override
  String get title => 'Excel-Tabelle erstellen';
  @override
  String get description =>
      'Erstellt eine Excel-Mappe (.xlsx). content: eine oder mehrere Markdown-Tabellen, je Blatt "## Blattname" davor '
      '(oder CSV mit ; getrennt). Erste Zeile = Spaltenköpfe. Zahlen, Datum (31.12.2026), Prozent (12 %) und Euro (12,50 €) werden echte Werte. '
      'Formeln mit = am Anfang, z. B. =SUMME(B2:B9) oder =B2*C2.';
  @override
  List<ToolParam> get params => const [
        ToolParam('title', ParamType.string, 'Dateiname/Titel der Mappe'),
        ToolParam('content', ParamType.string, 'Markdown-Tabellen (je Blatt "## Name" davor) oder CSV'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final title = (args['title'] ?? '').toString().trim();
    final content = (args['content'] ?? '').toString();
    final sheets = sheetsFromMarkdown(content, fallbackName: title.isEmpty ? 'Tabelle1' : sheetName(title));
    if (sheets.isEmpty) throw ToolException('Keine Tabelle gefunden – content als Markdown-Tabelle (| Spalte | … |) oder CSV angeben.');
    final t = title.isEmpty ? 'Tabelle' : title;
    final look = await resolveDesign(ctx: ctx, topic: t, decodeImage: out.decodeImage, readLocal: out.resolveImage, fetch: out.fetchBytes);
    final bytes = buildXlsx(sheets, title: t, design: look.design);
    final f = out.fileFor(t, 'xlsx');
    await f.writeAsBytes(bytes);
    await FileSource.save(f, type: 'xlsx', title: t, content: content, design: look.design);
    _artifact(ctx, f, 'xlsx');
    final formulas = RegExp(r'(^|\|)\s*=').allMatches(content).length;
    return 'Excel-Mappe erstellt: ${f.uri.pathSegments.last} – ${sheets.length} Blatt/Blätter '
        '(${sheets.map((s) => '${s.name}: ${s.rows.length} Zeilen').join(', ')})${formulas > 0 ? ', mit Formeln' : ''}. Der Nutzer sieht die Datei im Chat.';
  }
}

class CreatePresentationTool extends AgentTool {
  CreatePresentationTool(this.out);
  final OutputSpace out;

  @override
  Duration? get timeout => const Duration(minutes: 15);

  @override
  String get name => 'create_presentation';
  @override
  String get keywords => 'präsentation folien folie slides powerpoint pptx vortrag deck';
  @override
  String get title => 'Präsentation erstellen';
  @override
  String get description =>
      'Erstellt eine Präsentation (PowerPoint .pptx und PDF). content in Markdown: jede "# Überschrift" '
      'beginnt eine Folie, darunter 3–6 kurze Stichpunkte mit "- ", optional eine Tabelle. Bild auf einer Folie: '
      '![kurze Bildbeschreibung auf Englisch](auto) – es wird automatisch erzeugt (Bildmodell), oder ![](name.png) für ein vorhandenes Bild. '
      'Vorher mit generate_image erzeugte Bilder kommen automatisch auf Folien ohne Bild. '
      'Baue einen roten Faden: Einstieg → Etappen → Abschluss, Folientitel als Stationen. '
      'design: passender Stil (reise, reise-landschaft, reise-vintage, reise-nacht, natur, business, technik, warm, elegant, bildung, gesundheit, junels = hell, freundlich, modern wie die Junels-Webseite) oder auto. '
      'vorlage: Links oder Dateinamen von Beispielbildern oder PowerPoint/Word/Excel-Vorlagen des Nutzers – Farben, Schriften und Folienmaster werden übernommen.'
      '${DesignLibrary.describe}';
  @override
  List<ToolParam> get params => [
        const ToolParam('title', ParamType.string, 'Titel der Präsentation'),
        const ToolParam('content', ParamType.string, 'Folien in Markdown'),
        ToolParam('design', ParamType.enumeration, 'Stil der Folien', values: [
          'auto',
          ...DesignLibrary.user.map((u) => u.id),
          'reise', 'reise-landschaft', 'reise-vintage', 'reise-nacht', 'natur', 'business', 'technik', 'warm', 'elegant', 'bildung',
          'gesundheit', 'junels', 'standard'
        ]),
        const ToolParam('vorlage', ParamType.string, 'Design-Vorlagen: Links/Dateinamen (optional)'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final title = (args['title'] ?? '').toString().trim().isEmpty ? 'Präsentation' : args['title'].toString().trim();
    final want = wantsImages(ctx.userRequest);
    final canGen = out.imageGenerator?.call() != null;
    final raw = placeImages((args['content'] ?? '').toString(),
        files: ctx.generatedImages, auto: want && canGen, maxAuto: out.maxAutoImages, slides: true);
    final (content, made) = await autoImages(out, raw, ctx);
    final split = splitSlides(content);
    if (split.slides.isEmpty) throw ToolException('Keine Folien gefunden: jede Folie mit "# Titel" beginnen.');
    final look = await resolveDesign(
      ctx: ctx,
      topic: '$title $content',
      design: args['design']?.toString(),
      reference: args['vorlage']?.toString(),
      decodeImage: out.decodeImage,
      readLocal: out.resolveImage,
      fetch: out.fetchBytes,
    );
    final agenda = look.design.journey ||
        RegExp(r'roter faden|roten faden|customer journey|journey|agenda|ablauf|route', caseSensitive: false).hasMatch(ctx.userRequest);
    final pptx = buildPptx(
        title: title,
        subtitle: split.subtitle,
        slides: split.slides,
        resolveImage: out.resolveImage,
        design: look.design,
        template: look.template,
        agenda: agenda);
    final pdf = buildSlidesPdf(
        title: title, subtitle: split.subtitle, slides: split.slides, resolveImage: out.resolveImage, theme: look.design.pdfTheme);
    final f1 = out.fileFor(title, 'pptx');
    await f1.writeAsBytes(pptx);
    final f2 = File(f1.path.replaceFirst(RegExp(r'\.pptx$'), '.pdf'));
    await f2.writeAsBytes(pdf);
    await FileSource.save(f1, type: 'pptx', title: title, content: content, design: look.design, agenda: agenda, templateBytes: look.templateBytes);
    _artifact(ctx, f1, 'pptx');
    _artifact(ctx, f2, 'pdf');
    final pictures = RegExp(r'!\[[^\]]*\]\(([^)]+)\)').allMatches(content).where((m) => out.resolveImage(m.group(1)!) != null).length;
    return 'Präsentation mit ${split.slides.length + 1} Folien${pictures > 0 ? ' und $pictures Bildern' : ''} erstellt: ${f1.uri.pathSegments.last} '
        '(PowerPoint) und ${f2.uri.pathSegments.last} (PDF). ${look.summary}.${agenda ? ' Mit Ablauf-/Routenfolie und Fortschrittsleiste als rotem Faden.' : ''}'
        '${made > 0 ? ' $made Bilder wurden dafür neu erzeugt (mit KI-Kennzeichnung).' : ''}'
        '${want && pictures == 0 && !canGen ? ' Hinweis für den Nutzer: Für Bilder fehlt das Bildmodell (Systemcheck → Bilder erzeugen, SD-Turbo).' : ''}'
        '${_imagesHint(out, content)}';
  }
}

/// Zeichnet ein Diagramm und liefert PNG-Bytes (in der App über dart:ui).
typedef ChartRenderer = Future<Uint8List> Function(ChartSpec spec);

class ChartSpec {
  ChartSpec({required this.kind, required this.title, required this.labels, required this.series, this.unit = ''});
  final String kind; // bar | line | pie
  final String title;
  final List<String> labels;
  final List<({String name, List<double> values})> series;
  final String unit;
}

class CreateChartTool extends AgentTool {
  CreateChartTool(this.out, this.render);
  final OutputSpace out;
  final ChartRenderer render;

  @override
  String get name => 'create_chart';
  @override
  String get keywords => 'diagramm chart grafik balken linie torte kurve statistik werte';
  @override
  String get title => 'Diagramm erstellen';
  @override
  String get description =>
      'Zeichnet ein Diagramm als PNG-Bild (für Dokumente/Folien per ![](dateiname.png) nutzbar). '
      'values: Zahlen mit Komma getrennt; mehrere Reihen mit ";" trennen.';
  @override
  List<ToolParam> get params => const [
        ToolParam('kind', ParamType.enumeration, 'Diagrammart', values: ['bar', 'line', 'pie']),
        ToolParam('title', ParamType.string, 'Titel'),
        ToolParam('labels', ParamType.string, 'Beschriftungen, z. B. "Jan, Feb, Mär"'),
        ToolParam('values', ParamType.string, 'Werte, z. B. "12, 15, 9" oder "1,2,3; 4,5,6"'),
        ToolParam('series', ParamType.string, 'Namen der Reihen, mit ";" getrennt (optional)'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final title = (args['title'] ?? 'Diagramm').toString().trim();
    final labels = (args['labels'] ?? '').toString().split(RegExp(r'[,;\n]')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    final rows = (args['values'] ?? '').toString().split(';');
    final names = (args['series'] ?? '').toString().split(';').map((s) => s.trim()).toList();
    final series = <({String name, List<double> values})>[];
    for (var i = 0; i < rows.length; i++) {
      final vals = rows[i]
          .split(RegExp(r'[,\s]+'))
          .map((s) => double.tryParse(s.trim().replaceAll(RegExp(r'[^\d.\-]'), '')))
          .whereType<double>()
          .toList();
      if (vals.isNotEmpty) series.add((name: i < names.length && names[i].isNotEmpty ? names[i] : 'Reihe ${i + 1}', values: vals));
    }
    if (series.isEmpty) throw ToolException('values enthält keine Zahlen');
    final n = series.map((s) => s.values.length).reduce((a, b) => a > b ? a : b);
    while (labels.length < n) {
      labels.add('${labels.length + 1}');
    }
    final kind = (args['kind'] ?? 'bar').toString();
    final png = await render(ChartSpec(kind: kind, title: title, labels: labels.take(n).toList(), series: series));
    final f = out.fileFor(title, 'png');
    await f.writeAsBytes(png);
    _artifact(ctx, f, 'image');
    final name = f.uri.pathSegments.last;
    return 'Diagramm gespeichert als "$name". In Dokumenten/Folien einbinden mit ![${title.replaceAll(']', '')}]($name).';
  }
}

/// Erzeugt ein Bild zum Prompt und liefert den Dateipfad (App kümmert sich um Modell/Fortschritt).
typedef ImageGenerator = Future<String> Function(String prompt, String format, String negative);

class GenerateImageTool extends AgentTool {
  GenerateImageTool(this.generate);
  final ImageGenerator generate;

  @override
  Duration? get timeout => const Duration(minutes: 8);

  @override
  String get name => 'generate_image';
  @override
  String get keywords => 'bild bilder foto illustration malen male zeichne erzeuge logo';
  @override
  String get title => 'Bild generieren';
  @override
  String get description =>
      'Erzeugt ein Bild (Foto, Illustration) lokal mit Stable Diffusion. prompt auf ENGLISCH, '
      'konkret beschreiben (Motiv, Stil, Licht). Dauert am Handy 1–3 Minuten.';
  @override
  List<ToolParam> get params => const [
        ToolParam('prompt', ParamType.string, 'Bildbeschreibung auf Englisch'),
        ToolParam('format', ParamType.enumeration, 'Seitenverhältnis', values: ['square', 'landscape', 'portrait']),
        ToolParam('avoid', ParamType.string, 'Was nicht im Bild sein soll (Englisch, optional)'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final prompt = (args['prompt'] ?? '').toString().trim();
    if (prompt.isEmpty) throw ToolException('prompt ist leer');
    final path = await generate(prompt, (args['format'] ?? 'square').toString(), (args['avoid'] ?? '').toString());
    final f = File(path);
    ctx.generatedImages.add(f.path);
    _artifact(ctx, f, 'image');
    final name = f.uri.pathSegments.last;
    return 'Bild gespeichert als "$name" (der Nutzer sieht es im Chat). In Dokumenten/Folien einbinden mit ![]($name).';
  }
}

/// Beantwortet eine Frage zu einem Bild (Bildverständnis des Sprachmodells).
typedef ImageQuestion = Future<String> Function(String imageName, String question);

class LookAtImageTool extends AgentTool {
  LookAtImageTool(this.ask);
  final ImageQuestion ask;

  @override
  String get name => 'look_at_image';
  @override
  String get keywords => 'bild foto screenshot anhang scan sieh schau erkenne';
  @override
  String get title => 'Bild ansehen';
  @override
  String get description => 'Schaut sich ein angehängtes Bild an und beantwortet eine Frage dazu (Inhalt, Text im Bild, Details).';
  @override
  List<ToolParam> get params => const [
        ToolParam('name', ParamType.string, 'Dateiname des Bildes'),
        ToolParam('question', ParamType.string, 'Was soll im Bild nachgesehen werden?'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final name = (args['name'] ?? '').toString().trim();
    final q = (args['question'] ?? '').toString().trim();
    return ask(name, q.isEmpty ? 'Beschreibe das Bild genau.' : q);
  }
}


/// Quelle einer erzeugten Datei (Markdown + Design), damit sie später gezielt geändert werden kann.
/// Liegt unsichtbar neben der Datei: „.Name.pptx.junels.json“.
class FileSource {
  FileSource(
      {required this.file,
      required this.type,
      required this.title,
      required this.content,
      required this.design,
      this.agenda = false,
      this.templatePath});
  final File file;
  final String type; // pptx | pdf | docx | xlsx | raw-docx | raw-xlsx (fremde Datei, direkt geändert)
  String title;
  String content;
  final SlideDesign design;
  final bool agenda;
  final String? templatePath;

  static File _meta(File f) => File('${f.parent.path}/.${f.uri.pathSegments.last}.junels.json');

  static Future<void> save(File f,
      {required String type,
      required String title,
      required String content,
      required SlideDesign design,
      bool agenda = false,
      Uint8List? templateBytes}) async {
    String? tpl;
    if (templateBytes != null) {
      final t = File('${f.parent.path}/.${f.uri.pathSegments.last}.vorlage.pptx');
      await t.writeAsBytes(templateBytes);
      tpl = t.path;
    }
    await _meta(f).writeAsString(jsonEncode({
      'type': type,
      'title': title,
      'content': content,
      'design': design.toJson(),
      if (agenda) 'agenda': true,
      if (tpl != null) 'template': tpl,
    }));
  }

  static FileSource? load(File f) {
    final m = _meta(f);
    if (!m.existsSync()) return null;
    try {
      final j = jsonDecode(m.readAsStringSync()) as Map<String, dynamic>;
      return FileSource(
        file: f,
        type: j['type'] as String? ?? 'pdf',
        title: j['title'] as String? ?? '',
        content: j['content'] as String? ?? '',
        design: SlideDesign.fromJson((j['design'] as Map?)?.cast<String, dynamic>() ?? const {}),
        agenda: j['agenda'] as bool? ?? false,
        templatePath: j['template'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Erzeugte Dateien mit Quelle, neueste zuerst.
  static List<File> editable(Directory dir) {
    if (!dir.existsSync()) return const [];
    final list = [
      for (final e in dir.listSync())
        if (e is File && !e.uri.pathSegments.last.startsWith('.') && RegExp(r'\.(pptx|pdf|docx|xlsx)$').hasMatch(e.path) && _meta(e).existsSync()) e
    ];
    // PDF neben einer PPTX gehört zur Präsentation
    list.removeWhere((f) => f.path.endsWith('.pdf') && File(f.path.replaceFirst(RegExp(r'\.pdf$'), '.pptx')).existsSync() && !FileSource._isDoc(f));
    list.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return list;
  }

  static bool _isDoc(File f) => load(f)?.type == 'pdf';

  /// Markdown in Teile: Präsentation → Folien („# “), Dokument → Abschnitte („# “ oder „## “).
  static (String, List<String>) parts(String md, {required bool slides}) {
    final head = slides ? RegExp(r'^#\s') : RegExp(r'^#{1,2}\s');
    final pre = StringBuffer();
    final out = <StringBuffer>[];
    var code = false;
    for (final line in md.split('\n')) {
      if (line.trimLeft().startsWith('```')) code = !code;
      if (!code && head.hasMatch(line)) out.add(StringBuffer());
      (out.isEmpty ? pre : out.last).writeln(line);
    }
    return (pre.toString().trim(), [for (final b in out) b.toString().trim()]);
  }

  static String join(String pre, List<String> parts) => [if (pre.trim().isNotEmpty) pre.trim(), ...parts].join('\n\n');
}

/// Einzelne Folien, Abschnitte oder Zellen einer Datei ändern, statt alles neu zu machen.
/// Präsentationen, PDF- und Word-Dokumente von Junels über ihren Markdown; fremde Word-/Excel-Dateien
/// (Anhänge) direkt im Dateiformat – deren Layout bleibt erhalten, geändert wird eine Kopie.
class EditFileTool extends AgentTool {
  EditFileTool(this.out);
  final OutputSpace out;

  @override
  Duration? get timeout => const Duration(minutes: 10);
  @override
  String get name => 'edit_file';
  @override
  String get title => 'Datei gezielt ändern';
  @override
  String get keywords => 'folie abschnitt überarbeiten ändern ersetzen einfügen löschen präsentation dokument korrigieren word excel zelle zeile blatt';
  @override
  String get description =>
      'Ändert eine erstellte oder angehängte Datei gezielt: Präsentation, PDF, Word (.docx) oder Excel (.xlsx). '
      'Erst aktion "anzeigen" (Übersicht; mit folie/abschnitt den Inhalt lesen). Dann "ersetzen", "einfuegen" (danach) oder "loeschen". '
      'Präsentation: folie = Nummer (1 = Titelfolie). Dokument/Word: abschnitt = Nummer oder Überschrift; suchen + inhalt ersetzt Text. '
      'Excel: abschnitt = Blattname; zellen = "B3=42; C3==SUMME(B1:B2)" setzt Zellen, inhalt = Tabelle/CSV hängt Zeilen an (einfuegen) '
      'oder ersetzt das Blatt (ersetzen); einfuegen mit neuem Blattnamen legt ein Blatt an. datei: leer = zuletzt erstellt.';
  @override
  List<ToolParam> get params => const [
        ToolParam('aktion', ParamType.enumeration, 'Was tun', values: ['anzeigen', 'ersetzen', 'einfuegen', 'loeschen']),
        ToolParam('datei', ParamType.string, 'Dateiname ("" = zuletzt erstellt)'),
        ToolParam('folie', ParamType.integer, 'Foliennummer der Präsentation (1 = Titelfolie, 0 = keine)'),
        ToolParam('abschnitt', ParamType.string, 'Abschnitt (Nummer/Überschrift) oder Excel-Blatt ("" = keiner)'),
        ToolParam('inhalt', ParamType.string, 'Neuer Inhalt in Markdown, Excel: Tabelle/CSV ("" bei anzeigen/loeschen)'),
        ToolParam('suchen', ParamType.string, 'Word/Dokument: Text, der durch inhalt ersetzt wird ("" = keiner)'),
        ToolParam('zellen', ParamType.string, 'Excel: Zellen setzen, z. B. "B3=42; C3==SUMME(B1:B2)" ("" = keine)'),
      ];

  static final _ext = RegExp(r'\.(pptx|pdf|docx|xlsx)$', caseSensitive: false);

  /// Datei finden: erstellte Dateien, sonst angehängte Word/Excel (→ Kopie zum Bearbeiten)
  Future<File?> _find(String name) async {
    final files = FileSource.editable(out.dir);
    final n = name.trim().toLowerCase();
    if (n.isEmpty) return files.firstOrNull;
    final hit = files.where((f) => f.path.split(Platform.pathSeparator).last.toLowerCase() == n).firstOrNull ??
        files.where((f) => f.path.split(Platform.pathSeparator).last.toLowerCase().contains(n.replaceAll(_ext, ''))).firstOrNull;
    if (hit != null) return hit;
    final att = out.attachedFiles?.call() ?? const {};
    final key = att.keys.where((k) => k.toLowerCase() == n).firstOrNull ??
        att.keys.where((k) => k.toLowerCase().contains(n.replaceAll(_ext, ''))).firstOrNull;
    if (key == null) return null;
    final ext = key.split('.').last.toLowerCase();
    if (ext != 'docx' && ext != 'xlsx') return null;
    final copy = out.fileFor('${key.substring(0, key.length - ext.length - 1)} (bearbeitet)', ext);
    await File(att[key]!).copy(copy.path);
    await FileSource.save(copy, type: 'raw-$ext', title: key, content: '', design: designById('klar'));
    return copy;
  }

  /// „B3=42; C3==SUMME(B1;B2)“ → {B3: 42, C3: =SUMME(B1;B2)} (Semikolon in Formeln bleibt erhalten)
  static Map<String, String> parseCells(String text) {
    final out = <String, String>{};
    for (final part in text.split(RegExp(r'\n|;\s*(?=[A-Za-z]{1,3}\d+\s*[:=])'))) {
      final m = RegExp(r'^\s*([A-Za-z]{1,3}\d+)\s*[:=]\s?(.*)$', dotAll: true).firstMatch(part);
      if (m != null) out[m.group(1)!.toUpperCase()] = m.group(2)!.trim();
    }
    return out;
  }

  static List<List<String>> _rows(String inhalt) {
    final sheets = sheetsFromMarkdown(inhalt);
    return sheets.isEmpty ? [] : sheets.first.rows;
  }

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final f = await _find((args['datei'] ?? '').toString());
    if (f == null) {
      throw ToolException('Keine änderbare Datei gefunden. Ändern lassen sich hier erstellte Präsentationen, PDFs, Word- und Excel-Dateien '
          'sowie angehängte Word-/Excel-Dateien.');
    }
    final src = FileSource.load(f)!;
    final action = (args['aktion'] ?? 'anzeigen').toString();
    final inhalt = (args['inhalt'] ?? '').toString().trim();
    final suchen = (args['suchen'] ?? '').toString();
    final zellen = (args['zellen'] ?? '').toString().trim();
    final abschnitt = (args['abschnitt'] ?? '').toString().trim();
    final name = f.path.split(Platform.pathSeparator).last;
    switch (src.type) {
      case 'xlsx' || 'raw-xlsx':
        return _excel(f, name, action, abschnitt, inhalt, zellen, ctx);
      case 'raw-docx':
        return _word(f, name, action, abschnitt, inhalt, suchen, ctx);
    }
    // Text ersetzen in Junels-Dokumenten
    if (suchen.isNotEmpty) {
      if (!src.content.contains(suchen)) throw ToolException('„$suchen“ kommt in $name nicht vor.');
      final n = suchen.allMatches(src.content).length;
      await _rebuild(f, src, src.title, src.content.replaceAll(suchen, inhalt), ctx);
      ctx.answerNow = true;
      return '$name: „$suchen“ $n× ersetzt.';
    }
    final deck = src.type == 'pptx';
    final (pre, parts) = FileSource.parts(src.content, slides: deck);
    String headOf(String p) => p.split('\n').first.replaceFirst(RegExp(r'^#+\s*'), '').trim();

    // Nummer → Index in parts (Präsentation: 1 = Titel, ggf. 2 = Route)
    final offset = deck ? (src.agenda && parts.length >= 3 ? 2 : 1) : 0;
    int? index; // -1 = Titelfolie
    final folie = int.tryParse('${args['folie'] ?? 0}') ?? 0;
    if (deck && folie > 0) {
      final n = folie;
      if (n == 1) {
        index = -1;
      } else if (offset == 2 && n == 2) {
        throw ToolException('Folie 2 ist die automatische Reiseroute – sie entsteht aus den Folientiteln. Ändere die Titel der anderen Folien.');
      } else {
        index = n - 1 - offset;
      }
    } else if (!deck && abschnitt.isNotEmpty) {
      final n = int.tryParse(abschnitt);
      index = n != null ? n - 1 : parts.indexWhere((p) => headOf(p).toLowerCase().contains(abschnitt.toLowerCase()));
    }
    if (index != null && index != -1 && (index < 0 || index >= parts.length)) {
      throw ToolException('${deck ? 'Folie' : 'Abschnitt'} gibt es nicht. ${_overview(deck, src, parts, offset)}');
    }

    if (action == 'anzeigen') {
      if (index == null) return '$name – ${_overview(deck, src, parts, offset)}';
      if (index == -1) return 'Folie 1 (Titelfolie):\n# ${src.title}\n$pre';
      return '${deck ? 'Folie ${index + 1 + offset}' : 'Abschnitt ${index + 1}'} von $name:\n\n${parts[index]}';
    }
    // Dokument ohne Abschnittsangabe: einfuegen = ans Ende
    if (index == null && !deck && action == 'einfuegen' && inhalt.isNotEmpty) index = parts.isEmpty ? null : parts.length - 1;
    if (index == null && !deck && action == 'einfuegen' && inhalt.isNotEmpty) {
      await _rebuild(f, src, src.title, FileSource.join(pre, [inhalt]), ctx);
      ctx.answerNow = true;
      return '$name: Inhalt angefügt.';
    }
    if (index == null) throw ToolException('Bitte ${deck ? 'folie' : 'abschnitt'} angeben. ${_overview(deck, src, parts, offset)}');

    var newPre = pre;
    var newTitle = src.title;
    String done;
    if (index == -1) {
      if (action != 'ersetzen') throw ToolException('Die Titelfolie kann nur ersetzt werden.');
      final lines = inhalt.split('\n');
      if (lines.first.startsWith('#')) {
        newTitle = lines.first.replaceFirst(RegExp(r'^#+\s*'), '').trim();
        newPre = lines.skip(1).join('\n').trim();
      } else {
        newPre = inhalt;
      }
      done = 'Titelfolie geändert';
    } else {
      String fix(String md) {
        if (md.isEmpty) throw ToolException('inhalt fehlt.');
        final h = deck ? '# ' : '## ';
        return md.startsWith('#') ? md : '$h${headOf(parts[index!])}\n$md';
      }
      switch (action) {
        case 'ersetzen':
          parts[index] = fix(inhalt);
          done = '${deck ? 'Folie ${index + 1 + offset}' : 'Abschnitt ${index + 1}'} ersetzt';
        case 'einfuegen':
          parts.insert(index + 1, fix(inhalt));
          done = 'neue ${deck ? 'Folie ${index + 2 + offset}' : 'Abschnitt ${index + 2}'} eingefügt';
        case 'loeschen':
          if (parts.length <= 1) throw ToolException('Die letzte ${deck ? 'Folie' : 'Abschnitt'} kann nicht gelöscht werden.');
          parts.removeAt(index);
          done = '${deck ? 'Folie ${index + 1 + offset}' : 'Abschnitt ${index + 1}'} gelöscht';
        default:
          throw ToolException('Unbekannte aktion "$action".');
      }
    }
    final made = await _rebuild(f, src, newTitle, FileSource.join(newPre, parts), ctx);
    ctx.answerNow = true;
    return '$name: $done. Design und übrige ${deck ? 'Folien' : 'Abschnitte'} unverändert.${made > 0 ? ' $made Bild(er) neu erzeugt.' : ''}';
  }

  /// Junels-Datei aus geändertem Markdown neu erzeugen → Anzahl neuer Bilder
  Future<int> _rebuild(File f, FileSource src, String newTitle, String content0, ToolContext ctx) async {
    final (content, made) = await autoImages(out, content0, ctx);
    switch (src.type) {
      case 'pptx':
        final split = splitSlides(content);
        PptxTemplate? tpl;
        if (src.templatePath != null && File(src.templatePath!).existsSync()) {
          tpl = PptxTemplate.parse(File(src.templatePath!).readAsBytesSync());
        }
        await f.writeAsBytes(buildPptx(
            title: newTitle,
            subtitle: split.subtitle,
            slides: split.slides,
            resolveImage: out.resolveImage,
            design: src.design,
            template: tpl,
            agenda: src.agenda));
        final pdf = File(f.path.replaceFirst(RegExp(r'\.pptx$'), '.pdf'));
        await pdf.writeAsBytes(buildSlidesPdf(
            title: newTitle, subtitle: split.subtitle, slides: split.slides, resolveImage: out.resolveImage, theme: src.design.pdfTheme));
        await FileSource.save(f,
            type: 'pptx',
            title: newTitle,
            content: content,
            design: src.design,
            agenda: src.agenda,
            templateBytes: tpl == null ? null : File(src.templatePath!).readAsBytesSync());
        _artifact(ctx, f, 'pptx');
        _artifact(ctx, pdf, 'pdf');
      case 'docx':
        await f.writeAsBytes(buildDocx(title: newTitle, markdown: content, resolveImage: out.resolveImage, design: src.design));
        await FileSource.save(f, type: 'docx', title: newTitle, content: content, design: src.design);
        _artifact(ctx, f, 'docx');
      default:
        await f.writeAsBytes(buildPdfDocument(title: newTitle, markdown: content, resolveImage: out.resolveImage, theme: src.design.pdfTheme));
        await FileSource.save(f, type: 'pdf', title: newTitle, content: content, design: src.design);
        _artifact(ctx, f, 'pdf');
    }
    return made;
  }

  Future<String> _excel(File f, String name, String action, String abschnitt, String inhalt, String zellen, ToolContext ctx) async {
    final book = XlsxBook.open(await f.readAsBytes());
    String overview() => 'Blätter: ${[for (final (i, s) in book.sheets.indexed) '${i + 1}. ${s.$1}'].join(' · ')}';
    try {
      if (action == 'anzeigen') {
        return abschnitt.isEmpty && book.sheets.length > 1 ? '$name – ${overview()}\n\n${book.preview('')}' : '$name – ${book.preview(abschnitt)}';
      }
      String done;
      if (zellen.isNotEmpty) {
        final cells = parseCells(zellen);
        if (cells.isEmpty) throw ToolException('zellen nicht verstanden – Beispiel: "B3=42; C3==SUMME(B1:B2)"');
        if (action == 'loeschen') cells.updateAll((_, __) => '');
        book.setCells(abschnitt, cells);
        done = '${cells.length} Zelle(n) ${action == 'loeschen' ? 'geleert' : 'gesetzt'} (${cells.keys.take(8).join(', ')})';
      } else if (action == 'einfuegen') {
        final rows = _rows(inhalt);
        if (rows.isEmpty) throw ToolException('inhalt: Zeilen als Markdown-Tabelle oder CSV angeben.');
        final exists = abschnitt.isEmpty || book.sheets.any((s) => s.$1.toLowerCase() == abschnitt.toLowerCase()) || int.tryParse(abschnitt) != null;
        if (exists) {
          final at = book.appendRows(abschnitt, rows);
          done = '${rows.length} Zeile(n) ab Zeile $at angefügt';
        } else {
          final n = book.addSheet(abschnitt, rows);
          done = 'neues Blatt „$n“ mit ${rows.length} Zeilen';
        }
      } else if (action == 'ersetzen') {
        final rows = _rows(inhalt);
        if (rows.isEmpty) throw ToolException('inhalt: neue Tabelle angeben oder zellen nutzen.');
        book.replaceSheet(abschnitt, rows);
        done = 'Blatt ${abschnitt.isEmpty ? '1' : '„$abschnitt“'} ersetzt (${rows.length} Zeilen)';
      } else {
        throw ToolException('Zum Löschen zellen angeben (z. B. "B3=; B4="). ${overview()}');
      }
      await f.writeAsBytes(book.save());
      _artifact(ctx, f, 'xlsx');
      ctx.answerNow = true;
      return '$name: $done. Übrige Zellen und Formatierung unverändert; Formeln rechnet Excel beim Öffnen neu.';
    } on FormatException catch (e) {
      throw ToolException('${e.message} ${overview()}');
    }
  }

  Future<String> _word(File f, String name, String action, String abschnitt, String inhalt, String suchen, ToolContext ctx) async {
    final doc = DocxDocument.open(await f.readAsBytes());
    try {
      if (action == 'anzeigen') {
        if (abschnitt.isEmpty) {
          final all = doc.textOf(0, doc.elements.length);
          return '$name – ${doc.overview()}${all.length < 4000 ? '\n\n$all' : ''}';
        }
        final s = doc.section(abschnitt);
        return 'Abschnitt „${s.title}“ von $name:\n\n${doc.textOf(s.start, s.end)}';
      }
      String done;
      if (suchen.isNotEmpty) {
        final n = doc.replaceText(suchen, inhalt);
        if (n == 0) throw ToolException('„$suchen“ kommt in $name nicht vor (Text muss genau passen).');
        done = '„$suchen“ in $n Absatz/Absätzen ersetzt';
      } else {
        switch (action) {
          case 'ersetzen' || 'einfuegen':
            if (inhalt.isEmpty) throw ToolException('inhalt fehlt.');
            final news = doc.fromMarkdown(inhalt, resolveImage: out.resolveImage);
            if (abschnitt.isEmpty) {
              if (action == 'ersetzen') throw ToolException('Bitte abschnitt angeben (oder suchen nutzen). ${doc.overview()}');
              doc.elements.addAll(news);
              done = 'Inhalt am Ende angefügt';
            } else {
              final s = doc.section(abschnitt);
              if (action == 'einfuegen') {
                doc.elements.insertAll(s.end, news);
                done = 'nach „${s.title}“ eingefügt';
              } else {
                // eigene Überschrift im inhalt ersetzt auch die alte, sonst bleibt sie
                final keepHead = !inhalt.trimLeft().startsWith('#');
                doc.elements.replaceRange(keepHead ? s.start + 1 : s.start, s.end, news);
                done = 'Abschnitt „${s.title}“ ersetzt';
              }
            }
          case 'loeschen':
            if (abschnitt.isEmpty) throw ToolException('Bitte abschnitt angeben. ${doc.overview()}');
            final s = doc.section(abschnitt);
            doc.elements.removeRange(s.start, s.end);
            done = 'Abschnitt „${s.title}“ gelöscht';
          default:
            throw ToolException('Unbekannte aktion "$action".');
        }
      }
      await f.writeAsBytes(doc.save());
      _artifact(ctx, f, 'docx');
      ctx.answerNow = true;
      return '$name: $done. Übriges Dokument und Formatierung unverändert.';
    } on FormatException catch (e) {
      throw ToolException(e.message);
    }
  }

  String _overview(bool deck, FileSource src, List<String> parts, int offset) {
    String headOf(String p) => p.split('\n').first.replaceFirst(RegExp(r'^#+\s*'), '').trim();
    if (!deck) return 'Abschnitte: ${[for (var i = 0; i < parts.length; i++) '${i + 1}. ${headOf(parts[i])}'].join(' · ')}';
    return 'Folien: 1. ${src.title} (Titel)${offset == 2 ? ' · 2. Reiseroute (automatisch)' : ''} · '
        '${[for (var i = 0; i < parts.length; i++) '${i + 1 + offset}. ${headOf(parts[i])}'].join(' · ')}';
  }
}
