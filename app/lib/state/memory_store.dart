// Langzeit-Gedächtnis: kurze Notizen über den Nutzer, über alle Chats hinweg.

import 'dart:convert';
import 'dart:io';

class MemoryNote {
  MemoryNote(this.text, [DateTime? created, this.category = 'sonstiges', this.confirmed = true])
      : created = created ?? DateTime.now();
  final String text;
  final DateTime created;

  /// vorliebe | person | routine | sonstiges
  String category;

  /// Vom Nutzer bestätigt (nur bestätigte Einträge nutzt der Agent).
  bool confirmed;

  static const categories = {
    'vorliebe': 'Vorlieben',
    'person': 'Personen',
    'routine': 'Routinen',
    'sonstiges': 'Sonstiges',
  };

  Map<String, Object> toJson() => {
        't': text,
        'c': created.toIso8601String(),
        if (category != 'sonstiges') 'k': category,
        if (!confirmed) 'ok': false,
      };
  factory MemoryNote.fromJson(Map<String, dynamic> j) => MemoryNote(
        j['t'] as String,
        DateTime.tryParse(j['c'] as String? ?? ''),
        categories.containsKey(j['k']) ? j['k'] as String : guessCategory(j['t'] as String),
        j['ok'] as bool? ?? true,
      );

  /// Bereich aus dem Text erraten (für alte Einträge und wenn das Modell keinen angibt).
  static String guessCategory(String t) {
    final l = t.toLowerCase();
    if (RegExp(r'\b(jeden|jede|täglich|morgens|abends|immer um|montags|dienstags|mittwochs|donnerstags|freitags|wöchentlich|routine|gewohnheit)\b').hasMatch(l)) {
      return 'routine';
    }
    if (RegExp(r'\b(mag|mögen|liebt|lieber|bevorzug\w*|gern|gerne|hasst|mag nicht|lieblings\w*|vorliebe)').hasMatch(l)) return 'vorliebe';
    if (RegExp(r'\b(frau|mann|partner\w*|tochter|sohn|kind|kinder|mutter|vater|bruder|schwester|chef\w*|kolleg\w*|freund\w*|heißt|kunde|kundin)\b').hasMatch(l)) {
      return 'person';
    }
    return 'sonstiges';
  }

  /// Sensible Themen (Gesundheit, Finanzen, Religion, Politik, …) – standardmäßig nicht merken.
  static final sensitive = RegExp(
      r'\b(krank\w*|krankheit|diagnose|therapie|medikament\w*|depression|diabetes|krebs|schwanger\w*|gesundheit|arzt|ärztin|'
      r'gehalt|einkommen|schulden|kredit\w*|kontostand|iban|passwort|pin\b|religion|religiös|glaube|partei|wähl\w*|politisch|'
      r'sexuell\w*|orientierung|vorstrafe\w*)',
      caseSensitive: false);
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

  Future<void> add(String text, {String? category, bool confirmed = true}) async {
    final t = text.trim();
    if (t.isEmpty) return;
    // Dubletten vermeiden
    notes.removeWhere((n) => n.text.toLowerCase() == t.toLowerCase());
    notes.add(MemoryNote(t, null,
        MemoryNote.categories.containsKey(category) && category != 'sonstiges' ? category! : MemoryNote.guessCategory(t), confirmed));
    while (notes.length > maxNotes) {
      notes.removeAt(0);
    }
    await _save();
  }

  /// Für den Abgleich: Notiz übernehmen bzw. löschen (ohne Duplikate).
  Future<void> putSynced(MemoryNote n) async {
    notes.removeWhere((x) => x.text.toLowerCase() == n.text.toLowerCase());
    notes.add(n);
    notes.sort((a, b) => a.created.compareTo(b.created));
    await _save();
  }

  Future<void> removeText(String text) async {
    notes.removeWhere((x) => x.text.toLowerCase() == text.toLowerCase());
    await _save();
  }

  Future<void> remove(MemoryNote n) async {
    notes.remove(n);
    await _save();
  }

  Future<void> confirm(MemoryNote n, {String? category}) async {
    n.confirmed = true;
    if (category != null) n.category = category;
    await _save();
  }

  Future<void> setCategory(MemoryNote n, String category) async {
    n.category = category;
    await _save();
  }

  List<MemoryNote> get pending => [for (final n in notes) if (!n.confirmed) n];

  /// Block für den System-Prompt.
  String promptBlock({int maxChars = 2000}) {
    if (!notes.any((n) => n.confirmed)) return '';
    final b = StringBuffer('Was du aus früheren Gesprächen über den Nutzer weißt:\n');
    for (final n in notes.reversed) {
      if (!n.confirmed) continue; // erst nach Bestätigung durch den Nutzer
      final line = '- ${n.text}\n';
      if (b.length + line.length > maxChars) break;
      b.write(line);
    }
    return b.toString();
  }
}
