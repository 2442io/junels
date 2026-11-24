/// Agent-Test-Satz: typische Aufträge mit Erwartungen. Zwei Stufen:
/// 1. Auswahl (ohne Modell, in jedem Build): Bekommt das Modell die richtigen Werkzeuge?
/// 2. Live (mit echtem Modell, Test-Werkzeuge ohne Wirkung): Ruft es das richtige Werkzeug auf
///    und steht das Ergebnis in der Antwort?
library;

import 'dart:async';

import '../agent/agent_runner.dart';
import '../agent/tool.dart';
import '../llama_engine.dart';
import 'routing.dart';

class AgentCase {
  const AgentCase(
    this.id,
    this.area,
    this.prompt, {
    this.tools = const {},
    this.notTools = const {},
    this.required,
    this.hasFiles = false,
    this.hasDocs = false,
    this.call = const {},
    this.noCall = false,
    this.answerAny = const [],
    this.answerNot = const [],
  });

  final String id;
  final String area;
  final String prompt;

  /// Diese Werkzeuge muss die Auswahl anbieten
  final Set<String> tools;

  /// Diese Werkzeuge darf die Auswahl NICHT anbieten
  final Set<String> notTools;

  /// Pflicht-Werkzeug (Datei erstellen …); null = keins
  final String? required;
  final bool hasFiles;
  final bool hasDocs;

  /// Live: eines davon muss aufgerufen werden
  final Set<String> call;

  /// Live: gar kein Werkzeug aufrufen (direkt antworten)
  final bool noCall;

  /// Live: Antwort enthält mindestens eines davon (ohne Groß/Klein)
  final List<String> answerAny;

  /// Live: Antwort enthält keines davon
  final List<String> answerNot;
}

