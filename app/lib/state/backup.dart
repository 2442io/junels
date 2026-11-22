// Sicherung: alle Chats, Prozesse, Beobachtungen, Einstellungen, Gedächtnis, Wissensbasis,
// eigene Designs (und optional erstellte Dateien) als eine ZIP-Datei – und wiederherstellen.
// Modelle, Stimmen und Schlüssel (Tresor/Schlüsselbund) sind nicht enthalten.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_engine/agent_engine.dart';

import '../version.dart';

class Backup {
  Backup({required this.root, required this.outputs, required this.attachments});
  final Directory root;
  final Directory outputs;
  final Directory attachments;

  /// Nicht sichern: groß und neu ladbar bzw. geheim/gerätegebunden.
  static const _skipDirs = {'models', 'voice', 'vad', 'kvcache', 'cache', 'tmp', 'update', '.vorschau'};
  static const _skipFiles = {'sync_key', 'update_token', 'sync_state.json'};

  static const _maxFile = 50 * 1024 * 1024;
  static const _maxFiles = 400 * 1024 * 1024;

  /// Erstellt die Sicherung; [withFiles] = auch erstellte Dateien und Anhänge.
  Future<(Uint8List, String)> create({bool withFiles = true}) async {
    final zip = ZipWriter();
    var count = 0;
    var size = 0;
    void addDir(Directory dir, String prefix, {bool limit = false}) {
      if (!dir.existsSync()) return;
      for (final e in dir.listSync(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final rel = e.path.substring(dir.path.length + 1).replaceAll('\\', '/');
        final segs = rel.split('/');
        if (segs.any((s) => _skipDirs.contains(s)) || _skipFiles.contains(segs.last) || segs.last.endsWith('.tmp')) continue;
        final len = e.lengthSync();
        if (limit && (len > _maxFile || size + len > _maxFiles)) continue;
        zip.add('$prefix/$rel', e.readAsBytesSync());
        size += len;
        count++;
      }
    }

    addDir(root, 'daten');
    if (withFiles) {
      addDir(outputs, 'ausgaben', limit: true);
      addDir(attachments, 'anhaenge', limit: true);
    }
    zip.addString(
        'junels-sicherung.json',
        jsonEncode({
          'app': 'Junels',
          'version': appVersion,
          'build': appBuild,
          'created': DateTime.now().toIso8601String(),
          'files': count,
          'platform': Platform.operatingSystem,
        }));
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return (zip.build(), 'Junels-Sicherung ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}-${two(now.minute)}.zip');
  }

  /// Prüft eine Sicherung und liefert ihre Kennzahlen (oder null, wenn es keine ist).
  static Map<String, dynamic>? inspect(Uint8List bytes) {
    try {
      final z = readZip(bytes);
      final meta = z['junels-sicherung.json'];
      if (meta == null) return null;
      final j = jsonDecode(utf8.decode(meta)) as Map<String, dynamic>;
      j['chats'] = z.keys.where((k) => k.startsWith('daten/chats/')).length;
      return j;
    } catch (_) {
      return null;
    }
  }

  /// Stellt wieder her: ersetzt die Daten (Modelle bleiben). Vorher wird der aktuelle Stand
  /// als Sicherung in „Ausgaben“ abgelegt. Danach muss die App neu starten.
  Future<String> restore(Uint8List bytes) async {
    final z = readZip(bytes);
    if (!z.containsKey('junels-sicherung.json')) throw Exception('Das ist keine Junels-Sicherung.');
    // Sicherheitskopie des aktuellen Stands
    final (before, name) = await create(withFiles: false);
    final safety = File('${outputs.path}/Vor Wiederherstellung – $name');
    await safety.writeAsBytes(before);
    // Daten ersetzen (außer Modelle usw.)
    if (root.existsSync()) {
      for (final e in root.listSync()) {
        final n = e.path.split(Platform.pathSeparator).last;
        if (_skipDirs.contains(n) || _skipFiles.contains(n)) continue;
        try {
          e.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
    var n = 0;
    for (final entry in z.entries) {
      final k = entry.key;
      if (k.contains('..')) continue;
      final String target;
      if (k.startsWith('daten/')) {
        target = '${root.path}/${k.substring(6)}';
      } else if (k.startsWith('ausgaben/')) {
        target = '${outputs.path}/${k.substring(9)}';
      } else if (k.startsWith('anhaenge/')) {
        target = '${attachments.path}/${k.substring(9)}';
      } else {
        continue;
      }
      final f = File(target);
      if (k.startsWith('ausgaben/') && f.existsSync()) continue; // vorhandene Dateien nicht überschreiben
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(entry.value);
      n++;
    }
    return 'Wiederhergestellt: $n Dateien. Dein bisheriger Stand liegt als „${safety.uri.pathSegments.last}“ in den Ausgaben.';
  }
}
