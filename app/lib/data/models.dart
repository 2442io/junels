// Datenmodelle der App (persistiert als JSON).

import 'dart:math';

String newId() {
  final r = Random();
  return '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${r.nextInt(1 << 32).toRadixString(36)}';
}

/// Ein importiertes GGUF-Modell im App-Verzeichnis.
class StoredModel {
  StoredModel({
    required this.id,
    required this.fileName,
    required this.path,
    required this.sizeBytes,
    required this.displayName,
    required this.architecture,
    required this.quantization,
    this.trainedContext,
    this.catalogId,
    DateTime? imported,
  }) : imported = imported ?? DateTime.now();

  final String id;
  final String fileName;
  final String path;
  final int sizeBytes;
  final String displayName;
  final String architecture;
  final String quantization;
  final int? trainedContext;
  final String? catalogId;
  final DateTime imported;

  String get sizeLabel => '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';

  Map<String, Object?> toJson() => {
        'id': id,
        'fileName': fileName,
        'path': path,
        'sizeBytes': sizeBytes,
        'displayName': displayName,
        'architecture': architecture,
        'quantization': quantization,
        'trainedContext': trainedContext,
        'catalogId': catalogId,
        'imported': imported.toIso8601String(),
      };

  factory StoredModel.fromJson(Map<String, dynamic> j) => StoredModel(
        id: j['id'] as String,
        fileName: j['fileName'] as String,
        path: j['path'] as String,
        sizeBytes: (j['sizeBytes'] as num).toInt(),
        displayName: j['displayName'] as String? ?? j['fileName'] as String,
        architecture: j['architecture'] as String? ?? '?',
        quantization: j['quantization'] as String? ?? '?',
        trainedContext: (j['trainedContext'] as num?)?.toInt(),
        catalogId: j['catalogId'] as String?,
        imported: DateTime.tryParse(j['imported'] as String? ?? ''),
      );
}

/// Agent-Profil: System-Prompt und Verhalten.
class AgentProfile {
  AgentProfile({
    required this.id,
    required this.name,
    required this.systemPrompt,
    this.temperature = 0.3,
    this.maxSteps = 6,
    this.useTools = true,
    this.builtin = false,
  });

  final String id;
  String name;
  String systemPrompt;
  double temperature;
  int maxSteps;
  bool useTools;
  final bool builtin;

  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'systemPrompt': systemPrompt,
        'temperature': temperature,
        'maxSteps': maxSteps,
        'useTools': useTools,
        'builtin': builtin,
      };

  factory AgentProfile.fromJson(Map<String, dynamic> j) => AgentProfile(
        id: j['id'] as String,
        name: j['name'] as String,
        systemPrompt: j['systemPrompt'] as String,
        temperature: (j['temperature'] as num?)?.toDouble() ?? 0.3,
        maxSteps: (j['maxSteps'] as num?)?.toInt() ?? 6,
        useTools: j['useTools'] as bool? ?? true,
        builtin: j['builtin'] as bool? ?? false,
      );

  static List<AgentProfile> defaults() => [
        AgentProfile(
          id: 'assistant',
          name: 'Allgemeiner Assistent',
          builtin: true,
          systemPrompt:
              'Du bist ein hilfreicher, präziser Assistent, der vollständig offline auf diesem Gerät läuft. '
              'Antworte knapp und korrekt. Wenn dir Informationen fehlen, sag das offen.',
        ),
        AgentProfile(
          id: 'analyst',
          name: 'Datei-Analyst',
          builtin: true,
          maxSteps: 8,
          systemPrompt:
              'Du analysierst angehängte Dateien (Text, CSV, JSON). Lies die relevanten Stellen mit den Tools, '
              'bevor du antwortest, und nenne die Fundstelle (Datei und Zeile). Fasse Ergebnisse strukturiert zusammen; '
              'längere Tabellen oder Berichte legst du mit write_artifact ab.',
        ),
        AgentProfile(
          id: 'calc',
          name: 'Rechen-Assistent',
          builtin: true,
          temperature: 0.1,
          systemPrompt:
              'Du löst Rechen- und Umrechnungsaufgaben. Jede Rechnung führst du mit dem calculator-Tool aus '
              'und zeigst den Rechenweg kurz.',
        ),
        AgentProfile(
          id: 'chat',
          name: 'Nur Chat (ohne Tools)',
          builtin: true,
          temperature: 0.7,
          useTools: false,
          systemPrompt: 'Du bist ein freundlicher Gesprächspartner. Antworte in der Sprache des Nutzers.',
        ),
      ];
}

