// Lokale Persistenz als JSON-Dateien im App-Verzeichnis (kein Netzwerk, keine Cloud).

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

class Storage {
  Storage._(this.root, this.documentsDir);

  final Directory root;

  /// Auf iPadOS über Finder/Dateien-App sichtbar (UIFileSharingEnabled):
  /// dort abgelegte .gguf-Dateien werden ohne Kopie übernommen.
  final Directory documentsDir;

  Directory get modelsDir => Directory('${root.path}/models');
  Directory get voiceDir => Directory('${root.path}/voice');
  Directory get chatsDir => Directory('${root.path}/chats');
  File get _settings => File('${root.path}/settings.json');
  File get _profiles => File('${root.path}/profiles.json');
  File get _models => File('${root.path}/models.json');
  File get _prompts => File('${root.path}/prompts.json');

  Future<List<SavedPrompt>> loadPrompts() async {
    final j = await _readJson(_prompts);
    if (j is! List) return [];
    return [for (final x in j) if (x is Map) SavedPrompt.fromJson(x.cast())];
  }

  Future<void> savePrompts(List<SavedPrompt> p) => _writeJson(_prompts, p.map((e) => e.toJson()).toList());

  static Future<Storage> open() async {
    // Application Support: nicht für den Nutzer sichtbar, auf iOS/macOS im Sandbox-Container
    final base = await getApplicationSupportDirectory();
    final docs = await getApplicationDocumentsDirectory();
    final s = Storage._(Directory('${base.path}/offline_agent'), docs);
    await s.modelsDir.create(recursive: true);
    await s.chatsDir.create(recursive: true);
    await s.voiceDir.create(recursive: true);
    return s;
  }

  Future<Object?> _readJson(File f) async {
    try {
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null; // beschädigte Datei: mit Standardwerten weiter
    }
  }

  /// Schreibt atomar (erst temporäre Datei, dann umbenennen).
  Future<void> _writeJson(File f, Object data) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(data), flush: true);
    await tmp.rename(f.path);
  }

  Future<AppSettings> loadSettings() async {
    final j = await _readJson(_settings);
    return j is Map<String, dynamic> ? AppSettings.fromJson(j) : AppSettings();
  }

  Future<void> saveSettings(AppSettings s) => _writeJson(_settings, s.toJson());

  Future<List<AgentProfile>> loadProfiles() async {
    final j = await _readJson(_profiles);
    final custom = j is List
        ? [for (final p in j) AgentProfile.fromJson((p as Map).cast())]
        : <AgentProfile>[];
    // eingebaute Profile immer aktuell halten, eigene Änderungen daran übernehmen
    final byId = {for (final p in custom) p.id: p};
    final result = <AgentProfile>[];
    for (final d in AgentProfile.defaults()) {
      final saved = byId.remove(d.id);
      if (saved != null) {
        d
          ..name = saved.name
          ..systemPrompt = saved.systemPrompt
          ..temperature = saved.temperature
          ..maxSteps = saved.maxSteps
          ..useTools = saved.useTools;
      }
      result.add(d);
    }
    result.addAll(byId.values);
    return result;
  }

  Future<void> saveProfiles(List<AgentProfile> p) =>
      _writeJson(_profiles, p.map((x) => x.toJson()).toList());

  Future<List<StoredModel>> loadModels() async {
    final j = await _readJson(_models);
    if (j is! List) return [];
    final list = [for (final m in j) StoredModel.fromJson((m as Map).cast())];
    // Pfade im App-Container können sich nach Updates ändern (iOS): anhand des Dateinamens neu auflösen
    final fixed = <StoredModel>[];
    for (final m in list) {
      final inModels = File('${modelsDir.path}/${m.fileName}');
      final inDocs = File('${documentsDir.path}/${m.fileName}');
      if (await inModels.exists()) {
        fixed.add(StoredModel.fromJson({...m.toJson(), 'path': inModels.path}));
      } else if (await inDocs.exists()) {
        fixed.add(StoredModel.fromJson({...m.toJson(), 'path': inDocs.path}));
      } else if (await File(m.path).exists()) {
        fixed.add(m);
      }
    }
    return fixed;
  }

  Future<void> saveModels(List<StoredModel> m) =>
      _writeJson(_models, m.map((x) => x.toJson()).toList());

  /// .gguf-Dateien im Dokumente-Ordner (iPadOS: per Finder/Dateien-App abgelegt).
  Future<List<File>> ggufInDocuments() async {
    if (!await documentsDir.exists()) return [];
    return [
      await for (final f in documentsDir.list())
        if (f is File && f.path.toLowerCase().endsWith('.gguf')) f
    ];
  }

  Future<List<Conversation>> loadConversations() async {
    final list = <Conversation>[];
    await for (final f in chatsDir.list()) {
      if (f is File && f.path.endsWith('.json')) {
        final j = await _readJson(f);
        if (j is Map<String, dynamic>) {
          try {
            list.add(Conversation.fromJson(j));
          } catch (_) {}
        }
      }
    }
    list.sort((a, b) => b.updated.compareTo(a.updated));
    return list;
  }

  Future<void> saveConversation(Conversation c) =>
      _writeJson(File('${chatsDir.path}/${c.id}.json'), c.toJson());

  Future<void> deleteConversation(String id) async {
    final f = File('${chatsDir.path}/$id.json');
    if (await f.exists()) await f.delete();
  }

  /// Übernimmt eine gewählte Modelldatei ins App-Verzeichnis.
  /// [move] = true verschiebt (z. B. aus dem Cache des Datei-Wählers),
  /// sonst wird kopiert. [onProgress] liefert 0..1.
  Future<File> importModelFile(String sourcePath, String fileName,
      {required bool move, void Function(double)? onProgress}) async {
    var target = File('${modelsDir.path}/$fileName');
    var i = 1;
    while (await target.exists()) {
      final dot = fileName.lastIndexOf('.');
      final base = dot > 0 ? fileName.substring(0, dot) : fileName;
      target = File('${modelsDir.path}/$base-$i.gguf');
      i++;
    }
    final src = File(sourcePath);
    if (move) {
      try {
        final moved = await src.rename(target.path);
        onProgress?.call(1);
        return moved;
      } on FileSystemException {
        // anderes Dateisystem: unten kopieren
      }
    }
    final total = await src.length();
    final out = target.openWrite();
    var done = 0;
    var lastReport = 0.0;
    try {
      await for (final chunk in src.openRead()) {
        out.add(chunk);
        done += chunk.length;
        final p = total > 0 ? done / total : 1.0;
        if (p - lastReport >= 0.01) {
          lastReport = p;
          onProgress?.call(p);
        }
      }
      await out.flush();
    } catch (_) {
      await out.close();
      if (await target.exists()) await target.delete();
      rethrow;
    }
    await out.close();
    if (move) {
      try {
        await src.delete();
      } catch (_) {}
    }
    onProgress?.call(1);
    return target;
  }
}
