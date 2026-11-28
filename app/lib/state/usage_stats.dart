// Auswertung der Nutzung (auf dem Gerät berechnet): Chats, Themen, Funktionen, Tokens,
// Nutzungszeit und geschätzte Zeitersparnis. Für die Seite „Auswertung“ und – nur als Zahlen,
// ohne Inhalte – für den Admin-Bereich der Agent-API.

import 'dart:math' as math;

import 'app_controller.dart';

/// Themengebiete (Stichwörter in den eigenen Nachrichten)
const _topics = <String, String>{
  'Arbeit & Büro': r'meeting|besprechung|protokoll|kunde|projekt|präsentation|angebot|rechnung|bericht|mail an|e-mail|team|chef|kolleg|termin|aufgabe|strategie|konzept',
  'Recherche & Wissen': r'was ist|wie funktioniert|erklär|warum|unterschied|zusammenfass|quelle|studie|recherch|news|nachrichten|wikipedia',
  'Einkaufen & Preise': r'preis|kaufen|günstig|angebot|amazon|geizhals|willhaben|shop|bestell|vergleich|€|euro|rabatt|black friday',
  'Reisen & Mobilität': r'reise|urlaub|flug|hotel|zug|öbb|bahn|ticket|route|wetter|ski|strand|städtetrip',
  'Technik & IT': r'code|python|php|javascript|server|app|computer|mac|android|software|fehler|bug|api|ki\b|modell|llm|website|datenbank',
  'Finanzen & Verträge': r'steuer|finanz|konto|bank|versicherung|vertrag|kündig|miete|kredit|budget|ausgaben',
  'Gesundheit & Sport': r'arzt|gesund|sport|training|laufen|fitness|ernährung|schlaf|apotheke',
  'Essen & Kochen': r'rezept|kochen|essen|restaurant|backen|zutaten|abendessen|frühstück',
  'Behörden & Formulare': r'antrag|formular|behörde|amt|oesterreich\.gv|wien\.gv|finanzonline|meldezettel|pass|bürgerservice',
  'Freizeit & Kultur': r'film|serie|musik|spotify|buch|konzert|spiel|museum|theater|ausflug|wochenende',
  'Schreiben & Texte': r'schreib|formulier|text|brief|post|linkedin|übersetz|korrigier|umformulier',
};

/// Werkzeug → Funktion (für „Funktionen“)
String featureOf(String tool) {
  final t = tool.toLowerCase();
  if (t.contains('search') || t == 'fetch_url' || t == 'read_page' || t == 'news' || t == 'wikipedia') return 'Web-Recherche';
  if (t.startsWith('browse') || t.startsWith('browser') || t.contains('web_job') || t == 'click' || t == 'fill_form') return 'Browser & Web-Jobs';
  if (t.contains('word') || t == 'create_document') return 'Word & Dokumente';
  if (t.contains('presentation') || t.contains('pptx')) return 'Präsentationen';
  if (t.contains('excel') || t.contains('xlsx') || t.contains('table')) return 'Excel & Tabellen';
  if (t.contains('pdf')) return 'PDF';
  if (t.contains('image')) return 'Bilder';
  if (t.contains('chart')) return 'Diagramme';
  if (t.contains('calendar') || t.contains('mail')) return 'Kalender & Mail';
  if (t.contains('weather')) return 'Wetter';
  if (t.contains('remember') || t.contains('memory') || t.contains('knowledge')) return 'Gedächtnis & Wissen';
  if (t.contains('app') || t.contains('mcp')) return 'Apps & MCP';
  if (t.contains('file') || t.contains('read_')) return 'Dateien';
  return 'Weitere Werkzeuge';
}

/// Geschätzte Minuten, die eine Antwort mit diesem Werkzeug von Hand dauern würde
const _savedMin = <String, double>{
  'Web-Recherche': 8,
  'Browser & Web-Jobs': 15,
  'Word & Dokumente': 25,
  'Präsentationen': 40,
  'Excel & Tabellen': 20,
  'PDF': 10,
  'Bilder': 10,
  'Diagramme': 10,
  'Kalender & Mail': 4,
  'Wetter': 1,
  'Gedächtnis & Wissen': 1,
  'Apps & MCP': 3,
  'Dateien': 5,
  'Weitere Werkzeuge': 3,
};

class UsageStats {
  UsageStats._();

