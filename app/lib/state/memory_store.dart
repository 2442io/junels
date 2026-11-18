// Langzeit-Gedächtnis: kurze Notizen über den Nutzer, über alle Chats hinweg.

import 'dart:convert';
import 'dart:io';

class MemoryNote {
  MemoryNote(this.text, [DateTime? created]) : created = created ?? DateTime.now();
  final String text;
  final DateTime created;
  Map<String, Object> toJson() => {'t': text, 'c': created.toIso8601String()};
  factory MemoryNote.fromJson(Map<String, dynamic> j) =>
      MemoryNote(j['t'] as String, DateTime.tryParse(j['c'] as String? ?? ''));
}

class MemoryStore {
  MemoryStore(this.file);
  final File file;
  final List<MemoryNote> notes = [];
  static const maxNotes = 60;

  Future<void> load() async {
    notes.clear();
    try {
      if (await file.exists()) {
        final j = jsonDecode(await file.readAsString()) as List;
        notes.addAll([for (final n in j) MemoryNote.fromJson((n as Map).cast())]);
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(notes.map((n) => n.toJson()).toList()));
    await tmp.rename(file.path);
  }

  Future<void> add(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    // Dubletten vermeiden
    notes.removeWhere((n) => n.text.toLowerCase() == t.toLowerCase());
    notes.add(MemoryNote(t));
    while (notes.length > maxNotes) {
      notes.removeAt(0);
    }
    await _save();
  }

  Future<void> remove(MemoryNote n) async {
    notes.remove(n);
    await _save();
  }

  /// Block für den System-Prompt.
  String promptBlock({int maxChars = 2000}) {
    if (notes.isEmpty) return '';
    final b = StringBuffer('Was du aus früheren Gesprächen über den Nutzer weißt:\n');
    for (final n in notes.reversed) {
      final line = '- ${n.text}\n';
      if (b.length + line.length > maxChars) break;
      b.write(line);
    }
    return b.toString();
  }
}
