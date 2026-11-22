// Watchlist: Webseiten oder Themen regelmäßig prüfen und Neues erkennen.
// Reine Logik (ohne Flutter), damit sie testbar ist; Speichern, Zeitplan und
// Benachrichtigung übernimmt die App.

import 'dart:convert';
import 'dart:math' as math;

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
    this.promptMode = false,
    this.query = '',
    this.recentOnly = false,
    this.flowId,
  })  : seenLinks = seenLinks ?? [],
        events = events ?? [];

  final String id;
  WatchKind kind;
  String title;

  /// Adresse (Seite) bzw. Suchanfrage oder Beschreibung (Thema).
  String target;
  int intervalMinutes;
  bool summarize;
  bool notify;
  bool enabled;
  DateTime? lastCheck;
  String? fingerprint;

  /// Thema als Beschreibung („Prompt“): [target] beschreibt in eigenen Worten, was gesucht ist;
  /// [query] ist die daraus abgeleitete Suchanfrage, der Agent prüft die Treffer auf Relevanz.
  bool promptMode;

  /// Tatsächlich verwendete Suchanfrage (leer = [target]).
  String query;

  /// Nur aktuelle Meldungen (Nachrichten der letzten 24 Stunden).
  bool recentOnly;

  /// Gehört zu einem Prozess (Auslöser „Beobachten“ im Canvas).
  String? flowId;

  /// Letzter Textstand der Seite (für den Vergleich, gekürzt).
  String snapshot;
  final List<String> seenLinks;
  final List<WatchEvent> events;
  String? lastError;

  int get unseen => events.where((e) => !e.seen).length;

  /// Suchanfrage für Nachrichten und Websuche.
  String get searchQuery => (promptMode && query.trim().isNotEmpty ? query : target).trim();

  /// Fällig? (15 s Spielraum, weil der Zeitplan alle 30 s nachsieht)
  bool due(DateTime now) =>
      enabled && (lastCheck == null || now.difference(lastCheck!).inSeconds >= intervalMinutes * 60 - 15);

  /// Auswahl für die Oberfläche (Minuten → Beschriftung).
  static const intervalOptions = <(int, String)>[
    (1, 'jede Minute'),
    (5, 'alle 5 Minuten'),
    (10, 'alle 10 Minuten'),
    (15, 'alle 15 Minuten'),
    (30, 'alle 30 Minuten'),
    (60, 'stündlich'),
    (180, 'alle 3 Stunden'),
    (360, 'alle 6 Stunden'),
    (720, 'alle 12 Stunden'),
    (1440, 'täglich'),
    (10080, 'wöchentlich'),
  ];

  static String labelFor(int minutes) {
    for (final (m, l) in intervalOptions) {
      if (m == minutes) return l;
    }
    if (minutes < 60) return minutes == 1 ? 'jede Minute' : 'alle $minutes Minuten';
    if (minutes % 1440 == 0) return minutes == 1440 ? 'täglich' : 'alle ${minutes ~/ 1440} Tage';
    if (minutes % 60 == 0) return minutes == 60 ? 'stündlich' : 'alle ${minutes ~/ 60} Stunden';
    return 'alle $minutes Minuten';
  }

  String get intervalLabel => labelFor(intervalMinutes);

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'target': target,
        'interval': intervalMinutes,
        'summarize': summarize,
        'notify': notify,
        'enabled': enabled,
        if (promptMode) 'prompt': true,
        if (query.isNotEmpty) 'query': query,
        if (recentOnly) 'recent': true,
        if (flowId != null) 'flow': flowId,
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
        intervalMinutes: math.max(1, (j['interval'] as num?)?.toInt() ?? 360),
        summarize: j['summarize'] as bool? ?? true,
        notify: j['notify'] as bool? ?? true,
        enabled: j['enabled'] as bool? ?? true,
        promptMode: j['prompt'] as bool? ?? false,
        query: j['query'] as String? ?? '',
        recentOnly: j['recent'] as bool? ?? false,
        flowId: j['flow'] as String?,
        lastCheck: DateTime.tryParse(j['lastCheck'] as String? ?? ''),
        fingerprint: j['fp'] as String?,
        snapshot: j['snapshot'] as String? ?? '',
        seenLinks: (j['seen'] as List? ?? const []).cast<String>(),
        events: [for (final e in (j['events'] as List? ?? const [])) WatchEvent.fromJson((e as Map).cast())],
        lastError: j['error'] as String?,
      );
}

/// Suchanfrage wie bei Google: "genaue Phrase", -ausschließen, site:domain.at, OR.
/// Die Anfrage geht unverändert an die Suchmaschinen; Ausschlüsse und site: werden
/// zusätzlich lokal geprüft (nicht jede Suchmaschine hält sich daran).
class SearchQuery {
  SearchQuery._(this.raw, this.phrases, this.excludes, this.sites, this.words);
  final String raw;
  final List<String> phrases;
  final List<String> excludes;
  final List<String> sites;
  final List<String> words;