  int chats = 0;
  int messages = 0; // eigene Nachrichten
  int answers = 0;
  int activeDays = 0;
  double usageHours = 0; // Zeit in Sitzungen (geschätzt aus den Zeitstempeln)
  double agentHours = 0; // Rechenzeit der KI
  int tokens = 0;
  double savedHours = 0;
  int docs = 0;
  int voice = 0;
  int transcripts = 0;
  int automations = 0;
  int local = 0;
  int cloud = 0;
  DateTime? first;
  final weeks = <String, (int, double)>{}; // ISO-Woche → (Nachrichten, gesparte Stunden)
  final hours = List<int>.filled(24, 0); // Nachrichten je Tageszeit
  final topics = <String, int>{};
  final features = <String, int>{};
  final skills = <String, int>{};
  final savedBy = <String, double>{};

  static String isoWeek(DateTime d) {
    final day = DateTime.utc(d.year, d.month, d.day);
    final thursday = day.add(Duration(days: 4 - (day.weekday)));
    final week = 1 + (thursday.difference(DateTime.utc(thursday.year, 1, 1)).inDays ~/ 7);
    return '${thursday.year}-W${week.toString().padLeft(2, '0')}';
  }

  static UsageStats compute(AppController app) {
    final s = UsageStats._();
    final days = <String>{};
    final times = <DateTime>[];
    void save(String what, double min, DateTime at) {
      s.savedHours += min / 60;
      s.savedBy[what] = (s.savedBy[what] ?? 0) + min / 60;
      final w = isoWeek(at);
      final o = s.weeks[w] ?? (0, 0.0);
      s.weeks[w] = (o.$1, o.$2 + min / 60);
    }

    final topicRe = {for (final e in _topics.entries) e.key: RegExp(e.value, caseSensitive: false)};
    for (final c in [...app.conversations, app.feed]) {
      if (c.entries.isEmpty) continue;
      if (!identical(c, app.feed)) s.chats++;
      for (final e in c.entries) {
        final at = e.time;
        if (s.first == null || at.isBefore(s.first!)) s.first = at;
        if (e.role == 'user') {
          if (e.origin != null) continue; // automatisch erzeugt
          s.messages++;
          times.add(at);
          days.add('${at.year}-${at.month}-${at.day}');
          s.hours[at.hour]++;
          final w = isoWeek(at);
          final o = s.weeks[w] ?? (0, 0.0);
          s.weeks[w] = (o.$1 + 1, o.$2);
          if (e.viaVoice) s.voice++;
          var hit = false;
          for (final t in topicRe.entries) {
            if (t.value.hasMatch(e.text)) {
              s.topics[t.key] = (s.topics[t.key] ?? 0) + 1;
              hit = true;
            }
          }
          if (!hit && e.text.trim().isNotEmpty) s.topics['Sonstiges'] = (s.topics['Sonstiges'] ?? 0) + 1;
          continue;
        }
        // Antworten
        if (e.text.isEmpty && e.error != null) continue;
        s.answers++;
        if (e.origin != null) s.automations++;
        final ms = e.durationMs ?? 0;
        s.agentHours += ms / 3600000;
        final tps = e.tokensPerSecond ?? 0;
        if (tps > 0 && ms > 0) s.tokens += (ms / 1000 * tps).round();
        final via = (e.via ?? '').toLowerCase();
        if (via.contains('lokal') || via.contains('gerät')) {
          s.local++;
        } else if (via.isNotEmpty) {
          s.cloud++;
        }
        if (e.skill != null && e.skill!.isNotEmpty) s.skills[e.skill!] = (s.skills[e.skill!] ?? 0) + 1;
        final used = <String>{for (final st in e.steps) if ((st.tool ?? '').isNotEmpty) featureOf(st.tool!)};
        if (e.view != null && e.view != 'text') used.add('Darstellung (Karten, Tabellen …)');
        if (e.skill == 'Mitschrift') {
          s.transcripts++;
          used.add('Mitschrift');
          // Protokoll von Hand: etwa die doppelte Gesprächsdauer
          final m = RegExp(r'· (?:(\d+):)?(\d{2}):(\d{2}) ·').firstMatch(e.text);
          if (m != null) {
            final min = (int.tryParse(m.group(1) ?? '0') ?? 0) * 60 + int.parse(m.group(2)!) + int.parse(m.group(3)!) / 60;
            save('Mitschrift', min * 1.5, at);
          }
        }
        for (final f in used) {
          s.features[f] = (s.features[f] ?? 0) + 1;
          final m = _savedMin[f];
          if (m != null) save(f, m, at);
        }
        s.docs += e.files.where((f) => RegExp(r'\.(docx|pptx|xlsx|pdf)$', caseSensitive: false).hasMatch(f)).length;
        if (used.isEmpty) save('Antworten & Texte', 2, at); // einfache Antwort: ein paar Minuten Suchen/Schreiben
      }
    }
    // Geplante Abläufe und externe Aufrufe
    for (final r in app.runStats.records) {
      s.tokens += r.tokensIn + r.tokensOut;
      if (r.ok) save('Automatisierungen', 5, r.start);
    }
    s.automations += app.runStats.records.length;
    s.features['Automatisierungen'] = (s.features['Automatisierungen'] ?? 0) + app.runStats.records.length;
    if (s.voice > 0) s.features['Sprechen'] = s.voice;

    // Nutzungszeit: Sitzungen aus den Zeitstempeln (Lücke > 30 min = neue Sitzung)
    times.sort();
    DateTime? start, last;
    for (final t in times) {
      if (last == null || t.difference(last).inMinutes > 30) {
        if (start != null) s.usageHours += last!.difference(start).inSeconds / 3600 + 2 / 60;
        start = t;
      }
      last = t;
    }
    if (start != null) s.usageHours += last!.difference(start).inSeconds / 3600 + 2 / 60;
    s.activeDays = days.length;
    return s;
  }

