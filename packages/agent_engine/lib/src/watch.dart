// Watchlist: Webseiten oder Themen regelmäßig prüfen und Neues erkennen.
// Reine Logik (ohne Flutter), damit sie testbar ist; Speichern, Zeitplan und
// Benachrichtigung übernimmt die App.

import 'dart:convert';

import 'agent/network_tools.dart';
import 'sync/sync_crypto.dart' show sha256, hexOf;

enum WatchKind { page, topic }

/// Ein gefundener neuer Stand.
class WatchEvent {
  WatchEvent({required this.time, required this.title, this.detail = '', List<Map<String, String>>? links, this.seen = false})
      : links = links ?? [];
  final DateTime time;
  final String title;
  String detail;
  final List<Map<String, String>> links;
  bool seen;

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'title': title,
        if (detail.isNotEmpty) 'detail': detail,
        if (links.isNotEmpty) 'links': links,
        if (seen) 'seen': true,
      };

  factory WatchEvent.fromJson(Map<String, dynamic> j) => WatchEvent(
        time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime.now(),
        title: j['title'] as String? ?? '',
        detail: j['detail'] as String? ?? '',
        links: [for (final l in (j['links'] as List? ?? const [])) (l as Map).cast<String, String>()],
        seen: j['seen'] as bool? ?? false,
      );
}

class WatchItem {
  WatchItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.target,
    this.intervalMinutes = 360,
    this.summarize = true,
    this.notify = true,
    this.enabled = true,
    this.lastCheck,
    this.fingerprint,
    this.snapshot = '',
    List<String>? seenLinks,
    List<WatchEvent>? events,
    this.lastError,
  })  : seenLinks = seenLinks ?? [],
        events = events ?? [];

  final String id;
  WatchKind kind;
  String title;

  /// Adresse (Seite) bzw. Suchbegriffe (Thema).
  String target;
  int intervalMinutes;
  bool summarize;
  bool notify;
  bool enabled;
  DateTime? lastCheck;
  String? fingerprint;

  /// Letzter Textstand der Seite (für den Vergleich, gekürzt).
  String snapshot;
  final List<String> seenLinks;
  final List<WatchEvent> events;
  String? lastError;

  int get unseen => events.where((e) => !e.seen).length;

  bool due(DateTime now) =>
      enabled && (lastCheck == null || now.difference(lastCheck!).inMinutes >= intervalMinutes);

  String get intervalLabel => switch (intervalMinutes) {
        <= 60 => 'stündlich',
        <= 180 => 'alle 3 Stunden',
        <= 360 => 'alle 6 Stunden',
        <= 720 => 'alle 12 Stunden',
        <= 1440 => 'täglich',
        _ => 'wöchentlich',
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'target': target,
        'interval': intervalMinutes,
        'summarize': summarize,
        'notify': notify,
        'enabled': enabled,
        if (lastCheck != null) 'lastCheck': lastCheck!.toIso8601String(),
        if (fingerprint != null) 'fp': fingerprint,
        if (snapshot.isNotEmpty) 'snapshot': snapshot,
        if (seenLinks.isNotEmpty) 'seen': seenLinks.length > 400 ? seenLinks.sublist(seenLinks.length - 400) : seenLinks,
        'events': [for (final e in events.take(40)) e.toJson()],
        if (lastError != null) 'error': lastError,
      };

  factory WatchItem.fromJson(Map<String, dynamic> j) => WatchItem(
        id: j['id'] as String,
        kind: j['kind'] == 'topic' ? WatchKind.topic : WatchKind.page,
        title: j['title'] as String? ?? '',
        target: j['target'] as String? ?? '',
        intervalMinutes: (j['interval'] as num?)?.toInt() ?? 360,
        summarize: j['summarize'] as bool? ?? true,
        notify: j['notify'] as bool? ?? true,
        enabled: j['enabled'] as bool? ?? true,
        lastCheck: DateTime.tryParse(j['lastCheck'] as String? ?? ''),
        fingerprint: j['fp'] as String?,
        snapshot: j['snapshot'] as String? ?? '',
        seenLinks: (j['seen'] as List? ?? const []).cast<String>(),
        events: [for (final e in (j['events'] as List? ?? const [])) WatchEvent.fromJson((e as Map).cast())],
        lastError: j['error'] as String?,
      );
}

/// Ergebnis einer Prüfung.
class WatchCheck {
  WatchCheck({this.event, this.first = false, this.error});

  /// Neuer Stand (null = nichts Neues).
  final WatchEvent? event;

  /// Erste Prüfung: Ausgangsstand gespeichert, keine Meldung.
  final bool first;
  final String? error;
}

/// Prüft Einträge; [fetcher] ist austauschbar (Tests).
class WatchChecker {
  WatchChecker({this.fetcher = httpGetText});
  final Future<String> Function(Uri uri) fetcher;

  static String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Zeilen, die sich ständig ändern (Uhrzeiten, Zähler), stören den Vergleich nicht.
  static String _stable(String line) => line
      .replaceAll(RegExp(r'\b\d{1,2}:\d{2}(:\d{2})?\b'), '')
      .replaceAll(RegExp(r'\b(vor|before|ago)\s+\d+\s+\w+', caseSensitive: false), '')
      .trim();