/// Der Test-Satz. Neue Fälle hier ergänzen – jeder Fall läuft in jedem Build (Auswahl)
/// und im Live-Test mit.
const agentCases = <AgentCase>[
  // ---- Unterhaltung ohne Werkzeuge
  AgentCase('gruss', 'Gespräch', 'Hallo, wie geht es dir?', notTools: {'web_search', 'weather', 'calendar_list'}, noCall: true),
  AgentCase('regenbogen', 'Gespräch', 'Wie entsteht ein Regenbogen?', notTools: {'weather', 'web_search'}, noCall: true,
      answerAny: ['licht', 'tropfen', 'brech']),
  AgentCase('uebersetzen', 'Gespräch', 'Übersetze ins Englische: Ich freue mich auf das Treffen.',
      notTools: {'web_search', 'weather', 'calendar_add'}, noCall: true, answerAny: ['looking forward']),
  AgentCase('windows', 'Gespräch', 'Wie mache ich unter Windows einen Screenshot?', notTools: {'weather'}),
  // ---- Wetter, News, Websuche
  AgentCase('wetter', 'Wetter & Web', 'Wie wird das Wetter morgen in Wien?',
      tools: {'weather'}, call: {'weather'}, answerAny: ['12']),
  AgentCase('jacke', 'Wetter & Web', 'Brauche ich heute eine Jacke?', tools: {'weather'}, call: {'weather'}),
  AgentCase('news', 'Wetter & Web', 'Was gibt es Neues aus Österreich?',
      tools: {'news'}, call: {'news', 'web_search'}, answerAny: ['budget', 'u5', 'u-bahn']),
  AgentCase('aktuell', 'Wetter & Web', 'Wer ist der aktuelle Bundeskanzler von Österreich?',
      tools: {'web_search'}, call: {'web_search'}, answerAny: ['testfrau']),
  AgentCase('url', 'Wetter & Web', 'Fass mir https://example.com/artikel kurz zusammen',
      tools: {'web_fetch'}, call: {'web_fetch', 'browser'}, answerAny: ['radweg']),
  AgentCase('amazon', 'Wetter & Web', 'Such auf Amazon nach einer Laufjacke unter 80 Euro',
      tools: {'site_search'}, call: {'site_search', 'web_search', 'browser'}, answerAny: ['runfast', 'aerorun']),
  AgentCase('flug', 'Wetter & Web', 'Such mir einen günstigen Flug von Wien nach Lissabon im März',
      tools: {'browser', 'web_search'}, call: {'browser', 'web_search'}, answerAny: ['89']),
  // ---- Kalender, Erinnerungen, Kontakte
  AgentCase('kalender', 'Kalender & Kontakte', 'Was steht heute in meinem Kalender?',
      tools: {'calendar_list'}, call: {'calendar_list'}, answerAny: ['zahnarzt']),
  AgentCase('termin', 'Kalender & Kontakte', 'Trag mir für Freitag 10 Uhr einen Termin beim Friseur ein',
      tools: {'calendar_add'}, call: {'calendar_add'}),
  AgentCase('erinnerung', 'Kalender & Kontakte', 'Erinnere mich in 20 Minuten an den Herd',
      tools: {'send_notification'}, call: {'send_notification'}),
  AgentCase('nummer', 'Kalender & Kontakte', 'Wie ist die Telefonnummer von Anna?',
      tools: {'contacts_search'}, call: {'contacts_search'}, answerAny: ['660']),
  AgentCase('anruf', 'Kalender & Kontakte', 'Ruf Anna an', tools: {'call_phone'}, call: {'call_phone', 'contacts_search'}),
  AgentCase('mail', 'Kalender & Kontakte', 'Schreib eine E-Mail an Peter, dass ich mich um 10 Minuten verspäte',
      tools: {'compose_email'}, call: {'compose_email'}),
  AgentCase('whatsapp', 'Kalender & Kontakte', 'Schick Lisa per WhatsApp: Bin in 10 Minuten da',
      tools: {'compose_whatsapp'}, call: {'compose_whatsapp'}),
  AgentCase('posteingang', 'Kalender & Kontakte', 'Habe ich ungelesene Mails?',
      tools: {'mail_inbox'}, call: {'mail_inbox'}, answerAny: ['steuerberater', 'vermieter']),
  AgentCase('offen', 'Kalender & Kontakte', 'Was ist bei mir liegengeblieben?',
      tools: {'find_loose_ends', 'calendar_list'}, call: {'find_loose_ends', 'mail_inbox', 'calendar_list'}),
  // ---- Musik & Apps
  AgentCase('jazz', 'Musik & Apps', 'Spiel Jazz auf Spotify', tools: {'control_app'}, call: {'control_app'}),
  AgentCase('weiter', 'Musik & Apps', 'Nächstes Lied bitte', tools: {'control_app'}, call: {'control_app'}),
  // ---- Erstellen
  AgentCase('praesentation', 'Erstellen', 'Erstelle mir eine Präsentation über Peru mit 5 Folien',
      tools: {'create_presentation'}, required: 'create_presentation', call: {'create_presentation'}),
  AgentCase('pdf', 'Erstellen', 'Mach mir ein PDF-Handout zu Wien',
      tools: {'create_document'}, required: 'create_document', call: {'create_document'}),
  AgentCase('folie', 'Erstellen', 'Überarbeite Folie 3, sie ist zu lang',
      tools: {'edit_file'}, hasFiles: true, required: 'edit_file|create_presentation|create_document', call: {'edit_file', 'create_presentation'}),
  AgentCase('diagramm', 'Erstellen', 'Mach ein Balkendiagramm: Jan 10, Feb 14, März 9',
      tools: {'create_chart'}, call: {'create_chart'}),
  AgentCase('bild', 'Erstellen', 'Zeichne mir ein Bild von einem Fuchs im Schnee',
      tools: {'generate_image'}, notTools: {'weather'}, call: {'generate_image'}),
  AgentCase('skill', 'Erstellen', 'Erstelle einen Skill, der mir jeden Freitag einen Wochenrückblick schreibt',
      tools: {'skill_erstellen'}, call: {'skill_erstellen'}),
  // ---- Rechnen, Zeit, Gedächtnis, Dateien
  AgentCase('prozent', 'Rechnen & Wissen', 'Was sind 17,5 % von 2.340 Euro?',
      tools: {'calculator'}, call: {'calculator'}, answerAny: ['409,5', '409.5', '409,50']),
  AgentCase('wochentag', 'Rechnen & Wissen', 'Welcher Wochentag ist der 24.12.2026?', tools: {'datetime'}, answerAny: ['donnerstag']),
  AgentCase('merken', 'Rechnen & Wissen', 'Merk dir, dass ich vegetarisch esse', tools: {'remember'}, call: {'remember'}),
  AgentCase('unterlagen', 'Rechnen & Wissen', 'Was steht in meinen Unterlagen zur Kündigungsfrist?',
      tools: {'knowledge_search'}, hasDocs: true, call: {'knowledge_search', 'read_file'}, answerAny: ['drei monate', '3 monate']),
  AgentCase('verlauf', 'Rechnen & Wissen', 'Was hatte ich dich letztes Mal zu Peru gefragt?',
      tools: {'search_history'}, call: {'search_history'}, answerAny: ['impf']),
  AgentCase('datei', 'Rechnen & Wissen', 'Finde die Datei Rechnung März in meinen Downloads',
      tools: {'file_search'}, call: {'file_search'}, answerAny: ['rechnung_maerz']),
];