  List<MapEntry<String, num>> _top(Map<String, num> m, int n) => (m.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(n).toList();

  /// Letzte 12 Wochen (auch leere), älteste zuerst
  List<(String, int, double)> get lastWeeks {
    final out = <(String, int, double)>[];
    final now = DateTime.now();
    for (var i = 11; i >= 0; i--) {
      final w = isoWeek(now.subtract(Duration(days: 7 * i)));
      final v = weeks[w] ?? (0, 0.0);
      out.add((w, v.$1, v.$2));
    }
    return out;
  }

  List<MapEntry<String, num>> get topTopics => _top(topics, 8);
  List<MapEntry<String, num>> get topFeatures => _top(features, 10);
  List<MapEntry<String, num>> get topSaved => _top(savedBy, 8);
  List<MapEntry<String, num>> get topSkills => _top(skills, 6);

  /// Nur Zahlen und Kategorien – keine Inhalte, keine Chat-Titel.
  Map<String, Object?> toJson({String device = ''}) {
    double r1(double v) => (v * 10).round() / 10;
    return {
      'v': 1,
      'generated': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      if (device.isNotEmpty) 'device': device,
      'since': first == null ? 0 : first!.millisecondsSinceEpoch ~/ 1000,
      'kpi': {
        'chats': chats,
        'messages': messages,
        'answers': answers,
        'activeDays': activeDays,
        'usageHours': r1(usageHours),
        'agentHours': r1(agentHours),
        'tokens': tokens,
        'savedHours': r1(savedHours),
        'docs': docs,
        'voice': voice,
        'transcripts': transcripts,
        'automations': automations,
        'local': local,
        'cloud': cloud,
      },
      'weeks': [for (final w in lastWeeks) {'w': w.$1, 'm': w.$2, 's': r1(w.$3)}],
      'hours': hours,
      'topics': [for (final e in topTopics) {'n': e.key, 'v': e.value}],
      'features': [for (final e in topFeatures) {'n': e.key, 'v': e.value}],
      'saved': [for (final e in topSaved) {'n': e.key, 'v': r1(e.value.toDouble())}],
      'skills': [for (final e in topSkills) {'n': e.key, 'v': e.value}],
    };
  }

  static String fmtHours(double h) {
    if (h < 1) return '${math.max(0, (h * 60).round())} min';
    return '${h.toStringAsFixed(h < 10 ? 1 : 0).replaceAll('.', ',')} h';
  }

  static String fmtNum(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1).replaceAll('.', ',')} Mio.';
    if (n >= 10000) return '${(n / 1000).round()} Tsd.';
    final s = n.toString();
    return s.length > 3 ? '${s.substring(0, s.length - 3)}.${s.substring(s.length - 3)}' : s;
  }
}

