// Zentraler App-Zustand: Modelle, Engine, Profile, Tools, Chats, Agenten-Lauf.

import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:agent_engine/agent_engine.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../data/models.dart';
import '../data/storage.dart';
import 'background_work.dart';
import 'loose_ends.dart';
import 'conversation_mode.dart';
import 'browser_service.dart';
import 'device_bridge.dart';
import 'sync_service.dart';
import 'update_service.dart';
import '../tools/chart_render.dart';
import '../tools/save_prompt_tool.dart';
import 'activity_log.dart';
import 'automation.dart';
import 'connections.dart';
import 'memory_store.dart';
import 'smtp.dart';
import 'vault.dart';
import 'native_files.dart';
import 'voice_service.dart';

enum InternetMode {
  off('Internet aus'),
  ask('Jedes Mal fragen'),
  allowed('Für diesen Chat erlaubt');

  const InternetMode(this.label);
  final String label;
}

enum EngineStatus { none, loading, ready, error }

const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'heic'};

/// Bilddatei anhand der Endung.
bool isImageFile(String name) => _imageExts.contains(name.split('.').last.toLowerCase());

/// Antwort auf die Frage nach Internetzugriff.
enum NetworkChoice { once, chat, deny }

class DownloadState {
  DownloadState(this.entry);
  final CatalogEntry entry;
  final cancel = CancelToken();
  DownloadProgress? progress;
  String? error;
  bool extracting = false;
  bool get active => error == null;
}

class AppController extends ChangeNotifier with WidgetsBindingObserver {
  late final Storage storage;
  late final DeviceProfile device;
  AppSettings settings = AppSettings();
  List<AgentProfile> profiles = [];
  List<StoredModel> models = [];
  List<Conversation> conversations = [];
  Conversation? current;
  List<SavedPrompt> prompts = [];
  List<McpServerConfig> mcpServers = [];
  final Map<String, McpClient> _mcpClients = {};
  Timer? _scheduleTimer;
  final List<String> _promptQueue = [];
  /// Läuft ohne Oberfläche (Android-Hintergrund-Engine für geplante Prompts)
  bool headless = false;

  late final List<AgentTool> tools;

  // Gedächtnis & Wissensbasis
  late final MemoryStore memory;

  // ------------------------------------------------------------- Tresor für MCP-Anmeldungen

  static const _mcpSecretKeys = {'access_token', 'refresh_token', 'client_secret', 'id_token'};

  /// Anmelde-Tokens und Schlüssel-Header liegen im Tresor, nicht in mcp.json.
  Future<void> _saveMcp() async {
    final stripped = <McpServerConfig>[];
    for (final m in mcpServers) {
      final secrets = <String, String>{
        for (final e in m.oauth.entries)
          if (_mcpSecretKeys.contains(e.key)) e.key: e.value,
        for (final e in m.headers.entries) 'header:${e.key}': e.value,
      };
      try {
        await Vault.write('mcp:${m.id}', secrets.isEmpty ? null : jsonEncode(secrets));
      } catch (e) {
        appLog('Tresor', 'MCP ${m.name}: $e', error: true);
        stripped.add(m); // Tresor nicht verfügbar: lieber wie bisher speichern als Anmeldung verlieren
        continue;
      }
      final copy = McpServerConfig.fromJson(m.toJson());
      copy.oauth.removeWhere((k, _) => _mcpSecretKeys.contains(k));
      copy.headers.clear();
      if (secrets.isNotEmpty) copy.oauth['in_vault'] = '1';
      stripped.add(copy);
    }
    await storage.saveMcpServers(stripped);
  }

  Future<void> _loadMcpSecrets() async {
    var migrate = false;
    for (final m in mcpServers) {
      final raw = await Vault.read('mcp:${m.id}');
      if (raw != null) {
        try {
          final j = (jsonDecode(raw) as Map).cast<String, String>();
          for (final e in j.entries) {
            if (e.key.startsWith('header:')) {
              m.headers[e.key.substring(7)] = e.value;
            } else {
              m.oauth[e.key] = e.value;
            }
          }
        } catch (_) {}
      } else if (m.headers.isNotEmpty || m.oauth.keys.any(_mcpSecretKeys.contains)) {
        migrate = true; // alte Installation: Geheimnisse noch in mcp.json → in den Tresor
      }
      m.oauth.remove('in_vault');
    }
    if (migrate) await _saveMcp();
  }

  /// „Was hat der Agent getan?“
  late final ActivityLog activity;

  /// Watchlist (Seiten/Themen beobachten) und Prozesse (Workflows).
  late final WatchlistService watchlist = WatchlistService(this);
  late final FlowService flows = FlowService(this);
  late final ConnectionStore connections = ConnectionStore(this);

  Future<void> logActivity(Activity a) async {
    await activity.add(a);
    notifyListeners();
  }
  late final KnowledgeBase knowledge;
  String? knowledgeProgress; // Statuszeile beim Laden von Quellen
  CancelToken? _knowledgeCancel;

  // Systemcheck & Downloads
  int freeDisk = -1;
  final Map<String, DownloadState> downloads = {};
  final _downloader = Downloader();

  // Sprache
  late final VoiceService voice;
  late final ConversationMode conversation = ConversationMode(this);
  late final DeviceBridge deviceBridge = DeviceBridge(countryCodeOf: () => settings.countryCode);

  /// Eingebauter Browser, den der Agent bedient.
  late final BrowserService browser =
      BrowserService(confirmer: (t, d) => deviceBridge.confirm(t, d), currentChat: () => current?.id);

  /// Schnellstart-Aktion (Startbildschirm-Knopf, Dock-Menü): "conversation", "newchat", "prompt:<id>"
  final pendingLaunch = ValueNotifier<String?>(null);

  /// Text für das Eingabefeld (z. B. aus „Teilen an Junels“)
  final pendingInput = ValueNotifier<String?>(null);
  Timer? _watchTimer;
  late final SyncService sync = SyncService(this);
  late final UpdateService updates = UpdateService(storage.root);

  /// Wird von der Oberfläche gesetzt: fragt den Nutzer nach Internetzugriff.
  Future<NetworkChoice> Function(String purpose)? consentHandler;
  bool _turnInternetAllowed = false;

  // Engine
  LlamaEngine? engine;
  StoredModel? loadedModel;
  EngineStatus status = EngineStatus.none;
  String? statusMessage;
  double? importProgress;

  // Lauf
  bool running = false;

  /// Chat, in dem gerade eine Antwort entsteht.
  String? runningConvId;

  /// Läuft die Antwort im gerade angezeigten Chat?
  bool get runningHere => running && runningConvId != null && runningConvId == current?.id;

  /// Nachrichten, die warten, bis die laufende Antwort fertig ist (aus anderen Chats).
  final List<({Conversation conv, String text, List<Attachment> docs, ChatEntry placeholder})> _queue = [];

  bool isQueued(ChatEntry e) => _queue.any((q) => identical(q.placeholder, e));

  /// Seit wann die aktuelle Antwort läuft bzw. das Modell lädt (für die Zeitanzeige).
  DateTime? runStarted;
  DateTime? loadStarted;
  AgentRunner? _runner;

  /// Antwort, an der gerade gearbeitet wird, und Kommentare, die der Nutzer währenddessen schrieb.
  ChatEntry? _runningAnswer;
  final List<ChatEntry> _noteEntries = [];
  final Map<String, List<Attachment>> _attachments = {};
  GenerationStats? lastStats;
  double? lastTokensPerSecond;
  bool inspectorAttention = false;

  // Erzeugte Dateien, Bilder, Bildverständnis
  late final Directory outputsDir;
  late final Directory attachmentsDir;
  ImageEngine? _imageEngine;
  Timer? _imageIdle;
  /// Fortschritt der Bildgenerierung, z. B. "Bild wird erzeugt … 2/4"
  String? imageProgress;
  /// Bildbeschreibungen je Bildpfad (Bildverständnis), damit ein Bild nur einmal angesehen wird
  final Map<String, String> _imageNotes = {};

  // Speicher
  int processMemory = 0;
  int availableMemory = 0;
  int peakProcessMemory = 0;
  Timer? _memTimer;

  /// Getrennt vom restlichen Zustand, damit nicht die ganze App bei jedem Token neu baut.
  final ValueNotifier<bool?> darkMode = ValueNotifier(null);

  bool initialized = false;
  String? initError;

  // ------------------------------------------------------------------ Start

  Future<void> init() async {
    try {
      WidgetsBinding.instance.addObserver(this);
      storage = await Storage.open();
      device = DeviceProfile.detect();
      voiceLogFile = File('${storage.documentsDir.path}/junels_log.txt');
      voice = VoiceService(await getTemporaryDirectory());
      memory = MemoryStore(File('${storage.root.path}/memory.json'));
      await memory.load();
      activity = ActivityLog(File('${storage.root.path}/activity.json'));
      await activity.load();
      knowledge = KnowledgeBase(Directory('${storage.root.path}/knowledge'));
      await knowledge.load();
      outputsDir = Directory('${storage.documentsDir.path}/Ausgaben')..createSync(recursive: true);
      attachmentsDir = Directory('${storage.documentsDir.path}/Anhänge')..createSync(recursive: true);
      final out = OutputSpace(
        outputsDir,
        extraImages: () => {
          for (final a in attachments)
            if (a.path != null && isImageFile(a.name)) a.name: a.path!,
        },
        // Präsentationen/Dokumente bekommen ihre Bilder automatisch, sobald ein Bildmodell geladen und eingeschaltet ist
        imageGenerator: () =>
            imageModel != null && ImageEngine.available && settings.enabledTools.contains('generate_image') ? _generateImage : null,
        maxAutoImages: Platform.isAndroid || Platform.isIOS ? 3 : 6,
        decodeImage: _decodeRgba,
      );
      tools = [
        ...builtinTools(),
        ...networkTools(),
        RememberTool((f, category) async {
          // Sensible Themen nur, wenn ausdrücklich erlaubt
          if (!settings.memorySensitive && MemoryNote.sensitive.hasMatch(f)) {
            return 'Nicht gespeichert: sensibles Thema (Gesundheit, Finanzen, Religion, Politik …). '
                'Der Nutzer kann das in „Wissen & Gedächtnis“ erlauben.';
          }
          await memory.add(f, category: category, confirmed: !settings.memoryConfirm);
          unawaited(logActivity(Activity(kind: 'memory', title: 'Notiz fürs Gedächtnis', detail: f,
              approval: settings.memoryConfirm ? 'Wartet auf deine Bestätigung' : 'Automatisch (Bestätigung aus)')));
          notifyListeners();
          return settings.memoryConfirm
              ? 'Vorgemerkt: „$f“ – der Nutzer bestätigt es unter Wissen & Gedächtnis, dann gilt es.'
              : 'Gemerkt: $f';
        }),
        HistorySearchTool(_searchHistory),
        KnowledgeSearchTool(knowledge),
        CreateDocumentTool(out),
        CreatePresentationTool(out),
        EditFileTool(out),
        LooseEndsTool(this),
        CreateChartTool(out, renderChart),
        GenerateImageTool(_generateImage),
        LookAtImageTool(_askAboutImage),
        NotifyTool((title, text, at) async {
          await BackgroundWork.requestNotifyPermission();
          await BackgroundWork.notify(title, text, conversationId: current?.id, at: at);
        }),
        SavePromptTool(savePrompt, () => prompts),
        WeatherTool(defaultLocation: () => settings.homeCity),
        NewsTool(),
        SiteSearchTool(),
        BrowserTool(() => headless ? null : browser),
        ContactsTool(deviceBridge),
        EmailTool(deviceBridge),
        WhatsAppTool(deviceBridge),
        CallTool(deviceBridge),
        CalendarAddTool(deviceBridge),
        CalendarListTool(deviceBridge),
        FileSearchTool(deviceBridge),
        FileRenameTool(deviceBridge),
        FileMoveTool(deviceBridge),
      ];
      refreshFreeDisk();
      settings = await storage.loadSettings();
      darkMode.value = settings.darkMode;
      settings.contextSize = device.clampContext(settings.contextSize, null);
      profiles = await storage.loadProfiles();
      if (!profiles.any((p) => p.id == settings.activeProfileId)) {
        settings.activeProfileId = profiles.first.id;
      }
      models = await storage.loadModels();
      prompts = await storage.loadPrompts();
      var migrated = false;
      for (final p in prompts) {
        if (p.text.contains('dann Nachrichten mit Link.')) {
          p.text = p.text.replaceFirst('dann Nachrichten mit Link.', _morningNewsLine);
          migrated = true;
        }
      }
      if (migrated) await storage.savePrompts(prompts);
      mcpServers = await storage.loadMcpServers();
      await _loadMcpSecrets();
      conversations = await storage.loadConversations();
      await loadDesigns();
      await watchlist.load();
      await flows.load();
      await connections.load();
      // Nach längerer Pause mit neuem Chat starten, sonst im letzten weiterarbeiten
      final last = conversations.isNotEmpty ? conversations.first : null;
      current = last != null && DateTime.now().difference(last.updated) < idleNewChat ? last : null;
      if (current == null) newConversation(); // neuer Chat steht gleich in der Liste
      _pollMemory();
      _memTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollMemory());
      initialized = true;
      notifyListeners();

      if (!headless) {
        BackgroundWork.listen(
          onRunPrompt: (id) async {
            if (await runAutomation(id)) return;
            final p = prompts.where((x) => x.id == id).firstOrNull;
            if (p != null) await runPrompt(p, automated: true);
          },
          onOpenConversation: openConversationById,
        );
        _scheduleTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkSchedule());
        unawaited(BackgroundWork.takeLaunchConversation().then((id) {
          if (id != null) openConversationById(id);
        }));
        unawaited(_syncAlarms());
        Future<void>.delayed(const Duration(seconds: 5), _checkSchedule);
        Future<void>.delayed(const Duration(seconds: 8), _planFollowUps);
      }

      if (!headless) unawaited(sync.init());
      if (!headless) unawaited(updates.init());
      if (!headless) unawaited(_initDevice());
      McpOAuth.onTokens = (_) => unawaited(_saveMcp());