/// Protokoll eines Agenten-Schritts (für das Thought Log).
class StepLog {
  StepLog({
    required this.step,
    this.thought = '',
    this.tool,
    this.args,
    this.observation,
    this.isError = false,
    this.durationMs = 0,
  });

  final int step;
  String thought;
  String? tool;
  Map<String, dynamic>? args;
  String? observation;
  bool isError;
  int durationMs;

  Map<String, Object?> toJson() => {
        'step': step,
        'thought': thought,
        'tool': tool,
        'args': args,
        'observation': observation,
        'isError': isError,
        'durationMs': durationMs,
      };

  factory StepLog.fromJson(Map<String, dynamic> j) => StepLog(
        step: (j['step'] as num).toInt(),
        thought: j['thought'] as String? ?? '',
        tool: j['tool'] as String?,
        args: (j['args'] as Map?)?.cast<String, dynamic>(),
        observation: j['observation'] as String?,
        isError: j['isError'] as bool? ?? false,
        durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
      );
}

/// Quelle einer Antwort: Modell, Dokument oder Webseite.
class SourceRef {
  const SourceRef(this.kind, this.label, [this.url]);
  final String kind; // model | doc | web
  final String label;
  final String? url;

  Map<String, Object?> toJson() => {'kind': kind, 'label': label, if (url != null) 'url': url};
  factory SourceRef.fromJson(Map<String, dynamic> j) =>
      SourceRef(j['kind'] as String? ?? 'model', j['label'] as String? ?? '', j['url'] as String?);
}

class ChatEntry {
  ChatEntry({
    required this.role,
    this.text = '',
    List<StepLog>? steps,
    this.attachments = const [],
    this.error,
    this.truncated = false,
    this.tokensPerSecond,
    this.durationMs,
    List<Map<String, String>>? cards,
    this.viaVoice = false,
    List<SourceRef>? sources,
    List<String>? files,
    List<Map<String, String>>? actions,
    DateTime? time,
    this.via,
    this.cloudOffer = false,
  })  : steps = steps ?? [],
        actions = actions ?? [],
        sources = sources ?? [],
        files = files ?? [],
        cards = cards ?? [],
        time = time ?? DateTime.now();

  final String role; // user | assistant
  String text;
  final List<StepLog> steps;
  final List<String> attachments;
  String? error;
  bool truncated;
  double? tokensPerSecond;
  int? durationMs; // wie lange die Antwort gedauert hat
  List<Map<String, String>> cards; // Ergebnis-Karten (Produkte, Meldungen) fürs Karussell
  final bool viaVoice; // im Gesprächsmodus gesprochen
  final List<SourceRef> sources;

  /// Dateipfade: beim Nutzer angehängte Bilder, beim Agenten erzeugte Dateien.
  final List<String> files;

  /// Vorgeschlagene Aktionen (E-Mail, WhatsApp) mit Status pending | sent | opened | discarded.
  final List<Map<String, String>> actions;
  final DateTime time;

  /// Wer geantwortet hat, wenn nicht das lokale Modell (z. B. „Cloud · Claude“).
  String? via;

  /// Lokale Antwort hat nicht geklappt – „Mit Cloud beantworten“ anbieten.
  bool cloudOffer;

  Map<String, Object?> toJson() => {
        'role': role,
        if (via != null) 'via': via,
        if (cloudOffer) 'cloudOffer': true,
        'text': text,
        'steps': steps.map((s) => s.toJson()).toList(),
        'attachments': attachments,
        'error': error,
        'truncated': truncated,
        'tps': tokensPerSecond,
        if (durationMs != null) 'ms': durationMs,
        if (cards.isNotEmpty) 'cards': cards,
        'voice': viaVoice,
        if (sources.isNotEmpty) 'sources': sources.map((e) => e.toJson()).toList(),
        if (files.isNotEmpty) 'files': files,
        if (actions.isNotEmpty) 'actions': actions,
        'time': time.toIso8601String(),
      };

