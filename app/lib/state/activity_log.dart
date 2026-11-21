// „Was hat der Agent getan?“ – verständlicher Verlauf von Aktionen mit Freigabe.
// Alles läuft lokal; Kosten gibt es keine.

import 'dart:convert';
import 'dart:io';

class Activity {
  Activity({required this.kind, required this.title, this.detail = '', this.approval = '', this.conversationId, DateTime? time})
      : time = time ?? DateTime.now();

  /// mail | whatsapp | calendar | file | task | browser | memory | internet | call
  final String kind;
  final String title;
  final String detail;

  /// Wer hat es freigegeben, z. B. „Du hast ‚Senden‘ getippt“, „Geplante Aufgabe“.
  final String approval;
  final String? conversationId;
  final DateTime time;

  Map<String, Object?> toJson() => {
        'k': kind,
        't': title,
        if (detail.isNotEmpty) 'd': detail,
        if (approval.isNotEmpty) 'a': approval,
        if (conversationId != null) 'c': conversationId,
        'at': time.toIso8601String(),
      };

  factory Activity.fromJson(Map<String, dynamic> j) => Activity(
        kind: j['k'] as String? ?? 'task',
        title: j['t'] as String? ?? '',
        detail: j['d'] as String? ?? '',
        approval: j['a'] as String? ?? '',
        conversationId: j['c'] as String?,
        time: DateTime.tryParse(j['at'] as String? ?? ''),
      );
}

class ActivityLog {
  ActivityLog(this.file);
  final File file;
  final List<Activity> items = [];
  static const maxItems = 500;

  Future<void> load() async {
    items.clear();
    try {
      if (await file.exists()) {
        final j = jsonDecode(await file.readAsString()) as List;
        items.addAll([for (final x in j) Activity.fromJson((x as Map).cast())]);
      }
    } catch (_) {}
  }

  Future<void> add(Activity a) async {
    items.add(a);
    while (items.length > maxItems) {
      items.removeAt(0);
    }
    try {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
      await tmp.rename(file.path);
    } catch (_) {}
  }

  Future<void> clear() async {
    items.clear();
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
