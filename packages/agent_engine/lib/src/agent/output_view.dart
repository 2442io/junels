// Ausgabeformate: wie eine Antwort dargestellt wird – im Chat, in Skills, Abläufen und Beobachtungen.
// Darstellungen wie Karussell, Checkliste oder Ablauf baut die App aus den Werkzeug-Ergebnissen bzw. aus
// einfachem Markdown der Antwort. Das Modell muss dafür kein JSON schreiben – das klappt auch mit kleinen Modellen.

import '../documents/md_blocks.dart';

class OutputView {
  OutputView._();

  static const auto = '';
  static const text = 'text';
  static const cards = 'cards';
  static const table = 'table';
  static const list = 'list';
  static const steps = 'steps';
  static const chart = 'chart';
  static const pdf = 'pdf';
  static const word = 'word';
  static const excel = 'excel';
  static const pptx = 'pptx';

  /// Anzeige-Namen (Reihenfolge = Menü)
  static const labels = {
    auto: 'Automatisch',
    text: 'Text',
    cards: 'Karussell',
    table: 'Tabelle',
    list: 'Checkliste',
    steps: 'Ablauf',
    chart: 'Diagramm',
    pdf: 'PDF',
    word: 'Word',
    excel: 'Excel',
    pptx: 'PowerPoint',
  };

  static const hints = {
    auto: 'Junels wählt passend zur Antwort',
    text: 'Fließtext ohne Listen',
    cards: 'Wischbare Karten mit Bild, Preis, Link',
    table: 'Spalten und Zeilen zum Vergleichen',
    list: 'Punkte zum Abhaken',
    steps: 'Schritte nacheinander, als Zeitleiste',
    chart: 'Balken-, Linien- oder Tortendiagramm',
    pdf: 'Als PDF-Datei',
    word: 'Als Word-Dokument',
    excel: 'Als Excel-Tabelle',
    pptx: 'Als Präsentation',
  };

  static bool isFile(String v) => const {pdf, word, excel, pptx}.contains(v);
  static bool valid(String v) => labels.containsKey(v);

  /// Werkzeug, das für dieses Format ein Ergebnis liefern muss (Datei/Diagramm), sonst null
  static String? requiredTool(String v) => switch (v) {
        pdf => 'create_document',
        word => 'create_word',
        excel => 'create_excel',
        pptx => 'create_presentation',
        chart => 'create_chart',
        _ => null,
      };

  /// Format, das der Nutzer in der Nachricht selbst verlangt („… als Tabelle“), sonst null.
  /// Dateiformate erkennt schon das Routing (create_word usw.).
  static String? detect(String message) {
    final t = message.toLowerCase();
    if (RegExp(r'\b(als|in|im) (einer |ein |)?(tabelle|tabellenform|übersichtstabelle|vergleichstabelle)\b|tabellarisch').hasMatch(t) &&
        !RegExp(r'excel|xlsx').hasMatch(t)) {
      return table;
    }
    if (RegExp(r'\b(als|in|im) (einem |ein |)?(karussell|karten|kacheln)\b|zum durchwischen').hasMatch(t)) return cards;
    if (RegExp(r'\b(als|eine) (checkliste|to-?do-?liste|liste zum abhaken)\b|zum abhaken').hasMatch(t)) return list;
    if (RegExp(r'\b(als|in) (einem |einer |)?(ablauf|zeitleiste|zeitstrahl|timeline|workflow|schrittfolge)\b|schritt für schritt').hasMatch(t)) {
      return steps;
    }
    if (RegExp(r'\b(als|in) (fließtext|text)\b|ohne (liste|aufzählung|tabelle)').hasMatch(t)) return text;
    return null;
  }