/// Werkzeug-Beschreibungen für den Live-Test ohne App (CI). In der App werden die echten
/// Beschreibungen verwendet ([EvalStubTool.of]).
final evalToolSpecs = <EvalStubTool>[
  EvalStubTool('weather', 'Wetter', 'Wettervorhersage für einen Ort.', [const ToolParam('ort', ParamType.string, 'Ort')], network: true),
  EvalStubTool('news', 'Nachrichten', 'Aktuelle Schlagzeilen zu einem Thema oder Land.', [const ToolParam('thema', ParamType.string, 'Thema')],
      network: true),
  EvalStubTool('web_search', 'Websuche', 'Sucht im Internet nach aktuellen Informationen.', [const ToolParam('query', ParamType.string, 'Suchbegriff')],
      network: true),
  EvalStubTool('web_fetch', 'Webseite lesen', 'Liest den Text einer Webseite.', [const ToolParam('url', ParamType.string, 'Adresse')], network: true),
  EvalStubTool('site_search', 'In Shop suchen', 'Sucht direkt auf einer Seite wie Amazon oder Geizhals.',
      [const ToolParam('site', ParamType.string, 'Seite'), const ToolParam('query', ParamType.string, 'Suchbegriff')], network: true),
  EvalStubTool('browser', 'Browser', 'Öffnet Webseiten im Browser und bedient sie (Suchen, Klicken).',
      [const ToolParam('aufgabe', ParamType.string, 'Was im Browser zu tun ist')], network: true),
  EvalStubTool('calendar_list', 'Kalender lesen', 'Listet Termine eines Zeitraums.', [const ToolParam('tage', ParamType.integer, 'Anzahl Tage ab heute')]),
  EvalStubTool('calendar_add', 'Termin eintragen', 'Schlägt einen Kalendertermin vor (Nutzer bestätigt).',
      [const ToolParam('titel', ParamType.string, 'Titel'), const ToolParam('start', ParamType.string, 'Beginn ISO')]),
  EvalStubTool('send_notification', 'Erinnerung', 'Stellt eine Erinnerung für später.',
      [const ToolParam('text', ParamType.string, 'Text'), const ToolParam('in_minuten', ParamType.integer, 'In wie vielen Minuten')]),
  EvalStubTool('contacts_search', 'Kontakte', 'Sucht in den Kontakten.', [const ToolParam('name', ParamType.string, 'Name')]),
  EvalStubTool('call_phone', 'Anrufen', 'Bereitet einen Anruf vor (Nutzer bestätigt).', [const ToolParam('name', ParamType.string, 'Name oder Nummer')]),
  EvalStubTool('compose_email', 'E-Mail', 'Erstellt einen E-Mail-Entwurf (Nutzer bestätigt).',
      [const ToolParam('an', ParamType.string, 'Empfänger'), const ToolParam('betreff', ParamType.string, 'Betreff'), const ToolParam('text', ParamType.string, 'Text')]),
  EvalStubTool('compose_whatsapp', 'WhatsApp', 'Bereitet eine WhatsApp-Nachricht vor (Nutzer bestätigt).',
      [const ToolParam('an', ParamType.string, 'Empfänger'), const ToolParam('text', ParamType.string, 'Text')]),
  EvalStubTool('mail_inbox', 'Posteingang', 'Liest neue und unbeantwortete E-Mails.', []),
  EvalStubTool('find_loose_ends', 'Liegengeblieben', 'Sammelt offene Punkte aus Mails, Kalender und Aufgaben.', []),
  EvalStubTool('control_app', 'Apps steuern', 'Öffnet und steuert freigegebene Apps (z. B. Spotify: suchen, abspielen, weiter).',
      [const ToolParam('app', ParamType.string, 'App'), const ToolParam('aktion', ParamType.string, 'Aktion'), const ToolParam('suche', ParamType.string, 'Suchbegriff')]),
  EvalStubTool('create_presentation', 'Präsentation', 'Erstellt eine PowerPoint-Präsentation.',
      [const ToolParam('thema', ParamType.string, 'Thema'), const ToolParam('folien', ParamType.integer, 'Anzahl Folien')]),
  EvalStubTool('create_document', 'Dokument', 'Erstellt ein PDF- oder Word-Dokument.',
      [const ToolParam('titel', ParamType.string, 'Titel'), const ToolParam('inhalt', ParamType.string, 'Inhalt in Markdown')]),
  EvalStubTool('edit_file', 'Datei ändern', 'Ändert eine angehängte Datei (z. B. eine Folie).',
      [const ToolParam('datei', ParamType.string, 'Datei'), const ToolParam('aenderung', ParamType.string, 'Was zu ändern ist')]),
  EvalStubTool('create_chart', 'Diagramm', 'Erstellt ein Diagramm aus Werten.',
      [const ToolParam('art', ParamType.string, 'balken, linie, torte'), const ToolParam('daten', ParamType.string, 'Werte, z. B. Jan=10')]),
  EvalStubTool('generate_image', 'Bild erzeugen', 'Erzeugt ein Bild aus einer Beschreibung.', [const ToolParam('beschreibung', ParamType.string, 'Bildbeschreibung')]),
  EvalStubTool('skill_erstellen', 'Skill erstellen', 'Legt einen neuen Skill (wiederverwendbare Anleitung) an.',
      [const ToolParam('name', ParamType.string, 'Name'), const ToolParam('anleitung', ParamType.string, 'Anleitung')]),
  EvalStubTool('calculator', 'Rechner', 'Rechnet einen mathematischen Ausdruck aus.', [const ToolParam('ausdruck', ParamType.string, 'z. B. 2340*0.175')]),
  EvalStubTool('datetime', 'Datum & Zeit', 'Datum, Uhrzeit, Wochentag eines Datums.', [const ToolParam('datum', ParamType.string, 'Datum, optional')]),
  EvalStubTool('remember', 'Merken', 'Merkt sich etwas über den Nutzer dauerhaft.', [const ToolParam('fakt', ParamType.string, 'Was gemerkt wird')]),
  EvalStubTool('knowledge_search', 'Wissensbasis', 'Durchsucht die Dokumente des Nutzers.', [const ToolParam('query', ParamType.string, 'Suchbegriff')]),
  EvalStubTool('search_history', 'Verlauf', 'Durchsucht frühere Chats.', [const ToolParam('query', ParamType.string, 'Suchbegriff')]),
  EvalStubTool('file_search', 'Dateien suchen', 'Sucht Dateien auf dem Gerät.', [const ToolParam('name', ParamType.string, 'Dateiname oder Teil')]),
  EvalStubTool('read_file', 'Datei lesen', 'Liest eine angehängte Datei.', [const ToolParam('name', ParamType.string, 'Dateiname')]),
  EvalStubTool('save_prompt', 'Vorlage speichern', 'Speichert einen Auftrag als Vorlage, auch mit Zeitplan.', [const ToolParam('text', ParamType.string, 'Auftrag')]),
];