  factory ChatEntry.fromJson(Map<String, dynamic> j) => ChatEntry(
        role: j['role'] as String,
        text: j['text'] as String? ?? '',
        steps: [for (final s in (j['steps'] as List? ?? const [])) StepLog.fromJson((s as Map).cast())],
        attachments: (j['attachments'] as List? ?? const []).cast<String>(),
        sources: [for (final x in (j['sources'] as List? ?? const [])) SourceRef.fromJson((x as Map).cast())],
        files: (j['files'] as List? ?? const []).cast<String>(),
        actions: [for (final a in (j['actions'] as List? ?? const [])) (a as Map).cast<String, String>()],
        error: j['error'] as String?,
        truncated: j['truncated'] as bool? ?? false,
        tokensPerSecond: (j['tps'] as num?)?.toDouble(),
        durationMs: (j['ms'] as num?)?.toInt(),
        cards: [for (final c in (j['cards'] as List? ?? const [])) (c as Map).cast<String, String>()],
        viaVoice: j['voice'] as bool? ?? false,
        time: DateTime.tryParse(j['time'] as String? ?? ''),
        via: j['via'] as String?,
        cloudOffer: j['cloudOffer'] as bool? ?? false,
      );
}

class Conversation {
  Conversation({
    required this.id,
    this.title = 'Neuer Chat',
    List<ChatEntry>? entries,
    List<Map<String, dynamic>>? artifacts,
    DateTime? updated,
    this.internetAllowed = false,
    this.internetOff = false,
    this.cloudAllowed = false,
    this.routing,
    this.hybridTarget,
  })  : entries = entries ?? [],
        artifacts = artifacts ?? [],
        updated = updated ?? DateTime.now();

  final String id;
  String title;
  final List<ChatEntry> entries;
  final List<Map<String, dynamic>> artifacts;
  DateTime updated;

  /// Nutzer hat Internet für diesen ganzen Chat freigegeben.
  bool internetAllowed;
  bool internetOff; // Internet in diesem Chat ganz aus (keine Web-Tools)
  bool cloudAllowed; // Cloud-Anbieter für den ganzen Chat freigegeben
  String? routing; // KI-Modus nur für diesen Chat (null = Einstellung)
  String? hybridTarget; // Hybrid: danach onprem | cloud (null = Einstellung)

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'entries': entries.map((e) => e.toJson()).toList(),
        'artifacts': artifacts,
        'updated': updated.toIso8601String(),
        'internetAllowed': internetAllowed,
        'internetOff': internetOff,
        if (cloudAllowed) 'cloudAllowed': true,
        if (routing != null) 'routing': routing,
        if (hybridTarget != null) 'hybridTarget': hybridTarget,
      };

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'] as String,
        title: j['title'] as String? ?? 'Chat',
        entries: [for (final e in (j['entries'] as List? ?? const [])) ChatEntry.fromJson((e as Map).cast())],
        artifacts: [for (final a in (j['artifacts'] as List? ?? const [])) (a as Map).cast<String, dynamic>()],
        updated: DateTime.tryParse(j['updated'] as String? ?? ''),
        internetAllowed: j['internetAllowed'] as bool? ?? false,
        internetOff: j['internetOff'] as bool? ?? false,
        cloudAllowed: j['cloudAllowed'] as bool? ?? false,
        routing: j['routing'] as String?,
        hybridTarget: j['hybridTarget'] as String?,
      );
}

