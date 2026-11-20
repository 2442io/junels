// Zentraler App-Zustand: Modelle, Engine, Profile, Tools, Chats, Agenten-Lauf.

import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_engine/agent_engine.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../data/models.dart';
import '../data/storage.dart';
import 'background_work.dart';
import 'conversation_mode.dart';
import 'browser_service.dart';
import 'device_bridge.dart';
import 'sync_service.dart';
import 'update_service.dart';
import '../tools/chart_render.dart';
import '../tools/save_prompt_tool.dart';
import 'memory_store.dart';
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

  /// Seit wann die aktuelle Antwort läuft bzw. das Modell lädt (für die Zeitanzeige).
  DateTime? runStarted;
  DateTime? loadStarted;
  AgentRunner? _runner;
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
      knowledge = KnowledgeBase(Directory('${storage.root.path}/knowledge'));
      await knowledge.load();
      outputsDir = Directory('${storage.documentsDir.path}/Ausgaben')..createSync(recursive: true);
      attachmentsDir = Directory('${storage.documentsDir.path}/Anhänge')..createSync(recursive: true);
      final out = OutputSpace(outputsDir, extraImages: () => {
            for (final a in attachments)
              if (a.path != null && isImageFile(a.name)) a.name: a.path!,
          });
      tools = [
        ...builtinTools(),
        ...networkTools(),
        RememberTool((f) async {
          await memory.add(f);
          notifyListeners();
        }),
        HistorySearchTool(_searchHistory),
        KnowledgeSearchTool(knowledge),
        CreateDocumentTool(out),
        CreatePresentationTool(out),
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
      mcpServers = await storage.loadMcpServers();
      conversations = await storage.loadConversations();
      // Nach längerer Pause mit neuem Chat starten, sonst im letzten weiterarbeiten
      final last = conversations.isNotEmpty ? conversations.first : null;
      current = last != null && DateTime.now().difference(last.updated) < idleNewChat ? last : null;
      _pollMemory();
      _memTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollMemory());
      initialized = true;
      notifyListeners();

      if (!headless) {
        BackgroundWork.listen(
          onRunPrompt: (id) async {
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
      }

      if (!headless) unawaited(sync.init());
      if (!headless) unawaited(updates.init());
      if (!headless) unawaited(_initDevice());
      McpOAuth.onTokens = (_) => unawaited(storage.saveMcpServers(mcpServers));

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

  // ------------------------------------------------------------- MCP-Server

  Future<void> saveMcpServer(McpServerConfig srv) async {
    final i = mcpServers.indexWhere((x) => x.id == srv.id);
    if (i >= 0) {
      mcpServers[i] = srv;
    } else {
      mcpServers.add(srv);
    }
    await _mcpClients.remove(srv.id)?.close();
    await storage.saveMcpServers(mcpServers);
    notifyListeners();
  }

  Future<void> removeMcpServer(McpServerConfig srv) async {
    mcpServers.removeWhere((x) => x.id == srv.id);
    await _mcpClients.remove(srv.id)?.close();
    await storage.saveMcpServers(mcpServers);
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
      await storage.saveMcpServers(mcpServers);
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
    await storage.saveMcpServers(mcpServers);
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

  Future<void> loadModel(StoredModel m) async {
    if (status == EngineStatus.loading || running) return;
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
      settings.lastModelId = m.id;
      await storage.saveSettings(settings);
      appLog('Modell', '${m.displayName} geladen in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s, '
          'Context ${engine!.contextSize}, ${device.threads} Threads');
      if (!headless) unawaited(warmUp());
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
      {bool? manualEnd, int? pauseMs, bool? nearField, bool? smartVad, String? agentName, bool? wakeWord}) async {
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

  /// Pfad, falls das Katalog-Modell installiert ist.
  String? installedPath(CatalogEntry e) {
    if (e.kind == ModelKind.llm) {
      final m = models.where((m) => m.catalogId == e.id || m.fileName == e.fileName).firstOrNull;
      return m?.path;
    }
    final p = settings.installed[e.id];
    if (p == null) return null;
    final exists = e.kind == ModelKind.tts ? Directory(p).existsSync() : File(p).existsSync();
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
          settings.installed[e.id] = file.path;
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
        if (e.kind == ModelKind.tts) {
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
    return p != null && File(p).existsSync() ? p : null;
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
    String? sttLanguage,
    bool? autoSpeak,
    bool? sendAfterVoice,
  }) async {
    if (sttModelId != null) settings.sttModelId = sttModelId;
    if (ttsVoiceId != null) settings.ttsVoiceId = ttsVoiceId;
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
    final ask = consentHandler;
    if (ask == null) return false;
    onConsentAsk?.call(purpose);
    final choice = await ask(purpose);
    switch (choice) {
      case NetworkChoice.once:
        _turnInternetAllowed = true;
        return true;
      case NetworkChoice.chat:
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
    if (running) return;
    current = null;
    notifyListeners();
  }

  void selectConversation(Conversation c) {
    if (running) return;
    current = c;
    notifyListeners();
  }

  Future<void> deleteConversation(Conversation c) async {
    if (running && current?.id == c.id) return;
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
        return '$name wird nicht unterstützt (möglich: PDF, Bilder, TXT, MD, CSV, JSON, Code).';
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
      final words = prompt.replaceAll(RegExp(r'[^\w\s-]'), ' ').trim().split(RegExp(r'\s+')).take(5).join(' ');
      final f = OutputSpace(outputsDir).fileFor('Bild $words', 'png');
      await f.writeAsBytes(encodePngRgba(img.width, img.height, rgba));
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
          'Bilder und Diagramme zuerst erzeugen, dann im Dokument/den Folien mit ![](dateiname.png) einbinden. '
          'Schreibe Inhalte vollständig und gut gegliedert. Die Dateien erscheinen automatisch im Chat – '
          'in der final_answer nur kurz sagen, was erstellt wurde.');
    }
    if (voice) {
      system.write('\n\nGESPRÄCHSMODUS: Deine Antwort wird vorgelesen. Antworte wie im persönlichen Gespräch: '
          'kurz (meist 1–3 Sätze), natürlich, ohne Markdown, Listen, Tabellen, Emojis oder Links. '
          'Wiederhole die Frage nicht und fasse sie nicht zusammen – beginne sofort mit der Antwort. '
          'Denke nicht laut: kein Vorspann wie „Der Nutzer möchte …“, „Du fragst …“ oder „Okay, …“. '
          'Du heißt ${settings.agentName}. '
          'Wenn der Nutzer „weiter“ oder „mach weiter“ sagt, setze deine vorige Antwort genau dort fort, '
          'wo sie unterbrochen wurde.');
    }
    return system.toString();
  }

  AgentRunner _makeRunner(LlamaEngine eng, String system, {List<AgentTool>? tools}) {
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
    );
  }

  /// Auslöser je Werkzeug: Nur wenn die Nachricht danach klingt, bekommt das Modell
  /// das Werkzeug zu sehen. Für „Hi“ oder normale Fragen gibt es gar keine Werkzeuge –
  /// dann antwortet das Modell direkt (ein Durchlauf statt Agenten-Schleife).
  static final _toolTriggers = <String, RegExp>{
    'browser': RegExp(r'browser|öffne\w* .*(seite|webseite|website|\.(com|at|de)\b)|geh\w* auf|navigier|klick|surf|'
        r'amazon|ebay|willhaben|shop|bestell|anmelde|formular|auf der seite|im browser|such\w* (auf|bei) '),
    'web_fetch': RegExp(r'https?://|www\.|\b[\w-]+\.(com|at|de|ch|li|org|net|io|eu|fyi|ai|app)\b|webseite|website|link\b|artikel'),
    'site_search': RegExp(r'amazon|ebay|geizhals|idealo|willhaben|otto\.de|mediamarkt|thalia|chefkoch|wikipedia|'
        r'shop|kaufen|bestell|angebot|günstig|preisvergleich|produkt|auf [\w-]+\.(at|de|com)\b.*such|such\w* (auf|bei) '),
    'web_search': RegExp(r'internet|im netz|online|google|such(e|en)? (im|nach|mal|mir)|such mir|finde (mir|im)|recherch|'
        r'angebot|kaufen|empfehl\w* .*(produkt|marke)|vergleich|test(sieger|bericht)|'
        r'aktuell|neueste|letzte woche|börse|aktienkurs|wechselkurs|was kostet|preis von|wer ist (der|die) (aktuelle|neue)'),
    'weather': RegExp(r'wetter|regen|regnet|temperatur|grad\b|schnee|sonnig|wind|gewitter|schirm|jacke|vorhersage'),
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
          tool,
    ];
  }

  @Deprecated('toolsFor verwenden')
  List<AgentTool> voiceToolsFor(String input) => toolsFor(input);

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
      r'wetter|regen|regnet|schnee|schneit|temperatur|grad\b|sonnig|gewitter|schirm|wird es (warm|kalt|heiß)|vorhersage',
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
    if (_otherIntent.hasMatch(input)) return null;
    final weather = find('weather'), news = find('news');
    bool isWeather(String t) => weather != null && _weatherIntent.hasMatch(t);
    bool isNews(String t) => news != null && _newsIntent.hasMatch(t);
    // Erst die neue Nachricht, nur bei Nachfragen auch die vorige
    final w = isWeather(input), n = isNews(input);
    final useWeather = w || (!n && input != gate && isWeather(gate) && !isNews(gate));
    final useNews = !useWeather && (n || (input != gate && isNews(gate)));
    if (useWeather) return (weather!, {'location': weatherPlace(input, gate), 'days': 7});
    if (useNews) {
      return (news!, {'topic': _newsTopicOf(input, gate), 'source': _newsSourceOf(input) == 'auto' ? _newsSourceOf(gate) : _newsSourceOf(input), 'count': 6});
    }
    return null;
  }

  static const _siteWord = r'([a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:de|at|com|ch|net|org|eu|io)|amazon|ebay|willhaben|geizhals|idealo|'
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
          ? _makeRunner(eng, _systemText(voice: true, tools: const []), tools: const [])
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
  Future<void> resendFrom(int index, {String? newText}) async {
    final conv = current;
    if (conv == null || running || index < 0 || index >= conv.entries.length) return;
    final entry = conv.entries[index];
    if (entry.role != 'user') return;
    final text = (newText ?? entry.text).trim();
    if (text.isEmpty) return;
    conv.entries.removeRange(index, conv.entries.length);
    await storage.saveConversation(conv);
    notifyListeners();
    await send(text, voice: entry.viaVoice);
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
        'Fasse alles kurz und übersichtlich zusammen: zuerst Termine, dann Wetter (mit Tipp, z. B. Schirm), dann Nachrichten mit Link.';
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
    await BackgroundWork.schedule([
      for (final p in prompts)
        if (p.nextAfter(now) case final at?) (id: p.id, title: p.title, at: at),
    ]);
  }

  void _checkSchedule() {
    if (!initialized || running || status == EngineStatus.loading) return;
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
    current = null;
    final conv = _ensureConversation();
    final now = DateTime.now();
    conv.title = '${p.title} · ${now.day}.${now.month}. ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    if (p.allowInternet) conv.internetAllowed = true;
    try {
      await send(p.text);
    } finally {
      settings.activeProfileId = previousProfile;
    }
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

  void openConversationById(String id) {
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

  Future<void> send(String input, {bool voice = false, void Function(String text, bool done)? onAnswer}) async {
    final eng = engine;
    if (eng == null || running || input.trim().isEmpty) {
      onAnswer?.call('', true);
      return;
    }
    final conv = _ensureConversation();

    var history = <ChatMessage>[
      for (final e in conv.entries)
        if (e.text.trim().isNotEmpty && e.error == null)
          ChatMessage(e.role, e.role == 'assistant' ? cleanModelText(e.text) : e.text),
    ];
    // kurze Nachfrage („wien“, „und morgen?“): Werkzeuge auch nach der vorigen Frage wählen
    final prevUser = conv.entries.lastWhere((e) => e.role == 'user', orElse: () => ChatEntry(role: 'user')).text;
    final gateText = looksLikeFollowUp(input) ? '$prevUser $input' : input;
    // Gesprächsmodus: kurzer Verlauf. Der Anfang springt nur alle 10 Nachrichten weiter,
    // damit der vorgerechnete Teil (Cache) von Runde zu Runde gleich bleibt.
    if (voice) {
      final start = history.length <= 12 ? 0 : ((history.length - 6) ~/ 10) * 10;
      history = [
        for (final m in history.sublist(start))
          ChatMessage(m.role, m.content.length > 700 ? '${m.content.substring(0, 700)} …' : m.content),
      ];
    }
    var docs = List<Attachment>.of(attachments);
    var runTools = toolsFor(gateText,
        hasImages: docs.any((d) => isImageFile(d.name)), hasDocs: docs.any((d) => !isImageFile(d.name)));
    if (conv.internetOff) runTools = [for (final t in runTools) if (!t.requiresNetwork) t];
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
    final answer = ChatEntry(role: 'assistant');
    conv.entries..add(user)..add(answer);
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
    final system = _systemText(voice: voice, tools: runTools);
    final rag = knowledge.isEmpty ? '' : knowledge.contextFor(turnInput, maxChars: ctxSize >= 8192 ? 4000 : 2000);
    final ragHits = rag.isEmpty
        ? const <KnowledgeHit>[]
        : knowledge.search(turnInput).where((h) => rag.contains(h.chunk.url)).toList();
    if (rag.isNotEmpty) turnInput = '$rag\n\nFrage des Nutzers: $turnInput';

    var runner = _makeRunner(eng, system, tools: runTools);
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
    final ctx = ToolContext(
      attachments: docs,
      requestNetwork: (purpose) => _requestNetwork(conv, purpose),
      onArtifact: (a) {
        conv.artifacts.add(a.toJson());
        if (const {'pdf', 'pptx', 'image'}.contains(a.kind)) {
          answer.files.add(a.content);
        } else {
          inspectorAttention = true;
        }
        notifyListeners();
      },
    );

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
      final sw = Stopwatch()..start();
      try {
        final out = await tool.run(args, ctx).timeout(const Duration(seconds: 60));
        final cut = out.indexOf(moreCardsMarker);
        log.observation = out;
        turnInput = 'Ergebnis (${tool.title}):\n${cut < 0 ? out : out.substring(0, cut)}\n\n$turnInput\n'
            'Antworte direkt und kurz mit diesen Daten.';
        runner = _makeRunner(eng, _systemText(voice: voice, tools: const []), tools: const []);
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
    );

    try {
      await for (final ev in runner.run(history: history, userInput: turnInput, context: ctx2)) {
        switch (ev) {
          case StepStarted(step: final n):
            if (runner.agentMode) answer.steps.add(StepLog(step: n));
          case StepStreaming(thought: final liveThought, answer: final liveAnswer):
            if (runner.agentMode && liveThought != null) {
              final last = answer.steps.lastOrNull;
              if (last != null) last.thought = liveThought;
            }
            if (liveAnswer != null) {
              answer.text = liveAnswer;
              onAnswer?.call(liveAnswer, false);
            }
          case ToolCalled(:final tool, :final args, thought: final callThought):
            final last = answer.steps.lastOrNull;
            if (last != null) {
              last
                ..tool = tool
                ..args = args
                ..thought = callThought;
            }
          case ToolResult(:final output, :final isError, :final duration):
            final last = answer.steps.lastOrNull;
            if (last != null) {
              last
                ..observation = output
                ..isError = isError
                ..durationMs = duration.inMilliseconds;
            }
          case MetricsUpdate(:final stats):
            lastStats = stats;
            if (stats.generatedTokens > 2) lastTokensPerSecond = stats.tokensPerSecond;
            answer.tokensPerSecond = lastTokensPerSecond;
          case FinalAnswer(:final text, :final truncated, thought: final finalThought):
            answer
              ..text = text
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
      // Ergebnisse (Produkte, Meldungen) als Karten fürs Karussell
      answer.cards = [
        for (final st in answer.steps)
          if (st.isError != true && const {'site_search', 'news', 'web_fetch', 'web_search', 'browser'}.contains(st.tool))
            for (final c in parseResultCards(st.observation ?? '')) c.toJson(),
        // Links, die das Modell in die Antwort geschrieben hat, ebenfalls als Karte
        for (final m in RegExp(r'https?://[^\s<>()\[\]]*[^\s<>()\[\].,;:!?\x27"]').allMatches(answer.text))
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
      runStarted = null;
      unawaited(BackgroundWork.end('agent'));
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