/// Testdaten, die ein Werkzeug im Live-Test zurückgibt (fiktiv, damit das Modell nicht aus dem Gedächtnis antwortet).
const evalObservations = <String, String>{
  'weather': 'Wien, morgen: 12 °C, leichter Regen, Wind 15 km/h. Heute: 9 °C, bewölkt.',
  'news': '1. Nationalrat beschließt Budget 2027 (orf.at)\n2. Neue U-Bahn-Linie U5 eröffnet (wien.orf.at)',
  'web_search': '1. bundeskanzleramt.gv.at (Testdaten): Bundeskanzlerin ist Erika Testfrau, im Amt seit Oktober 2026.',
  'web_fetch': 'Titel: Testartikel. Inhalt: Die Stadt Musterhausen baut bis 2027 drei neue Radwege und eine Fahrradgarage.',
  'site_search': 'Amazon: 1. RunFast Laufjacke – 59,99 € (4,5 Sterne) 2. AeroRun Laufjacke – 74,90 € (4,3 Sterne)',
  'browser': 'Seite geöffnet: Flüge Wien → Lissabon im März ab 89 € (Testflug, Direktflug, 3 h 20 min).',
  'calendar_list': 'Heute: 09:00 Zahnarzt Dr. Huber; 14:00 Team-Meeting.',
  'calendar_add': 'Termin vorgeschlagen: Freitag 10:00 Friseur – wartet auf Bestätigung durch den Nutzer.',
  'send_notification': 'Erinnerung gestellt: in 20 Minuten – „Herd“.',
  'contacts_search': 'Anna Berger: +43 660 1234567, anna@example.com',
  'call_phone': 'Anruf an Anna Berger (+43 660 1234567) vorbereitet – wartet auf Bestätigung.',
  'compose_email': 'E-Mail-Entwurf an Peter erstellt – wartet auf Bestätigung.',
  'compose_whatsapp': 'WhatsApp an Lisa vorbereitet – wartet auf Bestätigung.',
  'mail_inbox': '3 ungelesene Mails: Steuerberater (Unterlagen fehlen), Vermieter (Heizung), Newsletter.',
  'find_loose_ends': 'Offen: 2 unbeantwortete Mails (Steuerberater, Vermieter), 1 Termin ohne Zusage.',
  'control_app': 'Spotify: spielt jetzt.',
  'create_presentation': 'Präsentation „Peru“ mit 5 Folien erstellt: Peru.pptx',
  'create_document': 'PDF „Wien Handout“ erstellt: Wien.pdf',
  'edit_file': 'Folie 3 gekürzt und gespeichert.',
  'create_chart': 'Diagramm erstellt: Balken Jan 10, Feb 14, März 9.',
  'generate_image': 'Bild erstellt: fuchs_schnee.png',
  'skill_erstellen': 'Skill „Wochenrückblick“ angelegt (/wochenrueckblick).',
  'calculator': '409.5',
  'datetime': 'Der 24.12.2026 ist ein Donnerstag.',
  'remember': 'Gemerkt: isst vegetarisch.',
  'knowledge_search': 'Mietvertrag.pdf, S. 4: Die Kündigungsfrist beträgt drei Monate zum Monatsende.',
  'read_file': 'Mietvertrag.pdf, S. 4: Die Kündigungsfrist beträgt drei Monate zum Monatsende.',
  'search_history': 'Chat vom 12.11.: „Welche Impfungen brauche ich für eine Reise nach Peru?“',
  'file_search': 'Gefunden: ~/Downloads/Rechnung_Maerz_2026.pdf',
  'save_prompt': 'Vorlage gespeichert.',
};

