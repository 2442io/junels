// Benachrichtigungen: sechs Arten (Aktion, Warnung, Erinnerung, Ergebnis, Info, Ruhig) mit Farbe, Symbol und
// Lautstärke, ein Postfach in der App, Ruhezeiten und Bündeln. Konzept: „Junels – Konzept Benachrichtigungen“.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'background_work.dart';

enum NotifyKind { aktion, warnung, erinnerung, ergebnis, info, ruhig }

extension NotifyKindX on NotifyKind {
  String get label => switch (this) {
        NotifyKind.aktion => 'Aktion',
        NotifyKind.warnung => 'Warnung',
        NotifyKind.erinnerung => 'Erinnerung',
        NotifyKind.ergebnis => 'Fertig',
        NotifyKind.info => 'Info',
        NotifyKind.ruhig => 'Hintergrund',
      };

  /// Mehrzahl für Bündel („3 Warnungen“).
  String get plural => switch (this) {
        NotifyKind.aktion => 'Aktionen',
        NotifyKind.warnung => 'Warnungen',
        NotifyKind.erinnerung => 'Erinnerungen',
        NotifyKind.ergebnis => 'Ergebnisse',
        NotifyKind.info => 'Infos',
        NotifyKind.ruhig => 'Hinweise',
      };

  /// Kommt auch in der Ruhezeit durch.
  bool get breaksQuiet => this == NotifyKind.aktion || this == NotifyKind.erinnerung;

  static NotifyKind parse(String? s, {NotifyKind fallback = NotifyKind.info}) {
    final t = (s ?? '').trim().toLowerCase();
    for (final k in NotifyKind.values) {
      if (k.name == t) return k;
    }
    return switch (t) {
      'action' || 'todo' => NotifyKind.aktion,
      'warning' || 'fehler' || 'alarm' => NotifyKind.warnung,
      'reminder' => NotifyKind.erinnerung,
      'result' || 'fertig' || 'done' => NotifyKind.ergebnis,
      _ => fallback,
    };
  }
}

/// Eine Meldung im Postfach.
class InboxItem {
  InboxItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.at,
    this.target,
    this.source = '',
    this.read = false,
    this.done = false,
  });

  final String id;
  final NotifyKind kind;
  String title;
  String body;
  DateTime at;
  final String? target; // Chat-Id oder watch:<id>
  final String source;
  bool read;
  bool done; // Aktion erledigt

  bool get waiting => kind == NotifyKind.aktion && !done;

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'body': body,
        'at': at.toIso8601String(),
        if (target != null) 'target': target,
        if (source.isNotEmpty) 'source': source,
        if (read) 'read': true,
        if (done) 'done': true,
      };

  factory InboxItem.fromJson(Map<String, dynamic> j) => InboxItem(
        id: '${j['id']}',
        kind: NotifyKindX.parse(j['kind'] as String?),
        title: '${j['title'] ?? ''}',
        body: '${j['body'] ?? ''}',
        at: DateTime.tryParse('${j['at']}') ?? DateTime.now(),
        target: j['target'] as String?,
        source: '${j['source'] ?? ''}',
        read: j['read'] == true,
        done: j['done'] == true,
      );
}

/// Einstellungen (liegen in den App-Einstellungen als Map).
class NotifySettings {
  NotifySettings({Set<NotifyKind>? off, this.quiet = false, this.quietFrom = 22, this.quietTo = 7, this.infoDigest = false})
      : off = off ?? {};
  final Set<NotifyKind> off; // Arten ohne Push (landen nur im Postfach)
  bool quiet;
  int quietFrom, quietTo; // Stunden
  bool infoDigest; // Infos einmal täglich gesammelt statt einzeln

  Map<String, Object?> toJson() => {
        'off': [for (final k in off) k.name],
        'quiet': quiet,
        'from': quietFrom,
        'to': quietTo,
        if (infoDigest) 'infoDigest': true,
      };

  factory NotifySettings.fromJson(Map<String, dynamic>? j) => j == null
      ? NotifySettings()
      : NotifySettings(
          off: {for (final s in (j['off'] as List? ?? const [])) NotifyKindX.parse('$s')},
          quiet: j['quiet'] == true,
          quietFrom: (j['from'] as num?)?.toInt() ?? 22,
          quietTo: (j['to'] as num?)?.toInt() ?? 7,
          infoDigest: j['infoDigest'] == true,
        );

  bool inQuiet(DateTime t) {
    if (!quiet || quietFrom == quietTo) return false;
    final h = t.hour;
    return quietFrom < quietTo ? (h >= quietFrom && h < quietTo) : (h >= quietFrom || h < quietTo);
  }

  /// Ende der aktuellen Ruhezeit.
  DateTime quietEnd(DateTime t) {
    var end = DateTime(t.year, t.month, t.day, quietTo);
    if (!end.isAfter(t)) end = end.add(const Duration(days: 1));
    return end;
  }
}

/// Postfach + Zustellung (Ruhezeit, Bündeln, Abschalten je Art).
class Notifier extends ChangeNotifier {
  Notifier(this._file, this.settings);

  final File _file;
  NotifySettings Function() settings;
  final List<InboxItem> items = [];
  final Map<String, (int, DateTime)> _bundle = {}; // Quelle → (Anzahl, seit)
  final Map<NotifyKind, List<String>> _deferred = {}; // Ruhezeit: gesammelte Titel je Art

