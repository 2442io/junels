// UX-Bilder aller Seiten in Handy-Größe (test/ux/*.png) – zum Prüfen von Aufbau und Bedienbarkeit.
// Läuft im Build: flutter test test/help_screenshots_test.dart --update-goldens

// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_agent/data/models.dart';
import 'package:offline_agent/state/app_controller.dart';
import 'package:offline_agent/state/app_scope.dart';
import 'package:offline_agent/ui/inbox_page.dart';
import 'package:offline_agent/ui/sidebar.dart';
import 'package:offline_agent/ui/skills_page.dart';
import 'package:offline_agent/ui/chat_view.dart' show ChatView;
import 'package:offline_agent/state/skills.dart';
import 'package:offline_agent/ui/device_page.dart';
import 'package:offline_agent/ui/sync_page.dart';
import 'package:offline_agent/ui/notify_settings_page.dart';
import 'package:offline_agent/ui/mcp_page.dart';
import 'package:offline_agent/ui/mcp_serve_page.dart';
import 'package:offline_agent/ui/connections_page.dart';
import 'package:offline_agent/ui/apps_page.dart';
import 'package:offline_agent/ui/designs_page.dart';
import 'package:offline_agent/ui/backup_page.dart';
import 'package:offline_agent/ui/setups_page.dart';
import 'package:offline_agent/ui/update_page.dart';
import 'package:offline_agent/ui/self_test_page.dart';
import 'package:offline_agent/ui/monitor_page.dart';
import 'package:offline_agent/ui/flows_page.dart';
import 'package:offline_agent/ui/help_page.dart';
import 'package:offline_agent/ui/home_shell.dart';
import 'package:offline_agent/ui/knowledge_page.dart';
import 'package:offline_agent/ui/settings_page.dart';
import 'package:offline_agent/ui/system_check.dart';
import 'package:offline_agent/ui/tasks_page.dart';
import 'package:offline_agent/ui/theme.dart';
import 'package:offline_agent/ui/watchlist_page.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationSupportPath() async => '$dir/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$dir/docs';
  @override
  Future<String?> getTemporaryPath() async => '$dir/tmp';
  @override
  Future<String?> getApplicationCachePath() async => '$dir/cache';
  @override
  Future<String?> getLibraryPath() async => '$dir/lib';
  @override
  Future<String?> getDownloadsPath() async => '$dir/dl';
}

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    if (!File(f).existsSync()) {
      // ignore: avoid_print
      print('Schrift fehlt: $f');
      continue;
    }
    l.addFont(File(f).readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await l.load();
}

String? _flutterRoot() {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && env.isNotEmpty) return env;
  // flutter test läuft mit dem Dart aus <flutter>/bin/cache/dart-sdk
  final exe = Platform.resolvedExecutable;
  final i = exe.indexOf('/bin/cache/');
  return i > 0 ? exe.substring(0, i) : null;
}

late AppController app;

/// Beispielbilder für Karten (test/assets/demo/*.jpg)
String _img(String n) => '${Directory.current.path}/test/assets/demo/$n.jpg';

ChatEntry _a(String text, {List<StepLog>? steps, String? via, int ms = 4200, List<Map<String, String>>? cards}) =>
    ChatEntry(role: 'assistant', text: text, steps: steps, via: via, durationMs: ms, tokensPerSecond: 38.4, cards: cards);