/// Werkzeug ohne Wirkung: gibt Testdaten zurück und merkt sich den Aufruf.
class EvalStubTool extends AgentTool {
  EvalStubTool(this.name, this.title, this.description, this.params, {bool network = false}) : _network = network;

  /// Echte Beschreibung übernehmen, aber nichts ausführen.
  factory EvalStubTool.of(AgentTool t) => EvalStubTool(t.name, t.title, t.description, t.params, network: t.requiresNetwork);

  @override
  final String name;
  @override
  final String title;
  @override
  final String description;
  @override
  final List<ToolParam> params;
  final bool _network;
  @override
  bool get requiresNetwork => _network;

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async =>
      evalObservations[name] ?? 'Erledigt (Testdaten für $name).';
}

class CaseResult {
  CaseResult(this.c, {required this.offered, required this.called, required this.answer, required this.ms,
      required this.steps, required this.tokens, required this.problems, this.skipped = false});
  final AgentCase c;
  final Set<String> offered;
  final List<String> called;
  final String answer;
  final int ms;
  final int steps;
  final int tokens;
  final List<String> problems;
  final bool skipped;
  bool get passed => !skipped && problems.isEmpty;
}

class EvalReport {
  EvalReport(this.model, this.results, this.started);
  final String model;
  final List<CaseResult> results;
  final DateTime started;