  int get unread => items.where((i) => !i.read && i.kind != NotifyKind.ruhig).length;
  bool get hasWaiting => items.any((i) => i.waiting);
  bool get hasWarning => items.any((i) => !i.read && i.kind == NotifyKind.warnung);

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final list = jsonDecode(await _file.readAsString()) as List;
      items
        ..clear()
        ..addAll([for (final j in list) InboxItem.fromJson((j as Map).cast())]);
      final cut = DateTime.now().subtract(const Duration(days: 30));
      items.removeWhere((i) => i.at.isBefore(cut) && !i.waiting);
      notifyListeners();
    } catch (_) {}
  }

  Timer? _saveTimer;
  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () async {
      try {
        final tmp = File('${_file.path}.tmp');
        await tmp.writeAsString(jsonEncode([for (final i in items.take(300)) i.toJson()]), flush: true);
        await tmp.rename(_file.path);
      } catch (_) {}
    });
    notifyListeners();
  }

  /// Meldung ins Postfach legen und – je nach Art und Einstellungen – als Push zustellen.
  Future<void> send(NotifyKind kind, String title, String body,
      {String? target, String source = '', DateTime? at, bool inboxOnly = false}) async {
    title = title.trim().isEmpty ? 'Junels' : title.trim();
    body = body.trim();
    final now = DateTime.now();
    if (kind != NotifyKind.ruhig && at == null) {
      // Gleiche Quelle kurz hintereinander (Infos/Ergebnisse): eine Postfach-Zeile aktualisieren
      final same = source.isEmpty
          ? null
          : items.where((i) => i.source == source && !i.read && now.difference(i.at).inMinutes < 30 && i.kind == kind).firstOrNull;
      if (same != null && (kind == NotifyKind.info || kind == NotifyKind.ergebnis)) {
        same
          ..title = title
          ..body = body
          ..at = now;
      } else {
        items.insert(
            0,
            InboxItem(
              id: '${now.microsecondsSinceEpoch}',
              kind: kind,
              title: title,
              body: body,
              at: now,
              target: target,
              source: source,
            ));
      }
      _save();
    }
    if (inboxOnly || kind == NotifyKind.ruhig) return;
    final s = settings();
    if (s.off.contains(kind)) return;

    // Geplante Erinnerung: genau zur Zeit, unabhängig von Ruhezeit
    if (at != null) {
      await BackgroundWork.notify(title, body, conversationId: target, at: at, kind: kind.name);
      return;
    }
    // Infos gesammelt (einmal täglich 18 Uhr)
    if (kind == NotifyKind.info && s.infoDigest) {
      final list = _deferred[NotifyKind.info] ??= [];
      list.add(title);
      var when = DateTime(now.year, now.month, now.day, 18);
      if (!when.isAfter(now)) when = when.add(const Duration(days: 1));
      await BackgroundWork.notify('${list.length} ${list.length == 1 ? 'Info' : 'Infos'} von heute', list.reversed.take(6).join(' · '),
          at: when, kind: kind.name, id: 'digest-info');
      return;
    }
    // Ruhezeit: sammeln und am Ende zustellen
    if (s.inQuiet(now) && !kind.breaksQuiet) {
      final list = _deferred[kind] ??= [];
      list.add(title);
      await BackgroundWork.notify(list.length == 1 ? title : '${list.length} ${kind.plural}',
          list.length == 1 ? body : list.reversed.take(6).join(' · '),
          conversationId: list.length == 1 ? target : null, at: s.quietEnd(now), kind: kind.name, id: 'quiet-${kind.name}');
      return;
    }
    _deferred.remove(kind);
    // Bündeln: mehr als 3 Meldungen derselben Quelle in 30 Min → eine Meldung, die sich aktualisiert
    var id = '${target ?? title}';
    var t = title, b = body;
    if (source.isNotEmpty) {
      final prev = _bundle[source];
      final fresh = prev == null || now.difference(prev.$2).inMinutes >= 30;
      final count = fresh ? 1 : prev.$1 + 1;
      _bundle[source] = (count, fresh ? now : prev.$2);
      if (kind == NotifyKind.info || count > 3) {
        id = 'src-$source';
        if (count > 1) t = '$title (+${count - 1} weitere)';
      }
    }
    await BackgroundWork.notify(t, b, conversationId: target, kind: kind.name, id: id);
  }

  void markRead(InboxItem i) {
    i.read = true;
    _save();
  }

  void markAllRead() {
    for (final i in items) {
      i.read = true;
    }
    _save();
  }

  void markDone(InboxItem i) {
    i
      ..done = true
      ..read = true;
    _save();
  }

  /// Offene Aktionen eines Ziels erledigt (z. B. Begleitung „Weiter“ getippt).
  void doneFor(String target) {
    var changed = false;
    for (final i in items) {
      if (i.waiting && i.target == target) {
        i
          ..done = true
          ..read = true;
        changed = true;
      }
    }
    if (changed) _save();
  }

  void remove(InboxItem i) {
    items.remove(i);
    _save();
  }

  void clearRead() {
    items.removeWhere((i) => i.read && !i.waiting);
    _save();
  }
}
