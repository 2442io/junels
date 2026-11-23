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
    this.due,
    this.nativeId,
    this.archived = false,
  });

  final String id;
  final NotifyKind kind;
  String title;
  String body;
  DateTime at;
  final String? target; // Chat-Id oder watch:<id>
  final String source;
  bool read;
  bool done; // Aktion/Erinnerung erledigt
  DateTime? due; // Erinnerung: wann sie fällig ist (in der Zukunft = geplant)
  String? nativeId; // Kennung der geplanten System-Meldung (Schlummern, Abbrechen)
  bool archived; // aus der Liste genommen, aber im Archiv auffindbar

  bool get planned => due != null && due!.isAfter(DateTime.now()) && !done;
  bool get waiting => (kind == NotifyKind.aktion || kind == NotifyKind.erinnerung) && !done && !planned;

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
        if (due != null) 'due': due!.toIso8601String(),
        if (nativeId != null) 'native': nativeId,
        if (archived) 'archived': true,
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
        due: DateTime.tryParse('${j['due'] ?? ''}'),
        nativeId: j['native'] as String?,
        archived: j['archived'] == true,
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

  Iterable<InboxItem> get visible => items.where((i) => !i.archived);
  int get unread => visible.where((i) => !i.read && !i.planned && i.kind != NotifyKind.ruhig).length;
  bool get hasWaiting => visible.any((i) => i.waiting);
  bool get hasWarning => visible.any((i) => !i.read && i.kind == NotifyKind.warnung);

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final list = jsonDecode(await _file.readAsString()) as List;
      items
        ..clear()
        ..addAll([for (final j in list) InboxItem.fromJson((j as Map).cast())]);
      // Nichts verschwindet von selbst: nur archivierte Meldungen älter als 180 Tage werden entfernt
      final cut = DateTime.now().subtract(const Duration(days: 180));
      items.removeWhere((i) => i.archived && i.at.isBefore(cut));
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

    // Geplante Erinnerung: genau zur Zeit, unabhängig von Ruhezeit (Schlummern/Erledigt in der Meldung)
    if (at != null) {
      final item = InboxItem(
        id: '${now.microsecondsSinceEpoch}',
        kind: kind,
        title: title,
        body: body,
        at: at,
        target: target,
        source: source,
        due: at,
      )..nativeId = 'rem-${now.microsecondsSinceEpoch}';
      items.insert(0, item);
      _save();
      await BackgroundWork.notify(title, body, conversationId: target, at: at, kind: kind.name, id: item.nativeId);
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
    for (final i in visible) {
      i.read = true;
    }
    _save();
  }

  void markAllUnread() {
    for (final i in visible) {
      if (!i.planned) i.read = false;
    }
    _save();
  }

  void toggleRead(InboxItem i) {
    i.read = !i.read;
    _save();
  }

  /// Aus der Liste nehmen – bleibt im Archiv und lässt sich wiederherstellen.
  void archive(InboxItem i) {
    i
      ..archived = true
      ..read = true;
    _save();
  }

  void restore(InboxItem i) {
    i.archived = false;
    _save();
  }

  /// Gelesenes (außer Offenem) ins Archiv.
  void archiveRead() {
    for (final i in items) {
      if (i.read && !i.waiting && !i.planned) i.archived = true;
    }
    _save();
  }

  void markDone(InboxItem i) {
    i
      ..done = true
      ..read = true;
    if (i.nativeId != null) unawaited(BackgroundWork.cancelNotify(i.nativeId!));
    _save();
  }

  /// Erinnerung verschieben (Schlummern) – neue System-Meldung zur neuen Zeit.
  Future<void> snooze(InboxItem i, Duration d) async {
    final when = DateTime.now().add(d);
    i
      ..nativeId ??= 'rem-${i.id}'
      ..due = when
      ..at = when
      ..read = true;
    _save();
    await BackgroundWork.cancelNotify(i.nativeId!);
    await BackgroundWork.notify(i.title, i.body, conversationId: i.target, at: when, kind: i.kind.name, id: i.nativeId);
  }

  /// In Meldungen getipptes „Schlummern“/„Erledigt“ übernehmen (beim Start und wenn die App wieder vorne ist).
  Future<void> syncNative() async {
    final ev = await BackgroundWork.takeNotifyEvents();
    if (ev.isEmpty) return;
    for (final e in ev) {
      final i = items.where((i) => i.nativeId != null && BackgroundWork.stableId(i.nativeId!) == e.id).firstOrNull;
      if (i == null) continue;
      if (e.action == 'done') {
        i
          ..done = true
          ..read = true;
      } else if (e.action == 'snooze') {
        i
          ..due = e.at
          ..at = e.at;
      }
    }
    _save();
  }

  /// Offene Aktionen eines Ziels erledigt (z. B. Begleitung „Weiter“ getippt).
  void doneFor(String target) {
    var changed = false;
    for (final i in items) {
      if (i.waiting && i.kind == NotifyKind.aktion && i.target == target) {
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

  void clearArchive() {
    items.removeWhere((i) => i.archived);
    _save();
  }
}