  int get passed => results.where((r) => r.passed).length;
  int get counted => results.where((r) => !r.skipped).length;
  double get score => counted == 0 ? 0 : passed / counted;
  int get avgMs => counted == 0 ? 0 : results.where((r) => !r.skipped).fold<int>(0, (a, r) => a + r.ms) ~/ counted;

  Map<String, (int, int)> get byArea {
    final m = <String, (int, int)>{};
    for (final r in results.where((r) => !r.skipped)) {
      final (p, n) = m[r.c.area] ?? (0, 0);
      m[r.c.area] = (p + (r.passed ? 1 : 0), n + 1);
    }
    return m;
  }

  String toMarkdown() {
    final b = StringBuffer()
      ..writeln('## Agent-Test-Satz: $passed/$counted bestanden (${(score * 100).round()} %)')
      ..writeln()
      ..writeln('Modell: $model · ${started.toIso8601String().substring(0, 16)} · Ø ${(avgMs / 1000).toStringAsFixed(1)} s je Auftrag')
      ..writeln()
      ..writeln('| Bereich | bestanden |')
      ..writeln('|---|---|');
    for (final e in byArea.entries) {
      b.writeln('| ${e.key} | ${e.value.$1}/${e.value.$2} |');
    }
    b
      ..writeln()
      ..writeln('| Fall | Ergebnis | Werkzeuge | Zeit | Problem |')
      ..writeln('|---|---|---|---|---|');
    for (final r in results) {
      b.writeln('| ${r.c.id} | ${r.skipped ? '–' : (r.passed ? '✅' : '❌')} | ${r.called.isEmpty ? '–' : r.called.join(', ')} | '
          '${(r.ms / 1000).toStringAsFixed(1)} s | ${r.problems.join('; ').replaceAll('|', '/')} |');
    }
    return b.toString();
  }
}

/// Prüft nur die Auswahl (ohne Modell) – läuft in jedem Build.
List<String> checkRouting(AgentCase c, Iterable<String> toolNames) {
  final offered = ToolRouter.selectNames(toolNames, c.prompt, hasDocs: c.hasDocs);
  final req = ToolRouter.requiredToolFor(c.prompt, hasFiles: c.hasFiles);
  return [
    for (final t in c.tools)
      if (!offered.contains(t)) '„$t“ fehlt',
    for (final t in c.notTools)
      if (offered.contains(t)) '„$t“ unpassend angeboten',
    if (req != c.required) 'Pflicht-Werkzeug ${req ?? '–'} statt ${c.required ?? '–'}',
  ];
}

/// Live-Test: echtes Modell, Test-Werkzeuge ohne Wirkung.
class AgentEvaluator {
  AgentEvaluator({
    required this.backend,
    required this.systemPrompt,
    required this.tools,
    this.model = '',
    this.maxSteps = 6,
    this.maxTokensPerStep = 512,
    this.timeout = const Duration(minutes: 3),
  });

  final AgentBackend backend;

  /// System-Prompt für die gewählten Werkzeuge (wie im Chat)
  final String Function(List<AgentTool> tools) systemPrompt;
  final List<EvalStubTool> tools;
  final String model;
  final int maxSteps;
  final int maxTokensPerStep;
  final Duration timeout;
  bool _cancel = false;
  AgentRunner? _runner;

  void cancel() {
    _cancel = true;
    _runner?.stop();
  }

