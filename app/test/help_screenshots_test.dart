// Erzeugt die Bildschirmfotos für die Hilfe (assets/help/*.png) mit Beispieldaten.
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
            {'title': 'Offenes Modell schlägt Größere bei Code', 'link': 'https://futurezone.at/a', 'note': 'futurezone.at'},
            {'title': 'AI Act: Leitlinien für Hochrisiko-KI', 'link': 'https://derstandard.at/b', 'note': 'derstandard.at'},
            {'title': 'Smartphone-Chips verdoppeln KI-Tempo', 'link': 'https://heise.de/c', 'note': 'heise.de'},
          ]),
    ]);
  final c2 = Conversation(id: 'c2', title: 'Präsentation: Lokale KI im Unternehmen')..updated = now.subtract(const Duration(hours: 3));
  final c3 = Conversation(id: 'c3', title: 'Angebote Staubsauger-Roboter')..updated = now.subtract(const Duration(days: 1));
  final c4 = Conversation(id: 'c4', title: 'Mail an Sarah wegen Workshop')..updated = now.subtract(const Duration(days: 2));
  app.conversations = [c1, c2, c3, c4];
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
  app.flows.state['f1'] = {'n1': 'done', 'n2': 'done', 'n3': 'done', 'n4': 'running', 'n5': 'pending', 'n6': 'done'};

  await app.memory.add('Arbeitet in Wien als Solution Manager für KI.', category: 'person');
  await app.memory.add('Mag kurze Antworten mit Stichpunkten.', category: 'vorliebe');
  await app.memory.add('Montags um 9 Uhr Team-Meeting.', category: 'routine', confirmed: false);
}

Future<void> _shot(WidgetTester tester, String name, Size size, Widget home) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(AppScope(
    controller: app,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.dark,
      home: home,
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('../assets/help/$name.png'));
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

  testWidgets('Hilfe-Bildschirmfotos', (tester) async {
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
      'overview': (const Size(1440, 880), const HomeShell()),
      'chat': (const Size(420, 860), const HomeShell()),
      'tasks': (const Size(1080, 780), const TasksPage()),
      'prompts': (const Size(1080, 640), const PromptsPage()),
      'watch': (const Size(1080, 760), const WatchlistPage()),
      'flows': (const Size(1320, 760), const FlowEditor(id: 'f1')),
      'providers': (const Size(1240, 900), const SettingsPage(initial: 'providers')),
      'knowledge': (const Size(1080, 760), const KnowledgePage()),
      'systemcheck': (const Size(1080, 820), const SystemCheckPage()),
      'help': (const Size(1240, 800), const HelpPage(initial: 'flows')),
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