class AppSettings {
  AppSettings({
    this.contextSize = 2048,
    this.contextAuto = true,
    this.activeProfileId = 'assistant',
    this.lastModelId,
    this.autoLoadLastModel = true,
    Set<String>? enabledTools,
    this.darkMode,
    this.sttModelId,
    this.ttsVoiceId,
    this.systemVoice = '',
    this.sttLanguage = 'auto',
    this.autoSpeak = false,
    this.sendAfterVoice = true,
    this.voiceManualEnd = false,
    this.agentName = 'Junels',
    this.voiceWakeWord = true,
    this.voiceBargeIn = false,
    this.memoryConfirm = true,
    this.memorySensitive = false,
    this.meetingFollowUp = true,
    this.smtpHost = '',
    this.smtpPort = 465,
    this.smtpUser = '',
    this.smtpFrom = '',
    this.routing = 'local',
    this.autoModel = true,
    this.fastModelId,
    this.strongModelId,
    this.hybridFirst = 'local',
    this.hybridTarget = 'cloud',
    this.onPremId,
    this.cloudId,
    List<Map<String, dynamic>>? providers,
    this.voicePauseMs = 1200,
    this.voiceNearField = true,
    this.voiceSmartVad = true,
    this.homeCity = '',
    this.countryCode = '43',
    List<Map<String, String>>? watchFolders,
    List<Map<String, String>>? grantedFolders,
    this.lastWatchScan = 0,
    this.systemCheckSeen = false,
    Map<String, String>? installed,
  })  : enabledTools = enabledTools ??
            {
              'text_search', 'read_file', 'json_query', 'calculator', 'write_artifact', 'datetime',
              'web_search', 'web_fetch', 'remember', 'search_history', 'knowledge_search',
              'create_document', 'create_presentation', 'create_chart', 'generate_image', 'look_at_image',
              'send_notification',
              'save_prompt',
              ...AppSettings.deviceTools,
              'site_search',
              'browser',
            },
        installed = installed ?? {},
        watchFolders = watchFolders ?? [],
        providers = providers ?? [],
        grantedFolders = grantedFolders ?? [];

  int contextSize;

  /// true = Context automatisch auf das Maximum der Geräteklasse setzen
  bool contextAuto;
  String activeProfileId;
  String? lastModelId;
  bool autoLoadLastModel;
  final Set<String> enabledTools;
  bool? darkMode; // null = System

  // Sprache
  String? sttModelId; // Katalog-ID des Whisper-Modells
  String? ttsVoiceId; // Katalog-ID der Piper-Stimme ('__system__' = Stimme des Geräts)
  String systemVoice; // Stimme des Geräts: „Name|Locale“ (leer = Standard)
  String sttLanguage; // auto | de | en
  bool autoSpeak; // Antworten automatisch vorlesen
  bool sendAfterVoice; // nach Spracheingabe sofort senden
  bool voiceManualEnd; // Gesprächsmodus: Ende per "Fertig"-Taste statt Sprechpause
  String agentName; // Name, auf den der Agent im Gespräch hört
  bool voiceWakeWord; // Gesprächsmodus: nur reagieren, wenn der Name fällt
  bool voiceBargeIn; // Gesprächsmodus: Reinreden unterbricht die Antwort (sonst nur Tipp/Name)
  bool memoryConfirm; // neue Gedächtnis-Einträge erst nach Bestätigung verwenden
  bool memorySensitive; // Gesundheit, Finanzen, Religion … merken erlaubt
  bool meetingFollowUp; // nach Terminen eine Folgemail vorschlagen (Push)
  // Mailversand direkt aus Junels (Passwort liegt im Tresor, nicht hier)
  String smtpHost;
  int smtpPort;
  String smtpUser;
  String smtpFrom;
  bool get smtpReady => smtpHost.isNotEmpty && smtpUser.isNotEmpty;

  /// Automatische Modellwahl: einfache Fragen → schnelles, komplexe → starkes Modell
  bool autoModel;
  String? fastModelId;
  String? strongModelId;

  /// Wer antwortet: local | onprem | cloud | hybrid (erst lokal/On-Prem, Cloud nach Freigabe)
  String routing;

  /// Bei hybrid: zuerst „local“ (Gerät) oder „onprem“ (eigener Server)
  String hybridFirst;

  /// Bei hybrid: danach „cloud“ (mit Freigabe) oder „onprem“ (eigener Server, ohne Freigabe)
  String hybridTarget;
  String? onPremId;
  String? cloudId;