  Future<EvalReport> run(List<AgentCase> cases, {void Function(int done, int total, CaseResult? last)? onProgress}) async {
    final started = DateTime.now();
    final out = <CaseResult>[];
    onProgress?.call(0, cases.length, null);
    for (final c in cases) {
      if (_cancel) break;
      final r = await runCase(c);
      out.add(r);
      onProgress?.call(out.length, cases.length, r);
    }
    return EvalReport(model, out, started);
  }

  Future<CaseResult> runCase(AgentCase c) async {
    final names = {for (final t in tools) t.name};
    // Fall braucht ein Werkzeug, das es hier nicht gibt (ausgeschaltet) → überspringen
    if (c.call.isNotEmpty && !c.call.any(names.contains)) {
      return CaseResult(c, offered: const {}, called: const [], answer: '', ms: 0, steps: 0, tokens: 0,
          problems: const ['Werkzeug nicht eingeschaltet'], skipped: true);
    }
    final offered = ToolRouter.select(tools, (t) => (name: t.name, title: t.title, description: t.description), c.prompt, hasDocs: c.hasDocs);
    var req = ToolRouter.requiredToolFor(c.prompt, hasFiles: c.hasFiles);
    if (req != null && !req.split('|').any((x) => offered.any((t) => t.name == x))) req = null;
    final runner = _runner = AgentRunner(
      engine: backend,
      systemPrompt: systemPrompt(offered),
      tools: offered,
      maxSteps: maxSteps,
      maxTokensPerStep: maxTokensPerStep,
      requiredTool: req,
    );
    final ctx = ToolContext(
      attachments: const [],
      requestNetwork: (_) async => true,
    );
    final called = <String>[];
    var answer = '';
    var steps = 0;
    var tokens = 0;
    String? failure;
    final sw = Stopwatch()..start();
    try {
      await for (final ev in runner.run(history: const [], userInput: c.prompt, context: ctx).timeout(timeout)) {
        switch (ev) {
          case StepStarted():
            steps++;
          case ToolCalled(:final tool):
            called.add(tool);
          case MetricsUpdate(:final stats):
            tokens += stats.promptTokens + stats.generatedTokens;
          case FinalAnswer(:final text):
            answer = text;
          case AgentFinished(:final reason, :final message):
            if (reason == AgentStopReason.error) failure = message ?? 'Fehler';
            if (reason == AgentStopReason.stepLimit) failure = 'zu viele Schritte';
          default:
            break;
        }
      }
    } on TimeoutException {
      runner.stop();
      failure = 'Zeitüberschreitung';
    } catch (e) {
      failure = '$e';
    }
    sw.stop();
    final low = answer.toLowerCase();
    final problems = <String>[
      if (failure != null) failure,
      if (c.noCall && called.isNotEmpty) 'unnötig ${called.join(', ')} aufgerufen',
      if (c.call.isNotEmpty && !called.any(c.call.contains)) 'erwartet ${c.call.join(' oder ')}, aufgerufen ${called.isEmpty ? 'nichts' : called.join(', ')}',
      if (c.answerAny.isNotEmpty && !c.answerAny.any((k) => low.contains(k))) 'Antwort ohne ${c.answerAny.join('/')}',
      for (final k in c.answerNot)
        if (low.contains(k)) 'Antwort enthält „$k“',
      if (answer.trim().isEmpty && failure == null) 'keine Antwort',
    ];
    return CaseResult(c,
        offered: {for (final t in offered) t.name},
        called: called,
        answer: answer.length > 200 ? '${answer.substring(0, 200)} …' : answer,
        ms: sw.elapsedMilliseconds,
        steps: steps,
        tokens: tokens,
        problems: problems);
  }
}

/// Einfacher System-Prompt für den Live-Test ohne App (CI).
String evalSystemPrompt(List<AgentTool> tools) =>
    'Du bist Junels, ein hilfreicher persönlicher KI-Assistent. Heute ist Dienstag, der 24.11.2026, Ort: Wien. '
    'Antworte auf Deutsch, kurz und konkret. Nutze Werkzeuge, wenn die Frage aktuelle Daten, persönliche Daten '
    '(Kalender, Kontakte, Mails, Dateien) oder eine Aktion braucht; sonst antworte direkt.';