  factory SearchQuery.parse(String q) {
    final phrases = <String>[], excludes = <String>[], sites = <String>[], words = <String>[];
    for (final m in RegExp(r'(-?)"([^"]+)"|(\S+)').allMatches(q)) {
      if (m.group(2) != null) {
        (m.group(1) == '-' ? excludes : phrases).add(m.group(2)!.toLowerCase().trim());
        continue;
      }
      final w = m.group(3)!;
      final lw = w.toLowerCase();
      if (lw.startsWith('site:') && lw.length > 5) {
        sites.add(lw.substring(5).replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'^www\.'), '').replaceAll(RegExp(r'/.*'), ''));
      } else if (w.startsWith('-') && w.length > 1) {
        excludes.add(lw.substring(1));
      } else if (w != 'OR' && w != '|' && !lw.startsWith('when:')) {
        words.add(lw.replaceFirst(RegExp(r'^\+'), ''));
      }
    }
    return SearchQuery._(q.trim(), phrases, excludes, sites, words);
  }

  bool get hasFilters => excludes.isNotEmpty || sites.isNotEmpty;

  /// Treffer behalten? (Ausschlüsse und site: streng, der Rest bleibt den Suchmaschinen überlassen)
  bool accepts(String title, String note, String link) {
    final text = '$title $note'.toLowerCase();
    for (final e in excludes) {
      if (text.contains(e)) return false;
    }
    if (sites.isNotEmpty) {
      final host = (Uri.tryParse(link)?.host ?? '').toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
      // Google-News-Links zeigen auf news.google.com – dort entscheidet der Feed selbst
      if (host != 'news.google.com' && !sites.any((s) => host == s || host.endsWith('.$s'))) return false;
    }
    return true;
  }

  /// Kurzbeschreibung („enthält …, ohne …, nur auf …“) für die Oberfläche.
  String describe() => [
        if (words.isNotEmpty) words.join(' '),
        for (final p in phrases) '„$p“',
        if (excludes.isNotEmpty) 'ohne ${excludes.join(', ')}',
        if (sites.isNotEmpty) 'nur ${sites.join(', ')}',
      ].join(' · ');
}

/// Ein Treffer der Vorschau („Testen“ im Dialog).
class WatchPreview {
  WatchPreview({required this.ok, required this.message, List<Map<String, String>>? hits}) : hits = hits ?? [];
  final bool ok;
  final String message;
  final List<Map<String, String>> hits;
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

  /// Treffer zu einer Suchanfrage (Nachrichten-Feed + Websuche), gefiltert nach Ausschlüssen/site:.
  Future<List<Map<String, String>>> topicHits(String q, {bool recentOnly = false}) async {
    final sq = SearchQuery.parse(q);
    final found = <Map<String, String>>[];
    final errors = <String>[];
    // Nachrichten (Google-News-Feed) – versteht dieselben Operatoren wie die Google-Suche
    try {
      final rss = Uri.https('news.google.com', '/rss/search',
          {'q': recentOnly && !q.contains('when:') ? '$q when:1d' : q, 'hl': 'de', 'gl': 'AT', 'ceid': 'AT:de'});
      final xml = await fetcher(rss);
      for (final i in extractFeedItems(xml, rss).take(25)) {
        if (i.link.isEmpty || !sq.accepts(i.title, i.summary, i.link)) continue;
        found.add({'title': i.title, 'link': i.link, if (i.image.isNotEmpty) 'image': i.image, if (i.date.isNotEmpty) 'date': i.date});
      }
    } catch (e) {
      errors.add('News: $e');
    }
    // … und Websuche (bei „nur Aktuelles“ nur, wenn die Nachrichten nichts liefern)
    if (!recentOnly || found.isEmpty) {
      try {
        final (hits, _, errs) = await WebSearchTool.searchAllEngines(q, fetcher);
        for (final h in hits.take(12)) {
          if (!sq.accepts(h.title, h.snippet, h.url)) continue;
          found.add({'title': h.title, 'link': h.url, if (h.snippet.isNotEmpty) 'note': h.snippet});
        }
        if (hits.isEmpty) errors.addAll(errs);
      } catch (e) {
        errors.add('Suche: $e');
      }
    }
    if (found.isEmpty && errors.isNotEmpty) throw Exception(errors.join('; '));
    return found;
  }

  /// Vorschau ohne den Eintrag zu verändern – zum Ausprobieren vor dem Speichern.
  Future<WatchPreview> preview(WatchItem item) async {
    try {
      if (item.kind == WatchKind.page) {
        var url = item.target.trim();
        if (!url.startsWith('http')) url = 'https://$url';
        final uri = Uri.parse(url);
        final html = await fetcher(uri);
        final blocked = detectBlockPage(html);
        if (blocked != null) return WatchPreview(ok: false, message: blocked);
        final text = htmlToText(html);
        final items = extractPageItems(html, uri);
        final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
        return WatchPreview(
          ok: words > 0,
          message: words == 0
              ? 'Die Seite ist erreichbar, enthält aber keinen lesbaren Text (vermutlich per JavaScript gebaut).'
              : 'Seite erreichbar: $words Wörter, ${items.length} Einträge/Links erkannt. Junels meldet neue Einträge und Textänderungen.',
          hits: [
            for (final i in items.take(8))
              {'title': i.title, 'link': i.link, if (i.image.isNotEmpty) 'image': i.image}
          ],
        );
      }
      final q = item.searchQuery;
      if (q.isEmpty) return WatchPreview(ok: false, message: 'Bitte Suchbegriffe eingeben.');
      final hits = await topicHits(q, recentOnly: item.recentOnly);
      final sq = SearchQuery.parse(q);
      return WatchPreview(
        ok: hits.isNotEmpty,
        message: hits.isEmpty
            ? 'Im Moment keine Treffer – Junels meldet sich, sobald etwas erscheint.'
            : '${hits.length} aktuelle Treffer${sq.describe().isEmpty ? '' : ' (${sq.describe()})'}. Gemeldet werden nur neue.',
        hits: hits.take(8).toList(),
      );
    } catch (e) {
      return WatchPreview(ok: false, message: 'Nicht erreichbar: $e');
    }
  }

  Future<WatchCheck> _topic(WatchItem item, DateTime now) async {
    final found = await topicHits(item.searchQuery, recentOnly: item.recentOnly);
    if (found.isEmpty && item.fingerprint == null) {
      item.fingerprint = 'topic';
      return WatchCheck(first: true);
    }
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