  /// Angebundene Anbieter (ohne Schlüssel – die liegen im Tresor)
  List<Map<String, dynamic>> providers;
  int voicePauseMs; // Gesprächsmodus: so lange Pause beendet die Äußerung
  bool voiceNearField; // Gesprächsmodus: leisere Stimmen im Hintergrund ignorieren
  bool voiceSmartVad; // Gesprächsmodus: Silero-Spracherkennung statt nur Lautstärke
  String homeCity; // Heimatort für Wetter und Morgen-Übersicht
  String countryCode; // Landesvorwahl für WhatsApp (ohne +)
  List<Map<String, String>> watchFolders; // überwachte Ordner → Wissensbasis {id, name}
  List<Map<String, String>> grantedFolders; // Mac: freigegebene Ordner für Dateihilfe {id, name, path}
  int lastWatchScan;
  bool systemCheckSeen;

  /// Installierte Sprach-Modelle: Katalog-ID → Pfad (Datei oder Ordner)
  final Map<String, String> installed;

  Map<String, Object?> toJson() => {
        'contextSize': contextSize,
        'contextAuto': contextAuto,
        'activeProfileId': activeProfileId,
        'lastModelId': lastModelId,
        'autoLoadLastModel': autoLoadLastModel,
        'enabledTools': enabledTools.toList(),
        'darkMode': darkMode,
        'sttModelId': sttModelId,
        'ttsVoiceId': ttsVoiceId,
        'systemVoice': systemVoice,
        'sttLanguage': sttLanguage,
        'autoSpeak': autoSpeak,
        'sendAfterVoice': sendAfterVoice,
        'voiceManualEnd': voiceManualEnd,
        'agentName': agentName,
        'voiceWakeWord': voiceWakeWord,
        'voiceBargeIn': voiceBargeIn,
        'memoryConfirm': memoryConfirm,
        'memorySensitive': memorySensitive,
        'meetingFollowUp': meetingFollowUp,
        'smtpHost': smtpHost,
        'smtpPort': smtpPort,
        'smtpUser': smtpUser,
        'smtpFrom': smtpFrom,
        'routing': routing,
        'autoModel': autoModel,
        if (fastModelId != null) 'fastModelId': fastModelId,
        if (strongModelId != null) 'strongModelId': strongModelId,
        'hybridFirst': hybridFirst,
        'hybridTarget': hybridTarget,
        if (onPremId != null) 'onPremId': onPremId,
        if (cloudId != null) 'cloudId': cloudId,
        'providers': providers,
        'voicePauseMs': voicePauseMs,
        'voiceNearField': voiceNearField,
        'voiceSmartVad': voiceSmartVad,
        'homeCity': homeCity,
        'countryCode': countryCode,
        'watchFolders': watchFolders,
        'grantedFolders': grantedFolders,
        'lastWatchScan': lastWatchScan,
        'systemCheckSeen': systemCheckSeen,
        'installed': installed,
        'toolsVersion': toolsVersion,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        contextSize: (j['contextSize'] as num?)?.toInt() ?? 2048,
        contextAuto: j['contextAuto'] as bool? ?? true,
        activeProfileId: j['activeProfileId'] as String? ?? 'assistant',
        lastModelId: j['lastModelId'] as String?,
        autoLoadLastModel: j['autoLoadLastModel'] as bool? ?? true,
        enabledTools: (j['enabledTools'] as List?)?.cast<String>().toSet(),
        darkMode: j['darkMode'] as bool?,
        sttModelId: j['sttModelId'] as String?,
        ttsVoiceId: j['ttsVoiceId'] as String?,
        systemVoice: j['systemVoice'] as String? ?? '',
        sttLanguage: j['sttLanguage'] as String? ?? 'auto',
        autoSpeak: j['autoSpeak'] as bool? ?? false,
        sendAfterVoice: j['sendAfterVoice'] as bool? ?? true,
        voiceManualEnd: j['voiceManualEnd'] as bool? ?? false,
        agentName: (j['agentName'] as String?)?.trim().isNotEmpty == true ? (j['agentName'] as String).trim() : 'Junels',
        voiceWakeWord: j['voiceWakeWord'] as bool? ?? true,
        voiceBargeIn: j['voiceBargeIn'] as bool? ?? false,
        memoryConfirm: j['memoryConfirm'] as bool? ?? true,
        memorySensitive: j['memorySensitive'] as bool? ?? false,
        meetingFollowUp: j['meetingFollowUp'] as bool? ?? true,
        smtpHost: j['smtpHost'] as String? ?? '',
        smtpPort: (j['smtpPort'] as num?)?.toInt() ?? 465,
        smtpUser: j['smtpUser'] as String? ?? '',
        smtpFrom: j['smtpFrom'] as String? ?? '',
        routing: j['routing'] as String? ?? 'local',
        autoModel: j['autoModel'] as bool? ?? true,
        fastModelId: j['fastModelId'] as String?,
        strongModelId: j['strongModelId'] as String?,
        hybridFirst: j['hybridFirst'] as String? ?? 'local',
        hybridTarget: j['hybridTarget'] as String? ?? 'cloud',
        onPremId: j['onPremId'] as String?,
        cloudId: j['cloudId'] as String?,
        providers: [for (final m in (j['providers'] as List? ?? const [])) (m as Map).cast<String, dynamic>()],
        voicePauseMs: (j['voicePauseMs'] as num?)?.toInt() ?? 1200,
        voiceNearField: j['voiceNearField'] as bool? ?? true,
        voiceSmartVad: j['voiceSmartVad'] as bool? ?? true,
        homeCity: j['homeCity'] as String? ?? '',
        countryCode: j['countryCode'] as String? ?? '43',
        watchFolders: [for (final m in (j['watchFolders'] as List? ?? const [])) (m as Map).cast<String, String>()],
        grantedFolders: [for (final m in (j['grantedFolders'] as List? ?? const [])) (m as Map).cast<String, String>()],
        lastWatchScan: (j['lastWatchScan'] as num?)?.toInt() ?? 0,
        systemCheckSeen: j['systemCheckSeen'] as bool? ?? false,
        installed: (j['installed'] as Map?)?.cast<String, String>(),
      ).._migrateTools((j['toolsVersion'] as num?)?.toInt() ?? 1);