      if (!headless && settings.autoLoadLastModel && settings.lastModelId != null) {
        final m = models.where((x) => x.id == settings.lastModelId).firstOrNull;
        if (m != null) unawaited(loadModel(m));
      }
    } catch (e) {
      initError = e.toString();
      appLog('Start', 'Start fehlgeschlagen: $e', error: true);
      initialized = true;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _memTimer?.cancel();
    _scheduleTimer?.cancel();
    engine?.dispose();
    strongEngine?.dispose();
    _swapBack?.cancel();
    _strongIdle?.cancel();
    _typingDebounce?.cancel();
    if (initialized && initError == null) voice.dispose();
    super.dispose();
  }

  void _pollMemory() {
    try {
      processMemory = LlamaEngine.processMemory();
      availableMemory = LlamaEngine.availableMemory();
      if (processMemory > peakProcessMemory) peakProcessMemory = processMemory;
      notifyListeners();
    } catch (_) {
      // native Bibliothek nicht verfügbar
    }
  }

  // Android arbeitet dank Vordergrunddienst weiter; iPadOS würde die App einfrieren,
  // dort wird die Generierung sauber angehalten.
  /// So lange ohne Nutzung → beim nächsten Öffnen ein neuer Chat.
  static const idleNewChat = Duration(minutes: 30);
  DateTime? _backgroundSince;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (Platform.isIOS && (state == AppLifecycleState.paused || state == AppLifecycleState.hidden)) {
      if (running) stop();
    }
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _backgroundSince ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundSince;
      _backgroundSince = null;
      final c = current;
      if (since != null && !running && c != null && c.entries.isNotEmpty &&
          DateTime.now().difference(since) >= idleNewChat && DateTime.now().difference(c.updated) >= idleNewChat) {
        newConversation();
      }
    }
  }

  @override
  void didHaveMemoryPressure() {
    // Android meldet das bei großen Modellen ständig (onTrimMemory) – nicht abbrechen,
    // nur protokollieren. Wird es wirklich knapp, beendet das System selbst.
    voiceLog('Hinweis: System meldet Speicherdruck${running ? ' (Antwort läuft weiter)' : ''}');
  }

  // --------------------------------------------------------------- Getter

  AgentProfile get activeProfile =>
      profiles.firstWhere((p) => p.id == settings.activeProfileId, orElse: () => profiles.first);

  bool get needsSystemCheck => !settings.systemCheckSeen && models.isEmpty;

  /// Tools des Profils; Internet-Tools nur, wenn der Nutzer sie eingeschaltet hat.
  List<AgentTool> get activeTools => activeProfile.useTools
      ? [
          ...tools
              .where((t) => settings.enabledTools.contains(t.name))
              .where((t) => t.name != 'knowledge_search' || !knowledge.isEmpty)
              .where(_toolAvailableHere),
          ...mcpTools,
        ]
      : const [];

  static const _phoneTools = {'contacts_search', 'compose_email', 'compose_whatsapp', 'call_phone', 'calendar_add', 'calendar_list'};
  static const _macFileTools = {'file_search', 'file_rename', 'file_move'};

  bool _toolAvailableHere(AgentTool t) {
    if (_phoneTools.contains(t.name)) return DeviceBridge.supported;
    if (_macFileTools.contains(t.name)) return Platform.isMacOS && settings.grantedFolders.isNotEmpty;
    return true;
  }

  /// Tools aller aktiven MCP-Server (aus dem Zwischenspeicher, offline verfügbar).
  List<AgentTool> get mcpTools => [
        for (final srv in mcpServers)
          if (srv.enabled)
            for (final t in srv.tools)
              if (t.enabled) McpTool(srv, t, _mcpClients),
      ];

  /// Ein bestimmtes Tool eines MCP-Servers (auch wenn es für den Chat ausgeschaltet ist) – für Prozesse.
  AgentTool? mcpToolFor(String serverId, String toolName) {
    final srv = mcpServers.where((s) => s.id == serverId).firstOrNull;
    final spec = srv?.tools.where((t) => t.name == toolName).firstOrNull;
    if (srv == null || spec == null) return null;
    return McpTool(srv, spec, _mcpClients);
  }

  // ------------------------------------------------------------- MCP-Server

  Future<void> saveMcpServer(McpServerConfig srv) async {
    final i = mcpServers.indexWhere((x) => x.id == srv.id);
    if (i >= 0) {
      mcpServers[i] = srv;
    } else {
      mcpServers.add(srv);
    }
    await _mcpClients.remove(srv.id)?.close();
    await _saveMcp();
    notifyListeners();
  }

  Future<void> removeMcpServer(McpServerConfig srv) async {
    mcpServers.removeWhere((x) => x.id == srv.id);
    await _mcpClients.remove(srv.id)?.close();
    await _saveMcp();
    notifyListeners();
  }

  /// Server, die eine Anmeldung brauchen (id → WWW-Authenticate-Hinweis).
  final Map<String, String> mcpNeedsLogin = {};

  /// Anmeldung im Browser (OAuth), danach Tools laden.
  Future<String?> loginMcpServer(McpServerConfig srv) async {
    try {
      await BackgroundWork.begin('mcp-login', 'Warte auf Anmeldung bei ${srv.name} …');
      await McpOAuth.login(srv,
          wwwAuthenticate: mcpNeedsLogin[srv.id], openBrowser: (u) => NativeFiles.openUrl(u.toString()));
      mcpNeedsLogin.remove(srv.id);
      appLog('MCP', '${srv.name}: angemeldet');
      await _saveMcp();
      return await syncMcpServer(srv);
    } catch (e) {
      appLog('MCP', '${srv.name}: Anmeldung fehlgeschlagen: $e', error: true);
      return '$e';
    } finally {
      await BackgroundWork.end('mcp-login');
      notifyListeners();
    }
  }

  Future<void> logoutMcpServer(McpServerConfig srv) async {
    McpOAuth.logout(srv);
    await _mcpClients.remove(srv.id)?.close();
    await _saveMcp();
    notifyListeners();
  }

  /// Verbindet sich mit dem Server und lädt die Tool-Liste (vom Nutzer ausgelöst).
  Future<String?> syncMcpServer(McpServerConfig srv) async {
    await _mcpClients.remove(srv.id)?.close();
    final c = McpClient(srv, timeout: const Duration(seconds: 30));
    try {
      final info = await c.initialize();
      final list = await c.listTools();
      final previous = {for (final t in srv.tools) t.name: t.enabled};
      for (final t in list) {
        // bekannte Auswahl behalten; neue Tools bei großen Servern erst einmal aus
        t.enabled = previous[t.name] ?? list.length <= 10;
      }
      srv.tools = list;
      srv.lastSync = DateTime.now();
      final si = info['serverInfo'];
      if (srv.name.trim().isEmpty && si is Map && si['name'] is String) srv.name = si['name'] as String;
      _mcpClients[srv.id] = c;
      mcpNeedsLogin.remove(srv.id);
      await saveMcpServer(srv);
      _mcpClients[srv.id] = c;
      return null;
    } on McpAuthException catch (e) {
      await c.close();
      mcpNeedsLogin[srv.id] = e.wwwAuthenticate ?? '';
      notifyListeners();
      return 'Anmeldung nötig – tippe auf „Anmelden“.';
    } catch (e) {
      await c.close();
      return e.toString();
    }
  }

  List<Attachment> get attachments => _attachments[current?.id ?? ''] ?? const [];

  List<Artifact> get artifacts =>
      [for (final a in current?.artifacts ?? const <Map<String, dynamic>>[]) Artifact.fromJson(a)];

  List<int> get contextOptions =>
      [1024, 2048, 4096, 8192, 16384].where((c) => c <= device.maxContext).toList();

  /// Gewünschte Context-Größe (automatisch = Maximum der Geräteklasse).
  int get contextTarget => settings.contextAuto ? device.maxContext : settings.contextSize;

  // ---------------------------------------------------------------- Modelle

  Future<GgufInfo> inspectModel(String path) => GgufInfo.read(path);

  /// Passt ein geladenes Modell grob in den Arbeitsspeicher? (wie im Systemcheck)
  bool modelFitsMemory(StoredModel m) =>
      DeviceProfile.estimateRuntimeBytes(m.sizeBytes) <= device.memoryBudget(availableMemory);

  FitResult checkFit(GgufInfo info) => device.checkFit(info, device.clampContext(contextTarget, info));

  /// Übernimmt eine geprüfte Datei. [fromPickerCache]: Datei liegt in einem
  /// temporären Verzeichnis des Datei-Wählers und darf verschoben werden.
  Future<StoredModel> importModel(GgufInfo info, String fileName, {required bool fromPickerCache}) async {
    importProgress = 0;
    notifyListeners();
    try {
      final file = await storage.importModelFile(info.path, fileName, move: fromPickerCache, onProgress: (p) {
        importProgress = p;
        notifyListeners();
      });
      final stored = StoredModel(
        id: newId(),
        fileName: file.uri.pathSegments.last,
        path: file.path,
        sizeBytes: info.fileSize,
        displayName: [info.name, info.sizeLabel].whereType<String>().toSet().join(' '),
        architecture: info.architecture,
        quantization: info.quantization,
        trainedContext: info.contextLength,
      );
      models.add(stored);
      await storage.saveModels(models);
      return stored;
    } finally {
      importProgress = null;
      notifyListeners();
    }
  }

  /// Übernimmt .gguf-Dateien aus dem Dokumente-Ordner ohne Kopie (iPadOS:
  /// per Finder oder Dateien-App abgelegt). Gibt die Anzahl neuer Modelle zurück.
  Future<({int added, List<String> errors})> scanDocumentsFolder() async {
    final known = models.map((m) => m.path).toSet();
    var added = 0;
    final errors = <String>[];
    for (final f in await storage.ggufInDocuments()) {
      if (known.contains(f.path)) continue;
      try {
        final info = await GgufInfo.read(f.path);
        models.add(StoredModel(
          id: newId(),
          fileName: f.uri.pathSegments.last,
          path: f.path,
          sizeBytes: info.fileSize,
          displayName: [info.name, info.sizeLabel].whereType<String>().toSet().join(' '),
          architecture: info.architecture,
          quantization: info.quantization,
          trainedContext: info.contextLength,
        ));
        added++;
      } catch (e) {
        errors.add('${f.uri.pathSegments.last}: $e');
      }
    }
    if (added > 0) await storage.saveModels(models);
    notifyListeners();
    return (added: added, errors: errors);
  }

  Future<void> deleteModel(StoredModel m) async {
    if (loadedModel?.id == m.id) await unloadModel();
    models.removeWhere((x) => x.id == m.id);
    await storage.saveModels(models);
    try {
      await File(m.path).delete();
    } catch (_) {}
    if (settings.lastModelId == m.id) {
      settings.lastModelId = null;
      await storage.saveSettings(settings);
    }
    notifyListeners();
  }

  Future<void> loadModel(StoredModel m, {bool remember = true}) async {
    if (status == EngineStatus.loading || running) return;
    if (remember) _swapBack?.cancel();
    if (strongResident?.id == m.id) await _disposeStrong();
    status = EngineStatus.loading;
    loadStarted = DateTime.now();
    statusMessage = 'Lade ${m.displayName} …';
    notifyListeners();
    try {
      await unloadModel(notify: false);
      final info = await GgufInfo.read(m.path);
      final ctx = device.clampContext(contextTarget, info);
      final fit = device.checkFit(info, ctx);
      if (fit.level == FitLevel.refuse) throw EngineException(fit.message);
      // Selbst gewählter Context bleibt (nur wenn er gar nicht passt, wird verkleinert).
      // Automatisch: der größte, der gut passt – mindestens 4K, solange das noch geht.
      var effectiveCtx = ctx;
      if (settings.contextAuto && fit.level == FitLevel.warn) {
        final options = [32768, 16384, 8192, 6144, 4096, 3072, 2048].where((c) => c <= ctx).toList();
        effectiveCtx = options.firstWhere((c) => device.checkFit(info, c).level == FitLevel.ok,
            orElse: () => options.firstWhere((c) => c >= 4096 && device.checkFit(info, c).level != FitLevel.refuse,
                orElse: () => options.isEmpty ? ctx : options.last));
      }
      final sw = Stopwatch()..start();
      engine = await LlamaEngine.load(device.engineConfig(m.path, effectiveCtx));
      sw.stop();
      loadedModel = m;
      status = EngineStatus.ready;
      statusMessage = '${m.displayName} geladen in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s'
          '${fit.level == FitLevel.warn ? ' – ${fit.message}' : ''}';
      if (remember) {
        settings.lastModelId = m.id;
        await storage.saveSettings(settings);
      }
      appLog('Modell', '${m.displayName} geladen in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s, '
          'Context ${engine!.contextSize}, ${device.threads} Threads');
      if (!headless) unawaited(warmUp().then((_) => _preloadStrongIfRoomy()));
    } catch (e) {
      engine = null;
      loadedModel = null;
      status = EngineStatus.error;
      statusMessage = 'Laden fehlgeschlagen: $e';
      appLog('Modell', 'Laden von ${m.displayName} fehlgeschlagen: $e', error: true);
    }
    _pollMemory();
    notifyListeners();
  }

  Future<void> unloadModel({bool notify = true}) async {
    final e = engine;
    engine = null;
    loadedModel = null;
    status = EngineStatus.none;
    if (e != null) await e.dispose();
    if (notify) notifyListeners();
  }

  /// Einstellungen des Gesprächsmodus ändern und speichern.
  Future<void> setVoiceOptions(
      {bool? manualEnd, int? pauseMs, bool? nearField, bool? smartVad, String? agentName, bool? wakeWord, bool? bargeIn}) async {
    if (bargeIn != null) settings.voiceBargeIn = bargeIn;
    if (smartVad != null) settings.voiceSmartVad = smartVad;
    if (agentName != null && agentName.trim().isNotEmpty) settings.agentName = agentName.trim();
    if (wakeWord != null) settings.voiceWakeWord = wakeWord;
    if (manualEnd != null) settings.voiceManualEnd = manualEnd;
    if (pauseMs != null) settings.voicePauseMs = pauseMs;
    if (nearField != null) settings.voiceNearField = nearField;
    await storage.saveSettings(settings);
    conversation.applySettings();
    notifyListeners();
  }

  /// [size] <= 0 = automatisch.
  Future<void> setContextSize(int size) async {
    settings.contextAuto = size <= 0;
    if (size > 0) settings.contextSize = device.clampContext(size, null);
    await storage.saveSettings(settings);
    notifyListeners();
    // gleich mit der neuen Größe neu laden, damit die Einstellung wirkt
    final m = loadedModel;
    if (m != null && !running && status == EngineStatus.ready) await loadModel(m);
  }

  // ------------------------------------------------------ Systemcheck & Downloads

  void refreshFreeDisk() {
    try {
      freeDisk = SttEngine.freeDiskBytes(storage.root.path);
    } catch (_) {
      freeDisk = -1;
    }
  }

  Future<void> markSystemCheckSeen() async {
    if (settings.systemCheckSeen) return;
    settings.systemCheckSeen = true;
    await storage.saveSettings(settings);
  }

  List<Recommendation> recommendations(ModelKind kind) =>
      recommendFor(kind, device, freeDiskBytes: freeDisk, availableMemory: LlamaEngine.availableMemory());

  /// Fertiges Modell-Set „Handy“ oder „Desktop“: je Art die Empfehlung für diesen Gerätetyp –
  /// aber nur, was laut Systemcheck auf DIESEM Gerät läuft (sonst die Empfehlung fürs Gerät).
  List<CatalogEntry> modelSet({required bool mobile}) {
    final d = device;
    final prof = DeviceProfile(
      deviceClass: d.deviceClass,
      totalMemory: d.totalMemory,
      maxContext: d.maxContext,
      threads: d.threads,
      gpuLayers: d.gpuLayers,
      quantizeKv: d.quantizeKv,
      isMobile: mobile,
    );
    final avail = LlamaEngine.availableMemory();
    final out = <CatalogEntry>[];
    for (final kind in const [ModelKind.llm, ModelKind.stt, ModelKind.tts]) {
      final here = recommendFor(kind, d, freeDiskBytes: freeDisk, availableMemory: avail);
      bool runsHere(CatalogEntry e) => here.any((r) =>
          r.entry.id == e.id && (r.suitability == Suitability.recommended || r.suitability == Suitability.suitable));
      CatalogEntry? pick;
      if (kind == ModelKind.tts) {
        // Stimme: am Desktop Kokoro Martin, am Handy die kompakte Kokoro Victoria, sonst Piper
        final pref = mobile ? ['kokoro-de-victoria', 'piper-de-thorsten'] : ['kokoro-de-martin', 'kokoro-de-victoria', 'piper-de-thorsten'];
        pick = [for (final id in pref) ...modelCatalog.where((e) => e.id == id && runsHere(e))].firstOrNull;
      } else {
        final recs = recommendFor(kind, prof, freeDiskBytes: freeDisk, availableMemory: avail);
        pick = recs.where((r) => r.suitability == Suitability.recommended && runsHere(r.entry)).map((r) => r.entry).firstOrNull;
      }
      pick ??= here.where((r) => r.suitability == Suitability.recommended).map((r) => r.entry).firstOrNull;
      if (pick != null) out.add(pick);
    }
    return out;
  }

  /// Lädt das Set (was fehlt) und stellt es als aktiv ein.
  Future<void> installModelSet({required bool mobile}) async {
    final set = modelSet(mobile: mobile);
    for (final e in set) {
      if (installedPath(e) == null) {
        await startDownload(e);
        if (installedPath(e) == null) continue; // abgebrochen oder fehlgeschlagen
      }
      switch (e.kind) {
        case ModelKind.stt:
          settings.sttModelId = e.id;
        case ModelKind.tts:
          settings.ttsVoiceId = e.id;
        case ModelKind.llm:
          final m = storedModelFor(e);
          if (m != null && loadedModel?.path != m.path && !running) unawaited(loadModel(m));
        case ModelKind.image:
          break;
      }
      await storage.saveSettings(settings);
      notifyListeners();
    }
  }

  /// Pfad, falls das Katalog-Modell installiert ist.
  String? installedPath(CatalogEntry e) {
    if (e.kind == ModelKind.llm) {
      final m = models.where((m) => m.catalogId == e.id || m.fileName == e.fileName).firstOrNull;
      return m?.path;
    }
    final p = settings.installed[e.id];
    if (p == null) return null;
    final exists = e.isArchive ? Directory(p).existsSync() : File(p).existsSync();
    return exists ? p : null;
  }

  StoredModel? storedModelFor(CatalogEntry e) =>
      models.where((m) => m.catalogId == e.id || m.fileName == e.fileName).firstOrNull;

  /// Startet (oder setzt fort) den Download eines Katalog-Modells.
  Future<void> startDownload(CatalogEntry e) async {
    final running = downloads[e.id];
    if (running != null && running.active) return;
    final st = DownloadState(e);
    downloads[e.id] = st;
    notifyListeners();
    unawaited(BackgroundWork.begin('dl-${e.id}', 'Lade ${e.name} herunter …'));
    try {
      final dir = switch (e.kind) {
        ModelKind.llm => storage.modelsDir.path,
        ModelKind.stt => '${storage.voiceDir.path}/whisper',
        ModelKind.tts => '${storage.voiceDir.path}/piper',
        ModelKind.image => '${storage.modelsDir.path}/bild',
      };
      Directory(dir).createSync(recursive: true);
      final existing = File('$dir/${e.fileName}');
      final file = await existing.exists()
          ? existing // vollständig geladen, z. B. wenn danach das Entpacken scheiterte
          : await _downloader.download(e.url, existing.path, cancel: st.cancel, onProgress: (p) {
              st.progress = p;
              notifyListeners();
            });
      switch (e.kind) {
        case ModelKind.llm:
          final info = await GgufInfo.read(file.path);
          models.removeWhere((m) => m.fileName == e.fileName);
          models.add(StoredModel(
            id: newId(),
            fileName: e.fileName,
            path: file.path,
            sizeBytes: info.fileSize,
            displayName: e.name,
            architecture: info.architecture,
            quantization: info.quantization,
            trainedContext: info.contextLength,
            catalogId: e.id,
          ));
          await storage.saveModels(models);
        case ModelKind.stt:
          if (e.isArchive) {
            // sherpa-onnx-Erkenner (Canary, Parakeet) kommen als Archiv
            st.extracting = true;
            notifyListeners();
            await _extractInBackground(file.path, dir);
            await file.delete();
            settings.installed[e.id] = '$dir/${e.folderName}';
          } else {
            settings.installed[e.id] = file.path;
          }
          settings.sttModelId ??= e.id;
          await storage.saveSettings(settings);
        case ModelKind.image:
          settings.installed[e.id] = file.path;
          await storage.saveSettings(settings);
        case ModelKind.tts:
          st.extracting = true;
          notifyListeners();
          // Entpacken (bzip2) im Hintergrund-Isolate, damit die UI flüssig bleibt
          await _extractInBackground(file.path, dir);
          await file.delete();
          settings.installed[e.id] = '$dir/${e.folderName}';
          settings.ttsVoiceId ??= e.id;
          await storage.saveSettings(settings);
      }
      downloads.remove(e.id);
    } on DownloadCancelled {
      downloads.remove(e.id);
    } catch (err) {
      st.error = err.toString();
    } finally {
      unawaited(BackgroundWork.end('dl-${e.id}'));
    }
    refreshFreeDisk();
    notifyListeners();
  }

  void cancelDownload(CatalogEntry e) => downloads[e.id]?.cancel.cancel();

  /// Lädt ein beliebiges GGUF-Modell von einer Adresse (z. B. Hugging Face „resolve“-Link).
  /// Gibt eine Fehlermeldung zurück oder null.
  String? downloadCustomUrl(String raw) {
    var url = raw.trim();
    // Hugging-Face-Seitenlink (…/blob/main/…) in Download-Link umwandeln
    url = url.replaceFirst('/blob/', '/resolve/');
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isScheme('https')) return 'Bitte eine https-Adresse angeben.';
    final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    if (!name.toLowerCase().endsWith('.gguf')) return 'Die Adresse muss auf eine .gguf-Datei zeigen.';
    final entry = CatalogEntry(
      id: 'custom:$name',
      kind: ModelKind.llm,
      name: name.replaceAll('.gguf', ''),
      description: 'Eigener Download',
      url: uri.toString(),
      fileName: name,
      sizeBytes: 0,
      minClass: DeviceClass.s,
    );
    unawaited(startDownload(entry));
    return null;
  }

  List<DownloadState> get customDownloads =>
      downloads.values.where((d) => d.entry.id.startsWith('custom:')).toList();

  /// Löscht ein heruntergeladenes Sprach-Modell bzw. eine Stimme.
  Future<void> removeVoiceModel(CatalogEntry e) async {
    final p = settings.installed.remove(e.id);
    if (p != null) {
      try {
        if (e.isArchive) {
          await Directory(p).delete(recursive: true);
        } else {
          await File(p).delete();
        }
      } catch (_) {}
    }
    if (settings.sttModelId == e.id) settings.sttModelId = null;
    if (settings.ttsVoiceId == e.id) settings.ttsVoiceId = null;
    await storage.saveSettings(settings);
    refreshFreeDisk();
    notifyListeners();
  }

  // ---------------------------------------------------------------- Sprache

  String? get sttModelPath {
    final id = settings.sttModelId;
    if (id == null) return null;
    final p = settings.installed[id];
    return p != null && (File(p).existsSync() || Directory(p).existsSync()) ? p : null;
  }

  String? get ttsVoicePath {
    final id = settings.ttsVoiceId;
    if (id == null) return null;
    final p = settings.installed[id];
    return p != null && Directory(p).existsSync() ? p : null;
  }

  Future<void> setVoiceSettings({
    String? sttModelId,
    String? ttsVoiceId,
    String? systemVoice,
    String? sttLanguage,
    bool? autoSpeak,
    bool? sendAfterVoice,
  }) async {
    if (sttModelId != null) settings.sttModelId = sttModelId;
    if (ttsVoiceId != null) settings.ttsVoiceId = ttsVoiceId;
    if (systemVoice != null) settings.systemVoice = systemVoice;
    if (sttLanguage != null) settings.sttLanguage = sttLanguage;
    if (autoSpeak != null) settings.autoSpeak = autoSpeak;
    if (sendAfterVoice != null) settings.sendAfterVoice = sendAfterVoice;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  /// Aufnahme beenden und Text erkennen.
  Future<String> finishVoiceInput() async {
    final path = sttModelPath;
    if (path == null) throw Exception('Kein Whisper-Modell installiert (Systemcheck).');
    final t = await voice.stopAndTranscribe(
      modelPath: path,
      language: settings.sttLanguage,
      threads: device.threads,
    );
    return t.text;
  }

  /// Vorlesen: Piper, falls installiert, sonst die Systemstimme.
  Future<void> speakText(String text, {Object? key}) async {
    final lang = settings.sttLanguage == 'en' ? 'en' : 'de';
    voice.output.systemVoice = settings.systemVoice;
    await voice.speak(text, voiceDir: ttsVoicePath, key: key, language: lang);
    final err = voice.output.lastError.value;
    if (err != null) {
      voice.output.lastError.value = null;
      statusMessage = err;
      notifyListeners();
    }
  }

  // ------------------------------------------------- Gedächtnis & Verlauf

  List<String> _searchHistory(String query) => searchConversations(query, [
        for (final c in conversations)
          if (c.id != current?.id)
            (
              title: c.title,
              date: c.updated,
              messages: [for (final e in c.entries) if (e.text.isNotEmpty) (role: e.role, text: e.text)],
            ),
      ]);

  Future<void> addMemory(String text) async {
    await memory.add(text);
    notifyListeners();
  }

  Future<void> confirmMemory(MemoryNote n) async {
    await memory.confirm(n);
    unawaited(logActivity(Activity(kind: 'memory', title: 'Gedächtnis-Eintrag bestätigt', detail: n.text, approval: 'Von dir bestätigt')));
    notifyListeners();
  }

  Future<void> setMemoryCategory(MemoryNote n, String category) async {
    await memory.setCategory(n, category);
    notifyListeners();
  }

  Future<void> setMemoryOptions({bool? confirm, bool? sensitive}) async {
    if (confirm != null) settings.memoryConfirm = confirm;
    if (sensitive != null) settings.memorySensitive = sensitive;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  Future<void> removeMemory(MemoryNote n) async {
    await memory.remove(n);
    notifyListeners();
  }

  /// Gesprächsmodus: Antwort wurde nach [spoken] unterbrochen.
  Future<void> markLastAnswerInterrupted(String spoken) async {
    final c = current;
    if (c == null || c.entries.isEmpty) return;
    final last = c.entries.last;
    if (last.role != 'assistant') return;
    last
      ..text = spoken.trim().isEmpty ? '…(unterbrochen)' : '${spoken.trim()} …(unterbrochen)'
      ..truncated = true;
    await storage.saveConversation(c);
    notifyListeners();
  }

  // --------------------------------------------------------- Wissensbasis

  /// Lädt eine Webseite (optional mit Unterseiten) in die Wissensbasis.
  Future<String?> addWebSource(String raw, {bool followLinks = false}) async {
    var url = raw.trim();
    if (!url.startsWith('http')) url = 'https://$url';
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return 'Ungültige Adresse.';
    final cancel = _knowledgeCancel = CancelToken();
    knowledgeProgress = 'Lade ${uri.host} …';
    notifyListeners();
    try {
      final pages = await crawlSite(uri,
          followLinks: followLinks,
          maxPages: followLinks ? 30 : 1,
          cancelled: () => cancel.isCancelled, onProgress: (n, u) {
        knowledgeProgress = '$n Seite(n) geladen – $u';
        notifyListeners();
      });
      if (pages.isEmpty) return 'Auf der Seite wurde kein Text gefunden.';
      final existing = knowledge.sources.where((s) => s.origin == uri.toString()).firstOrNull;
      final src = KnowledgeSource(
        id: existing?.id ?? newId(),
        name: pages.first.title.isEmpty ? uri.host : pages.first.title,
        origin: uri.toString(),
        kind: 'web',
        crawl: followLinks,
      );
      knowledge.putSource(src, [for (final p in pages) (title: p.title, url: p.url, text: p.text)]);
      await knowledge.save();
      return null;
    } catch (e) {
      return 'Laden fehlgeschlagen: $e';
    } finally {
      knowledgeProgress = null;
      _knowledgeCancel = null;
      notifyListeners();
    }
  }

  void cancelKnowledgeLoad() => _knowledgeCancel?.cancel();

  Future<String?> refreshSource(KnowledgeSource s) =>
      s.kind == 'web' ? addWebSource(s.origin, followLinks: s.crawl) : Future.value('Dateien bitte neu hinzufügen.');

  /// Bild → RGBA (verkleinert) für Farbanalysen von Design-Vorlagen.
  static Future<(int, int, Uint8List)?> _decodeRgba(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 120);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final r = data == null ? null : (img.width, img.height, data.buffer.asUint8List());
      img.dispose();
      codec.dispose();
      return r;
    } catch (_) {
      return null;
    }
  }

  Future<String?> addFileSource(String path, String name) async {
    try {
      final text = name.toLowerCase().endsWith('.pdf')
          ? (await NativeFiles.pdfText(path)).text
          : await File(path).readAsString();
      if (text.trim().isEmpty) return '$name enthält keinen auslesbaren Text.';
      final existing = knowledge.sources.where((s) => s.origin == name).firstOrNull;
      knowledge.putSource(
        KnowledgeSource(id: existing?.id ?? newId(), name: name, origin: name, kind: 'file'),
        [(title: name, url: name, text: text)],
      );
      await knowledge.save();
      notifyListeners();
      return null;
    } catch (e) {
      return '$name konnte nicht gelesen werden (nur Textdateien): $e';
    }
  }

  Future<void> removeSource(KnowledgeSource s) async {
    knowledge.removeSource(s.id);
    await knowledge.save();
    notifyListeners();
  }

  // --------------------------------------------------------------- Internet

  Future<bool> _requestNetwork(Conversation conv, String purpose) async {
    if (conv.internetOff) return false;
    if (conv.internetAllowed || _turnInternetAllowed) return true;
    // Im Gespräch: per Stimme fragen (Ja/Nein), mit Knöpfen am Gesprächsbildschirm – kein Dialog
    final voiceAsk = voiceConsentHandler;
    final ask = consentHandler;
    if (voiceAsk == null && ask == null) return false;
    if (voiceAsk == null) onConsentAsk?.call(purpose);
    final choice = voiceAsk != null ? await voiceAsk(purpose) : await ask!(purpose);
    switch (choice) {
      case NetworkChoice.once:
        _turnInternetAllowed = true;
        return true;
      case NetworkChoice.chat:
        unawaited(logActivity(Activity(kind: 'internet', title: 'Internet für einen Chat freigegeben', detail: purpose,
            approval: voiceAsk != null ? 'Du hast im Gespräch „Ja“ gesagt' : 'Du hast „Für diesen Chat“ gewählt',
            conversationId: conv.id)));
        conv.internetAllowed = true;
        await storage.saveConversation(conv);
        notifyListeners();
        return true;
      case NetworkChoice.deny:
        return false;
    }
  }

  Future<void> revokeInternet() => setInternetMode(InternetMode.ask);

  /// Wird aufgerufen, wenn gleich nach Internet gefragt wird (Gesprächsmodus: ansagen).
  void Function(String purpose)? onConsentAsk;

  /// Gesprächsmodus: Internet-Freigabe per Stimme statt Dialog.
  Future<NetworkChoice> Function(String purpose)? voiceConsentHandler;

  InternetMode get internetMode {
    final c = current;
    if (c == null) return InternetMode.ask;
    if (c.internetOff) return InternetMode.off;
    return c.internetAllowed ? InternetMode.allowed : InternetMode.ask;
  }

  /// Internet für den aktuellen Chat: aus / fragen / erlaubt.
  Future<void> setInternetMode(InternetMode m) async {
    final c = _ensureConversation();
    c
      ..internetOff = m == InternetMode.off
      ..internetAllowed = m == InternetMode.allowed;
    await storage.saveConversation(c);
    appLog('Internet', 'Chat „${c.title}“: ${m.label}');
    notifyListeners();
  }

  Future<void> setDarkMode(bool? value) async {
    settings.darkMode = value;
    darkMode.value = value;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  Future<void> setAutoLoad(bool value) async {
    settings.autoLoadLastModel = value;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  // ------------------------------------------------------- Profile & Tools

  Future<void> selectProfile(String id) async {
    settings.activeProfileId = id;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  Future<void> saveProfile(AgentProfile p) async {
    final i = profiles.indexWhere((x) => x.id == p.id);
    if (i >= 0) {
      profiles[i] = p;
    } else {
      profiles.add(p);
    }
    await storage.saveProfiles(profiles);
    notifyListeners();
  }

  Future<void> deleteProfile(AgentProfile p) async {
    if (p.builtin) return;
    profiles.removeWhere((x) => x.id == p.id);
    if (settings.activeProfileId == p.id) settings.activeProfileId = profiles.first.id;
    await storage.saveProfiles(profiles);
    await storage.saveSettings(settings);
    notifyListeners();
  }

  Future<void> setToolEnabled(String name, bool enabled) async {
    if (enabled) {
      settings.enabledTools.add(name);
    } else {
      settings.enabledTools.remove(name);
    }
    await storage.saveSettings(settings);
    notifyListeners();
  }

  // ------------------------------------------------------------------ Chats

  void newConversation() {
    // Auch während eine Antwort läuft: die läuft im eigenen Chat weiter.
    // Der neue Chat steht sofort in der Liste; höchstens ein leerer Entwurf.
    final draft = conversations.where((c) => c.entries.isEmpty && !isRoutineChat(c)).firstOrNull;
    final pending = current == null ? _attachments.remove('') : null;
    if (draft != null) {
      conversations
        ..remove(draft)
        ..insert(0, draft);
      draft.updated = DateTime.now();
      current = draft;
    } else {
      final c = Conversation(id: newId());
      conversations.insert(0, c);
      current = c;
    }
    if (pending != null) _attachments[current!.id] = pending;
    notifyListeners();
  }

  // ---------------------------------------------------------------- Eigene Designs

  Directory get designsDir => Directory('${storage.root.path}/designs');
  File get _designsFile => File('${designsDir.path}/designs.json');

  Future<void> loadDesigns() async {
    try {
      if (!await _designsFile.exists()) return;
      final j = jsonDecode(await _designsFile.readAsString()) as Map<String, dynamic>;
      DesignLibrary.user
        ..clear()
        ..addAll([for (final d in (j['designs'] as List? ?? const [])) UserDesign.fromJson((d as Map).cast())]);
      DesignLibrary.defaultId = j['default'] as String?;
    } catch (e) {
      appLog('Designs', 'Laden fehlgeschlagen: $e', error: true);
    }
  }

  Future<void> saveDesigns() async {
    await designsDir.create(recursive: true);
    await _designsFile.writeAsString(jsonEncode({
      'designs': [for (final d in DesignLibrary.user) d.toJson()],
      if (DesignLibrary.defaultId != null) 'default': DesignLibrary.defaultId,
    }));
    notifyListeners();
  }

  Future<void> addDesign(SlideDesign d, {Uint8List? template}) async {
    String? path;
    if (template != null) {
      await designsDir.create(recursive: true);
      final f = File('${designsDir.path}/${d.id}.pptx');
      await f.writeAsBytes(template);
      path = f.path;
    }
    DesignLibrary.user.removeWhere((u) => u.id == d.id);
    DesignLibrary.user.add(UserDesign(design: d, templatePath: path));
    await saveDesigns();
  }

  Future<void> removeDesign(String id) async {
    final u = DesignLibrary.byId(id);
    if (u?.templatePath != null) {
      try {
        await File(u!.templatePath!).delete();
      } catch (_) {}
    }
    DesignLibrary.user.removeWhere((x) => x.id == id);
    if (DesignLibrary.defaultId == id) DesignLibrary.defaultId = null;
    await saveDesigns();
  }

  Future<void> setDefaultDesign(String? id) async {
    DesignLibrary.defaultId = id;
    await saveDesigns();
  }

  /// Für „Design aus Datei“ (Farben aus Bildern brauchen den Bild-Decoder der App).
  Future<(SlideDesign, Uint8List?)?> designFromFile(String path, String name) async {
    final bytes = await File(path).readAsBytes();
    return designFromSample(bytes, path.split(Platform.pathSeparator).last, name: name, decodeImage: _decodeRgba);
  }

  // ---------------------------------------------------------------- Anheften & Ordner

  Future<void> setPinned(Conversation c, bool pinned) async {
    c.pinned = pinned;
    await storage.saveConversation(c);
    notifyListeners();
  }

  /// Ordner (Projekte) in der Seitenleiste: aus den Chats.
  List<String> get chatFolders {
    final set = <String>{for (final c in conversations) if (c.folder != null && c.folder!.trim().isNotEmpty) c.folder!};
    return set.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  Future<void> setFolder(Conversation c, String? folder) async {
    final f = folder?.trim();
    c.folder = f == null || f.isEmpty ? null : f;
    await storage.saveConversation(c);
    notifyListeners();
  }

  Future<void> renameFolder(String from, String to) async {
    final t = to.trim();
    for (final c in conversations.where((c) => c.folder == from)) {
      c.folder = t.isEmpty ? null : t;
      await storage.saveConversation(c);
    }
    notifyListeners();
  }

  Future<void> renameConversation(Conversation c, String title) async {
    if (title.trim().isEmpty) return;
    c.title = title.trim();
    await storage.saveConversation(c);
    notifyListeners();
  }

  void selectConversation(Conversation c) {
    current = c;
    notifyListeners();
  }

  Future<void> deleteConversation(Conversation c) async {
    if (running && runningConvId == c.id) return;
    conversations.removeWhere((x) => x.id == c.id);
    _attachments.remove(c.id);
    if (current?.id == c.id) current = null;
    await storage.deleteConversation(c.id);
    notifyListeners();
  }

  Conversation _ensureConversation() {
    var c = current;
    if (c == null) {
      c = Conversation(id: newId());
      conversations.insert(0, c);
      current = c;
      // bereits gewählte Anhänge übernehmen
      final pending = _attachments.remove('');
      if (pending != null) _attachments[c.id] = pending;
    }
    return c;
  }

  static const maxAttachmentChars = 400000;

  /// Liest eine Textdatei als Anhang. Gibt eine Fehlermeldung zurück oder null.
  Future<String?> addAttachment(String path, String name) async {
    final key = current?.id ?? '';
    final ext = name.split('.').last.toLowerCase();
    try {
      final src = File(path);
      final size = await src.length();
      // Bilder und PDFs dauerhaft ablegen (die Auswahl liefert oft nur temporäre Kopien)
      Future<File> keep() async {
        var target = File('${attachmentsDir.path}/$name');
        var i = 2;
        while (target.existsSync() && target.lengthSync() != size) {
          final dot = name.lastIndexOf('.');
          target = File('${attachmentsDir.path}/${dot > 0 ? name.substring(0, dot) : name} ($i)${dot > 0 ? name.substring(dot) : ''}');
          i++;
        }
        if (!target.existsSync()) await src.copy(target.path);
        return target;
      }

      if (isImageFile(name)) {
        if (size > 25 * 1024 * 1024) return '$name ist größer als 25 MB.';
        if (ext == 'heic' || ext == 'webp') {
          return '$name: Format ${ext.toUpperCase()} wird nicht unterstützt – bitte als JPG oder PNG anhängen.';
        }
        final f = await keep();
        (_attachments[key] ??= []).add(Attachment(
          name: f.uri.pathSegments.last,
          content: 'Bild "${f.uri.pathSegments.last}". Inhalt mit dem Tool look_at_image ansehen. '
              'In Dokumente/Folien einbinden mit ![](${f.uri.pathSegments.last}).',
          path: f.path,
        ));
        notifyListeners();
        if (!canSeeImages) {
          statusMessage = visionHint;
          notifyListeners();
        }
        return null;
      }

      if (const {'docx', 'dotx', 'xlsx', 'pptx', 'potx'}.contains(ext)) {
        if (size > 80 * 1024 * 1024) return '$name ist größer als 80 MB.';
        final f = await keep();
        var text = officeText(await f.readAsBytes(), ext).trim();
        if (text.length > maxAttachmentChars) text = '${text.substring(0, maxAttachmentChars)}\n[… gekürzt]';
        final kind = switch (ext) { 'xlsx' => 'Excel', 'pptx' || 'potx' => 'PowerPoint', _ => 'Word' };
        (_attachments[key] ??= []).add(Attachment(
          name: name,
          content: '[$kind-Datei – Inhalt unten. Wird automatisch als Design-Vorlage (Farben, Schriften'
              '${kind == 'PowerPoint' ? ', Folienmaster' : ''}) für neue Präsentationen und Dokumente verwendet.]\n$text',
          path: f.path,
        ));
        notifyListeners();
        return null;
      }

      if (ext == 'pdf') {
        if (size > 80 * 1024 * 1024) return '$name ist größer als 80 MB.';
        final f = await keep();
        final r = await NativeFiles.pdfText(f.path);
        var text = r.text.trim();
        if (text.isEmpty) {
          return '$name enthält keinen auslesbaren Text (eingescanntes PDF?). '
              'Tipp: Seiten als Bilder anhängen, dann liest der Agent sie mit Bildverständnis.';
        }
        if (text.length > maxAttachmentChars) text = '${text.substring(0, maxAttachmentChars)}\n[… gekürzt]';
        (_attachments[key] ??= []).add(Attachment(name: name, content: '[PDF, ${r.pages} Seiten]\n$text', path: f.path));
        notifyListeners();
        return null;
      }

      final bytes = await src.readAsBytes();
      if (bytes.length > 4 * 1024 * 1024) return '$name ist größer als 4 MB.';
      // einfache Binärprüfung
      final probe = bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes;
      if (probe.where((b) => b == 0).length > 2) {
        return '$name wird nicht unterstützt (möglich: PDF, Word, Excel, PowerPoint, Bilder, TXT, MD, CSV, JSON, Code).';
      }
      var text = utf8.decode(bytes, allowMalformed: true);
      if (text.length > maxAttachmentChars) {
        text = '${text.substring(0, maxAttachmentChars)}\n[… gekürzt]';
      }
      (_attachments[key] ??= []).add(Attachment(name: name, content: text, path: path));
      notifyListeners();
      return null;
    } on PlatformException catch (e) {
      return '$name konnte nicht gelesen werden: ${e.message ?? e.code}';
    } catch (e) {
      return '$name konnte nicht gelesen werden: $e';
    }
  }

  // ------------------------------------------------------- Bildverständnis

  CatalogEntry? get _loadedCatalog => loadedModel?.catalogId == null
      ? null
      : modelCatalog.where((e) => e.id == loadedModel!.catalogId).firstOrNull;

  /// Kann das geladene Modell überhaupt Bilder verstehen?
  bool get modelSupportsVision => _loadedCatalog?.vision ?? false;

  String? get visionPath {
    final c = _loadedCatalog;
    if (c == null) return null;
    final p = settings.installed['mmproj:${c.id}'];
    return p != null && File(p).existsSync() ? p : null;
  }

  bool get canSeeImages => engine != null && modelSupportsVision && visionPath != null;

  String get visionHint {
    if (engine == null) return 'Bild angehängt. Zum Ansehen zuerst ein Sprachmodell laden.';
    if (!modelSupportsVision) {
      return 'Bild angehängt – ${loadedModel?.displayName ?? 'dieses Modell'} kann aber keine Bilder sehen. '
          'Für Bildverständnis Qwen 3.5 oder Gemma 4 laden (Systemcheck). '
          'In Dokumente/Folien einbinden geht trotzdem.';
    }
    return 'Bild angehängt. Für Bildverständnis die Zusatzdatei laden: Systemcheck → ${loadedModel?.displayName} → „Bilder verstehen“.';
  }

  /// Lädt die Projektor-Datei (mmproj) für das Katalogmodell aus demselben Hugging-Face-Repo.
  Future<void> downloadVision(CatalogEntry model) async {
    final id = 'mmproj:${model.id}';
    if (downloads[id]?.active ?? false) return;
    final repo = model.hfRepo;
    if (repo == null) return;
    var st = DownloadState(CatalogEntry(
      id: id,
      kind: ModelKind.llm,
      name: 'Bildverständnis für ${model.name}',
      description: '',
      url: '',
      fileName: 'mmproj-${model.id}.gguf',
      sizeBytes: 0,
      minClass: DeviceClass.s,
    ));
    downloads[id] = st;
    notifyListeners();
    unawaited(BackgroundWork.begin('dl-$id', 'Lade Bildverständnis …'));
    try {
      final files = await _hfFiles(repo);
      final mm = files.where((f) => f.path.split('/').last.toLowerCase().startsWith('mmproj')).toList();
      if (mm.isEmpty) throw Exception('Im Repo $repo gibt es keine Projektor-Datei (mmproj).');
      int rank(String n) {
        final l = n.toLowerCase();
        if (l.contains('q8')) return 0;
        if (l.contains('f16') && !l.contains('bf16')) return 1;
        if (l.contains('bf16')) return 2;
        return 3;
      }
      mm.sort((a, b) => rank(a.path).compareTo(rank(b.path)));
      final pick = mm.first;
      final entry = CatalogEntry(
        id: id,
        kind: ModelKind.llm,
        name: 'Bildverständnis für ${model.name}',
        description: pick.path,
        url: 'https://huggingface.co/$repo/resolve/main/${pick.path}',
        fileName: 'mmproj-${model.id}.gguf',
        sizeBytes: pick.size,
        minClass: DeviceClass.s,
      );
      st = DownloadState(entry);
      downloads[id] = st;
      notifyListeners();
      final target = '${storage.modelsDir.path}/${entry.fileName}';
      final f = await _downloader.download(entry.url, target, cancel: st.cancel, onProgress: (p) {
        st.progress = p;
        notifyListeners();
      });
      settings.installed[id] = f.path;
      await storage.saveSettings(settings);
      downloads.remove(id);
      if (statusMessage == visionHint) statusMessage = null;
    } on DownloadCancelled {
      downloads.remove(id);
    } catch (e) {
      st.error = e.toString();
    } finally {
      unawaited(BackgroundWork.end('dl-$id'));
      refreshFreeDisk();
      notifyListeners();
    }
  }

  Future<void> removeVision(CatalogEntry model) async {
    final p = settings.installed.remove('mmproj:${model.id}');
    if (p != null) {
      try {
        await File(p).delete();
      } catch (_) {}
    }
    await storage.saveSettings(settings);
    refreshFreeDisk();
    notifyListeners();
  }

  Future<List<({String path, int size})>> _hfFiles(String repo) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse('https://huggingface.co/api/models/$repo/tree/main'));
      final res = await req.close();
      if (res.statusCode != 200) throw Exception('Hugging Face antwortet mit ${res.statusCode}');
      final body = await res.transform(utf8.decoder).join();
      final list = jsonDecode(body) as List;
      return [
        for (final f in list.cast<Map>())
          if (f['type'] == 'file') (path: f['path'] as String, size: ((f['lfs'] as Map?)?['size'] ?? f['size'] ?? 0) as int),
      ];
    } finally {
      client.close();
    }
  }

  /// Fragt das Sprachmodell zu Bildern (lädt bei Bedarf den Projektor).
  Future<String> _visionQuery(List<String> imagePaths, String question) async {
    final eng = engine;
    final mm = visionPath;
    if (eng == null) throw ToolException('Kein Modell geladen.');
    if (!modelSupportsVision || mm == null) throw ToolException(visionHint);
    await eng.loadVision(mm);
    final marker = LlamaEngine.imageMarker;
    final prompt = await eng.formatChat([
      ChatMessage('user', '${List.filled(imagePaths.length, marker).join('\n')}\n$question'),
    ]);
    final out = StringBuffer();
    String? error;
    await for (final ev in eng.generateWithImages(prompt, imagePaths, maxTokens: 700)) {
      if (ev is TokenEvent) out.write(ev.text);
      if (ev is DoneEvent && ev.reason == FinishReason.error) error = ev.error;
    }
    if (error != null) throw ToolException('Bild konnte nicht ausgewertet werden: $error');
    return out.toString().trim();
  }

  Future<String> _askAboutImage(String name, String question) async {
    final all = attachments.where((a) => a.path != null && isImageFile(a.name)).toList();
    final hit = all.where((a) => a.name.toLowerCase() == name.toLowerCase()).firstOrNull ??
        all.where((a) => a.name.toLowerCase().contains(name.toLowerCase())).firstOrNull ??
        (all.length == 1 ? all.first : null);
    String? path = hit?.path;
    if (path == null) {
      final f = File('${outputsDir.path}/$name');
      if (f.existsSync()) path = f.path;
    }
    if (path == null) {
      throw ToolException('Bild "$name" nicht gefunden. Vorhanden: ${all.map((a) => a.name).join(', ')}');
    }
    return _visionQuery([path], '$question\nAntworte auf Deutsch.');
  }

  // ------------------------------------------------------- Bildgenerierung

  CatalogEntry? get imageModel => modelCatalog.where((e) => e.kind == ModelKind.image && installedPath(e) != null).firstOrNull;

  Future<String> _generateImage(String prompt, String format, String negative) async {
    final m = imageModel;
    if (m == null) {
      throw ToolException('Kein Bildmodell installiert. Der Nutzer kann im Systemcheck unter „Bilder erzeugen“ '
          'SD-Turbo laden (ca. 2 GB). Sag ihm das.');
    }
    if (!ImageEngine.available) throw ToolException('Bildgenerierung ist in dieser App-Version nicht enthalten.');
    _imageIdle?.cancel();
    imageProgress = 'Bildmodell wird geladen …';
    notifyListeners();
    try {
      final path = installedPath(m)!;
      if (_imageEngine?.modelPath != path) {
        await _imageEngine?.dispose();
        _imageEngine = await ImageEngine.load(path, threads: device.threads);
      }
      final (w, h) = switch (format) {
        'landscape' => (640, 448),
        'portrait' => (448, 640),
        _ => (512, 512),
      };
      final steps = device.isMobile ? 2 : 4;
      final started = DateTime.now();
      imageProgress = 'Bild wird erzeugt …';
      notifyListeners();
      final img = await _imageEngine!.generate(
        ImageRequest(prompt,
            negative: negative.isEmpty ? 'blurry, low quality, distorted, text, watermark' : negative,
            width: w,
            height: h,
            steps: steps,
            cfg: 1.0),
        onProgress: (step, total) {
          final secs = DateTime.now().difference(started).inSeconds;
          imageProgress = total > 0 && step > 0 ? 'Bild wird erzeugt … Schritt $step/$total ($secs s)' : 'Bild wird erzeugt … ($secs s)';
          notifyListeners();
        },
      );
      final rgba = Uint8List(img.width * img.height * 4);
      for (var i = 0; i < img.width * img.height; i++) {
        rgba[i * 4] = img.rgb[i * 3];
        rgba[i * 4 + 1] = img.rgb[i * 3 + 1];
        rgba[i * 4 + 2] = img.rgb[i * 3 + 2];
        rgba[i * 4 + 3] = 255;
      }
      // EU-Kennzeichnung: Symbol „AI GENERATED“ im Bild + maschinenlesbare Metadaten
      stampAiLabel(rgba, img.width, img.height);
      final words = prompt.replaceAll(RegExp(r'[^\w\s-]'), ' ').trim().split(RegExp(r'\s+')).take(5).join(' ');
      final f = OutputSpace(outputsDir).fileFor('KI-Bild $words', 'png');
      await f.writeAsBytes(encodePngRgba(img.width, img.height, rgba, text: aiImageMetadata(prompt: prompt)));
      return f.path;
    } on ImageGenException catch (e) {
      throw ToolException(e.message);
    } finally {
      imageProgress = null;
      notifyListeners();
      // Speicher freigeben: am Handy sofort, am Mac nach 5 Minuten Leerlauf
      _imageIdle = Timer(device.isMobile ? Duration.zero : const Duration(minutes: 5), () async {
        final e = _imageEngine;
        _imageEngine = null;
        await e?.dispose();
      });
    }
  }

  void cancelImage() => _imageEngine?.cancel();

  void removeAttachment(Attachment a) {
    _attachments[current?.id ?? '']?.remove(a);
    notifyListeners();
  }

  void clearInspectorAttention() {
    if (inspectorAttention) {
      inspectorAttention = false;
      notifyListeners();
    }
  }

  /// System-Prompt: Profil + Gedächtnis (+ Gesprächsmodus). Bleibt zwischen Turns gleich,
  /// damit der Präfix-Cache greift; die Wissensbasis-Auszüge kommen in die Nutzernachricht.
  String _systemText({bool voice = false, List<AgentTool>? tools}) {
    final activeTools = tools ?? this.activeTools;
    final profile = activeProfile;
    final system = StringBuffer(profile.systemPrompt.trim());
    final mem = memory.promptBlock();
    if (mem.isNotEmpty) system.write('\n\n$mem');
    if (activeTools.any((t) => t.name == 'remember')) {
      system.write('\nWenn der Nutzer etwas Wichtiges über sich erzählt oder dich bittet, '
          'dir etwas zu merken, nutze das Tool remember.');
    }
    system.write('\n\nQUELLEN: Stütze dich auf Auszüge aus der Wissensbasis, angehängte Dokumente oder '
        'Webseiten, wenn vorhanden, und nenne sie im Text (Titel oder Adresse). Nutzt du nur dein eigenes '
        'Wissen, sag das nicht extra – die App ergänzt die Quellenangabe automatisch.');
    if (activeTools.any((t) => t.name.startsWith('create_') || t.name == 'generate_image')) {
      system.write('\n\nDATEIEN: Wünscht der Nutzer ein Dokument, eine Präsentation, ein Diagramm oder ein Bild, '
          'erstelle es mit create_document, create_presentation, create_chart bzw. generate_image. '
          '${imageModel != null ? 'Für Bilder in Folien/Dokumenten schreibe ![kurze englische Bildbeschreibung](auto) – sie werden automatisch erzeugt. ' : ''}'
          'Bilder und Diagramme zuerst erzeugen, dann im Dokument/den Folien mit ![](dateiname.png) einbinden. '
          'Schreibe Inhalte vollständig und gut gegliedert. Beschreibe Folien oder Dokumente nie nur (kein Folienplan, '
          'keine Anleitung zum Selbermachen) – erstelle die Datei. Links zu Design-Vorlagen oder Beispielbildern nicht öffnen, '
          'sondern bei create_presentation als vorlage angeben. Die Dateien erscheinen automatisch im Chat – '
          'in der final_answer nur kurz sagen, was erstellt wurde.');
    }
    if ((tools ?? activeTools).any((t) => t.name == 'browser')) {
      system.write('\n\nBROWSER: Nennt der Nutzer eine Webseite oder Adresse, öffne sie mit browser '
          '(action "open" oder "search") – nicht web_search. Wiederhole keine Suche, die schon nichts gefunden hat.');
    }
    if (voice) {
      system.write('\n\nGESPRÄCHSMODUS: Deine Antwort wird vorgelesen. Antworte wie im persönlichen Gespräch: '
          'kurz (meist 1–3 Sätze), natürlich, ohne Markdown, Listen, Tabellen, Emojis oder Links. '
          'Wiederhole die Frage nicht und fasse sie nicht zusammen – beginne sofort mit der Antwort. '
          'Denke nicht laut: kein Vorspann wie „Der Nutzer möchte …“, „Du fragst …“ oder „Okay, …“. '
          'Fang auch nicht mit den Worten der Frage an: Auf „Wie entsteht ein Regenbogen?“ nicht „Ein Regenbogen '
          'entsteht durch …“, sondern gleich „Sonnenlicht wird in Regentropfen gebrochen …“. '
          'Du heißt ${settings.agentName}. '
          'Wenn der Nutzer „weiter“ oder „mach weiter“ sagt, setze deine vorige Antwort genau dort fort, '
          'wo sie unterbrochen wurde.');
    }
    return system.toString();
  }

  /// Anweisung für den Gesprächsmodus – hängt an der Frage, nicht am System-Prompt (Cache!).
  String voiceTurnHint() => '[Gesprächsmodus – deine Antwort wird vorgelesen: antworte wie im persönlichen Gespräch, '
      'kurz (meist 1–3 Sätze), ohne Markdown, Listen, Tabellen, Emojis oder Links. Wiederhole die Frage nicht, '
      'beginne sofort mit der Antwort. Sagt der Nutzer „weiter“, setze deine vorige Antwort fort. Du heißt ${settings.agentName}.]';

  AgentRunner _makeRunner(AgentBackend eng, String system, {List<AgentTool>? tools, String? requiredTool}) {
    final profile = activeProfile;
    final browsing = (tools ?? activeTools).any((t) => t.name == 'browser');
    return AgentRunner(
      engine: eng,
      systemPrompt: system,
      tools: tools ?? activeTools,
      // Im Browser braucht der Agent mehrere Klicks
      maxSteps: browsing ? math.max(profile.maxSteps, 12) : profile.maxSteps,
      // Platz für ganze Dokumente in einem Tool-Aufruf
      maxTokensPerStep: (eng.contextSize ~/ 3).clamp(256, 4096),
      observationLimit: device.deviceClass == DeviceClass.s ? (browsing ? 1800 : 1000) : (browsing ? 3000 : 2000),
      sampling: SamplingParams(temperature: profile.temperature.clamp(0.0, 0.5), topP: 0.9),
      chatSampling: SamplingParams(temperature: profile.temperature),
      requiredTool: requiredTool,
    );
  }

  static final _makeVerb = RegExp(r'erstell|mach|bau|generier|erzeug|schreib|gestalt|überarbeit|entwirf|entwerf|anlegen|leg .* an|exportier|als (pdf|powerpoint|pptx|datei)|brauche|hätte gern|möchte',
      caseSensitive: false);
  static final _deckWord = RegExp(r'präsentation|powerpoint|folien|pptx|slides|foliensatz|slide ?deck', caseSensitive: false);
  static final _docWord = RegExp(r'\bpdf\b|word-?dokument|dokument|handout|bericht als', caseSensitive: false);

  /// Verlangt die Nachricht eine Datei? → Werkzeug, das der Agent dafür nutzen muss.
  static final _editIntent = RegExp(r'(folie|abschnitt|kapitel|seite)\s*\d+|überarbeit|ändere|ersetze|lösche|füge .* ein|ergänze|kürze|korrigier',
      caseSensitive: false);

  static String? requiredToolFor(String text, {bool hasFiles = false}) {
    // Bestehende Datei ändern („Folie 3 überarbeiten“) – edit_file oder neu erstellen zählt
    if (hasFiles && _editIntent.hasMatch(text) && !RegExp(r'neue (präsentation|powerpoint|datei|pdf)', caseSensitive: false).hasMatch(text)) {
      return 'edit_file|create_presentation|create_document';
    }
    if (!_makeVerb.hasMatch(text)) return null;
    if (_deckWord.hasMatch(text)) return 'create_presentation';
    if (_docWord.hasMatch(text)) return 'create_document';
    return null;
  }

  /// Auslöser je Werkzeug: Nur wenn die Nachricht danach klingt, bekommt das Modell
  /// das Werkzeug zu sehen. Für „Hi“ oder normale Fragen gibt es gar keine Werkzeuge –
  /// dann antwortet das Modell direkt (ein Durchlauf statt Agenten-Schleife).
  static final _toolTriggers = <String, RegExp>{
    'browser': RegExp(r'browser|https?://|\b[a-z0-9-]+\.(at|de|com|ch|li|net|org|io|eu|info|fyi|app|dev|ai|co|shop)\b|öffne\w* .*(seite|webseite|website)|geh\w* auf|navigier|klick|surf|'
        r'amazon|ebay|willhaben|shop|bestell|anmelde|formular|auf der seite|im browser|such\w* (auf|bei) '),
    'web_fetch': RegExp(r'https?://|www\.|\b[\w-]+\.(com|at|de|ch|li|org|net|io|eu|fyi|ai|app)\b|webseite|website|link\b|artikel'),
    'site_search': RegExp(r'amazon|ebay|geizhals|idealo|willhaben|otto\.de|mediamarkt|thalia|chefkoch|wikipedia|'
        r'shop|kaufen|bestell|angebot|günstig|preisvergleich|produkt|auf [\w-]+\.(at|de|com)\b.*such|such\w* (auf|bei) '),
    'web_search': RegExp(r'internet|im netz|online|google|such(e|en)? (im|nach|mal|mir)|such mir|finde (mir|im)|recherch|'
        r'angebot|kaufen|empfehl\w* .*(produkt|marke)|vergleich|test(sieger|bericht)|'
        r'aktuell|neueste|letzte woche|börse|aktienkurs|wechselkurs|was kostet|preis von|wer ist (der|die) (aktuelle|neue)'),
    // Wortgrenzen: „Regenbogen“, „Windows“, „Jackett“ sind keine Wetterfragen
    'weather': RegExp(r'wetter|\bregen\b|regnet|regenschirm|temperatur|\d+\s*grad\b|\bgrad (wird|hat|haben)|\bschnee\b|schneit|sonnig|'
        r'\bwind(ig)?\b|gewitter|\bschirm\b|\bjacke\b|vorhersage'),
    'news': RegExp(r'news|nachrichten|schlagzeilen|neuigkeiten|neues (zu|von|aus|über|bei|in)|was gibt.s neues|was gibt es neues|meldungen|presse|morgen-übersicht'),
    'contacts_search': RegExp(r'nummer von|telefonnummer|handynummer|e-?mail-?adresse von|adresse von|kontakt'),
    'compose_email': RegExp(r'e-?mail|\bmail\b|mail an|mailen'),
    'compose_whatsapp': RegExp(r'whats ?app|\bwa\b'),
    'call_phone': RegExp(r'ruf\w* .*\ban\b|anrufen|telefonier|\banruf'),
    'calendar_add': RegExp(r'termin|kalender|eintragen|trag .* ein|meeting|besprechung|einladung|veranstaltung|plakat|flyer'),
    'calendar_list': RegExp(r'termin|kalender|was steht|was hab ich|habe ich (heute|morgen)|agenda|tagesplan|morgen-übersicht|bin ich (frei|verfügbar)'),
    'file_search': RegExp(r'datei|dateien|ordner|dokumente? (finden|suchen)|finde .*\.(pdf|docx?|xlsx?|jpg|png)|downloads|schreibtisch'),
    'file_rename': RegExp(r'umbenenn|benenn|dateinamen?'),
    'file_move': RegExp(r'verschieb|sortier|aufräumen|ordne|in den ordner'),
    'calculator': RegExp(r'\d\s*(%|prozent|[+*/^×÷]|mal\b|geteilt|plus|minus|hoch)|rechne|berechne|wurzel|zins'),
    'datetime': RegExp(r'uhrzeit|wie spät|datum|wochentag|welcher tag|kalenderwoche|wie lange (noch )?bis|in \d+ tagen'),
    'remember': RegExp(r'merk dir|merke dir|vergiss|behalte|notier dir|erinnere dich|was weißt du über mich'),
    'send_notification': RegExp(r'erinner|wecker|benachrichtig|push|in \d+ (minuten|stunden)|um \d{1,2}[:.]\d{2}|morgen um'),
    'save_prompt': RegExp(r'prompt|vorlage|als (prompt|vorlage)|jeden (morgen|tag|montag)|täglich'),
    'create_document': RegExp(r'\bpdf\b|dokument|bericht|report|handout|word'),
    'create_presentation': RegExp(r'präsentation|folien|powerpoint|pptx|slides'),
    'find_loose_ends': RegExp(r'liegengeblieben|liegen geblieben|unerledigt|was (ist|hab ich|habe ich) (noch )?(offen|vergessen)|offene (punkte|aufgaben|sachen|dinge|themen)|nachfassen|was steht (noch )?aus'),
    'edit_file': RegExp(r'folie\s*\d|abschnitt|kapitel|überarbeit|änder|ersetz|lösch|einfüg|füg .* (ein|hinzu)|korrigier|tausch|umschreib|kürz|ergänz'),
    'create_chart': RegExp(r'diagramm|chart|grafik|balken|kurve|visualisier'),
    'generate_image': RegExp(r'(erstell|generier|mal|zeichne|erzeug)\w* .*\b(bild|foto|illustration|logo|grafik)|bild von|zeichne|male mir'),
    'knowledge_search': RegExp(r'wissensbasis|meine(n)? (dokument|unterlagen|quellen|notizen)|laut (dem|der|meinen)|im dokument'),
    'search_history': RegExp(r'früher|letztes mal|haben wir (schon|mal)|hatte ich|verlauf|vorhin|gestern (gesagt|gefragt)'),
    'read_file': RegExp(r'datei|file|\.txt|\.csv|\.md\b'),
    'text_search': RegExp(r'such(e|en)? (in|im) (der|dem|den) (datei|text)'),
    'json_query': RegExp(r'\bjson\b'),
    'write_artifact': RegExp(r'\bhtml\b|webseite (bauen|erstellen)|artefakt|code (für|schreiben)|skript'),
  };

  /// Werkzeuge passend zur Nachricht (Chat und Gespräch).
  List<AgentTool> toolsFor(String input, {bool hasImages = false, bool hasDocs = false}) {
    final t = input.toLowerCase();
    final words = RegExp(r'[\p{L}\d]{5,}', unicode: true).allMatches(t).map((m) => m.group(0)!).toSet();
    return [
      for (final tool in activeTools)
        if (_toolTriggers[tool.name]?.hasMatch(t) ??
            (tool.name == 'look_at_image'
                ? hasImages
                : tool.name.contains('__')
                    // MCP: wenn Wörter aus Name/Beschreibung in der Nachricht vorkommen
                    ? words.any((w) => '${tool.name} ${tool.title} ${tool.description}'.toLowerCase().contains(w))
                    : false))
          tool
        else if (hasDocs && (tool.name == 'knowledge_search' || tool.name == 'read_file'))
          tool
        // „Was ist liegengeblieben?“: auch Mail-/Aufgaben-Werkzeuge (MCP) und Kalender
        else if ((_toolTriggers['find_loose_ends']?.hasMatch(t) ?? false) &&
            (tool.name == 'calendar_list' || (tool.name.contains('__') && looseEndsMcp.hasMatch('${tool.name} ${tool.title} ${tool.description}'))))
          tool,
    ];
  }

  @Deprecated('toolsFor verwenden')
  List<AgentTool> voiceToolsFor(String input) => toolsFor(input);

  // ---------------------------------------------------------------- Freigabe-Karten

  /// Mail-Konto für den Direktversand (Passwort aus dem Tresor).
  Future<SmtpAccount?> smtpAccount() async {
    if (!settings.smtpReady) return null;
    final pw = await Vault.read('smtp:${settings.smtpUser}');
    if (pw == null || pw.isEmpty) return null;
    return SmtpAccount(
        host: settings.smtpHost, port: settings.smtpPort, user: settings.smtpUser, password: pw, from: settings.smtpFrom);
  }

  Future<void> saveSmtp({required String host, required int port, required String user, required String password, String from = ''}) async {
    if (settings.smtpUser.isNotEmpty && settings.smtpUser != user) await Vault.delete('smtp:${settings.smtpUser}');
    settings
      ..smtpHost = host.trim()
      ..smtpPort = port
      ..smtpUser = user.trim()
      ..smtpFrom = from.trim();
    if (password.isNotEmpty) await Vault.write('smtp:${user.trim()}', password);
    await storage.saveSettings(settings);
    notifyListeners();
  }

  Future<void> removeSmtp() async {
    if (settings.smtpUser.isNotEmpty) await Vault.delete('smtp:${settings.smtpUser}');
    settings
      ..smtpHost = ''
      ..smtpUser = ''
      ..smtpFrom = '';
    await storage.saveSettings(settings);
    notifyListeners();
  }

  /// Freigegebene Aktion ausführen (Tipp auf „Senden“ oder „Ja“ im Gespräch).
  /// Liefert eine kurze Meldung für die Oberfläche.
  Future<String> runAction(ChatEntry entry, int index, {String approval = 'Du hast „Senden“ getippt'}) async {
    final a = entry.actions[index];
    if (a['status'] != 'pending') return 'Schon erledigt';
    final conv = conversations.where((c) => c.entries.contains(entry)).firstOrNull;
    final who = (a['name'] ?? '').isNotEmpty ? a['name']! : (a['to'] ?? '');
    String msg;
    try {
      if (a['type'] == 'email') {
        final acc = await smtpAccount();
        if (acc != null && (a['to'] ?? '').contains('@')) {
          await sendMail(acc, to: a['to']!, subject: a['subject'] ?? '', body: a['body'] ?? '');
          a['status'] = 'sent';
          msg = 'E-Mail an $who gesendet';
          unawaited(logActivity(Activity(kind: 'mail', title: 'E-Mail an $who gesendet', detail: a['subject'] ?? '',
              approval: approval, conversationId: conv?.id)));
        } else {
          await deviceBridge.composeEmail(a['to'] ?? '', a['subject'] ?? '', a['body'] ?? '');
          a['status'] = 'opened';
          msg = acc == null ? 'Mail-App geöffnet – dort nur noch senden' : 'Mail-App geöffnet (Empfänger fehlt)';
          unawaited(logActivity(Activity(kind: 'mail', title: 'E-Mail an $who in der Mail-App geöffnet',
              detail: a['subject'] ?? '', approval: approval, conversationId: conv?.id)));
        }
      } else {
        await deviceBridge.whatsapp(a['to'] ?? '', a['body'] ?? '');
        a['status'] = 'opened';
        msg = 'WhatsApp geöffnet – dort nur noch senden';
        unawaited(logActivity(Activity(kind: 'whatsapp', title: 'WhatsApp an $who geöffnet', detail: a['body'] ?? '',
            approval: approval, conversationId: conv?.id)));
      }
    } on SmtpException catch (e) {
      msg = 'Nicht gesendet: ${e.message}';
      a['error'] = e.message;
    } catch (e) {
      msg = 'Fehler: $e';
      a['error'] = '$e';
    }
    if (conv != null) await storage.saveConversation(conv);
    notifyListeners();
    return msg;
  }

  Future<void> updateAction(ChatEntry entry, int index, Map<String, String> changes) async {
    entry.actions[index].addAll(changes);
    final conv = conversations.where((c) => c.entries.contains(entry)).firstOrNull;
    if (conv != null) await storage.saveConversation(conv);
    notifyListeners();
  }

  /// Offene Aktion der letzten Antwort im aktuellen Chat (für „Ja“ im Gespräch).
  (ChatEntry, int)? get pendingAction {
    final e = current?.entries.lastOrNull;
    if (e == null || e.role != 'assistant') return null;
    final i = e.actions.indexWhere((a) => a['status'] == 'pending');
    return i < 0 ? null : (e, i);
  }

  // ------------------------------------------------------- Termin-Vorbereitung & Nachbereitung

  static const meetingPrepId = 'builtin-meeting-prep';

  /// Geplante Aufgabe „Termine vorbereiten“ anlegen (läuft wie andere geplante Prompts).
  Future<SavedPrompt> createMeetingPrep({int hour = 7, int minute = 30}) async {
    final existing = prompts.where((p) => p.id == meetingPrepId).firstOrNull;
    final p = SavedPrompt(
      id: meetingPrepId,
      title: 'Termine vorbereiten',
      text: 'Bereite meine heutigen Termine vor: pro Termin eine einseitige Notiz mit Infos zu Firma und Webseite.',
      schedule: ScheduleKind.weekdays,
      hour: hour,
      minute: minute,
      allowInternet: true,
      notify: true,
      lastRun: existing?.lastRun,
    );
    await savePrompt(p);
    return p;
  }

  static final _urlInText = RegExp(r'https?://[^\s<>"]+|\b(?:www\.)?[a-z0-9-]+\.(?:at|de|com|ch|io|net|org|eu|studio|ai|co)\b(?:/[^\s<>"]*)?',
      caseSensitive: false);
  static const _freeMail = {'gmail.com', 'gmx.at', 'gmx.net', 'gmx.de', 'outlook.com', 'hotmail.com', 'icloud.com', 'yahoo.com', 'web.de', 'aon.at', 'a1.net'};

  /// Webseite eines Termins: Link in Notizen/Ort, sonst Firmen-Domain einer E-Mail-Adresse.
  static String? meetingWebsite(CalendarEvent e) {
    final text = '${e.notes} ${e.location} ${e.title}';
    for (final m in RegExp(r'[\w.+-]+@([\w-]+\.[\w.-]+)').allMatches(text)) {
      final d = m.group(1)!.toLowerCase();
      if (!_freeMail.contains(d)) return 'https://$d';
    }
    final u = _urlInText.firstMatch(text.replaceAll(RegExp(r'[\w.+-]+@[\w.-]+'), ' '))?.group(0);
    if (u == null) return null;
    if (RegExp(r'(zoom\.us|teams\.microsoft|meet\.google|webex)', caseSensitive: false).hasMatch(u)) return null;
    return u.startsWith('http') ? u : 'https://$u';
  }

  /// Für jeden heutigen Termin eine einseitige Notiz (Dokument-Karte) im Chat „Termine …“.
  Future<Conversation?> prepareMeetings({bool automated = false}) async {
    if (!DeviceBridge.supported) return null;
    final now = DateTime.now();
    final events = (await deviceBridge.calendarList(DateTime(now.year, now.month, now.day), DateTime(now.year, now.month, now.day + 1)))
        .where((e) => !e.allDay && e.end.isAfter(now))
        .take(6)
        .toList();
    scheduleFollowUps(events);
    if (!await _ensureEngine()) return null;
    final conv = Conversation(id: newId(), title: 'Termine ${now.day}.${now.month}.');
    conversations.insert(0, conv);
    if (!automated) current = conv;
    if (events.isEmpty) {
      conv.entries.add(ChatEntry(role: 'assistant', text: 'Heute stehen keine Termine im Kalender – nichts vorzubereiten.'));
      await storage.saveConversation(conv);
      notifyListeners();
      return conv;
    }
    conv.internetAllowed = true; // geplante Aufgabe: Internet für die Firmen-Webseiten freigegeben
    final fetch = tools.whereType<WebFetchTool>().firstOrNull;
    for (final e in events) {
      final site = meetingWebsite(e);
      var page = '';
      if (site != null && fetch != null) {
        try {
          final r = await fetch.run({'url': site}, ToolContext(requestNetwork: (_) async => true));
          final cut = r.indexOf(moreCardsMarker);
          page = (cut < 0 ? r : r.substring(0, cut));
          if (page.length > 2500) page = page.substring(0, 2500);
        } catch (err) {
          page = '(Webseite nicht erreichbar: $err)';
        }
      }
      final time = '${e.begin.hour.toString().padLeft(2, '0')}:${e.begin.minute.toString().padLeft(2, '0')}';
      final prompt = 'Schreib eine einseitige Vorbereitung (Markdown, Stichpunkte) für meinen Termin heute um $time: „${e.title}“'
          '${e.location.isEmpty ? '' : ', Ort: ${e.location}'}.\n'
          '${e.notes.trim().isEmpty ? '' : 'Notizen zum Termin: ${e.notes.trim()}\n'}'
          '${page.isEmpty ? 'Keine Webseite bekannt – arbeite nur mit den Termin-Infos.\n' : 'Inhalt der Webseite $site:\n$page\n'}'
          'Gliederung: ## Worum es geht · ## Wer/Was ist die Firma · ## Mögliche Fragen · ## Ziele für das Gespräch. '
          'Erfinde nichts, was nicht in den Infos steht.';
      final text = await _generateText(prompt);
      final file = File('${outputsDir.path}/Vorbereitung ${e.title.replaceAll(RegExp(r'[^\w äöüÄÖÜß-]'), '').trim()} '
          '${now.day}.${now.month}.md');
      await file.writeAsString('# ${e.title} – $time\n\n$text\n');
      conv.entries.add(ChatEntry(
        role: 'assistant',
        text: '**$time ${e.title}**${site == null ? '' : ' · $site'}\n\n${text.split('\n').where((l) => l.trim().isNotEmpty).take(6).join('\n')}',
        files: [file.path],
      ));
      await storage.saveConversation(conv);
      notifyListeners();
    }
    unawaited(logActivity(Activity(kind: 'calendar', title: '${events.length} Termin(e) vorbereitet', conversationId: conv.id,
        approval: automated ? 'Geplante Aufgabe „Termine vorbereiten“' : 'Von dir gestartet')));
    if (automated) {
      unawaited(BackgroundWork.notify('Deine Termine sind vorbereitet', events.map((e) => e.title).join(' · '),
          conversationId: conv.id));
    }
    return conv;
  }

  /// Text ohne Werkzeuge erzeugen (für Hintergrund-Aufgaben).
  Future<String> _generateText(String prompt) async {
    final eng = engine;
    if (eng == null) return '';
    final r = _makeRunner(eng, _systemText(voice: false, tools: const []), tools: const []);
    var out = '';
    await for (final ev in r.run(history: const [], userInput: prompt, context: ToolContext())) {
      if (ev is FinalAnswer) out = ev.text;
    }
    return cleanModelText(out).trim();
  }

  /// Nach jedem Termin (Ende + 2 min) eine Push-Nachricht: „Folgemail entwerfen?“
  void scheduleFollowUps(List<CalendarEvent> events) {
    if (!settings.meetingFollowUp) return;
    final now = DateTime.now();
    for (final e in events) {
      if (e.allDay || !e.end.isAfter(now)) continue;
      final id = 'followup:${base64Url.encode(utf8.encode(e.title)).replaceAll('=', '')}:${e.end.millisecondsSinceEpoch}';
      unawaited(BackgroundWork.notify('Termin vorbei: ${e.title}', 'Soll ich eine Folgemail mit den Zusagen entwerfen?',
          conversationId: id, at: e.end.add(const Duration(minutes: 2))));
    }
  }

  Future<void> setMeetingFollowUp(bool v) async {
    settings.meetingFollowUp = v;
    await storage.saveSettings(settings);
    notifyListeners();
    if (v) unawaited(_planFollowUps());
  }

  /// Termine von heute holen und Folgemail-Erinnerungen setzen (beim Start, ohne Rückfrage).
  Future<void> _planFollowUps() async {
    if (!settings.meetingFollowUp || !DeviceBridge.supported) return;
    // Nur wenn der Kalender schon freigegeben wurde (Morgen-Übersicht oder Termin-Vorbereitung) – beim Start nicht fragen
    if (!prompts.any((p) => p.id == meetingPrepId || p.title == 'Morgen-Übersicht')) return;
    try {
      final now = DateTime.now();
      final ev = await deviceBridge.calendarList(DateTime(now.year, now.month, now.day), DateTime(now.year, now.month, now.day + 1));
      scheduleFollowUps(ev);
    } catch (_) {}
  }

  /// Kurze Nachfrage („wien“, „und morgen?“, „nein, Sport“) – keine neue, eigenständige Frage.
  static bool looksLikeFollowUp(String input) {
    final w = input.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
    if (w.isEmpty) return false;
    // Bezug auf vorher („weitere Ergebnisse dazu“, „mehr davon“, „nochmal“)
    if (w.length <= 10 &&
        RegExp(r'\b(dazu|davon|darüber|daraus|weitere\w*|mehr|nochmal|noch mal|nochmals|erneut|dort|damit|denen|'
                r'diese[nmrs]?|das gleiche|dasselbe|wieder)\b',
                caseSensitive: false)
            .hasMatch(input)) {
      return true;
    }
    if (w.length > 5) return false;
    final first = w.first.toLowerCase().replaceAll(RegExp(r'[^a-zäöüß]'), '');
    if (w.length >= 3 &&
        RegExp(r'^(wer|wie|was|wo|woher|wohin|wann|warum|wieso|weshalb|welche\w*|kannst|könntest|kann|gibt|ist|sind|'
                r'hast|mach\w*|erstell\w*|schreib\w*|zeig\w*|such\w*|öffne\w*|erklär\w*|sag\w*|nenn\w*|übersetz\w*|'
                r'berechne\w*|rechne\w*|ruf\w*|schick\w*)$')
            .hasMatch(first)) {
      return false;
    }
    return true;
  }

  static final _otherIntent = RegExp(
      r'kalender|termin|e-?mail|mail |whatsapp|anruf|ruf .* an|amazon|shop|kauf|bestell|browser|öffne|datei|dokument|'
      r'präsentation|folien|bild|foto|erinner|und dann|außerdem',
      caseSensitive: false);
  static final _weatherIntent = RegExp(
      r'wetter|\bregen\b|regnet|\bschnee\b|schneit|temperatur|\d+\s*grad\b|sonnig|gewitter|\bschirm\b|wird es (warm|kalt|heiß)|vorhersage',
      caseSensitive: false);
  static final _newsIntent =
      RegExp(r'\b(nachrichten|news|schlagzeilen|meldungen|neuigkeiten|was gibt.s neues)\b', caseSensitive: false);
  static const _placeStop = {
    'heute', 'morgen', 'übermorgen', 'der', 'die', 'das', 'den', 'dem', 'diesem', 'dieser', 'diese', 'nächster',
    'nächsten', 'nächste', 'kommenden', 'kommende', 'zukunft', 'montag', 'dienstag', 'mittwoch', 'donnerstag',
    'freitag', 'samstag', 'sonntag', 'woche', 'tagen', 'tage', 'früh', 'abend', 'nacht', 'mittag', 'zeit', 'ordnung',
    'grad', 'celsius', 'meinem', 'meiner', 'unserer', 'unserem', 'ein', 'einer', 'einem', 'zwei', 'drei',
  };

  /// Ort aus „Wetter in Graz“, „für Linz“ – zuerst aus der neuen Nachricht, sonst aus der vorigen.
  static String weatherPlace(String input, String gate) {
    String? find(String t) {
      String? hit;
      for (final m in RegExp(r'\b(?:in|für|fuer|bei|nach|von)\s+([a-zäöüß][\wäöüß.-]*(?:\s+(?:am|an der|im|bei)\s+[\wäöüß-]+)?)',
              caseSensitive: false)
          .allMatches(t)) {
        final p = m.group(1)!.replaceAll(RegExp(r'[.?!,]+$'), '');
        if (!_placeStop.contains(p.toLowerCase().split(' ').first)) hit = p;
      }
      return hit;
    }

    final w = input.trim().replaceAll(RegExp(r'[.?!]+$'), '');
    if (!w.contains(' ') && w.isNotEmpty && !_placeStop.contains(w.toLowerCase()) && !_weatherIntent.hasMatch(w)) return w;
    return find(input) ?? (identical(input, gate) ? null : find(gate)) ?? '';
  }

  static String _newsSourceOf(String t) {
    final l = t.toLowerCase();
    for (final s in newsSources) {
      if (RegExp('\\b${RegExp.escape(s.id)}\\b').hasMatch(l) || l.contains(s.name.toLowerCase())) return s.id;
    }
    if (l.contains('standard')) return 'derstandard';
    return 'auto';
  }

  static String _newsTopicOf(String input, String gate) {
    final m = RegExp(r'\b(?:über|zum thema|zu|zur|zum|rund um)\s+([\wäöüß -]{2,40})', caseSensitive: false).firstMatch(input);
    var topic = m?.group(1)?.trim() ?? '';
    if (topic.isNotEmpty && _newsSourceOf(topic) != 'auto') topic = '';
    final section = newsSection(input) ?? (topic.isEmpty ? newsSection(gate) : null);
    if (section != null && newsSection(topic) == null) topic = topic.isEmpty ? section : '$section $topic';
    return topic;
  }

  /// Welches Werkzeug ohne Planungsschritt sofort laufen kann (Wetter, Nachrichten).
  (AgentTool, Map<String, dynamic>)? directTool(String input, String gate, List<AgentTool> tools) {
    AgentTool? find(String n) => tools.where((t) => t.name == n).firstOrNull;
    // „Suche auf amazon.de nach Brotdosen“ / „such nach X auf willhaben“ → Seite direkt durchsuchen
    final shop = shopSearchOf(input);
    if (shop != null) {
      final browser = find('browser'), site = find('site_search');
      if (browser != null) return (browser, {'action': 'search', 'target': shop.$1, 'text': shop.$2});
      if (site != null) return (site, {'site': shop.$1, 'query': shop.$2});
    }
    // Adresse genannt („geh auf rtb.li/p/ainews …“, „Sportnews auf krone.at“) → diese Seite öffnen
    final page = pageAddressOf(input);
    if (page != null) {
      final browser = find('browser'), fetch = find('web_fetch');
      // Thema nur, wenn ausdrücklich genannt („… zu Anthropic“, „über KI“, „nach Design tools“)
      final rest = input.replaceAll(page.$2, ' ');
      final focus = RegExp(r'\b(?:zu|zum thema|über|nach|bezüglich|rund um)\s+([^.!?]{2,60})', caseSensitive: false)
              .firstMatch(rest)
              ?.group(1)
              ?.trim() ??
          '';
      if (browser != null) return (browser, {'action': 'open', 'target': page.$1, 'text': focus});
      if (fetch != null) return (fetch, {'url': page.$1});
    }
    if (_otherIntent.hasMatch(input)) return null;
    final weather = find('weather'), news = find('news');
    bool isWeather(String t) => weather != null && _weatherIntent.hasMatch(t);
    bool isNews(String t) => news != null && _newsIntent.hasMatch(t);
    // Erst die neue Nachricht, nur bei Nachfragen auch die vorige
    final w = isWeather(input), n = isNews(input);
    // Ging es vorher um eine bestimmte Webseite, bleibt die Nachfrage dort (Browser), nicht im News-Feed
    final gateOk = input != gate && pageAddressOf(gate) == null;
    final useWeather = w || (!n && gateOk && isWeather(gate) && !isNews(gate));
    final useNews = !useWeather && (n || (gateOk && isNews(gate)));
    if (useWeather) return (weather!, {'location': weatherPlace(input, gate), 'days': 7});
    if (useNews) {
      return (news!, {'topic': _newsTopicOf(input, gate), 'source': _newsSourceOf(input) == 'auto' ? _newsSourceOf(gate) : _newsSourceOf(input), 'count': 6});
    }
    return null;
  }

  static const _siteWord = r'([a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:de|at|com|ch|net|org|eu|io|fyi|li|info|app|dev|ai|co|shop)|amazon|ebay|willhaben|geizhals|idealo|'
      r'otto|mediamarkt|thalia|chefkoch|wikipedia|youtube|ikea|zalando)';

  /// (Seite, Suchbegriffe) aus „suche auf X nach Y“ oder „such nach Y auf X“ – sonst null.
  static (String, String)? shopSearchOf(String input) {
    final t = input.trim().replaceAll(RegExp(r'[.!?]+$'), '');
    final a = RegExp('(?:such\\w*|schau\\w*|find\\w*|geh\\w*)?\\s*(?:auf|bei|in)\\s+$_siteWord\\s+(?:und\\s+such\\w*\\s+)?(?:nach|für)\\s+(.{2,120}?)(?:\\s+(?:suchen|finden))?\$',
            caseSensitive: false)
        .firstMatch(t);
    // „brotdosen die spülmaschinenfest sind“ → „brotdosen spülmaschinenfest“
    String q(String x) => x
        .replaceAll(RegExp(r'\b(die|welche|der|das|einen?|eine)\b\s*', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\s+(sind|ist|sein sollen|sein soll|haben)\s*$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (a != null) return (a.group(1)!.toLowerCase(), q(a.group(2)!));
    final b = RegExp('such\\w*\\s+(?:mir\\s+)?(?:nach\\s+)?(.{2,120}?)\\s+(?:auf|bei)\\s+$_siteWord\$', caseSensitive: false).firstMatch(t);
    if (b != null) return (b.group(2)!.toLowerCase(), q(b.group(1)!));
    return null;
  }

  /// (Adresse, gefundener Text) einer genannten Webseite – sonst null. E-Mail-Adressen zählen nicht.
  static (String, String)? pageAddressOf(String input) {
    final u = RegExp(r'https?://[^\s<>"]+', caseSensitive: false).firstMatch(input);
    if (u != null) return (u.group(0)!.replaceAll(RegExp(r'[.,;:!?)]+$'), ''), u.group(0)!);
    final d = RegExp(r'(?<![@\w.-])((?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:at|de|com|ch|li|net|org|io|eu|info|fyi|app|dev|ai|co|shop)(?:/[^\s<>"]*)?)',
            caseSensitive: false)
        .firstMatch(input);
    if (d == null) return null;
    final addr = d.group(1)!.replaceAll(RegExp(r'[.,;:!?)]+$'), '');
    return ('https://$addr', d.group(0)!);
  }

  /// Titel für eine Karte aus einer nackten Adresse: „amazon.de – Suche: brotdosen“.
  static String _linkTitle(String url) {
    final u = Uri.tryParse(cleanLink(url));
    if (u == null || u.host.isEmpty) return url;
    final host = u.host.replaceFirst(RegExp(r'^www\.'), '');
    final q = u.queryParameters['k'] ?? u.queryParameters['q'] ?? u.queryParameters['query'] ??
        u.queryParameters['search_query'] ?? u.queryParameters['fs'] ?? u.queryParameters['s'];
    if (q != null && q.trim().isNotEmpty) return '$host – Suche: ${q.trim()}';
    final seg = u.pathSegments.where((p) => p.isNotEmpty && p != 'dp' && !RegExp(r'^[A-Z0-9]{10}$').hasMatch(p)).firstOrNull;
    if (seg == null) return host;
    final name = Uri.decodeComponent(seg).replaceAll(RegExp(r'[-_+]+'), ' ').replaceAll(RegExp(r'\.(html?|php|aspx?)$'), '');
    return '$host – ${name.length > 60 ? '${name.substring(0, 59)}…' : name}';
  }

  /// Kategorie einer Karte: Thema der Nachrichten, Suchbegriff, Seite.
  static String cardTag(String tool, Map<String, dynamic>? args) {
    String a(String k) => '${args?[k] ?? ''}'.trim();
    return switch (tool) {
      'news' => a('topic').isEmpty ? 'Top-Meldungen' : a('topic'),
      'web_search' => a('query').isEmpty ? 'Websuche' : 'Suche: ${a('query')}',
      'site_search' => a('site').isEmpty ? 'Shop' : a('site'),
      'web_fetch' => Uri.tryParse(a('url'))?.host.replaceFirst('www.', '') ?? 'Webseite',
      'browser' => 'Browser',
      _ => tool,
    };
  }

  /// Entfernt Links mit Pfad, die in keiner Quelle (Werkzeug, Dokument, Frage) vorkamen –
  /// also vom Modell erfunden wurden. Der Linktext bleibt, „(Beispiel-Link)“ verschwindet.
  static String stripInventedLinks(String text, String known) {
    final k = known.toLowerCase();
    bool real(String url) {
      final u = Uri.tryParse(url.trim());
      if (u == null || u.host.isEmpty) return false;
      if (u.path.length <= 1 && u.query.isEmpty) return true; // nur Domain: harmlos
      final c = cleanLink(url).toLowerCase().replaceFirst(RegExp(r'^https?://(www\.)?'), '');
      final core = c.length > 80 ? c.substring(0, 80) : c;
      return k.contains(core) || k.contains(url.toLowerCase());
    }

    var t = text.replaceAllMapped(RegExp(r'\[([^\]]+)\]\((https?://[^)\s]+)\)'), (m) => real(m.group(2)!) ? m.group(0)! : m.group(1)!);
    t = t.replaceAllMapped(RegExp(r'(?<![\(\w])https?://[^\s<>()\[\]]*[^\s<>()\[\].,;:!?\x27"]'), (m) => real(m.group(0)!) ? m.group(0)! : '');
    t = t.replaceAll(RegExp(r'\s*\((Beispiel-?Link|Beispiel|Link)\)', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'(Link|Quelle):\s*(?=\n|$)', caseSensitive: false), '');
    return t;
  }

  /// Entfernt nackte Adressen und „(Quellen: …)“-Anhänge – die Karten zeigen die Links.
  static String _stripCardLinks(String text) {
    var t = text.replaceAll(RegExp(r'\s*\((Quellen?|Quelle|Links?):[^)]*https?://[^)]*\)', caseSensitive: false), '');
    t = t.replaceAllMapped(RegExp(r'(?<!\]\()https?://[^\s<>()\[\]]{60,}'), (m) => '„${_linkTitle(m.group(0)!)}“ (Karte unten)');
    return t.replaceAll(RegExp(r'[ \t]+\n'), '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// Reine Rechenfrage („Was ist 15 % von 2.340 €?“) sofort ausrechnen.
  static String? quickCalc(String input) {
    var e = input.trim().toLowerCase();
    if (!RegExp(r'\d').hasMatch(e) || e.length > 120) return null;
    e = e
        .replaceFirst(RegExp(r'^(hey |hi |bitte )?(was|wie ?viel|wieviel) (ist|sind|ergibt|macht|gibt)\s+'), '')
        .replaceFirst(RegExp(r'^(rechne|berechne|kalkuliere)( mal| bitte)?:?\s+'), '')
        .replaceAll(RegExp(r'[?!=]+\s*$'), '')
        .replaceAll(RegExp(r'\bmal\b'), '*')
        .replaceAll(RegExp(r'\bgeteilt durch\b|\bdurch\b'), '/')
        .replaceAll(RegExp(r'\bplus\b'), '+')
        .replaceAll(RegExp(r'\bminus\b'), '-')
        .trim();
    if (!RegExp(r'^[\d\s.,+\-*/^()%€$a-zäöü]*$').hasMatch(e)) return null;
    if (!RegExp(r'[+\-*/^%]|prozent|von').hasMatch(e)) return null;
    if (RegExp(r'[a-zäöü]{3,}').allMatches(e).any((m) => !const {'von', 'prozent', 'eur', 'euro', 'of'}.contains(m.group(0)))) {
      return null;
    }
    try {
      final v = CalculatorTool.evaluate(e);
      if (v.isNaN || v.isInfinite) return null;
      return '$e = ${CalculatorTool.format(v)}';
    } catch (_) {
      return null;
    }
  }

  /// true, solange der System-Prompt nach dem Laden vorgerechnet wird
  bool warming = false;

  /// Rechnet nach dem Laden den System-Prompt vor (oder lädt ihn von der Platte),
  /// damit die erste Antwort sofort beginnt.
  Future<void> warmUp({bool voice = false}) async {
    final eng = engine;
    final m = loadedModel;
    if (eng == null || m == null || running || warming) return;
    warming = true;
    notifyListeners();
    try {
      final r = voice
          ? _makeRunner(eng, _systemText(tools: const []), tools: const [])
          : _makeRunner(eng, _systemText());
      final prompt = await eng.formatChat([ChatMessage('system', r.buildSystemPrompt(ToolContext()))]);
      var h = 0xcbf29ce484222325;
      for (final c in '${m.path}|${m.sizeBytes}|${eng.contextSize}|${device.quantizeKv}|$prompt'.codeUnits) {
        h = ((h ^ c) * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
      }
      final dir = Directory('${storage.root.path}/kvcache')..createSync(recursive: true);
      final f = File('${dir.path}/${h.toRadixString(16)}.bin');
      var ok = false;
      if (f.existsSync()) {
        ok = await eng.loadState(f.path) > 0;
        if (ok) f.setLastModifiedSync(DateTime.now());
      }
      if (!ok && engine == eng) {
        await eng.prefill(prompt);
        if (engine == eng && await eng.saveState(f.path) > 0) {
          // höchstens 4 Zustände behalten
          final all = dir.listSync().whereType<File>().toList()
            ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
          for (final old in all.skip(4)) {
            try {
              old.deleteSync();
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('Vorberechnung: $e');
    } finally {
      warming = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------- Bearbeiten / Wiederholen

  /// Sendet die Nutzernachricht an [index] erneut (optional mit neuem Text);
  /// alles danach im Chat wird verworfen.
  Future<void> resendFrom(int index, {String? newText, bool cloud = false, bool strong = false}) async {
    final conv = current;
    if (conv == null || running || index < 0 || index >= conv.entries.length) return;
    final entry = conv.entries[index];
    if (entry.role != 'user') return;
    final text = (newText ?? entry.text).trim();
    if (text.isEmpty) return;
    conv.entries.removeRange(index, conv.entries.length);
    await storage.saveConversation(conv);
    notifyListeners();
    await send(text, voice: entry.viaVoice, forceCloud: cloud, forceStrong: strong);
  }

  /// „Mit Cloud/On-Prem beantworten“ unter einer Antwort: bei Cloud mit Freigabe, dann neu beantworten.
  Future<void> answerWithCloud(int answerIndex) async {
    final conv = current;
    final p = escalationProvider(conv);
    if (conv == null || running || p == null) return;
    if (escalatesToCloud(conv) && !conv.cloudAllowed) {
      final ask = cloudConsentHandler;
      if (ask == null) return;
      final choice = await ask('Diese Frage mit ${p.name} (${p.model}) beantworten?');
      if (choice == NetworkChoice.deny) return;
      await _logCloudConsent(conv, choice);
    }
    for (var i = answerIndex - 1; i >= 0; i--) {
      if (conv.entries[i].role == 'user') return resendFrom(i, cloud: true);
    }
  }

  Future<void> _logCloudConsent(Conversation conv, NetworkChoice choice) async {
    unawaited(logActivity(Activity(
        kind: 'internet',
        title: choice == NetworkChoice.chat ? 'Cloud-Anbieter für einen Chat freigegeben' : 'Eine Frage an den Cloud-Anbieter',
        detail: '${cloudProvider?.name ?? ''} · ${cloudProvider?.model ?? ''}',
        approval: choice == NetworkChoice.chat ? 'Du hast „Ganzer Chat“ gewählt' : 'Du hast „Einmal“ gewählt',
        conversationId: conv.id)));
    if (choice == NetworkChoice.chat) {
      conv.cloudAllowed = true;
      await storage.saveConversation(conv);
      notifyListeners();
    }
  }

  /// Cloud-Freigabe für diesen Chat zurücknehmen.
  Future<void> revokeCloud() async {
    final conv = current;
    if (conv == null) return;
    conv.cloudAllowed = false;
    await storage.saveConversation(conv);
    notifyListeners();
  }

  // ------------------------------------------------- KI-Anbieter (On-Prem / Cloud)

  /// Fragt, ob die Cloud benutzt werden darf (Nein / Einmal / Ganzer Chat).
  Future<NetworkChoice> Function(String reason)? cloudConsentHandler;

  List<ProviderConfig> get providers => [for (final m in settings.providers) ProviderConfig.fromJson(m)];

  ProviderConfig? providerById(String? id) => id == null ? null : providers.where((p) => p.id == id).firstOrNull;

  ProviderConfig? get onPremProvider =>
      providerById(settings.onPremId) ?? providers.where((p) => p.onPrem && p.enabled).firstOrNull;

  ProviderConfig? get cloudProvider =>
      providerById(settings.cloudId) ?? providers.where((p) => !p.onPrem && p.enabled).firstOrNull;

  Future<void> saveProvider(ProviderConfig p, {String? apiKey}) async {
    final list = providers;
    final i = list.indexWhere((x) => x.id == p.id);
    if (i >= 0) {
      list[i] = p;
    } else {
      list.add(p);
    }
    if (apiKey != null) await Vault.write('provider:${p.id}', apiKey.trim().isEmpty ? null : apiKey.trim());
    settings.providers = [for (final x in list) x.toJson()];
    if (p.onPrem && settings.onPremId == null) settings.onPremId = p.id;
    if (!p.onPrem && settings.cloudId == null) settings.cloudId = p.id;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  Future<void> removeProvider(String id) async {
    settings.providers = [for (final x in providers) if (x.id != id) x.toJson()];
    if (settings.onPremId == id) settings.onPremId = null;
    if (settings.cloudId == id) settings.cloudId = null;
    try {
      await Vault.write('provider:$id', null);
    } catch (_) {}
    await storage.saveSettings(settings);
    notifyListeners();
  }

  Future<void> setRouting({String? routing, String? hybridFirst, String? hybridTarget, String? onPremId, String? cloudId}) async {
    if (routing != null) settings.routing = routing;
    if (hybridFirst != null) settings.hybridFirst = hybridFirst;
    if (hybridTarget != null) settings.hybridTarget = hybridTarget;
    if (onPremId != null) settings.onPremId = onPremId;
    if (cloudId != null) settings.cloudId = cloudId;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  Future<bool> providerHasKey(String id) async => (await Vault.read('provider:$id'))?.isNotEmpty ?? false;

  Future<RemoteBackend> remoteBackend(ProviderConfig p) async =>
      RemoteBackend(p, apiKey: await Vault.read('provider:${p.id}'));

  // ---- KI-Modus: pro Chat wählbar, sonst aus den Einstellungen
  // Werte im Chat: local | onprem | cloud | hybrid-onprem | hybrid-cloud

  /// local | onprem | cloud | hybrid
  String routingOf(Conversation? c) {
    final r = c?.routing ?? settings.routing;
    return r.startsWith('hybrid') ? 'hybrid' : r;
  }

  /// Hybrid: womit zuerst (local | onprem)
  String hybridFirstOf(Conversation? c) => c?.routing != null ? 'local' : settings.hybridFirst;

  /// Hybrid: wohin danach (onprem | cloud)
  String hybridTargetOf(Conversation? c) {
    final r = c?.routing;
    final t = (r != null && r.startsWith('hybrid-')) ? r.substring(7) : settings.hybridTarget;
    // erst On-Prem, dann On-Prem ergibt keinen Sinn
    return t == 'onprem' && hybridFirstOf(c) != 'onprem' ? 'onprem' : 'cloud';
  }

  bool escalatesToCloud(Conversation? c) => hybridTargetOf(c) == 'cloud';

  /// Wohin „Mit … beantworten“ bzw. der Rückfall im Hybrid-Modus geht.
  ProviderConfig? escalationProvider(Conversation? c) =>
      routingOf(c) != 'hybrid' ? null : (escalatesToCloud(c) ? cloudProvider : onPremProvider);

  /// KI-Modus für den aktuellen Chat setzen (null = wie in den Einstellungen).
  Future<void> setChatRouting(String? mode) async {
    final c = _ensureConversation();
    c.routing = mode;
    // Cloud ausdrücklich für diesen Chat gewählt = Freigabe für diesen Chat
    if (mode == 'cloud') c.cloudAllowed = true;
    await storage.saveConversation(c);
    notifyListeners();
  }

  /// Bezeichnung eines Modus für Menüs.
  static String routingName(String mode) => switch (mode) {
        'local' => 'Am Gerät',
        'onprem' => 'On-Prem',
        'cloud' => 'Cloud',
        'hybrid-onprem' => 'Hybrid: Gerät → On-Prem',
        'hybrid-cloud' => 'Hybrid: Gerät → Cloud',
        'hybrid' => 'Hybrid',
        _ => mode,
      };

  /// Kurzinfo für Kopfzeilen: null = alles lokal.
  String? get routingLabel {
    final c = current;
    return switch (routingOf(c)) {
      'onprem' => onPremProvider == null ? 'On-Prem nicht eingerichtet' : 'On-Prem · ${onPremProvider!.name}',
      'cloud' => cloudProvider == null ? 'Cloud nicht eingerichtet' : 'Cloud · ${cloudProvider!.name}',
      'hybrid' => escalatesToCloud(c)
          ? (c?.cloudAllowed == true ? 'Cloud freigegeben' : 'Gerät → Cloud nach Freigabe')
          : 'Gerät → On-Prem',
      _ => null,
    };
  }

  /// Kann gerade geantwortet werden (lokal oder über einen Anbieter)?
  bool get canChat {
    final c = current;
    return switch (routingOf(c)) {
      'onprem' => onPremProvider != null,
      'cloud' => cloudProvider != null,
      'hybrid' => hybridFirstOf(c) == 'onprem' ? onPremProvider != null : status == EngineStatus.ready,
      _ => status == EngineStatus.ready,
    };
  }

  /// Wählt das Modell für eine Antwort: (Backend, Anzeige, ist Cloud).
  Future<(AgentBackend?, String?, bool)> _backendFor(Conversation conv,
      {bool forceCloud = false, String input = '', int docChars = 0, bool forceStrong = false, bool voice = false}) async {
    final r = routingOf(conv);
    Future<(AgentBackend?, String?, bool)> remote(ProviderConfig? p, bool cloud) async =>
        p == null ? (null, null, cloud) : (await remoteBackend(p), '${cloud ? 'Cloud' : 'On-Prem'} · ${p.name} · ${p.model}', cloud);
    final toCloud = escalatesToCloud(conv);
    // forceCloud = Rückfall/Knopf „Mit … beantworten“
    if (forceCloud) return toCloud || r == 'cloud' ? remote(cloudProvider, true) : remote(onPremProvider, false);
    if (r == 'cloud' || (r == 'hybrid' && toCloud && conv.cloudAllowed)) return remote(cloudProvider, true);
    if (r == 'onprem' || (r == 'hybrid' && hybridFirstOf(conv) == 'onprem')) return remote(onPremProvider, false);
    final (e, v) = await _localFor(conv, input, docChars: docChars, forceStrong: forceStrong, voice: voice);
    return (e, v, false);
  }

  // ------------------------------------------------- Automatische Modellwahl

  /// Großes Modell, wenn es dauerhaft neben dem kleinen geladen bleibt (Speicherplan „beide“).
  LlamaEngine? strongEngine;
  StoredModel? strongResident;

  /// Letzter Speicherplan (für die Anzeige in den Einstellungen).
  ModelPlan? modelPlan;
  final Map<String, bool> _complexConv = {};
  final Map<String, GgufInfo> _infoCache = {};
  Timer? _swapBack;
  Timer? _strongIdle;
  Timer? _typingDebounce;
  bool _loadingStrong = false;

  /// Text für die Anzeige über dem Eingabefeld, solange ein Modell gewechselt/geladen wird.
  String? get modelSwitching {
    if (_loadingStrong) return statusMessage ?? 'Lade Modell für komplexe Aufgaben …';
    if (status == EngineStatus.loading && modelPair != null) return statusMessage ?? 'Modell wird geladen …';
    return null;
  }

  /// Schnelles und starkes Modell (null = keine automatische Wahl möglich/gewünscht).
  (StoredModel, StoredModel)? get modelPair {
    if (!settings.autoModel) return null;
    final f = models.where((m) => m.id == settings.fastModelId).firstOrNull;
    final st = models.where((m) => m.id == settings.strongModelId).firstOrNull;
    if (f != null && st != null && f.id != st.id) return (f, st);
    final budget = device.memoryBudget();
    final auto = pickModelPair<StoredModel>(models, (m) => m.sizeBytes,
        fits: (m) => DeviceProfile.estimateRuntimeBytes(m.sizeBytes) <= budget);
    if (auto == null) return null;
    return (f ?? auto.$1, st ?? auto.$2);
  }

  Future<GgufInfo> _info(StoredModel m) async => _infoCache[m.path] ??= await GgufInfo.read(m.path);

  int _ctxFor(GgufInfo info) {
    var ctx = device.clampContext(contextTarget, info);
    for (final c in [ctx, 8192, 4096, 2048]) {
      if (c <= ctx && device.checkFit(info, c).level == FitLevel.ok) return c;
    }
    return math.min(ctx, 2048);
  }

  Future<ModelPlan?> refreshModelPlan() async {
    final pair = modelPair;
    if (pair == null) {
      modelPlan = null;
      return null;
    }
    try {
      final a = await _info(pair.$1), b = await _info(pair.$2);
      // Bereits geladene Modelle zählen zum verfügbaren Speicher dazu
      final loaded = (engine != null ? DeviceProfile.estimateRuntimeBytes(loadedModel?.sizeBytes ?? 0) : 0) +
          (strongEngine != null ? DeviceProfile.estimateRuntimeBytes(strongResident?.sizeBytes ?? 0) : 0);
      modelPlan = planResidency(device, a, _ctxFor(a), b, _ctxFor(b), available: LlamaEngine.availableMemory() + loaded);
    } catch (e) {
      appLog('Modellwahl', 'Speicherplan: $e', error: true);
      modelPlan = null;
    }
    return modelPlan;
  }

  String _modelLabel(StoredModel? m) => 'Lokal · ${m?.displayName ?? 'Modell'}';

  /// Wählt das lokale Modell für eine Anfrage.
  Future<(AgentBackend?, String?)> _localFor(Conversation conv, String input,
      {int docChars = 0, bool forceStrong = false, bool voice = false}) async {
    final pair = modelPair;
    if (pair == null) return (engine as AgentBackend?, null);
    final (fast, strong) = pair;
    final a = assessTask(input, docChars: docChars, previousComplex: _complexConv[conv.id] ?? false);
    final complex = forceStrong || a.complex;
    _complexConv[conv.id] = complex;
    final plan = modelPlan ?? await refreshModelPlan();
    appLog('Modellwahl', '${complex ? 'komplex' : 'einfach'} – $a · Plan ${plan?.residency.name}');
    if (complex && plan != null && plan.residency != Residency.fastOnly) {
      if (plan.residency == Residency.both || strongEngine != null) {
        if (strongEngine == null) await _loadStrongResident(strong);
        if (strongEngine != null) {
          _touchStrong();
          return (strongEngine as AgentBackend?, _modelLabel(strong));
        }
      } else if (!voice || loadedModel?.id == strong.id) {
        // Wechsel: kleines Modell freigeben, großes laden; später automatisch zurück
        if (loadedModel?.id != strong.id) {
          statusMessage = 'Komplexe Aufgabe – lade ${strong.displayName} …';
          notifyListeners();
          await loadModel(strong, remember: false);
        }
        if (loadedModel?.id == strong.id) {
          _scheduleSwapBack(fast);
          return (engine as AgentBackend?, _modelLabel(strong));
        }
      }
    }
    if (engine == null) await _ensureEngine();
    // Einfache Frage, während gerade das große Modell geladen ist: einfach damit antworten (kein Hin und Her)
    if (loadedModel?.id == strong.id) _scheduleSwapBack(fast);
    return (engine as AgentBackend?, _modelLabel(loadedModel));
  }

  Future<void> _loadStrongResident(StoredModel m) async {
    if (_loadingStrong || strongResident?.id == m.id) return;
    _loadingStrong = true;
    final prev = statusMessage;
    statusMessage = 'Lade ${m.displayName} für komplexe Aufgaben …';
    notifyListeners();
    try {
      final info = await _info(m);
      final sw = Stopwatch()..start();
      strongEngine = await LlamaEngine.load(device.engineConfig(m.path, _ctxFor(info)));
      strongResident = m;
      appLog('Modellwahl', '${m.displayName} zusätzlich geladen in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');
      _touchStrong();
    } catch (e) {
      strongEngine = null;
      strongResident = null;
      appLog('Modellwahl', '${m.displayName} konnte nicht zusätzlich geladen werden: $e', error: true);
    } finally {
      _loadingStrong = false;
      statusMessage = prev;
      _pollMemory();
      notifyListeners();
    }
  }

  Future<void> _disposeStrong() async {
    _strongIdle?.cancel();
    final e = strongEngine;
    strongEngine = null;
    strongResident = null;
    if (e != null) await e.dispose();
  }

  /// Großes Modell nach längerer Pause freigeben (Speicher und Akku schonen).
  void _touchStrong() {
    _strongIdle?.cancel();
    _strongIdle = Timer(Duration(minutes: device.isMobile ? 5 : 30), () async {
      if (running) return _touchStrong();
      appLog('Modellwahl', '${strongResident?.displayName} nach Pause freigegeben');
      await _disposeStrong();
      _pollMemory();
      notifyListeners();
    });
  }

  /// Nach dem Wechsel aufs große Modell: nach einer Pause zurück zum schnellen.
  void _scheduleSwapBack(StoredModel fast) {
    _swapBack?.cancel();
    _swapBack = Timer(Duration(minutes: device.isMobile ? 3 : 8), () async {
      if (running || status == EngineStatus.loading) return _scheduleSwapBack(fast);
      if (loadedModel?.id == fast.id) return;
      appLog('Modellwahl', 'Pause – zurück zu ${fast.displayName}');
      await loadModel(fast);
    });
  }

  /// Desktop mit genug Speicher: großes Modell im Hintergrund vorladen.
  Future<void> _preloadStrongIfRoomy() async {
    final pair = modelPair;
    if (pair == null || headless || strongEngine != null || loadedModel?.id == pair.$2.id) return;
    final plan = await refreshModelPlan();
    if (plan?.residency == Residency.both && !device.isMobile) await _loadStrongResident(pair.$2);
  }

  /// Beim Tippen: Sieht die Anfrage komplex aus, das große Modell schon vorbereiten.
  void typingHint(String text) {
    _typingDebounce?.cancel();
    if (text.trim().length < 25 || modelPair == null) return;
    _typingDebounce = Timer(const Duration(milliseconds: 700), () async {
      final pair = modelPair;
      final conv = current;
      if (pair == null || running || status == EngineStatus.loading || _loadingStrong) return;
      if (!assessTask(text, previousComplex: conv == null ? false : (_complexConv[conv.id] ?? false)).complex) return;
      final plan = modelPlan ?? await refreshModelPlan();
      if (plan == null || plan.residency == Residency.fastOnly) return;
      if (plan.residency == Residency.both) {
        if (strongEngine == null) await _loadStrongResident(pair.$2);
      } else if (loadedModel?.id != pair.$2.id) {
        appLog('Modellwahl', 'Komplexe Eingabe erkannt – lade ${pair.$2.displayName} schon beim Tippen');
        statusMessage = 'Bereite ${pair.$2.displayName} vor …';
        notifyListeners();
        await loadModel(pair.$2, remember: false);
        _scheduleSwapBack(pair.$1);
      }
    });
  }

  Future<void> setAutoModel({bool? enabled, String? fastId, String? strongId}) async {
    if (enabled != null) settings.autoModel = enabled;
    if (fastId != null) settings.fastModelId = fastId.isEmpty ? null : fastId;
    if (strongId != null) settings.strongModelId = strongId.isEmpty ? null : strongId;
    await storage.saveSettings(settings);
    if (!settings.autoModel) await _disposeStrong();
    await refreshModelPlan();
    notifyListeners();
    unawaited(_preloadStrongIfRoomy());
  }

  /// Erzeugt die Antwort an [index] neu.
  Future<void> regenerate(int index) async {
    final conv = current;
    if (conv == null) return;
    for (var i = index - 1; i >= 0; i--) {
      if (conv.entries[i].role == 'user') return resendFrom(i);
    }
  }

  // ------------------------------------------------- Gespeicherte Prompts

  Future<void> savePrompt(SavedPrompt p) async {
    final i = prompts.indexWhere((x) => x.id == p.id);
    final old = i >= 0 ? prompts[i] : null;
    // Neuer oder geänderter Zeitplan: erst ab jetzt zählen (nichts sofort "nachholen")
    if (old == null || old.scheduleLabel != p.scheduleLabel) p.lastRun = DateTime.now();
    if (i >= 0) {
      prompts[i] = p;
    } else {
      prompts.add(p);
    }
    await storage.savePrompts(prompts);
    if (p.schedule != ScheduleKind.off && p.notify) unawaited(BackgroundWork.requestNotifyPermission());
    unawaited(_syncAlarms());
    notifyListeners();
  }

  Future<void> deletePrompt(SavedPrompt p) async {
    prompts.removeWhere((x) => x.id == p.id);
    await storage.savePrompts(prompts);
    unawaited(_syncAlarms());
    notifyListeners();
  }

  /// Android: Wecker für die nächsten Termine (auch bei geschlossener App).
  // ------------------------------------------------------------ Gerät

  Future<void> _initDevice() async {
    deviceBridge
      ..onLaunchAction = ((a) {
        pendingLaunch.value = a;
      })
      ..onShared = receiveShared
      ..init();
    await deviceBridge.grantFolders([
      for (final f in [...settings.grantedFolders, ...settings.watchFolders]) f['id']!,
    ]);
    final (action, shared) = await deviceBridge.takeLaunch();
    if (shared != null) await receiveShared(shared);
    if (action != null) pendingLaunch.value = action;
    unawaited(updateQuickActions());
    if (settings.watchFolders.isNotEmpty) {
      unawaited(Future<void>.delayed(const Duration(seconds: 20), scanWatchFolders));
    }
    _watchTimer?.cancel();
    _watchTimer = Timer.periodic(const Duration(minutes: 30), (_) => scanWatchFolders());
  }

  /// „Teilen an Junels“ / Dateien aufs Dock-Symbol: als Anhang bzw. Text ins Eingabefeld.
  Future<void> receiveShared(SharedContent c) async {
    final errors = <String>[];
    for (final (path, name) in c.files) {
      final err = await addAttachment(path, name);
      if (err != null) errors.add(err);
    }
    if (c.send && c.text.isNotEmpty && c.files.isEmpty && !running) {
      // Kurzbefehl: neue Frage direkt stellen
      newConversation();
      unawaited(send(c.text));
      appLog('Teilen', 'Frage per Kurzbefehl');
      return;
    }
    if (c.text.isNotEmpty) pendingInput.value = c.text;
    appLog('Teilen', '${c.files.length} Datei(en)${c.text.isEmpty ? '' : ', Text'} empfangen');
    if (errors.isNotEmpty) statusMessage = errors.join('\n');
    notifyListeners();
  }

  /// Schnellstart-Knöpfe (Android: lange auf das Symbol drücken; Mac: Dock-Menü).
  Future<void> updateQuickActions() => deviceBridge.setQuickActions([
        ('conversation', 'Gespräch starten'),
        ('newchat', 'Neuer Chat'),
        for (final p in prompts.take(3)) ('prompt:${p.id}', p.title),
      ]);

  /// Ordner, deren neue PDFs/Texte automatisch in die Wissensbasis kommen.
  Future<void> addWatchFolder() async {
    final f = await deviceBridge.pickFolder(message: 'Ordner überwachen: neue PDFs kommen in die Wissensbasis');
    if (f == null) return;
    settings.watchFolders.add({'id': f['id']!, 'name': f['name'] ?? f['path'] ?? 'Ordner', 'since': '0'});
    await storage.saveSettings(settings);
    notifyListeners();
    await scanWatchFolders();
  }

  Future<void> removeWatchFolder(Map<String, String> f) async {
    settings.watchFolders.removeWhere((x) => x['id'] == f['id']);
    await storage.saveSettings(settings);
    notifyListeners();
  }

  bool _scanning = false;
  Future<void> scanWatchFolders() async {
    if (_scanning || settings.watchFolders.isEmpty) return;
    _scanning = true;
    try {
      var added = 0;
      for (final f in settings.watchFolders) {
        final since = int.tryParse(f['since'] ?? '0') ?? 0;
        var newest = since;
        try {
          for (final (path, name, mod) in await deviceBridge.scanFolder(f['id']!, since)) {
            final err = await addFileSource(path, name);
            if (err == null) {
              added++;
            } else {
              appLog('Ordner', err, error: true);
            }
            if (mod > newest) newest = mod;
          }
        } catch (e) {
          appLog('Ordner', '${f['name']}: $e', error: true);
        }
        f['since'] = '$newest';
      }
      await storage.saveSettings(settings);
      if (added > 0) {
        appLog('Ordner', '$added neue Datei(en) in die Wissensbasis übernommen');
        notifyListeners();
      }
    } finally {
      _scanning = false;
    }
  }

  /// Mac: Ordner für die Dateihilfe freigeben.
  Future<void> addGrantedFolder() async {
    final f = await deviceBridge.pickFolder(message: 'Ordner freigeben: Junels darf hier Dateien suchen, umbenennen und verschieben');
    if (f == null) return;
    settings.grantedFolders.add({'id': f['id']!, 'name': f['name'] ?? '', 'path': f['path'] ?? ''});
    await storage.saveSettings(settings);
    notifyListeners();
  }

  Future<void> removeGrantedFolder(Map<String, String> f) async {
    settings.grantedFolders.removeWhere((x) => x['id'] == f['id']);
    await storage.saveSettings(settings);
    notifyListeners();
  }

  Future<void> setHomeCity(String city, {String? countryCode}) async {
    settings.homeCity = city.trim();
    if (countryCode != null && countryCode.trim().isNotEmpty) settings.countryCode = countryCode.replaceAll(RegExp(r'\D'), '');
    await storage.saveSettings(settings);
    notifyListeners();
  }

  /// Morgen-Übersicht als geplanten Prompt anlegen (Termine, Wetter, Nachrichten → Push).
  Future<SavedPrompt> createMorningBriefing({required String city, int hour = 7, int minute = 0, String topics = ''}) async {
    await setHomeCity(city);
    final text = 'Erstelle meine Morgen-Übersicht für heute:\n'
        '1. Rufe meine Termine für heute aus dem Kalender ab (calendar_list).\n'
        '2. Hole das Wetter für $city für heute (weather).\n'
        '3. Hole die wichtigsten Nachrichten${topics.trim().isEmpty ? '' : ' zu: ${topics.trim()}'} (news, 5 Meldungen).\n'
        'Fasse alles kurz und übersichtlich zusammen: zuerst Termine, dann Wetter (mit Tipp, z. B. Schirm), $_morningNewsLine';
    final existing = prompts.where((p) => p.title == 'Morgen-Übersicht').firstOrNull;
    final p = SavedPrompt(
      id: existing?.id,
      title: 'Morgen-Übersicht',
      text: text,
      schedule: ScheduleKind.daily,
      hour: hour,
      minute: minute,
      allowInternet: true,
      notify: true,
      lastRun: existing?.lastRun,
    );
    await savePrompt(p);
    // Kalender-Zugriff gleich jetzt erfragen – morgens im Hintergrund ginge das nicht
    if (DeviceBridge.supported) {
      try {
        final now = DateTime.now();
        await deviceBridge.calendarList(DateTime(now.year, now.month, now.day), DateTime(now.year, now.month, now.day + 1));
      } catch (e) {
        appLog('Gerät', 'Kalender-Zugriff: $e', error: true);
      }
    }
    return p;
  }

  /// Nach einem Abgleich: Prompts speichern und Wecker neu setzen.
  Future<void> promptsChangedExternally() async {
    await storage.savePrompts(prompts);
    unawaited(_syncAlarms());
    notifyListeners();
  }

  /// Oberfläche nach Änderungen von außen (Abgleich) neu zeichnen.
  void refreshUi() => notifyListeners();

  Future<void> _syncAlarms() async {
    unawaited(updateQuickActions());
    final now = DateTime.now();
    final watchAt = watchlist.nextDue;
    await BackgroundWork.schedule([
      for (final p in prompts)
        if (p.nextAfter(now) case final at?) (id: p.id, title: p.title, at: at),
      for (final f in flows.flows)
        if (f.nextAfter(now) case final at?) (id: 'flow:${f.id}', title: f.name, at: at),
      if (watchAt != null) (id: '__watch__', title: 'Watchlist', at: watchAt.isBefore(now) ? now.add(const Duration(minutes: 1)) : watchAt),
    ]);
  }

  Future<void> syncAutomationAlarms() => _syncAlarms();

  /// Weckruf bzw. Hintergrundlauf für Watchlist ('__watch__') oder Prozess ('flow:<id>').
  Future<bool> runAutomation(String id) async {
    if (id == '__watch__') {
      await watchlist.checkDue();
      unawaited(_syncAlarms());
      return true;
    }
    if (id.startsWith('flow:')) {
      final wf = flows.flows.where((f) => f.id == id.substring(5)).firstOrNull;
      if (wf != null) await flows.run(wf);
      unawaited(_syncAlarms());
      return true;
    }
    return false;
  }

  /// Chat, in dem Prozess-Läufe protokolliert werden.
  Conversation automationConversation() {
    const id = 'automatik';
    var c = conversations.where((x) => x.id == id).firstOrNull;
    if (c == null) {
      c = Conversation(id: id, title: '⚙ Automatik');
      conversations.insert(0, c);
    }
    return c;
  }

  /// Modell für Hintergrund-Aufgaben: folgt der Einstellung „Wer antwortet?“,
  /// fragt aber nie nach Cloud-Freigabe (dafür ist niemand da).
  Future<AgentBackend?> _automationBackend() async {
    switch (settings.routing) {
      case 'cloud':
        final p = cloudProvider;
        if (p != null) return remoteBackend(p);
      case 'onprem':
        final p = onPremProvider;
        if (p != null) return remoteBackend(p);
      case 'hybrid':
        if (settings.hybridFirst == 'onprem' && onPremProvider != null) return remoteBackend(onPremProvider!);
    }
    if (!await _ensureEngine()) return null;
    return engine;
  }

  Future<T> _exclusive<T>(String convId, Future<T> Function() body) async {
    // Lokales Modell kann nur eine Sache gleichzeitig – auf laufende Antworten warten
    for (var i = 0; i < 1800 && running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    running = true;
    runningConvId = convId;
    runStarted = DateTime.now();
    notifyListeners();
    try {
      return await body();
    } finally {
      running = false;
      runningConvId = null;
      runStarted = null;
      notifyListeners();
      _drainQueue();
    }
  }

  /// Einfache Textantwort für Hintergrund-Aufgaben (Zusammenfassen, Prozesse erzeugen).
  Future<String> automationText(String prompt, {String? grammar, int maxTokens = 600}) async {
    final eng = await _automationBackend();
    if (eng == null) return '';
    return _exclusive('automatik', () async {
      final msgs = [ChatMessage('system', _systemText(voice: false, tools: const [])), ChatMessage('user', prompt)];
      final buf = StringBuffer();
      try {
        await for (final ev in eng.generate(skipThinking(await eng.formatChat(msgs)),
            grammar: grammar, sampling: const SamplingParams(temperature: 0.3), maxTokens: maxTokens)) {
          if (ev is TokenEvent) buf.write(ev.text);
        }
      } catch (e) {
        appLog('Automatik', 'Text: $e', error: true);
      } finally {
        if (eng is RemoteBackend) eng.close();
      }
      return cleanModelText(buf.toString()).trim();
    });
  }

  /// Agenten-Auftrag aus einem Prozess (mit Werkzeugen).
  Future<String> automationAgent(String prompt, {required bool allowInternet, required Conversation conv, required ChatEntry entry}) async {
    final eng = await _automationBackend();
    if (eng == null) throw Exception('Kein Modell bereit (Systemcheck oder KI-Anbieter einrichten).');
    return _exclusive(conv.id, () async {
      var tools = toolsFor(prompt, hasImages: false, hasDocs: false);
      tools = [for (final t in tools) if (t.name != 'browser' && (allowInternet || !t.requiresNetwork)) t];
      final runner = _makeRunner(eng, _systemText(voice: false, tools: tools), tools: tools);
      var answer = '';
      String? error;
      final ctx = ToolContext(
        requestNetwork: (_) async => allowInternet,
        propose: (a) {
          entry.actions.add(a);
          notifyListeners();
        },
        onArtifact: (a) {
          conv.artifacts.add(a.toJson());
          if (const {'pdf', 'pptx', 'image'}.contains(a.kind)) entry.files.add(a.content);
          notifyListeners();
        },
      );
      try {
        await for (final ev in runner.run(history: const [], userInput: prompt, context: ctx)) {
          switch (ev) {
            case FinalAnswer(:final text):
              answer = text;
            case ToolResult(:final output, :final isError):
              if (!isError) {
                final cards = parseResultCards(output);
                if (cards.isNotEmpty) entry.cards = [...entry.cards, for (final c in cards) c.toJson()].take(40).toList();
              }
            case AgentFinished(:final reason, :final message):
              if (reason == AgentStopReason.error) error = message;
            default:
              break;
          }
        }
      } finally {
        if (eng is RemoteBackend) eng.close();
      }
      if (answer.trim().isEmpty && error != null) throw Exception(error);
      return stripAnswerPreamble(cleanModelText(answer), prompt) ?? cleanModelText(answer);
    });
  }

  void _checkSchedule() {
    if (!initialized) return;
    // Watchlist braucht kein Modell (Zusammenfassen wartet selbst auf eine freie Engine)
    unawaited(watchlist.checkDue());
    if (running || status == EngineStatus.loading) return;
    flows.checkDue();
    final now = DateTime.now();
    for (final p in prompts) {
      if (p.isDue(now)) {
        unawaited(runPrompt(p, automated: true));
        return; // einer nach dem anderen
      }
    }
    if (_promptQueue.isNotEmpty) {
      final p = prompts.where((x) => x.id == _promptQueue.removeAt(0)).firstOrNull;
      if (p != null) unawaited(runPrompt(p, automated: true));
    }
  }

  /// Wartet auf ein geladenes Modell (lädt bei Bedarf das zuletzt genutzte).
  Future<bool> _ensureEngine() async {
    for (var i = 0; i < 600 && status == EngineStatus.loading; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (engine != null) return true;
    final m = models.where((x) => x.id == settings.lastModelId).firstOrNull ?? models.firstOrNull;
    if (m == null) return false;
    await loadModel(m);
    return engine != null;
  }

  /// Führt einen gespeicherten Prompt in einem neuen Chat aus.
  Future<Conversation?> runPrompt(SavedPrompt p, {bool automated = false}) async {
    if (running) {
      if (automated && !_promptQueue.contains(p.id)) _promptQueue.add(p.id);
      return null;
    }
    if (p.id == meetingPrepId) {
      p.lastRun = DateTime.now();
      await storage.savePrompts(prompts);
      return prepareMeetings(automated: automated);
    }
    p.lastRun = DateTime.now();
    await storage.savePrompts(prompts);
    unawaited(_syncAlarms());
    if (!await _ensureEngine()) {
      if (automated && p.notify) {
        await BackgroundWork.notify(p.title, 'Konnte nicht starten: kein Sprachmodell geladen.');
      }
      statusMessage = 'Kein Sprachmodell für „${p.title}“.';
      notifyListeners();
      return null;
    }
    final previousProfile = settings.activeProfileId;
    if (p.profileId != null && profiles.any((x) => x.id == p.profileId)) settings.activeProfileId = p.profileId!;
    final now = DateTime.now();
    final stamp = '${now.day}.${now.month}. ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    // Routine (mit Zeitplan): immer derselbe Chat, nur die Ergebnisse. Vorlage ohne Zeitplan: neuer Chat.
    final routine = p.schedule != ScheduleKind.off;
    final Conversation conv;
    if (routine) {
      conv = routineConversation('routine-${p.id}', p.scheduleLabel == 'Nur per Klick' ? p.title : '${p.title} · ${p.timeLabel}');
    } else {
      current = null;
      conv = _ensureConversation();
      conv.title = '${p.title} · $stamp';
    }
    if (p.allowInternet) conv.internetAllowed = true;
    // von Hand gestartet: den Routinen-Chat zeigen
    if (routine && !automated) {
      current = conv;
      notifyListeners();
    }
    final before = conv.entries.length;
    try {
      await send(p.text, target: routine ? conv : null, noHistory: routine);
    } finally {
      settings.activeProfileId = previousProfile;
    }
    if (routine) _keepOnlyOutput(conv, before, 'Ergebnis $stamp');
    if (automated && p.notify) {
      final answer = conv.entries.lastOrNull;
      final text = answer?.error ?? answer?.text ?? '';
      final short = text.replaceAll(RegExp(r'[#*_`>|]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
      await BackgroundWork.notify(p.title, short.length > 240 ? '${short.substring(0, 240)}…' : short,
          conversationId: conv.id);
    }
    notifyListeners();
    return conv;
  }

  // ------------------------------------------------------------ Routinen-Chats

  static const _morningNewsLine = 'dann Nachrichten: 2–3 Sätze Überblick ohne Links und ohne Liste der Meldungen – '
      'die Meldungen sieht der Nutzer als Karten nach Thema. Erfinde keine Meldungen oder Links.';

  /// Chats von Routinen (geplante Aufgaben, Prozesse) – eigene Kategorie in der Seitenleiste.
  static bool isRoutineChat(Conversation c) => c.id.startsWith('routine-') || c.id.startsWith('flowrun-') || c.id == 'automatik';

  /// Chat einer Routine: immer derselbe, wird nicht zum aktuellen Chat.
  Conversation routineConversation(String id, String title) {
    var c = conversations.where((x) => x.id == id).firstOrNull;
    if (c == null) {
      c = Conversation(id: id, title: title);
      conversations.insert(0, c);
    } else {
      c.title = title;
    }
    return c;
  }

  /// Nur das Ergebnis behalten: die Frage (Prompt) der Routine entfernen, Zeitpunkt vermerken, ältere Läufe kürzen.
  void _keepOnlyOutput(Conversation conv, int before, String label) {
    final added = conv.entries.sublist(before.clamp(0, conv.entries.length));
    for (final e in added.where((e) => e.role == 'user').toList()) {
      conv.entries.remove(e);
    }
    for (final e in added.where((e) => e.role == 'assistant')) {
      e.via = label;
    }
    if (conv.entries.length > 40) conv.entries.removeRange(0, conv.entries.length - 40);
    conv.updated = DateTime.now();
    unawaited(storage.saveConversation(conv));
    notifyListeners();
  }

  void openConversationById(String id) {
    if (id.startsWith('watch:')) {
      pendingLaunch.value = 'watch';
      return;
    }
    if (id.startsWith('followup:')) {
      // Push „Termin vorbei“ angetippt → neuer Chat mit vorbereiteter Bitte
      final parts = id.split(':');
      var title = '';
      try {
        title = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      } catch (_) {}
      current = null;
      pendingInput.value = 'Schreib eine kurze Folgemail zum Termin „$title“. Zusagen und nächste Schritte: ';
      notifyListeners();
      return;
    }
    final c = conversations.where((x) => x.id == id).firstOrNull;
    if (c != null && !running) {
      current = c;
      notifyListeners();
    }
  }

  // ----------------------------------------------------------- Agenten-Lauf

  /// Schickt eine Nachricht an den Agenten.
  /// [voice]: Gesprächsmodus (kurze, gesprochene Antworten).
  /// [onAnswer]: bekommt den wachsenden Antworttext (für Vorlesen während des Schreibens).
  /// Welche Quellen eine Antwort hatte: Wissensbasis, Anhänge, Web-Tools – sonst das Modell.
  List<SourceRef> _collectSources(ChatEntry answer, List<Attachment> docs, List<KnowledgeHit> ragHits) {
    final out = <SourceRef>[];
    final seen = <String>{};
    void add(SourceRef r) {
      final key = '${r.kind}|${r.url ?? r.label}';
      if (seen.add(key)) out.add(r);
    }

    final urlRe = RegExp(r'https?://[^\s)\]>"]+');
    void addKb(String title, String url) =>
        url.startsWith('http') ? add(SourceRef('web', title.isEmpty ? url : title, url)) : add(SourceRef('doc', title.isEmpty ? url : title));

    for (final h in ragHits) {
      addKb(h.chunk.title, h.chunk.url);
    }
    for (final d in docs) {
      add(SourceRef('doc', d.name));
    }
    for (final st in answer.steps) {
      if (st.isError == true) continue;
      final obs = st.observation ?? '';
      switch (st.tool) {
        case 'web_fetch':
          final u = st.args?['url']?.toString();
          if (u != null && u.isNotEmpty) add(SourceRef('web', u, u));
        case 'web_search':
          // nur Treffer, die die Antwort auch nennt; sonst die ersten drei
          final urls = urlRe.allMatches(obs).map((m) => m.group(0)!).toList();
          final cited = urls.where((u) => answer.text.contains(Uri.tryParse(u)?.host ?? '\u0000')).toList();
          for (final u in (cited.isNotEmpty ? cited : urls.take(3))) {
            add(SourceRef('web', u, u));
          }
        case 'knowledge_search':
          for (final m in RegExp(r'\[\d+\] (.+?) – (\S+)').allMatches(obs)) {
            addKb(m.group(1)!, m.group(2)!);
          }
        case 'calculator':
          add(SourceRef('tool', 'Rechner'));
        case 'weather':
          add(SourceRef('web', 'Open-Meteo', 'https://open-meteo.com'));
        case 'news' || 'site_search' || 'browser':
          for (final m in RegExp(r'Link: (\S+)').allMatches(obs).take(4)) {
            add(SourceRef('web', m.group(1)!, m.group(1)!));
          }
        case 'calendar_list' || 'calendar_add':
          add(SourceRef('tool', 'Kalender'));
        case 'contacts_search' || 'compose_email' || 'compose_whatsapp' || 'call_phone':
          add(SourceRef('tool', 'Adressbuch'));
        case 'file_search' || 'file_rename' || 'file_move':
          add(SourceRef('tool', 'Dateien'));
        case 'datetime':
          add(SourceRef('tool', 'Uhr des Geräts'));
        case 'read_file' || 'text_search' || 'json_query':
          final n = st.args?['name']?.toString() ?? st.args?['file']?.toString();
          if (n != null && n.isNotEmpty) add(SourceRef('doc', n));
      }
    }
    if (out.isEmpty) {
      add(SourceRef('model', loadedModel?.displayName ?? 'Sprachmodell'));
    }
    return out;
  }

  Future<void> send(String input,
      {bool voice = false,
      void Function(String text, bool done)? onAnswer,
      void Function(String tool)? onToolStart,
      Conversation? target,
      bool noHistory = false,
      List<Attachment>? withDocs,
      bool forceCloud = false,
      bool forceStrong = false}) async {
    if (!canChat && !forceCloud || input.trim().isEmpty) {
      onAnswer?.call('', true);
      return;
    }
    if (running) {
      // Im selben Chat: als Kommentar an den laufenden Auftrag geben – der Agent berücksichtigt ihn sofort
      final r = _runner, ans = _runningAnswer, here = current;
      if (!voice && onAnswer == null && r != null && ans != null && here != null && runningConvId == here.id &&
          withDocs == null && attachments.isEmpty && r.addNote(input.trim())) {
        final note = ChatEntry(role: 'user', text: input.trim());
        final i = here.entries.indexOf(ans);
        here.entries.insert(i < 0 ? here.entries.length : i, note);
        _noteEntries.add(note);
        appLog('Agent', 'Kommentar während der Arbeit: ${input.trim()}');
        notifyListeners();
        return;
      }
      // Läuft schon eine Antwort (in einem anderen Chat): Nachricht vormerken
      if (voice || onAnswer != null) {
        onAnswer?.call('', true);
        return;
      }
      final c = _ensureConversation();
      final docs = List<Attachment>.of(attachments);
      _attachments.remove(c.id);
      final ph = ChatEntry(role: 'user', text: input.trim(), attachments: docs.map((d) => d.name).toList());
      c.entries.add(ph);
      _queue.add((conv: c, text: input.trim(), docs: docs, placeholder: ph));
      statusMessage = 'Wartet, bis die laufende Antwort fertig ist';
      notifyListeners();
      return;
    }
    final conv = target ?? _ensureConversation();
    runningConvId = conv.id;
    final (eng0, via, usedCloud) = await _backendFor(conv,
        forceCloud: forceCloud,
        input: input,
        docChars: (withDocs ?? attachments).fold<int>(0, (n, d) => n + d.content.length),
        forceStrong: forceStrong,
        voice: voice);
    if (statusMessage != null && statusMessage!.startsWith('Komplexe Aufgabe')) statusMessage = null;
    if (eng0 == null) {
      runningConvId = null;
      conv.entries
        ..add(ChatEntry(role: 'user', text: input.trim()))
        ..add(ChatEntry(role: 'assistant', error: usedCloud ? 'Kein Cloud-Anbieter eingerichtet (Einstellungen → KI-Anbieter).' : 'Kein Modell bereit.'));
      notifyListeners();
      onAnswer?.call('', true);
      return;
    }
    final AgentBackend eng = eng0;

    var history = <ChatMessage>[
      for (final e in conv.entries)
        if (e.text.trim().isNotEmpty && e.error == null)
          ChatMessage(e.role, e.role == 'assistant' ? cleanModelText(e.text) : e.text),
    ];
    // kurze Nachfrage („wien“, „und morgen?“): Werkzeuge auch nach der vorigen Frage wählen
    final prevUser = conv.entries.lastWhere((e) => e.role == 'user', orElse: () => ChatEntry(role: 'user')).text;
    // Design-Vorschläge/Links zur vorigen Präsentation („hier sind Design-Vorschläge …“) gehören dazu
    final designFollowUp = (designReferencesIn(input).isNotEmpty || wantsDesign(input)) &&
        !_deckWord.hasMatch(input) &&
        requiredToolFor(prevUser) != null;
    final gateText = looksLikeFollowUp(input) || designFollowUp ? '$prevUser $input' : input;
    final requiredTool = requiredToolFor(gateText,
        hasFiles: conv.artifacts.any((a) => const {'pptx', 'pdf'}.contains(a['kind'])));
    // Gesprächsmodus: gleicher Verlauf und gleicher System-Prompt wie im Chat – so bleibt der
    // vorgerechnete Teil (Cache) gültig und die erste Antwort kommt ohne langes Vorrechnen.
    // Routinen: jede Ausführung für sich (kein Verlauf).
    if (noHistory) history = [];
    var docs = List<Attachment>.of(withDocs ?? attachments);
    var runTools = toolsFor(gateText,
        hasImages: docs.any((d) => isImageFile(d.name)), hasDocs: docs.any((d) => !isImageFile(d.name)));
    if (conv.internetOff) runTools = [for (final t in runTools) if (!t.requiresNetwork) t];
    // Links sind hier Design-Vorlagen: die übernimmt das Präsentations-Tool – kein Browser nötig
    if (requiredTool != null) {
      final urls = RegExp(r'https?://\S+').allMatches(input).map((m) => m.group(0)!).toList();
      if (urls.isNotEmpty && urls.every((u) => designReferencesIn(u).isNotEmpty)) {
        runTools = [for (final t in runTools) if (!const {'browser', 'web_fetch', 'site_search', 'web_search'}.contains(t.name)) t];
      }
      for (final name in requiredTool.split('|')) {
        if (runTools.any((t) => t.name == name)) continue;
        final t = activeTools.where((t) => t.name == name).firstOrNull;
        if (t != null) runTools = [...runTools, t];
      }
    }
    // Browser nur im Chat mit offener App; dann ersetzt er die einfache Shop-Suche
    if (voice || headless) {
      runTools = [for (final t in runTools) if (t.name != 'browser') t];
    } else if (runTools.any((t) => t.name == 'browser')) {
      runTools = [for (final t in runTools) if (t.name != 'site_search') t];
    }
    final user = ChatEntry(
        role: 'user',
        text: input.trim(),
        attachments: docs.map((d) => d.name).toList(),
        viaVoice: voice,
        files: [for (final d in docs) if (d.path != null && isImageFile(d.name)) d.path!]);
    final answer = ChatEntry(role: 'assistant', via: via);
    conv.entries..add(user)..add(answer);
    _runningAnswer = answer;
    _noteEntries.clear();
    if (conv.title == 'Neuer Chat') {
      final t = input.trim().replaceAll('\n', ' ');
      conv.title = t.length > 40 ? '${t.substring(0, 40)}…' : t;
    }
    conv.updated = DateTime.now();

    final ctxSize = eng.contextSize;
    var turnInput = input.trim();
    // reine Rechenfrage: exakt ausrechnen, Modell formuliert nur noch die Antwort
    final calc = docs.isEmpty ? quickCalc(turnInput) : null;
    if (calc != null) {
      runTools = const [];
      turnInput = 'Exakt berechnet (Rechner): $calc\n\nFrage des Nutzers: $turnInput\n'
          'Antworte kurz mit diesem Ergebnis.';
    }
    final system = _systemText(tools: runTools);
    final rag = knowledge.isEmpty ? '' : knowledge.contextFor(turnInput, maxChars: ctxSize >= 8192 ? 4000 : 2000);
    final ragHits = rag.isEmpty
        ? const <KnowledgeHit>[]
        : knowledge.search(turnInput).where((h) => rag.contains(h.chunk.url)).toList();
    if (rag.isNotEmpty) turnInput = '$rag\n\nFrage des Nutzers: $turnInput';

    if (voice) turnInput = '$turnInput\n\n${voiceTurnHint()}';
    var runner = _makeRunner(eng, system, tools: runTools, requiredTool: requiredTool);
    _runner = runner;
    running = true;
    runStarted = DateTime.now();
    unawaited(BackgroundWork.begin('agent', 'Agent schreibt eine Antwort …'));
    statusMessage = null;
    notifyListeners();
    try {
      await WakelockPlus.enable();
    } catch (_) {}

    _turnInternetAllowed = false;
    void propose(Map<String, String> a) {
      answer.actions.add(a);
      notifyListeners();
    }

    final ctx = ToolContext(
      attachments: docs,
      requestNetwork: (purpose) => _requestNetwork(conv, purpose),
      propose: propose,
      onArtifact: (a) {
        // gezielt geänderte Datei: alten Eintrag ersetzen statt verdoppeln
        conv.artifacts.removeWhere((x) => x['content'] == a.content && x['kind'] == a.kind);
        conv.artifacts.add(a.toJson());
        if (const {'pdf', 'pptx', 'image'}.contains(a.kind)) {
          if (!answer.files.contains(a.content)) answer.files.add(a.content);
        } else {
          inspectorAttention = true;
        }
        notifyListeners();
      },
    );
    ctx.userRequest = gateText.trim();

    // Angehängte Bilder einmal ansehen (Bildverständnis), die Beschreibung bekommt der Agent als Text
    final unseen = [for (final d in docs) if (d.path != null && isImageFile(d.name) && !_imageNotes.containsKey(d.path)) d];
    if (unseen.isNotEmpty && canSeeImages) {
      final log = StepLog(step: 0)
        ..tool = 'look_at_image'
        ..args = {'name': unseen.map((d) => d.name).join(', ')}
        ..thought = 'Ich sehe mir ${unseen.length == 1 ? 'das Bild' : 'die Bilder'} an.';
      answer.steps.add(log);
      notifyListeners();
      final sw = Stopwatch()..start();
      for (final d in unseen) {
        try {
          final note = await _visionQuery([d.path!],
              'Der Nutzer schreibt dazu: "${input.trim()}"\n'
              'Beschreibe das Bild ausführlich auf Deutsch: Was ist zu sehen? Gib alle lesbaren Texte, Zahlen und '
              'Tabellen wörtlich wieder. Beantworte, soweit möglich, die Frage des Nutzers.');
          _imageNotes[d.path!] = note;
        } catch (e) {
          _imageNotes[d.path!] = 'Bild konnte nicht ausgewertet werden: $e';
          log.isError = true;
        }
        if (runner.isStopped) break;
      }
      log
        ..observation = unseen.map((d) => '${d.name}: ${_imageNotes[d.path!] ?? ''}').join('\n\n')
        ..durationMs = sw.elapsedMilliseconds;
      notifyListeners();
    }
    docs = [
      for (final d in docs)
        if (d.path != null && _imageNotes.containsKey(d.path))
          Attachment(
              name: d.name,
              path: d.path,
              content: 'Bild "${d.name}" – Inhalt (vom Modell erkannt):\n${_imageNotes[d.path]}\n'
                  'Einbinden in Dokumente/Folien mit ![](${d.name}).')
        else
          d,
    ];
    // Schnellweg: reine Wetter- oder Nachrichtenfrage → Werkzeug sofort, das Modell schreibt nur noch die Antwort
    final direct = calc == null && docs.isEmpty && !runner.isStopped ? directTool(input.trim(), gateText, runTools) : null;
    if (direct != null) {
      final (tool, args) = direct;
      final log = StepLog(step: 1)
        ..tool = tool.name
        ..args = args
        ..thought = 'Ich frage ${tool.title} direkt ab.';
      answer.steps.add(log);
      notifyListeners();
      onToolStart?.call(tool.name);
      final sw = Stopwatch()..start();
      try {
        final out = await tool.run(args, ctx).timeout(const Duration(seconds: 60));
        final cut = out.indexOf(moreCardsMarker);
        log.observation = out;
        final what = tool.name == 'browser'
            ? 'Die Seite wurde im eingebauten Browser geöffnet; das ist ihr Inhalt (der Nutzer sieht die Einträge als Karten)'
            : 'Ergebnis (${tool.title})';
        turnInput = '$what:\n${cut < 0 ? out : out.substring(0, cut)}\n\n$turnInput\n'
            'Antworte direkt mit diesen Daten. Behaupte nicht, du könntest die Seite nicht abrufen.';
        runner = _makeRunner(eng, _systemText(tools: const []), tools: const []);
        _runner = runner;
      } catch (e) {
        // Klappt der Schnellweg nicht, macht der Agent normal weiter
        log
          ..observation = 'Fehler: $e'
          ..isError = true;
      }
      log.durationMs = sw.elapsedMilliseconds;
      notifyListeners();
    }
    final ctx2 = ToolContext(
      attachments: docs,
      requestNetwork: ctx.requestNetwork,
      onArtifact: ctx.onArtifact,
      propose: propose,
    );

    try {
      await for (final ev in runner.run(history: history, userInput: turnInput, context: ctx2)) {
        switch (ev) {
          case NoteApplied(:final text):
            answer.steps.add(StepLog(step: answer.steps.length + 1)
              ..thought = 'Dein Kommentar wird berücksichtigt: „$text“'
              ..observation = 'Kommentar übernommen');
            statusMessage = null;
          case StepStarted(step: final n):
            if (runner.agentMode) answer.steps.add(StepLog(step: n));
          case StepStreaming(thought: final liveThought, answer: final liveAnswer):
            if (runner.agentMode && liveThought != null) {
              final last = answer.steps.lastOrNull;
              if (last != null) last.thought = liveThought;
            }
            if (liveAnswer != null) {
              // wiederholte Frage / lautes Denken am Anfang nicht anzeigen
              answer.text = stripAnswerPreamble(liveAnswer, input, done: false) ?? '';
              onAnswer?.call(liveAnswer, false);
            }
          case ToolCalled(:final tool, :final args, thought: final callThought):
            onToolStart?.call(tool);
            final last = answer.steps.lastOrNull;
            if (last != null) {
              last
                ..tool = tool
                ..args = args
                ..thought = callThought;
            }
          case ToolResult(:final output, :final isError, :final duration, :final tool):
            final last = answer.steps.lastOrNull;
            if (last != null) {
              last
                ..observation = output
                ..isError = isError
                ..durationMs = duration.inMilliseconds;
            }
            // Aktionen mit Wirkung im Verlauf festhalten
            const acts = {
              'calendar_add': ('calendar', 'Termin eingetragen'),
              'call_phone': ('call', 'Anruf gestartet'),
              'file_rename': ('file', 'Datei umbenannt'),
              'file_move': ('file', 'Datei verschoben'),
              'browser': ('browser', 'Im Browser gearbeitet'),
            };
            final act = acts[tool];
            if (act != null && !isError) {
              final detail = output.split('\n').first;
              unawaited(logActivity(Activity(
                  kind: act.$1,
                  title: act.$2,
                  detail: detail.length > 160 ? '${detail.substring(0, 160)}…' : detail,
                  approval: tool == 'browser' ? 'Im Chat beauftragt' : 'Im Chat beauftragt, auf dem Gerät bestätigt',
                  conversationId: conv.id)));
            }
          case MetricsUpdate(:final stats):
            lastStats = stats;
            if (stats.generatedTokens > 2) lastTokensPerSecond = stats.tokensPerSecond;
            answer.tokensPerSecond = lastTokensPerSecond;
          case FinalAnswer(:final text, :final truncated, thought: final finalThought):
            answer
              ..text = stripAnswerPreamble(text, input) ?? text
              ..truncated = truncated;
            onAnswer?.call(text, true);
            final last = answer.steps.lastOrNull;
            if (last != null && finalThought != null && finalThought.isNotEmpty) {
              last.thought = finalThought;
            }
          case AgentFinished(:final reason, :final message):
            switch (reason) {
              case AgentStopReason.error:
                answer.error = message ?? 'Unbekannter Fehler';
              case AgentStopReason.stepLimit:
                if (answer.text.isEmpty) answer.error = message ?? 'Schrittlimit erreicht';
              case AgentStopReason.stopped:
                if (answer.text.isEmpty) answer.text = '_(gestoppt)_';
              case AgentStopReason.answered:
                break;
            }
        }
        notifyListeners();
      }
    } catch (e) {
      answer.error = e.toString();
    } finally {
      if (answer.error != null) appLog('Agent', 'Antwort fehlgeschlagen: ${answer.error}', error: true);
      for (final st in answer.steps) {
        if (st.isError == true) appLog('Tool', '${st.tool}: ${st.observation ?? ''}', error: true);
      }
      final ms = lastStats;
      appLog('Agent', '${voice ? 'Gespräch' : 'Chat'}: ${answer.steps.length} Schritt(e)'
          '${ms == null ? '' : ', Prompt ${ms.promptTokens} neu/${ms.reusedTokens} aus Cache, '
              'erstes Token ${(ms.timeToFirstTokenMs / 1000).toStringAsFixed(1)} s, ${ms.tokensPerSecond.toStringAsFixed(1)} Tokens/s'}');
      answer.sources
        ..clear()
        ..addAll(_collectSources(answer, docs, ragHits));
      // Adressen, die in keiner Quelle vorkamen, hat das Modell erfunden → entfernen
      final known = [
        input,
        for (final st in answer.steps) st.observation ?? '',
        for (final d in docs) d.content,
        rag,
      ].join('\n');
      answer.text = stripInventedLinks(answer.text, known);
      // Ergebnisse (Produkte, Meldungen) als Karten fürs Karussell – mit Kategorie (Thema bzw. Suche)
      answer.cards = [
        for (final st in answer.steps)
          if (st.isError != true && const {'site_search', 'news', 'web_fetch', 'web_search', 'browser'}.contains(st.tool))
            for (final c in parseResultCards(st.observation ?? '')) {...c.toJson(), 'tag': cardTag(st.tool!, st.args)},
        // Links, die das Modell in die Antwort geschrieben hat (und die es wirklich gibt), ebenfalls als Karte
        for (final m in RegExp(r'https?://[^\s<>()\[\]]*[^\s<>()\[\].,;:!?\x27"]').allMatches(answer.text))
          if ((Uri.tryParse(m.group(0)!)?.path ?? '').length > 1)
            {'title': _linkTitle(m.group(0)!), 'link': cleanLink(m.group(0)!)},
      ].fold<List<Map<String, String>>>([], (acc, c) {
        // doppelte Links nur einmal (auch mit/ohne Tracking-Anhang)
        final l = c['link'] == null ? null : cleanLink(c['link']!);
        if (!acc.any((x) => x['link'] != null && cleanLink(x['link']!) == l)) acc.add(c);
        return acc;
      }).take(60).toList();
      // Hat das Modell lange Adressen geschrieben, die schon als Karte da sind: aus dem Text nehmen
      if (answer.cards.isNotEmpty) answer.text = _stripCardLinks(answer.text);
      if (calc != null) answer.sources.insert(0, SourceRef('tool', 'Rechner'));
      if (runStarted != null) answer.durationMs = DateTime.now().difference(runStarted!).inMilliseconds;
      onAnswer?.call(answer.text, true);
      running = false;
      runningConvId = null;
      runStarted = null;
      unawaited(BackgroundWork.end('agent'));
      // Kommentare, die zu spät kamen (Antwort war schon fertig): als eigene Nachricht beantworten
      final late = runner.pendingNotes;
      for (final text in late) {
        final e = _noteEntries.where((x) => x.text == text).firstOrNull;
        if (e != null) _queue.add((conv: conv, text: text, docs: const <Attachment>[], placeholder: e));
      }
      _noteEntries.clear();
      _runningAnswer = null;
      _runner = null;
      try {
        await WakelockPlus.disable();
      } catch (_) {}
      conv.updated = DateTime.now();
      conversations
        ..remove(conv)
        ..insert(0, conv);
      await storage.saveConversation(conv);
      _pollMemory();
      notifyListeners();
    }
    if (!voice && settings.autoSpeak && answer.error == null && answer.text.trim().isNotEmpty && ttsVoicePath != null) {
      unawaited(speakText(answer.text, key: answer).catchError((_) {}));
    }
    // Nicht dabei (App im Hintergrund oder anderer Chat offen) → Push-Nachricht, wenn fertig
    final away = WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed || current?.id != conv.id;
    if (!voice && !headless && away && answer.text.trim().isNotEmpty) {
      final body = cleanModelText(answer.text).replaceAll(RegExp(r'[*_#>`]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
      unawaited(BackgroundWork.notify(answer.error == null ? 'Junels ist fertig: ${conv.title}' : 'Junels: Fehler in ${conv.title}',
              body.length > 200 ? '${body.substring(0, 200)}…' : body,
              conversationId: conv.id)
          .catchError((_) {}));
    }
    if (eng is RemoteBackend) eng.close();
    // Schnelles Modell ist gescheitert → automatisch mit dem starken Modell wiederholen
    final pairNow = modelPair;
    if (!usedCloud && !forceStrong && !voice && !headless && pairNow != null && via == _modelLabel(pairNow.$1) &&
        current?.id == conv.id && answer.text != '_(gestoppt)_' && (answer.error != null || answer.text.trim().isEmpty)) {
      final i = conv.entries.indexOf(answer);
      if (i > 0) {
        appLog('Modellwahl', 'Schnelles Modell ohne Antwort – wiederhole mit ${pairNow.$2.displayName}');
        await resendFrom(i - 1, strong: true);
        return;
      }
    }
    // Hybrid: Gerät hat nicht geklappt → On-Prem direkt bzw. Cloud nach Freigabe
    final esc = escalationProvider(conv);
    if (!usedCloud && via?.startsWith('On-Prem') != true && esc != null && !headless) {
      final failed = answer.error != null || answer.text.trim().isEmpty;
      answer.cloudOffer = true;
      final toCloud = escalatesToCloud(conv);
      final ask = cloudConsentHandler;
      if (failed && answer.text != '_(gestoppt)_' && !voice && current?.id == conv.id && (!toCloud || ask != null)) {
        var choice = NetworkChoice.once;
        if (toCloud && !conv.cloudAllowed) {
          choice = await ask!('Das Modell am Gerät konnte die Frage nicht beantworten. Mit ${esc.name} (${esc.model}) beantworten?');
          if (choice != NetworkChoice.deny) await _logCloudConsent(conv, choice);
        }
        if (choice != NetworkChoice.deny) {
          final i = conv.entries.indexOf(answer);
          if (i > 0) {
            appLog('KI-Modus', 'Gerät ohne Antwort – weiter mit ${esc.name}');
            await resendFrom(i - 1, cloud: true);
            return;
          }
        }
      }
      notifyListeners();
    }
    // Vorgemerkte Nachricht aus einem anderen Chat jetzt beantworten
    _drainQueue();
  }

  void _drainQueue() {
    if (_queue.isNotEmpty && !running) {
      final q = _queue.removeAt(0);
      q.conv.entries.remove(q.placeholder);
      statusMessage = null;
      unawaited(send(q.text, target: q.conv, withDocs: q.docs));
    }
  }

  void stop() {
    _runner?.stop();
    engine?.stop();
    _imageEngine?.cancel();
  }
}

/// Top-Level-Funktion: Die Closure für Isolate.run darf nur die beiden Pfade
/// enthalten – eine Closure in einer Methode würde den ganzen AppController
/// (inkl. AudioPlayer) mitschicken, was nicht erlaubt ist.
Future<void> _extractInBackground(String archivePath, String targetDir) =>
    Isolate.run(() => extractFileToDisk(archivePath, targetDir));