  /// Anweisung an das Modell (an den Auftrag angehängt).
  static String instruction(String v) => switch (v) {
        text => '[AUSGABE: Antworte als zusammenhängender Text in kurzen Absätzen – ohne Tabellen und Aufzählungen.]',
        table => '[AUSGABE: Antworte mit einer Markdown-Tabelle (Kopfzeile, dann je Eintrag eine Zeile), davor höchstens ein Satz.]',
        cards => '[AUSGABE: Jedes Ergebnis als eigener Punkt: "- **Name** – Preis (falls bekannt) – ein kurzer Satz – Link". '
            'Nimm Links und Preise aus den Werkzeug-Ergebnissen, erfinde keine. Davor höchstens ein Satz, keine Tabelle.]',
        list => '[AUSGABE: Antworte als Checkliste – jede Zeile "- [ ] konkrete Aufgabe", kurz. Davor höchstens ein Satz.]',
        steps => '[AUSGABE: Antworte als Ablauf in der richtigen Reihenfolge – jede Zeile "1. **Schritt** – kurze Erklärung". '
            'Davor höchstens ein Satz.]',
        chart => '[AUSGABE: Zeige das Ergebnis als Diagramm – rufe create_chart auf und erkläre es danach in einem Satz.]',
        pdf || word || excel || pptx => '[AUSGABE: Liefere das Ergebnis als ${labels[v]}-Datei – rufe ${requiredTool(v)} auf, '
            'beschreibe die Datei nicht nur.]',
        _ => '',
      };
}

final _link = RegExp(r'https?://[^\s<>()\[\]]*[^\s<>()\[\].,;:!?"]');
final _price = RegExp(r'(?:€\s?\d[\d.,]*|\d[\d.,]*\s?(?:€|EUR|Euro|USD|\$))', caseSensitive: false);

/// Karten aus einer Antwort mit Aufzählung („- **Name** – 29,90 € – Satz – https://…“) oder Überschriften je Eintrag.
List<Map<String, String>> cardsFromText(String answer) {
  final out = <Map<String, String>>[];
  final lines = answer.split('\n');
  Map<String, String>? cur;
  void flush() {
    if (cur != null && (cur!['title'] ?? '').isNotEmpty) out.add(cur!);
    cur = null;
  }

  for (final raw in lines) {
    final line = raw.trimRight();
    final item = RegExp(r'^\s{0,3}(?:[-*•]|\d+[.)])\s+(?:\[[ xX]\]\s+)?(.+)$').firstMatch(line);
    final head = RegExp(r'^#{2,4}\s+(.+)$').firstMatch(line);
    if (item != null || head != null) {
      flush();
      var body = (item ?? head)!.group(1)!.trim();
      final mdLink = RegExp(r'\[([^\]]+)\]\((https?://[^)]+)\)').firstMatch(body);
      var link = mdLink?.group(2) ?? _link.firstMatch(body)?.group(0) ?? '';
      // Linktext ist nur dann Inhalt, wenn es keinen fetten Titel gibt („[Amazon](…)“ wäre sonst Rauschen)
      if (mdLink != null) body = body.replaceFirst(mdLink.group(0)!, body.contains('**') ? '' : mdLink.group(1)!);
      body = body.replaceAll(_link, '').replaceAll(RegExp(r'\s*\(\s*\)'), '');
      final price = _price.firstMatch(body)?.group(0) ?? '';
      // Titel: fetter Teil, sonst bis zum ersten Trenner
      final bold = RegExp(r'\*\*(.+?)\*\*').firstMatch(body)?.group(1);
      final parts = body.split(RegExp(r'\s+[–—-]\s+|:\s+|\s+\|\s+'));
      final title = plainInline(bold ?? parts.first).trim();
      var note = plainInline(body.replaceFirst(bold != null ? '**$bold**' : parts.first, ''))
          .replaceAll(price, '')
          .replaceAll(RegExp(r'^[\s–—:|,-]+|[\s–—:|,-]+$'), '')
          .replaceAll(RegExp(r'\s+[–—|]\s+[–—|]\s+'), ' – ')
          .trim();
      if (link.endsWith(')')) link = link.substring(0, link.length - 1);
      cur = {'title': title, if (link.isNotEmpty) 'link': link, if (price.isNotEmpty) 'price': price.trim(), if (note.isNotEmpty) 'note': note};
      continue;
    }
    // Folgezeilen eines Eintrags (eingerückt): Link/Preis/Text ergänzen
    if (cur != null && line.trim().isNotEmpty && (raw.startsWith('  ') || raw.startsWith('\t'))) {
      final l = _link.firstMatch(line)?.group(0);
      if (l != null && cur!['link'] == null) cur!['link'] = l;
      final p = _price.firstMatch(line)?.group(0);
      if (p != null && cur!['price'] == null) cur!['price'] = p.trim();
      final rest = plainInline(line.replaceAll(_link, '').trim()).replaceFirst(RegExp(r'^(Link|Preis|Bild):\s*', caseSensitive: false), '');
      if (rest.isNotEmpty && l == null && p == null) cur!['note'] = [cur!['note'], rest].whereType<String>().join(' ');
    } else if (line.trim().isEmpty) {
      // Leerzeile beendet keinen Eintrag mit Überschrift, aber eine Aufzählung schon
    } else if (cur != null && head == null) {
      flush();
    }
  }
  flush();
  return out.length >= 2 ? out : const [];
}