  static const toolsVersion = 10;
  static const deviceTools = ['weather', 'news', 'contacts_search', 'compose_email', 'compose_whatsapp', 'call_phone', 'calendar_add', 'calendar_list', 'file_search', 'file_rename', 'file_move'];

  /// Neue Tools bei älteren Einstellungen einschalten.
  void _migrateTools(int from) {
    if (from < 2) enabledTools.addAll(['web_search', 'web_fetch']);
    if (from < 3) enabledTools.addAll(['remember', 'search_history', 'knowledge_search']);
    if (from < 4) {
      enabledTools.addAll(['create_document', 'create_presentation', 'create_chart', 'generate_image', 'look_at_image']);
    }
    if (from < 5) enabledTools.add('send_notification');
    if (from < 6) enabledTools.add('save_prompt');
    if (from < 7) enabledTools.addAll(deviceTools);
    if (from < 8) enabledTools.add('site_search');
    // 1.19 hatte den Browser für bestehende Installationen vergessen
    if (from < 10 && !enabledTools.contains('browser')) enabledTools.add('browser');
    if (from < 9) enabledTools.add('browser');
  }
}

/// Vorlagen für das Eingabefeld.
const promptPresets = <(String, String)>[
  ('Zusammenfassen', 'Fasse die angehängte Datei in 5 Stichpunkten zusammen.'),
  ('Suchen', 'Suche in den angehängten Dateien nach: '),
  ('Tabelle', 'Erstelle aus den Daten eine Markdown-Tabelle und lege sie als Artefakt ab.'),
  ('Präsentation', 'Erstelle eine Präsentation mit 6 Folien zum Thema: '),
  ('PDF-Bericht', 'Schreibe einen kurzen Bericht als PDF über: '),
  ('Bild', 'Erzeuge ein Bild: '),
  ('Diagramm', 'Zeichne ein Balkendiagramm mit diesen Werten: '),
  ('Rechnen', 'Berechne: '),
  ('JSON prüfen', 'Lies die JSON-Datei und liste alle Schlüssel der obersten Ebene auf.'),
];

// ------------------------------------------------------------ Gespeicherte Prompts

enum ScheduleKind { off, daily, weekdays, weekly }

/// Gespeicherter Prompt, per Klick oder nach Zeitplan ausführbar.
class SavedPrompt {
  SavedPrompt({
    String? id,
    required this.title,
    required this.text,
    this.profileId,
    this.schedule = ScheduleKind.off,
    this.hour = 8,
    this.minute = 30,
    this.weekday = DateTime.monday,
    this.allowInternet = false,
    this.notify = true,
    this.lastRun,
    this.enabled = true,
  }) : id = id ?? newId();

