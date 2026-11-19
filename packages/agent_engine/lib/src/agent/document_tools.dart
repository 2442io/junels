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
  OutputSpace(this.dir, {this.extraImages});

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
  String get name => 'create_document';
  @override
  String get title => 'PDF-Dokument erstellen';
  @override
  String get description =>
      'Erstellt ein PDF-Dokument (Bericht, Brief, Zusammenfassung) aus Markdown: # Überschriften, Listen, '
      'Tabellen, **fett**, Bilder mit ![Titel](dateiname.png).';
  @override
  List<ToolParam> get params => const [
        ToolParam('title', ParamType.string, 'Titel des Dokuments'),
        ToolParam('content', ParamType.string, 'Inhalt in Markdown'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final title = (args['title'] ?? '').toString().trim();
    final content = (args['content'] ?? '').toString();
    if (content.trim().isEmpty) throw ToolException('content ist leer');
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
  String get name => 'create_presentation';
  @override
  String get title => 'Präsentation erstellen';
  @override
  String get description =>
      'Erstellt eine Präsentation (PowerPoint .pptx und PDF). content in Markdown: jede "# Überschrift" '
      'beginnt eine Folie, darunter 3–6 kurze Stichpunkte mit "- ", optional ein Bild ![](name.png) oder eine Tabelle.';
  @override
  List<ToolParam> get params => const [
        ToolParam('title', ParamType.string, 'Titel der Präsentation'),
        ToolParam('content', ParamType.string, 'Folien in Markdown'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final title = (args['title'] ?? '').toString().trim().isEmpty ? 'Präsentation' : args['title'].toString().trim();
    final content = (args['content'] ?? '').toString();
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
    return 'Präsentation mit ${split.slides.length + 1} Folien erstellt: ${f1.uri.pathSegments.last} '
        '(PowerPoint) und ${f2.uri.pathSegments.last} (PDF).${_imagesHint(out, content)}';
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
  String get name => 'generate_image';
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
