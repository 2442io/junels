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

class ChatEntry {
  ChatEntry({
    required this.role,
    this.text = '',
    List<StepLog>? steps,
    this.attachments = const [],
    this.error,
    this.truncated = false,
    this.tokensPerSecond,
    DateTime? time,
  })  : steps = steps ?? [],
        time = time ?? DateTime.now();

  final String role; // user | assistant
  String text;
  final List<StepLog> steps;
  final List<String> attachments;
  String? error;
  bool truncated;
  double? tokensPerSecond;
  final DateTime time;

  Map<String, Object?> toJson() => {
        'role': role,
        'text': text,
        'steps': steps.map((s) => s.toJson()).toList(),
        'attachments': attachments,
        'error': error,
        'truncated': truncated,
        'tps': tokensPerSecond,
        'time': time.toIso8601String(),
      };

  factory ChatEntry.fromJson(Map<String, dynamic> j) => ChatEntry(
        role: j['role'] as String,
        text: j['text'] as String? ?? '',
        steps: [for (final s in (j['steps'] as List? ?? const [])) StepLog.fromJson((s as Map).cast())],
        attachments: (j['attachments'] as List? ?? const []).cast<String>(),
        error: j['error'] as String?,
        truncated: j['truncated'] as bool? ?? false,
        tokensPerSecond: (j['tps'] as num?)?.toDouble(),
        time: DateTime.tryParse(j['time'] as String? ?? ''),
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

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'entries': entries.map((e) => e.toJson()).toList(),
        'artifacts': artifacts,
        'updated': updated.toIso8601String(),
        'internetAllowed': internetAllowed,
      };

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'] as String,
        title: j['title'] as String? ?? 'Chat',
        entries: [for (final e in (j['entries'] as List? ?? const [])) ChatEntry.fromJson((e as Map).cast())],
        artifacts: [for (final a in (j['artifacts'] as List? ?? const [])) (a as Map).cast<String, dynamic>()],
        updated: DateTime.tryParse(j['updated'] as String? ?? ''),
        internetAllowed: j['internetAllowed'] as bool? ?? false,
      );
}

class AppSettings {
  AppSettings({
    this.contextSize = 2048,
    this.activeProfileId = 'assistant',
    this.lastModelId,
    this.autoLoadLastModel = true,
    Set<String>? enabledTools,
    this.darkMode,
    this.sttModelId,
    this.ttsVoiceId,
    this.sttLanguage = 'auto',
    this.autoSpeak = false,
    this.sendAfterVoice = true,
    this.systemCheckSeen = false,
    Map<String, String>? installed,
  })  : enabledTools = enabledTools ??
            {
              'text_search', 'read_file', 'json_query', 'calculator', 'write_artifact', 'datetime',
              'web_search', 'web_fetch',
            },
        installed = installed ?? {};

  int contextSize;
  String activeProfileId;
  String? lastModelId;
  bool autoLoadLastModel;
  final Set<String> enabledTools;
  bool? darkMode; // null = System

  // Sprache
  String? sttModelId; // Katalog-ID des Whisper-Modells
  String? ttsVoiceId; // Katalog-ID der Piper-Stimme
  String sttLanguage; // auto | de | en
  bool autoSpeak; // Antworten automatisch vorlesen
  bool sendAfterVoice; // nach Spracheingabe sofort senden
  bool systemCheckSeen;

  /// Installierte Sprach-Modelle: Katalog-ID → Pfad (Datei oder Ordner)
  final Map<String, String> installed;

  Map<String, Object?> toJson() => {
        'contextSize': contextSize,
        'activeProfileId': activeProfileId,
        'lastModelId': lastModelId,
        'autoLoadLastModel': autoLoadLastModel,
        'enabledTools': enabledTools.toList(),
        'darkMode': darkMode,
        'sttModelId': sttModelId,
        'ttsVoiceId': ttsVoiceId,
        'sttLanguage': sttLanguage,
        'autoSpeak': autoSpeak,
        'sendAfterVoice': sendAfterVoice,
        'systemCheckSeen': systemCheckSeen,
        'installed': installed,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        contextSize: (j['contextSize'] as num?)?.toInt() ?? 2048,
        activeProfileId: j['activeProfileId'] as String? ?? 'assistant',
        lastModelId: j['lastModelId'] as String?,
        autoLoadLastModel: j['autoLoadLastModel'] as bool? ?? true,
        enabledTools: (j['enabledTools'] as List?)?.cast<String>().toSet(),
        darkMode: j['darkMode'] as bool?,
        sttModelId: j['sttModelId'] as String?,
        ttsVoiceId: j['ttsVoiceId'] as String?,
        sttLanguage: j['sttLanguage'] as String? ?? 'auto',
        autoSpeak: j['autoSpeak'] as bool? ?? false,
        sendAfterVoice: j['sendAfterVoice'] as bool? ?? true,
        systemCheckSeen: j['systemCheckSeen'] as bool? ?? false,
        installed: (j['installed'] as Map?)?.cast<String, String>(),
      );
}

/// Vorlagen für das Eingabefeld.
const promptPresets = <(String, String)>[
  ('Zusammenfassen', 'Fasse die angehängte Datei in 5 Stichpunkten zusammen.'),
  ('Suchen', 'Suche in den angehängten Dateien nach: '),
  ('Tabelle', 'Erstelle aus den Daten eine Markdown-Tabelle und lege sie als Artefakt ab.'),
  ('Rechnen', 'Berechne: '),
  ('JSON prüfen', 'Lies die JSON-Datei und liste alle Schlüssel der obersten Ebene auf.'),
];