  final String id;
  String title;
  String text;
  String? profileId; // null = aktives Profil
  ScheduleKind schedule;
  int hour;
  int minute;
  int weekday; // 1 = Montag … 7 = Sonntag (nur wöchentlich)
  bool allowInternet; // automatisch ohne Nachfrage (für Läufe ohne Nutzer)
  bool notify;
  DateTime? lastRun;
  bool enabled; // geplante Aufgabe an/aus (Zeitplan bleibt erhalten)

  static const weekdayNames = ['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', 'Sonntag'];

  String get timeLabel => '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  String get scheduleLabel => switch (schedule) {
        ScheduleKind.off => 'Nur per Klick',
        ScheduleKind.daily => 'Täglich $timeLabel',
        ScheduleKind.weekdays => 'Mo–Fr $timeLabel',
        ScheduleKind.weekly => 'Jeden ${weekdayNames[weekday - 1]} $timeLabel',
      };

  bool _dayMatches(DateTime d) => switch (schedule) {
        ScheduleKind.off => false,
        ScheduleKind.daily => true,
        ScheduleKind.weekdays => d.weekday <= DateTime.friday,
        ScheduleKind.weekly => d.weekday == weekday,
      };

  /// Nächster geplanter Zeitpunkt nach [from] (null = kein Zeitplan).
  DateTime? nextAfter(DateTime from) {
    if (schedule == ScheduleKind.off || !enabled) return null;
    for (var i = 0; i < 8; i++) {
      final d = DateTime(from.year, from.month, from.day + i, hour, minute);
      if (d.isAfter(from) && _dayMatches(d)) return d;
    }
    return null;
  }

  /// Letzter geplanter Zeitpunkt bis einschließlich [now].
  DateTime? lastDueBefore(DateTime now) {
    if (schedule == ScheduleKind.off) return null;
    for (var i = 0; i < 8; i++) {
      final d = DateTime(now.year, now.month, now.day - i, hour, minute);
      if (!d.isAfter(now) && _dayMatches(d)) return d;
    }
    return null;
  }

  /// Fällig? Verpasste Läufe werden nachgeholt, aber nur am selben Tag.
  bool isDue(DateTime now) {
    if (!enabled) return false;
    final due = lastDueBefore(now);
    if (due == null) return false;
    if (lastRun != null && !lastRun!.isBefore(due)) return false;
    return due.year == now.year && due.month == now.month && due.day == now.day;
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'text': text,
        'profileId': profileId,
        'schedule': schedule.name,
        'hour': hour,
        'minute': minute,
        'weekday': weekday,
        'allowInternet': allowInternet,
        'notify': notify,
        if (!enabled) 'enabled': false,
        'lastRun': lastRun?.toIso8601String(),
      };

  factory SavedPrompt.fromJson(Map<String, dynamic> j) => SavedPrompt(
        id: j['id'] as String?,
        title: j['title'] as String? ?? '',
        text: j['text'] as String? ?? '',
        profileId: j['profileId'] as String?,
        schedule: ScheduleKind.values.asNameMap()[j['schedule']] ?? ScheduleKind.off,
        hour: (j['hour'] as num?)?.toInt() ?? 8,
        minute: (j['minute'] as num?)?.toInt() ?? 30,
        weekday: (j['weekday'] as num?)?.toInt() ?? 1,
        allowInternet: j['allowInternet'] as bool? ?? false,
        notify: j['notify'] as bool? ?? true,
        enabled: j['enabled'] as bool? ?? true,
        lastRun: DateTime.tryParse(j['lastRun'] as String? ?? ''),
      );
}

/// Dauer lesbar: "8 s", "1 min 5 s", "1 h 2 min".
String formatDuration(int ms) {
  final s = (ms / 1000).round();
  if (ms < 10000) return '${(ms / 1000).toStringAsFixed(1).replaceAll('.', ',')} s';
  if (s < 60) return '$s s';
  if (s < 3600) return '${s ~/ 60} min ${s % 60} s';
  return '${s ~/ 3600} h ${(s % 3600) ~/ 60} min';
}