  Future<WatchCheck> check(WatchItem item, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    try {
      final r = item.kind == WatchKind.page ? await _page(item, t) : await _topic(item, t);
      item
        ..lastCheck = t
        ..lastError = null;
      if (r.event != null) item.events.insert(0, r.event!);
      if (item.events.length > 40) item.events.removeRange(40, item.events.length);
      return r;
    } catch (e) {
      item
        ..lastCheck = t
        ..lastError = '$e';
      return WatchCheck(error: '$e');
    }
  }

  Future<WatchCheck> _page(WatchItem item, DateTime now) async {
    var url = item.target.trim();
    if (!url.startsWith('http')) url = 'https://$url';
    final html = await fetcher(Uri.parse(url));
    final blocked = detectBlockPage(html);
    if (blocked != null) throw Exception(blocked);
    final text = htmlToText(html);
    final lines = [
      for (final l in const LineSplitter().convert(text))
        if (_stable(_norm(l)).length >= 3) _norm(l)
    ];
    final fp = hexOf(sha256(utf8.encode(lines.map(_stable).join('\n'))));
    final items = extractPageItems(html, Uri.parse(url));
    final links = [for (final i in items) if (i.link.isNotEmpty) i.link];
    if (item.fingerprint == null) {
      item
        ..fingerprint = fp
        ..snapshot = _cap(lines.join('\n'))
        ..seenLinks.addAll(links.where((l) => !item.seenLinks.contains(l)));
      return WatchCheck(first: true);
    }
    if (fp == item.fingerprint) return WatchCheck();
    final old = item.snapshot.split('\n').map(_stable).toSet();
    final added = [for (final l in lines) if (!old.contains(_stable(l)) && l.length > 12) l];
    final oldNew = lines.map(_stable).toSet();
    final removed = [for (final l in item.snapshot.split('\n')) if (!oldNew.contains(_stable(l)) && l.length > 12) l];
    final newLinks = [
      for (final i in items)
        if (i.link.isNotEmpty && !item.seenLinks.contains(i.link)) {'title': i.title, 'link': i.link, if (i.image.isNotEmpty) 'image': i.image}
    ];
    item
      ..fingerprint = fp
      ..snapshot = _cap(lines.join('\n'));
    for (final l in newLinks) {
      item.seenLinks.add(l['link']!);
    }
    if (added.isEmpty && removed.isEmpty && newLinks.isEmpty) return WatchCheck();
    final detail = [
      if (added.isNotEmpty) 'Neu:\n${added.take(8).map((l) => '+ ${_short(l)}').join('\n')}',
      if (removed.isNotEmpty) 'Entfernt:\n${removed.take(4).map((l) => '− ${_short(l)}').join('\n')}',
    ].join('\n\n');
    final title = newLinks.isNotEmpty
        ? '${newLinks.length} neue${newLinks.length == 1 ? 'r Eintrag' : ' Einträge'} auf ${item.title}'
        : 'Änderung auf ${item.title}';
    return WatchCheck(event: WatchEvent(time: now, title: title, detail: detail, links: newLinks.take(12).toList()));
  }

  Future<WatchCheck> _topic(WatchItem item, DateTime now) async {
    final q = item.target.trim();
    final found = <Map<String, String>>[];
    final errors = <String>[];
    // Nachrichten (Google-News-Feed) …
    try {
      final rss = Uri.https('news.google.com', '/rss/search', {'q': q, 'hl': 'de', 'gl': 'AT', 'ceid': 'AT:de'});
      final xml = await fetcher(rss);
      for (final i in extractFeedItems(xml, rss).take(20)) {
        if (i.link.isNotEmpty) found.add({'title': i.title, 'link': i.link, if (i.image.isNotEmpty) 'image': i.image});
      }
    } catch (e) {
      errors.add('News: $e');
    }
    // … und Websuche
    try {
      final (hits, _, errs) = await WebSearchTool.searchAllEngines(q, fetcher);
      for (final h in hits.take(10)) {
        found.add({'title': h.title, 'link': h.url, if (h.snippet.isNotEmpty) 'note': h.snippet});
      }
      if (hits.isEmpty) errors.addAll(errs);
    } catch (e) {
      errors.add('Suche: $e');
    }
    if (found.isEmpty) throw Exception(errors.isEmpty ? 'keine Treffer' : errors.join('; '));
    String key(String link) => cleanLink(link).replaceFirst(RegExp(r'^https?://(www\.)?'), '');
    final seen = item.seenLinks.toSet();
    final fresh = <Map<String, String>>[];
    final keys = <String>{};
    for (final f in found) {
      final k = key(f['link']!);
      if (seen.contains(k) || !keys.add(k)) continue;
      fresh.add(f);
    }
    item.seenLinks.addAll(keys);
    if (item.fingerprint == null) {
      item.fingerprint = 'topic';
      return WatchCheck(first: true);
    }
    if (fresh.isEmpty) return WatchCheck();
    return WatchCheck(
        event: WatchEvent(
      time: now,
      title: '${fresh.length} neue${fresh.length == 1 ? 'r Treffer' : ' Treffer'} zu „${item.title}“',
      detail: fresh.take(5).map((f) => '• ${f['title']}').join('\n'),
      links: fresh.take(12).toList(),
    ));
  }

  static String _cap(String s) => s.length > 40000 ? s.substring(0, 40000) : s;
  static String _short(String s) => s.length > 160 ? '${s.substring(0, 160)}…' : s;
}
