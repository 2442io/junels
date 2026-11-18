// Zentraler App-Zustand: Modelle, Engine, Profile, Tools, Chats, Agenten-Lauf.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_engine/agent_engine.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../data/models.dart';
import '../data/storage.dart';
import 'voice_service.dart';

enum EngineStatus { none, loading, ready, error }

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

  final List<AgentTool> tools = [...builtinTools(), ...networkTools()];

  // Systemcheck & Downloads
  int freeDisk = -1;
  final Map<String, DownloadState> downloads = {};
  final _downloader = Downloader();

  // Sprache
  late final VoiceService voice;

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
  AgentRunner? _runner;
  final Map<String, List<Attachment>> _attachments = {};
  GenerationStats? lastStats;
  double? lastTokensPerSecond;
  bool inspectorAttention = false;

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
      voice = VoiceService(await getTemporaryDirectory());
      refreshFreeDisk();
      settings = await storage.loadSettings();
      darkMode.value = settings.darkMode;
      settings.contextSize = device.clampContext(settings.contextSize, null);
      profiles = await storage.loadProfiles();
      if (!profiles.any((p) => p.id == settings.activeProfileId)) {
        settings.activeProfileId = profiles.first.id;
      }
      models = await storage.loadModels();
      conversations = await storage.loadConversations();
      current = conversations.isNotEmpty ? conversations.first : null;
      _pollMemory();
      _memTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollMemory());
      initialized = true;
      notifyListeners();

      if (settings.autoLoadLastModel && settings.lastModelId != null) {
        final m = models.where((x) => x.id == settings.lastModelId).firstOrNull;
        if (m != null) unawaited(loadModel(m));
      }
    } catch (e) {
      initError = e.toString();
      initialized = true;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _memTimer?.cancel();
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

  // Mobile: Generierung anhalten, wenn die App in den Hintergrund geht
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (device.isMobile && (state == AppLifecycleState.paused || state == AppLifecycleState.hidden)) {
      if (running) stop();
    }
  }

  @override
  void didHaveMemoryPressure() {
    if (running) {
      stop();
      statusMessage = 'Das System meldet Speicherknappheit – Generierung wurde gestoppt.';
      notifyListeners();
    }
  }

  // --------------------------------------------------------------- Getter

  AgentProfile get activeProfile =>
      profiles.firstWhere((p) => p.id == settings.activeProfileId, orElse: () => profiles.first);

  bool get needsSystemCheck => !settings.systemCheckSeen && models.isEmpty;

  /// Tools des Profils; Internet-Tools nur, wenn der Nutzer sie eingeschaltet hat.
  List<AgentTool> get activeTools => activeProfile.useTools
      ? tools.where((t) => settings.enabledTools.contains(t.name)).toList()
      : const [];

  List<Attachment> get attachments => _attachments[current?.id ?? ''] ?? const [];

  List<Artifact> get artifacts =>
      [for (final a in current?.artifacts ?? const <Map<String, dynamic>>[]) Artifact.fromJson(a)];

  List<int> get contextOptions =>
      [1024, 2048, 4096, 8192, 16384].where((c) => c <= device.maxContext).toList();

  /// Gewünschte Context-Größe (automatisch = Maximum der Geräteklasse).
  int get contextTarget => settings.contextAuto ? device.maxContext : settings.contextSize;

  // ---------------------------------------------------------------- Modelle

  Future<GgufInfo> inspectModel(String path) => GgufInfo.read(path);

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
    statusMessage = 'Lade ${m.displayName} …';
    notifyListeners();
    try {
      await unloadModel(notify: false);
      final info = await GgufInfo.read(m.path);
      final ctx = device.clampContext(contextTarget, info);
      final fit = device.checkFit(info, ctx);
      if (fit.level == FitLevel.refuse) throw EngineException(fit.message);
      // bei knappem Speicher Context zusätzlich begrenzen
      final effectiveCtx = fit.level == FitLevel.warn && ctx > 2048 ? 2048 : ctx;
      final sw = Stopwatch()..start();
      engine = await LlamaEngine.load(device.engineConfig(m.path, effectiveCtx));
      sw.stop();
      loadedModel = m;
      status = EngineStatus.ready;
      statusMessage = '${m.displayName} geladen in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s'
          '${fit.level == FitLevel.warn ? ' – ${fit.message}' : ''}';
      settings.lastModelId = m.id;
      await storage.saveSettings(settings);
    } catch (e) {
      engine = null;
      loadedModel = null;
      status = EngineStatus.error;
      statusMessage = 'Laden fehlgeschlagen: $e';
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

  /// [size] <= 0 = automatisch.
  Future<void> setContextSize(int size) async {
    settings.contextAuto = size <= 0;
    if (size > 0) settings.contextSize = device.clampContext(size, null);
    await storage.saveSettings(settings);
    notifyListeners();
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
      recommendFor(kind, device, freeDiskBytes: freeDisk);

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
    try {
      final dir = switch (e.kind) {
        ModelKind.llm => storage.modelsDir.path,
        ModelKind.stt => '${storage.voiceDir.path}/whisper',
        ModelKind.tts => '${storage.voiceDir.path}/piper',
      };
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

  Future<void> speakText(String text, {Object? key}) async {
    final dir = ttsVoicePath;
    if (dir == null) throw Exception('Keine Stimme installiert (Systemcheck).');
    await voice.speak(text, voiceDir: dir, key: key);
  }

  // --------------------------------------------------------------- Internet

  Future<bool> _requestNetwork(Conversation conv, String purpose) async {
    if (conv.internetAllowed || _turnInternetAllowed) return true;
    final ask = consentHandler;
    if (ask == null) return false;
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

  Future<void> revokeInternet() async {
    final c = current;
    if (c == null) return;
    c.internetAllowed = false;
    await storage.saveConversation(c);
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
    try {
      final bytes = await File(path).readAsBytes();
      if (bytes.length > 4 * 1024 * 1024) return '$name ist größer als 4 MB.';
      // einfache Binärprüfung
      final probe = bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes;
      if (probe.where((b) => b == 0).length > 2) {
        return '$name ist keine Textdatei (unterstützt: TXT, MD, CSV, JSON, Code).';
      }
      var text = utf8.decode(bytes, allowMalformed: true);
      if (text.length > maxAttachmentChars) {
        text = '${text.substring(0, maxAttachmentChars)}\n[… gekürzt]';
      }
      final key = current?.id ?? '';
      (_attachments[key] ??= []).add(Attachment(name: name, content: text, path: path));
      notifyListeners();
      return null;
    } catch (e) {
      return '$name konnte nicht gelesen werden: $e';
    }
  }

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

  // ----------------------------------------------------------- Agenten-Lauf

  Future<void> send(String input) async {
    final eng = engine;
    if (eng == null || running || input.trim().isEmpty) return;
    final conv = _ensureConversation();
    final profile = activeProfile;

    final history = <ChatMessage>[
      for (final e in conv.entries)
        if (e.text.trim().isNotEmpty && e.error == null) ChatMessage(e.role, e.text),
    ];
    final docs = List<Attachment>.of(attachments);
    final user = ChatEntry(role: 'user', text: input.trim(), attachments: docs.map((d) => d.name).toList());
    final answer = ChatEntry(role: 'assistant');
    conv.entries..add(user)..add(answer);
    if (conv.title == 'Neuer Chat') {
      final t = input.trim().replaceAll('\n', ' ');
      conv.title = t.length > 40 ? '${t.substring(0, 40)}…' : t;
    }
    conv.updated = DateTime.now();

    final ctxSize = eng.contextSize;
    final runner = AgentRunner(
      engine: eng,
      systemPrompt: profile.systemPrompt,
      tools: activeTools,
      maxSteps: profile.maxSteps,
      maxTokensPerStep: (ctxSize ~/ 4).clamp(256, 1024),
      observationLimit: device.deviceClass == DeviceClass.s ? 1000 : 2000,
      sampling: SamplingParams(temperature: profile.temperature.clamp(0.0, 0.5), topP: 0.9),
      chatSampling: SamplingParams(temperature: profile.temperature),
    );
    _runner = runner;
    running = true;
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
        inspectorAttention = true;
        notifyListeners();
      },
    );

    try {
      await for (final ev in runner.run(history: history, userInput: input.trim(), context: ctx)) {
        switch (ev) {
          case StepStarted(step: final n):
            if (runner.agentMode) answer.steps.add(StepLog(step: n));
          case StepStreaming(thought: final liveThought, answer: final liveAnswer):
            if (runner.agentMode && liveThought != null) {
              final last = answer.steps.lastOrNull;
              if (last != null) last.thought = liveThought;
            }
            if (liveAnswer != null) answer.text = liveAnswer;
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
      running = false;
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
    if (settings.autoSpeak && answer.error == null && answer.text.trim().isNotEmpty && ttsVoicePath != null) {
      unawaited(speakText(answer.text, key: answer).catchError((_) {}));
    }
  }

  void stop() {
    _runner?.stop();
    engine?.stop();
  }
}

/// Top-Level-Funktion: Die Closure für Isolate.run darf nur die beiden Pfade
/// enthalten – eine Closure in einer Methode würde den ganzen AppController
/// (inkl. AudioPlayer) mitschicken, was nicht erlaubt ist.
Future<void> _extractInBackground(String archivePath, String targetDir) =>
    Isolate.run(() => extractFileToDisk(archivePath, targetDir));