/// Text vor der ersten Aufzählung/Tabelle/Überschrift (Einleitung)
String introOf(String answer) {
  final lines = <String>[];
  for (final l in answer.split('\n')) {
    if (RegExp(r'^\s{0,3}([-*•]|\d+[.)])\s+|^\s*\||^#{1,4}\s').hasMatch(l)) break;
    lines.add(l);
  }
  return lines.join('\n').trim();
}

/// Text nach dem letzten Listenpunkt (Schluss), falls durch Leerzeile getrennt
String outroOf(String answer) {
  final blocks = answer.trim().split(RegExp(r'\n\s*\n'));
  if (blocks.length < 2) return '';
  final last = blocks.last.trim();
  return RegExp(r'^\s{0,3}([-*•]|\d+[.)])\s+|^\s*\||^#{1,4}\s', multiLine: true).hasMatch(last) ? '' : last;
}

/// Punkte einer Checkliste („- [ ] …“, „- …“, „1. …“)
List<String> checklistItems(String answer) => [
      for (final m in RegExp(r'^\s{0,3}(?:[-*•]|\d+[.)])\s+(?:\[[ xX]\]\s+)?(.+)$', multiLine: true).allMatches(answer))
        plainInline(m.group(1)!).trim(),
    ];

/// Schritte eines Ablaufs: (Titel, Erklärung)
List<(String, String)> stepsFrom(String answer) {
  final out = <(String, String)>[];
  for (final m in RegExp(r'^\s{0,3}(?:\d+[.)]|[-*•]|#{2,4})\s+(.+)$', multiLine: true).allMatches(answer)) {
    final body = m.group(1)!.trim();
    final bold = RegExp(r'^\*\*(.+?)\*\*[:\s–—-]*(.*)$').firstMatch(body);
    if (bold != null) {
      out.add((plainInline(bold.group(1)!).trim(), plainInline(bold.group(2)!).trim()));
      continue;
    }
    final split = RegExp(r'^(.{2,60}?)(?:\s+[–—-]\s+|:\s+)(.+)$').firstMatch(body);
    out.add(split != null ? (plainInline(split.group(1)!).trim(), plainInline(split.group(2)!).trim()) : (plainInline(body), ''));
  }
  return out;
}

/// Erste Markdown-Tabelle der Antwort (erste Zeile = Kopf), sonst null
List<List<String>>? tableFrom(String answer) {
  for (final b in parseMarkdown(answer)) {
    if (b is MdTable && b.rows.length >= 2) return [for (final r in b.rows) [for (final c in r) plainInline(c).trim()]];
  }
  return null;
}

/// Karten → Tabelle (für „als Tabelle“ bei Suchergebnissen)
List<List<String>> cardsToTable(List<Map<String, String>> cards) {
  final hasPrice = cards.any((c) => (c['price'] ?? '').isNotEmpty);
  final hasNote = cards.any((c) => (c['note'] ?? '').isNotEmpty);
  return [
    ['Name', if (hasPrice) 'Preis', if (hasNote) 'Info', 'Link'],
    for (final c in cards)
      [c['title'] ?? '', if (hasPrice) c['price'] ?? '', if (hasNote) c['note'] ?? '', c['link'] ?? ''],
  ];
}
