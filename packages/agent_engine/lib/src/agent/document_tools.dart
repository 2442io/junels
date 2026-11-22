// Werkzeuge zum Erstellen von Dateien: PDF-Dokumente, Präsentationen (PPTX + PDF),
// Diagramme und Bilder. Ergebnisse landen im Ausgabe-Ordner und als Artefakt im Chat.

import 'dart:io';
import 'dart:typed_data';

import '../documents/md_blocks.dart';
import '../documents/pdf_writer.dart';
import '../documents/pptx_writer.dart';
import 'tool.dart';

/// Gemeinsame Umgebung für die Datei-Werkzeuge.
class OutputSpace {
  OutputSpace(this.dir, {this.extraImages, this.imageGenerator, this.maxAutoImages = 3});

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
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final title = (args['title'] ?? '').toString().trim();
    if ((args['content'] ?? '').toString().trim().isEmpty) throw ToolException('content ist leer');
    final want = wantsImages(ctx.userRequest);
    final raw = placeImages((args['content'] ?? '').toString(),
        files: ctx.generatedImages, auto: want && out.imageGenerator?.call() != null, maxAuto: out.maxAutoImages, slides: false);
    final (content, _) = await autoImages(out, raw, ctx);
    final bytes = buildPdfDocument(title: title.isEmpty ? 'Dokument' : title, markdown: content, resolveImage: out.resolveImage);
    final f = out.fileFor(title.isEmpty ? 'Dokument' : title, 'pdf');
    await f.writeAsBytes(bytes);
    _artifact(ctx, f, 'pdf');
    return 'PDF erstellt: ${f.uri.pathSegments.last} (${(bytes.length / 1024).ceil()} KB). '
        'Der Nutzer sieht die Datei im Chat.${_imagesHint(out, content)}';
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
      'Vorher mit generate_image erzeugte Bilder kommen automatisch auf Folien ohne Bild.';
  @override
  List<ToolParam> get params => const [
        ToolParam('title', ParamType.string, 'Titel der Präsentation'),
        ToolParam('content', ParamType.string, 'Folien in Markdown'),
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
    final pptx = buildPptx(title: title, subtitle: split.subtitle, slides: split.slides, resolveImage: out.resolveImage);
    final pdf = buildSlidesPdf(title: title, subtitle: split.subtitle, slides: split.slides, resolveImage: out.resolveImage);
    final f1 = out.fileFor(title, 'pptx');
    await f1.writeAsBytes(pptx);
    final f2 = File(f1.path.replaceFirst(RegExp(r'\.pptx$'), '.pdf'));
    await f2.writeAsBytes(pdf);
    _artifact(ctx, f1, 'pptx');
    _artifact(ctx, f2, 'pdf');
    final pictures = RegExp(r'!\[[^\]]*\]\(([^)]+)\)').allMatches(content).where((m) => out.resolveImage(m.group(1)!) != null).length;
    return 'Präsentation mit ${split.slides.length + 1} Folien${pictures > 0 ? ' und $pictures Bildern' : ''} erstellt: ${f1.uri.pathSegments.last} '
        '(PowerPoint) und ${f2.uri.pathSegments.last} (PDF).${made > 0 ? ' $made Bilder wurden dafür neu erzeugt (mit KI-Kennzeichnung).' : ''}'
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