Future<void> _demo() async {
  app.settings
    ..systemCheckSeen = true
    ..homeCity = 'Wien'
    ..routing = 'hybrid'
    ..hybridFirst = 'local';
  app.loadedModel = StoredModel(
      id: 'm', fileName: 'qwen.gguf', path: '/x', sizeBytes: 2600000000, displayName: 'Qwen3.5 4B', architecture: 'qwen', quantization: 'Q4_K_M');
  app.status = EngineStatus.ready;
  app.settings.providers = [
    ProviderConfig(id: 'p1', kind: ProviderKind.anthropic, name: 'Claude', baseUrl: ProviderKind.anthropic.defaultUrl, model: 'claude-sonnet-5-5').toJson(),
    ProviderConfig(id: 'p2', kind: ProviderKind.ollama, name: 'Büro-Server', baseUrl: 'http://10.0.0.20:11434/v1', model: 'qwen3:32b').toJson(),
    ProviderConfig(id: 'p3', kind: ProviderKind.openai, name: 'OpenAI', baseUrl: ProviderKind.openai.defaultUrl, model: 'gpt-5-mini').toJson(),
  ];
  app.settings.cloudId = 'p1';
  app.settings.onPremId = 'p2';

  final now = DateTime.now();
  final c1 = Conversation(id: 'c1', title: 'Tech-News & Wetter für morgen')
    ..updated = now
    ..entries.addAll([
      ChatEntry(role: 'user', text: 'Wie wird das Wetter morgen in Wien – brauche ich einen Schirm?'),
      _a('**Morgen in Wien:** bewölkt, ab Mittag Regen (80 %), 6–9 °C, Wind aus West.\n\n'
          'Ja – nimm einen **Schirm** mit, vor allem für den Heimweg ab 16 Uhr. Am Donnerstag wird es wieder trocken und sonnig.',
          steps: [
            StepLog(step: 1, tool: 'weather', thought: 'Ich frage das Wetter direkt ab.', args: {'location': 'Wien'}, observation: 'Wien: Mi 6–9 °C, Regen 80 % …', durationMs: 640),
          ],
          ms: 3100),
      ChatEntry(role: 'user', text: 'Und was sind die wichtigsten KI-News heute?'),
      _a('Die drei wichtigsten Meldungen heute:\n\n'
          '1. **Neues Open-Source-Modell** schlägt größere Modelle bei Code-Aufgaben – läuft auch auf Laptops.\n'
          '2. **EU AI Act:** Leitlinien für Hochrisiko-Systeme veröffentlicht, Übergangsfrist bis 2027.\n'
          '3. **Lokale KI auf Smartphones** wird schneller: neue Chips verdoppeln die Tokens pro Sekunde.',
          steps: [
            StepLog(step: 1, tool: 'news', thought: 'Ich suche aktuelle KI-Nachrichten.', args: {'query': 'KI'}, observation: '12 Meldungen gefunden', durationMs: 1800),
            StepLog(step: 2, thought: 'Ich fasse die wichtigsten drei zusammen.'),
          ],
          ms: 9400,
          cards: [
            {'title': 'Offenes Modell schlägt Größere bei Code', 'link': 'https://futurezone.at/a', 'note': 'futurezone.at', 'image': _img('news1')},
            {'title': 'AI Act: Leitlinien für Hochrisiko-KI', 'link': 'https://derstandard.at/b', 'note': 'derstandard.at', 'image': _img('news2')},
            {'title': 'Smartphone-Chips verdoppeln KI-Tempo', 'link': 'https://heise.de/c', 'note': 'heise.de', 'image': _img('news3')},
          ]),
    ]);
  final c2 = Conversation(id: 'c2', title: 'Präsentation: Lokale KI im Unternehmen')..updated = now.subtract(const Duration(hours: 3));
  final c3 = Conversation(id: 'c3', title: 'Angebote Staubsauger-Roboter')..updated = now.subtract(const Duration(days: 1));
  final c4 = Conversation(id: 'c4', title: 'Mail an Sarah wegen Workshop')..updated = now.subtract(const Duration(days: 2));
  app.conversations = [c1, c2, c3, c4];
  // Angeheftet: Ordner und Chat mit Symbol & Farbe
  c1
    ..pinned = true
    ..icon = 'stern'
    ..color = 'gelb';
  c2
    ..folder = 'Junels'
    ..color = 'blau';
  c3.folder = 'Steuer 2026';
  app.settings.folderMeta = {
    'Junels': {'pinned': true, 'icon': 'rakete', 'color': 'lila'},
    'Steuer 2026': {'color': 'gruen'},
  };
  app.current = c1;

  app.prompts = [
    SavedPrompt(title: 'Morgen-Übersicht', text: 'Termine, Wetter, News', schedule: ScheduleKind.daily, hour: 7, minute: 0)
      ..lastRun = now.subtract(const Duration(hours: 5)),
    SavedPrompt(title: 'Morning Briefing News', text: 'Tech-News zusammenfassen', schedule: ScheduleKind.weekdays, hour: 8, minute: 15),
    SavedPrompt(title: 'Wochenrückblick', text: 'Woche zusammenfassen', schedule: ScheduleKind.weekly, hour: 16, minute: 0, weekday: DateTime.friday)
      ..enabled = false,
    SavedPrompt(title: 'E-Mail freundlich umformulieren', text: 'Formuliere freundlich: '),
    SavedPrompt(title: 'Protokoll aus Notizen', text: 'Mach aus diesen Notizen ein Protokoll: '),
  ];
  // Geplante Aufgaben werden zu Skills mit Zeitplan
  await app.adoptScheduledPrompts();
  // Sammlung „Ergebnisse“
  final f = app.feed;
  app.webJobs.jobs.add(WebJob(id: 'demo-job', title: 'Preis-Scout', goal: 'RTX 4070 Super unter 550 €', status: 'läuft', current: 2, steps: [
    JobStep('geizhals.at öffnen und nach „RTX 4070 Super“ suchen', status: 'ok', note: '38 Treffer'),
    JobStep('Angebote über 2 Seiten sammeln', status: 'ok', note: '24 Angebote'),
    JobStep('willhaben.at nach gebrauchten Karten durchsuchen', status: 'läuft'),
    JobStep('Ergebnis als Tabelle zusammenstellen'),
  ]));
  f.entries.addAll([
    ChatEntry(role: 'assistant', origin: '🧭 Preis-Scout', originId: 'job:demo-job', time: now.subtract(const Duration(minutes: 2))),
    ChatEntry(role: 'assistant', text: '## KI-News\n- OpenAI stellt neues Modell vor\n- EU AI Act: neue Leitlinien\n- Anthropic veröffentlicht Studie zu Agenten\n- Google zeigt Gemini-Update\n- Microsoft investiert in Rechenzentren in Österreich',
        origin: '⏱ Morning Briefing News', originId: 'prompt:${app.prompts[1].id}', time: now.subtract(const Duration(hours: 3))),
    ChatEntry(role: 'user', text: 'Wie wird das Wetter morgen in Wien?', origin: '🎙 Gespräch 17:40', originId: 'voice:1', viaVoice: true, time: now.subtract(const Duration(hours: 2))),
    ChatEntry(role: 'assistant', text: 'Morgen wird es in Wien bewölkt bei 6 Grad, am Nachmittag kann es regnen.', origin: '🎙 Gespräch 17:40', originId: 'voice:1', time: now.subtract(const Duration(hours: 2))),
    ChatEntry(role: 'assistant', error: 'Webseite nicht erreichbar (Zeitüberschreitung)', origin: '⚙ Tech-News am Morgen', originId: 'flow:f1', time: now.subtract(const Duration(days: 1, hours: 2))),
  ]);
  app.skills.forPrompt(app.prompts[1].id)?.output = 'table';

  app.watchlist.items.addAll([
    WatchItem(id: 'w1', kind: WatchKind.page, title: 'Karriere – Beispiel GmbH', target: 'https://beispiel.at/karriere', intervalMinutes: 360, lastCheck: now.subtract(const Duration(minutes: 42)), fingerprint: 'x', events: [
      WatchEvent(time: now.subtract(const Duration(minutes: 42)), title: '2 neue Einträge auf Karriere – Beispiel GmbH', detail: 'Neu: „Senior Data Scientist (m/w/d)“ und „AI Solution Manager“.', links: [
        {'title': 'Senior Data Scientist (m/w/d)', 'link': 'https://beispiel.at/karriere/1'},
        {'title': 'AI Solution Manager', 'link': 'https://beispiel.at/karriere/2'},
      ]),
    ]),
    WatchItem(id: 'w2', kind: WatchKind.topic, title: 'Anthropic', target: 'Anthropic Claude', intervalMinutes: 180, lastCheck: now.subtract(const Duration(hours: 1)), fingerprint: 'topic'),
    WatchItem(id: 'w3', kind: WatchKind.page, title: 'geizhals.at – Roboter', target: 'https://geizhals.at/?cat=hhstsaug', intervalMinutes: 1440, lastCheck: now.subtract(const Duration(hours: 9)), fingerprint: 'y'),
  ]);

  final wf = Workflow(id: 'f1', name: 'Tech-News am Morgen', description: 'Jeden Morgen Tech-News suchen, zusammenfassen und schicken');
  wf.nodes.addAll([
    FlowNode(id: 'n1', type: FlowNodeType.trigger, title: 'Jeden Morgen', config: {'mode': 'schedule', 'hour': 7, 'minute': 0, 'days': 'weekdays'}),
    FlowNode(id: 'n2', type: FlowNodeType.tool, title: 'Nachrichten holen', config: {'tool': 'news', 'args': {'query': 'KI'}}),
    FlowNode(id: 'n3', type: FlowNodeType.agent, title: 'Zusammenfassen', config: {'prompt': 'Fasse {{vorher}} in 5 Punkten zusammen.'}),
    FlowNode(id: 'n4', type: FlowNodeType.condition, title: 'Wichtig?', config: {'contains': 'KI'}),
    FlowNode(id: 'n5', type: FlowNodeType.notify, title: 'Push-Nachricht', config: {'title': 'Tech-News', 'text': '{{vorher}}'}),
    FlowNode(id: 'n6', type: FlowNodeType.save, title: 'Als Notiz', config: {'mode': 'memory'}),
  ]);
  wf.connect('n1', 'n2');
  wf.connect('n2', 'n3');
  wf.connect('n3', 'n4');
  wf.connect('n4', 'n5');
  wf.connect('n3', 'n6');
  wf.layout(dx: 300, dy: 150);
  wf.lastRun = now.subtract(const Duration(hours: 2));
  wf.lastStatus = 'Erfolgreich';
  final wf2 = Workflow(id: 'f2', name: 'Schirm-Erinnerung')
    ..nodes.addAll([
      FlowNode(id: 'n1', type: FlowNodeType.trigger, title: 'Mo–Fr 17:00', config: {'mode': 'schedule', 'hour': 17, 'minute': 0, 'days': 'weekdays'}),
      FlowNode(id: 'n2', type: FlowNodeType.tool, title: 'Wetter morgen', config: {'tool': 'weather', 'args': {'location': 'Wien'}}),
      FlowNode(id: 'n3', type: FlowNodeType.condition, title: 'Regen?', config: {'contains': 'Regen'}),
      FlowNode(id: 'n4', type: FlowNodeType.notify, title: 'Erinnern'),
    ]);
  wf2.connect('n1', 'n2');
  wf2.connect('n2', 'n3');
  wf2.connect('n3', 'n4');
  app.flows.flows.addAll([wf, wf2]);
  for (final f in [wf, wf2]) {
    app.skills.syncFlow(f.id, f.name, f.description);
  }
  app.skills.upsert(Skill(
      id: 'u-amazon',
      name: 'Amazon Suche',
      when: 'Produkte auf Amazon suchen und vergleichen',
      instructions: '1. Auf amazon.de suchen\n2. Die besten 5 mit Preis und Link nennen',
      tools: ['site_search', 'web_search'],
      icon: 'shopping',
      internet: 'allow',
      output: 'cards'));
  final views = Conversation(id: 'c5', title: 'Ansichten')
    ..updated = now
    ..entries.addAll([
      ChatEntry(role: 'user', text: '/amazon ski unterwäsche merino für männer'),
      ChatEntry(role: 'assistant', skill: 'Amazon Suche', view: 'cards', durationMs: 35000, via: 'Lokal · Gemma 4 12B',
          text: 'Drei gute Merino-Sets für den Skitag:\n\n- **Merino-tech Set** – 49,99 € – warm, weich – https://www.amazon.de/dp/B01\n'
              '- **DANISH ENDURANCE Thermo** – 39,95 € – mit Reißverschluss – https://www.amazon.de/dp/B02\n- **Icebreaker 200 Oasis** – 89,90 € – sehr langlebig – https://www.amazon.de/dp/B03',
          cards: [
            {'title': 'Merino-tech Set', 'link': 'https://www.amazon.de/dp/B01', 'note': '49,99 € · warm, weich', 'tag': 'Preistipp', 'image': _img('merino1')},
            {'title': 'DANISH ENDURANCE Thermo', 'link': 'https://www.amazon.de/dp/B02', 'note': '39,95 € · mit Reißverschluss', 'image': _img('merino2')},
            {'title': 'Icebreaker 200 Oasis', 'link': 'https://www.amazon.de/dp/B03', 'note': '89,90 € · sehr langlebig', 'image': _img('merino3')},
          ]),
      ChatEntry(role: 'user', text: 'Vergleich die drei als Tabelle'),
      ChatEntry(role: 'assistant', view: 'table', durationMs: 4000,
          text: 'Im Vergleich:\n\n| Set | Preis | Merino | Besonderheit |\n|---|---|---|---|\n| Merino-tech | 49,99 € | 100 % | weich |\n'
              '| DANISH ENDURANCE | 39,95 € | 80 % | Reißverschluss |\n| Icebreaker 200 | 89,90 € | 100 % | langlebig |'),
      ChatEntry(role: 'user', text: 'Was muss ich für den Skiurlaub packen? Als Checkliste'),
      ChatEntry(role: 'assistant', view: 'list', checked: [0, 2], durationMs: 3000,
          text: 'Deine Packliste:\n\n- [ ] Skipass und Ausweis\n- [ ] Helm und Brille\n- [ ] Merino-Unterwäsche\n- [ ] Sonnencreme\n- [ ] Ladegerät'),
      ChatEntry(role: 'user', text: 'Wie wachse ich meine Ski? Schritt für Schritt'),
      ChatEntry(role: 'assistant', view: 'steps', durationMs: 3500,
          text: 'So geht es:\n\n1. **Reinigen** – Belag mit Base Cleaner säubern\n2. **Wachs auftragen** – Bügeleisen auf 120 °C, Wachs auftropfen\n'
              '3. **Abkühlen** – mindestens 30 Minuten\n4. **Abziehen** – mit der Plexiklinge von vorne nach hinten\n5. **Ausbürsten** – Struktur freilegen'),
    ]);
  app.conversations.add(views);
  // Für die Webseite: Web-Job mit Karten
  final bikes = Conversation(id: 'c6', title: 'E-Bikes unter 2.000 €')
    ..updated = now
    ..pinned = true
    ..icon = 'rakete'
    ..color = 'gruen'
    ..entries.addAll([
      ChatEntry(role: 'user', text: 'Finde die 3 günstigsten E-Bikes unter 2.000 € – Lieferung bis Weihnachten'),
      ChatEntry(role: 'assistant', view: 'cards', durationMs: 48000, via: 'Lokal · Qwen3.5 4B', tokensPerSecond: 41.2,
          steps: [
            StepLog(step: 1, tool: 'web_search', thought: 'Ich suche aktuelle Angebote.', args: {'query': 'E-Bike unter 2000 Euro lieferbar'}, observation: '24 Angebote', durationMs: 2100),
            StepLog(step: 2, tool: 'browse', thought: 'Ich vergleiche Preise auf geizhals.at.', args: {'url': 'https://geizhals.at'}, observation: '3 Shops verglichen', durationMs: 5200),
            StepLog(step: 3, thought: 'Ich prüfe Lieferzeiten und fasse zusammen.'),
          ],
          text: 'Hier sind die drei günstigsten – alle **vor Weihnachten lieferbar**:\n\n'
              '1. **City E1** – 1.499 € – 500 Wh, bis 90 km\n2. **Urban 7** – 1.689 € – leicht, Riemenantrieb\n3. **Trek Go** – 1.899 € – Federgabel, 625 Wh',
          cards: [
            {'title': 'City E1', 'link': 'https://geizhals.at/1', 'note': '1.499 € · 500 Wh · bis 90 km', 'tag': 'Günstigster', 'image': _img('bike1')},
            {'title': 'Urban 7', 'link': 'https://geizhals.at/2', 'note': '1.689 € · leicht · Riemen', 'image': _img('bike2')},
            {'title': 'Trek Go', 'link': 'https://geizhals.at/3', 'note': '1.899 € · Federgabel · 625 Wh', 'image': _img('bike3')},
          ]),
      ChatEntry(role: 'user', text: 'Merk dir das City E1 – ich schau es mir am Samstag an 👍'),
      ChatEntry(role: 'assistant', text: 'Gemerkt! Soll ich dich am Samstag um 9 Uhr erinnern?', durationMs: 900),
    ]);
  app.conversations.insert(0, bikes);
  app.flows.state['f1'] = {'n1': 'done', 'n2': 'done', 'n3': 'done', 'n4': 'running', 'n5': 'pending', 'n6': 'done'};

  await app.memory.add('Arbeitet in Wien als Solution Manager für KI.', category: 'person');
  await app.memory.add('Mag kurze Antworten mit Stichpunkten.', category: 'vorliebe');
  await app.memory.add('Montags um 9 Uhr Team-Meeting.', category: 'routine', confirmed: false);
}

Future<void> _shot(WidgetTester tester, String name, Size size, Widget home, {bool warm = false, double dpr = 1.0}) async {
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  await tester.pumpWidget(AppScope(
    controller: app,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light, warm: warm),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: warm ? ThemeMode.light : ThemeMode.dark,
      home: KeyedSubtree(key: ValueKey(name), child: home),
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  // Bilder aus Dateien wirklich laden (sonst bleiben sie im Test leer)
  await tester.runAsync(() async {
    for (final el in find.byType(Image).evaluate()) {
      final w = el.widget as Image;
      if (w.image is FileImage) await precacheImage(w.image, el);
    }
  });
  await tester.pump(const Duration(milliseconds: 120));
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('ux/$name.png'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final tmp = Directory.systemTemp.createTempSync('junels_shots');
    for (final d in ['support', 'docs', 'tmp', 'cache']) {
      Directory('${tmp.path}/$d').createSync(recursive: true);
    }
    PathProviderPlatform.instance = _Paths(tmp.path);
    // Plugins ohne Test-Implementierung stumm schalten
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'junels/background',
      'junels/files',
      'junels/device',
      'flutter_tts',
      'com.llfbandit.record/messages',
      'dev.fluttercommunity.plus/wakelock',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (call) async => null);
    }
    await _font('Inter', [for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) 'assets/fonts/Inter-$w.ttf']);
    await _font('JetBrainsMono', ['assets/fonts/JetBrainsMono-Regular.ttf', 'assets/fonts/JetBrainsMono-Medium.ttf']);
    final root = _flutterRoot();
    await _font('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  // Bilder für die Webseite: hell & warm (Farbstil „Junels“), doppelte Auflösung
  testWidgets('Marketing-Bilder', (tester) async {
    app = AppController()..headless = true;
    await tester.runAsync(() async {
      await app.init();
      await _demo();
    });
    app.settings.uiStyle = 'junels';
    Widget chat(String id) => Builder(builder: (_) {
          app.current = app.conversations.firstWhere((c) => c.id == id);
          return const HomeShell();
        });
    final shots = <String, (Size, Widget)>{
      'm_chat': (const Size(400, 860), chat('c6')),
      'm_news': (const Size(400, 860), chat('c1')),
      'm_cards': (const Size(400, 860), chat('c5')),
      'm_results': (const Size(400, 860), Builder(builder: (_) {
        app.current = app.feed;
        return const Scaffold(body: ChatView());
      })),
      'm_skills': (const Size(400, 860), const SkillsPage()),
      'm_tasks': (const Size(400, 860), const SkillsPage(filter: 'schedule')),
      'm_flow': (const Size(400, 860), const FlowEditor(id: 'f1')),
      'm_watch': (const Size(400, 860), const WatchDetailPage(id: 'w1')),
      'm_menu': (const Size(400, 860), const Scaffold(body: Sidebar())),
      'm_desktop': (const Size(1440, 900), chat('c6')),
      'm_desktop_cards': (const Size(1440, 900), chat('c5')),
    };
    for (final e in shots.entries) {
      try {
        await _shot(tester, e.key, e.value.$1, e.value.$2, warm: true, dpr: 2);
        // ignore: avoid_print
        print('Bild: ${e.key}');
      } catch (err) {
        // ignore: avoid_print
        print('Bild ${e.key} fehlgeschlagen: $err');
      }
      FlutterError.onError = FlutterError.presentError;
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('UX-Bilder', (tester) async {
    app = AppController()..headless = true;
    await tester.runAsync(() async {
      await app.init();
      if (app.initError != null) {
        // ignore: avoid_print
        print('init-Fehler: ${app.initError}');
      }
      await _demo();
    });
    final shots = <String, (Size, Widget)>{
      'menu': (const Size(412, 1700), const Scaffold(body: Sidebar())),
      'inbox': (const Size(412, 1700), const InboxPage()),
      'tasks': (const Size(412, 1700), const SkillsPage(filter: 'schedule')),
      'job_editor': (const Size(412, 2200), SkillEditor(skill: app.skills.byId('b-preis-scout'))),
      'results': (const Size(412, 1600), Builder(builder: (_) {
        app.current = app.feed;
        return const Scaffold(body: ChatView());
      })),
      'plan_editor': (const Size(412, 2000), SkillEditor(
          draft: Skill(id: 'u-new', name: 'News: KI', instructions: 'Die wichtigsten KI-News in 5 Punkten', auto: false, output: 'cards'),
          plan: (kind: ScheduleKind.weekdays, hour: 7, minute: 30, weekday: 1))),
      'flows': (const Size(412, 1700), const FlowsPage()),
      'flow_editor': (const Size(412, 1700), const FlowEditor(id: 'f1')),
      'watch': (const Size(412, 1700), const WatchlistPage()),
      'watch_detail': (const Size(412, 1700), const WatchDetailPage(id: 'w1')),
      'skills': (const Size(412, 1700), const SkillsPage()),
      'prompts': (const Size(412, 1700), const PromptsPage()),
      'knowledge': (const Size(412, 1700), const KnowledgePage()),
      'activity': (const Size(412, 1700), const ActivityPage()),
      'monitor': (const Size(412, 1700), const MonitorPage()),
      'settings': (const Size(412, 1700), const SettingsPage()),
      's_models': (const Size(412, 1700), const SettingsPage(initial: 'models')),
      's_providers': (const Size(412, 1700), const SettingsPage(initial: 'providers')),
      's_agent': (const Size(412, 1700), const SettingsPage(initial: 'agent')),
      's_voice': (const Size(412, 1700), const SettingsPage(initial: 'voice')),
      's_ext': (const Size(412, 1700), const SettingsPage(initial: 'ext')),
      's_app': (const Size(412, 1700), const SettingsPage(initial: 'app')),
      's_data': (const Size(412, 1700), const SettingsPage(initial: 'data')),
      'device': (const Size(412, 1700), const DevicePage()),
      'vault': (const Size(412, 1700), const VaultPage()),
      'notify': (const Size(412, 1700), const NotifySettingsPage()),
      'sync': (const Size(412, 1700), const SyncPage()),
      'mcp': (const Size(412, 1700), const McpPage()),
      'mcp_serve': (const Size(412, 1700), const McpServePage()),
      'connections': (const Size(412, 1700), const ConnectionsPage()),
      'apps': (const Size(412, 1700), const AppsPage()),
      'designs': (const Size(412, 1700), const DesignsPage()),
      'backup': (const Size(412, 1700), const BackupPage()),
      'setups': (const Size(412, 1700), const SetupsPage()),
      'updates': (const Size(412, 1700), const UpdatePage()),
      'selftest': (const Size(412, 1700), const SelfTestPage()),
      'help': (const Size(412, 1700), const HelpPage()),
      'home_phone': (const Size(412, 900), const HomeShell()),
      'desktop': (const Size(1440, 900), const HomeShell()),
      'desktop_settings': (const Size(1280, 900), const SettingsPage()),
      'skill_editor': (const Size(412, 2200), SkillEditor(skill: app.skills.byId('u-amazon'))),
      'views': (const Size(412, 2400), Builder(builder: (_) {
        app.current = app.conversations.firstWhere((c) => c.id == 'c5');
        return const HomeShell();
      })),
    };
    final failed = <String>[];
    for (final e in shots.entries) {
      try {
        await _shot(tester, e.key, e.value.$1, e.value.$2);
        // ignore: avoid_print
        print('Bild: ${e.key}');
      } catch (err) {
        failed.add(e.key);
        // ignore: avoid_print
        print('Bild ${e.key} fehlgeschlagen: $err');
      }
      // Fehler eines Bilds nicht ins nächste tragen
      FlutterError.onError = FlutterError.presentError;
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pumpWidget(const SizedBox());
    // ignore: avoid_print
    print('Fertig, fehlgeschlagen: $failed');
  });
}
