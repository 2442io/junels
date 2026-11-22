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
  WatchEvent(
      {required this.time, required this.title, this.detail = '', List<Map<String, String>>? links, this.seen = false, this.kind = ''})
      : links = links ?? [];

  /// '' = neue Treffer/Änderung, 'alert' = Schwellenwert, 'digest' = Wochenrückblick, 'quiet' = nur gesammelt.
  final String kind;
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
        if (kind.isNotEmpty) 'kind': kind,
      };

  factory WatchEvent.fromJson(Map<String, dynamic> j) => WatchEvent(
        time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime.now(),
        title: j['title'] as String? ?? '',
        detail: j['detail'] as String? ?? '',
        links: [for (final l in (j['links'] as List? ?? const [])) (l as Map).cast<String, String>()],
        seen: j['seen'] as bool? ?? false,
        kind: j['kind'] as String? ?? '',
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
    this.alertOp = '',
    this.alertValue,
    this.valueLabel = '',
    this.symbol = '',
    this.lastValue,
    this.alertArmed = true,
    this.digest = '',
    this.lastDigest,
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

  /// Schwellenwert: 'below' | 'above' ('' = bei jedem neuen Treffer melden).
  String alertOp;
  double? alertValue;

  /// Seite: Beschriftung, neben der die Zahl steht (z. B. „Preis“); leer = erste Zahl.
  String valueLabel;

  /// Thema: Börsenkürzel (wird beim ersten Abruf ermittelt, z. B. NVDA).
  String symbol;
  double? lastValue;
  String currency = '';

  /// Nach einer Meldung erst wieder melden, wenn der Wert zurück über/unter die Schwelle ging.
  bool alertArmed;

  /// '' = Einzelmeldungen, 'weekly' = zusätzlich Wochenrückblick, 'weeklyOnly' = nur Wochenrückblick.
  String digest;
  DateTime? lastDigest;

  bool get hasAlert => alertOp.isNotEmpty && alertValue != null;
  bool get digestOnly => digest == 'weeklyOnly';

  /// Kurzbeschreibung des Schwellenwerts („unter 120“).
  String get alertLabel => !hasAlert ? '' : '${alertOp == 'below' ? 'unter' : 'über'} ${formatNumber(alertValue!)}';

  /// Wochenrückblick fällig? Sonntags ab 18 Uhr, höchstens einmal in 6 Tagen.
  bool digestDue(DateTime now) {
    if (digest.isEmpty) return false;
    if (lastDigest == null) {
      lastDigest = now; // ab jetzt sammeln
      return false;
    }
    return now.weekday == DateTime.sunday && now.hour >= 18 && now.difference(lastDigest!).inHours >= 6 * 24;
  }

  /// Meldungen seit dem letzten Rückblick (ohne Rückblicke).
  List<WatchEvent> digestEvents() => [
        for (final e in events)
          if (e.kind != 'digest' && (lastDigest == null || e.time.isAfter(lastDigest!))) e
      ];

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
        if (hasAlert) 'alert': {'op': alertOp, 'value': alertValue, 'armed': alertArmed},
        if (valueLabel.isNotEmpty) 'valueLabel': valueLabel,
        if (symbol.isNotEmpty) 'symbol': symbol,
        if (lastValue != null) 'lastValue': lastValue,
        if (currency.isNotEmpty) 'currency': currency,
        if (digest.isNotEmpty) 'digest': digest,
        if (lastDigest != null) 'lastDigest': lastDigest!.toIso8601String(),
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
        alertOp: ((j['alert'] as Map?)?['op'] as String?) ?? '',
        alertValue: ((j['alert'] as Map?)?['value'] as num?)?.toDouble(),
        alertArmed: ((j['alert'] as Map?)?['armed'] as bool?) ?? true,
        valueLabel: j['valueLabel'] as String? ?? '',
        symbol: j['symbol'] as String? ?? '',
        lastValue: (j['lastValue'] as num?)?.toDouble(),
        digest: j['digest'] as String? ?? '',
        lastDigest: DateTime.tryParse(j['lastDigest'] as String? ?? ''),
      )..currency = j['currency'] as String? ?? '';
}

/// Zahl lesbar (deutsch): 1234.5 → „1.234,50“.
String formatNumber(double v) {
  final neg = v < 0;
  final a = v.abs();
  final dec = a >= 1000 || a == a.roundToDouble() ? 0 : (a >= 1 ? 2 : 4);
  final parts = a.toStringAsFixed(dec).split('.');
  final int0 = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
  return '${neg ? '−' : ''}$int0${parts.length > 1 ? ',${parts[1]}' : ''}';
}

/// Zahl aus Text („1.234,56“, „1,234.56“, „118.4“, „120“).
double? parseNumber(String s) {
  var t = s.trim().replaceAll(RegExp(r'[\s\u00a0\u202f]'), '');
  t = t.replaceAll(RegExp(r'[^\d.,\-−]'), '').replaceAll('−', '-');
  if (t.isEmpty) return null;
  final lastDot = t.lastIndexOf('.'), lastComma = t.lastIndexOf(',');
  if (lastDot >= 0 && lastComma >= 0) {
    // beides: das hintere ist das Dezimalzeichen
    t = lastComma > lastDot ? t.replaceAll('.', '').replaceAll(',', '.') : t.replaceAll(',', '');
  } else if (lastComma >= 0) {
    // nur Komma: 3 Ziffern danach und mehrfach → Tausender, sonst Dezimal
    final after = t.length - lastComma - 1;
    t = (after == 3 && ','.allMatches(t).length > 1) ? t.replaceAll(',', '') : t.replaceAll(',', '.');
  } else if (lastDot >= 0 && ('.'.allMatches(t).length > 1 || (t.length - lastDot - 1 == 3 && !RegExp(r'^-?0\.').hasMatch(t)))) {
    t = t.replaceAll('.', ''); // „100.000“ = hunderttausend
  }
  return double.tryParse(t);
}

/// „Melde dich, wenn die Nvidia-Aktie unter 120 fällt“ → (below, 120, „Nvidia“).
({String op, double value, String subject})? parseAlertRequest(String text) {
  final m = RegExp(
          r'(unter|unterhalb|kleiner als|weniger als|below|under|<|über|oberhalb|größer als|mehr als|above|over|>)\s*(?:den wert |die marke |von )?([\d][\d.,]*)',
          caseSensitive: false)
      .firstMatch(text);
  if (m == null) return null;
  final v = parseNumber(m.group(2)!);
  if (v == null) return null;
  final w = m.group(1)!.toLowerCase();
  final op = RegExp(r'unter|kleiner|weniger|below|under|<').hasMatch(w) ? 'below' : 'above';
  final subject = alertSubject(text.replaceRange(m.start, m.end, ' '));
  return (op: op, value: v, subject: subject);
}

/// Worum geht es? („die Nvidia-Aktie fällt“ → „Nvidia“)
String alertSubject(String text) {
  return text
      .replaceAll(RegExp(r'\b(melde|meld|sag|informiere|benachrichtige|gib|bescheid|dich|mich|mir|bitte|wenn|sobald|falls|der|die|das|den|dem|des|'
              r'fällt|sinkt|steigt|liegt|geht|ist|kurs|wert|preis|aktie|aktienkurs|notiert|euro|eur|dollar|usd|punkte|zu|von|auf)\b',
              caseSensitive: false), ' ')
      .replaceAll(RegExp(r'-?aktie\b|-?kurs\b', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s.-]', unicode: true), ' ')
      .replaceAll(RegExp(r'(^|\s)[-.]+|[-.]+(?=\s|$)'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Titel vergleichbar machen (ohne Quelle „ – finanzen.ch“, Satzzeichen, Füllwörter).
Set<String> titleWords(String title) {
  var t = title.toLowerCase().replaceFirst(RegExp(r'\s[-–—|]\s[^-–—|]{2,40}$'), '');
  return {
    for (final w in t.split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)))
      if (w.length > 2 && !const {'der', 'die', 'das', 'und', 'mit', 'für', 'von', 'the', 'and', 'auf', 'ist', 'nach', 'bei', 'aus', 'den', 'dem', 'news'}.contains(w)) w
  };
}

/// Gleiche Meldung? (Jaccard-Ähnlichkeit der Titelwörter)
bool sameStory(String a, String b) {
  final x = titleWords(a), y = titleWords(b);
  if (x.isEmpty || y.isEmpty) return false;
  final inter = x.intersection(y).length;
  return inter / (x.length + y.length - inter) >= 0.5 || (inter >= 4 && inter / math.min(x.length, y.length) >= 0.75);
}

/// Quelle aus dem Titel („… - finanzen.ch“) oder der Adresse.
String sourceOf(Map<String, String> hit) {
  final m = RegExp(r'\s[-–—|]\s([^-–—|]{2,40})$').firstMatch(hit['title'] ?? '');
  if (m != null) return m.group(1)!.trim();
  return Uri.tryParse(hit['link'] ?? '')?.host.replaceFirst('www.', '') ?? '';
}

/// Gleiche Meldungen aus mehreren Quellen zusammenfassen: erster Treffer bleibt,
/// die übrigen Quellen stehen in 'sources'.
List<Map<String, String>> mergeDuplicates(List<Map<String, String>> hits) {
  final out = <Map<String, String>>[];
  for (final h in hits) {
    final same = out.where((o) => sameStory(o['title'] ?? '', h['title'] ?? '')).firstOrNull;
    if (same == null) {
      out.add(Map.of(h));
    } else {
      final src = sourceOf(h);
      final have = (same['sources'] ?? sourceOf(same)).split(', ').where((x) => x.isNotEmpty).toList();
      if (src.isNotEmpty && !have.contains(src)) have.add(src);
      same['sources'] = have.join(', ');
    }
  }
  return out;
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
      final r = item.hasAlert ? await _alert(item, t) : (item.kind == WatchKind.page ? await _page(item, t) : await _topic(item, t));
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
    return WatchCheck(
        event: WatchEvent(
            time: now,
            title: title,
            detail: detail,
            links: newLinks.take(12).toList(),
            kind: item.digestOnly ? 'quiet' : '',
            seen: item.digestOnly));
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
    // Dieselbe Meldung aus mehreren Quellen nur einmal; schon gemeldete (letzte 3 Tage) nicht nochmal
    final recent = [
      for (final e in item.events)
        if (now.difference(e.time).inDays < 3)
          for (final l in e.links) l['title'] ?? ''
    ];
    final merged = [
      for (final f in mergeDuplicates(fresh))
        if (!recent.any((r) => sameStory(r, f['title'] ?? ''))) f
    ];
    if (merged.isEmpty) return WatchCheck();
    String line(Map<String, String> f) => '• ${f['title']}${f['sources'] != null ? ' _(auch: ${f['sources']})_' : ''}';
    return WatchCheck(
        event: WatchEvent(
      time: now,
      title: '${merged.length} neue${merged.length == 1 ? 'r Treffer' : ' Treffer'} zu „${item.title}“',
      detail: merged.take(5).map(line).join('\n'),
      links: merged.take(12).toList(),
      kind: item.digestOnly ? 'quiet' : '',
      seen: item.digestOnly,
    ));
  }

  /// Schwellenwert: Wert ermitteln, nur beim Über-/Unterschreiten melden.
  Future<WatchCheck> _alert(WatchItem item, DateTime now) async {
    final v = await currentValue(item);
    final limit = item.alertValue!;
    final hit = item.alertOp == 'below' ? v < limit : v > limit;
    item.lastValue = v;
    item.fingerprint ??= 'alert';
    if (!hit) {
      // 0,5 % Abstand, damit ein Pendeln um die Schwelle nicht ständig meldet
      final back = item.alertOp == 'below' ? v >= limit * 1.005 : v <= limit * 0.995;
      if (back) item.alertArmed = true;
      return WatchCheck();
    }
    if (!item.alertArmed) return WatchCheck();
    item.alertArmed = false;
    final unit = item.currency.isEmpty ? '' : ' ${item.currency}';
    final what = item.symbol.isNotEmpty ? '${item.title} (${item.symbol})' : item.title;
    return WatchCheck(
        event: WatchEvent(
      time: now,
      kind: 'alert',
      title: '$what ${item.alertOp == 'below' ? 'unter' : 'über'} ${formatNumber(limit)}$unit',
      detail: 'Aktueller Wert: **${formatNumber(v)}$unit** (Schwelle: ${item.alertLabel}$unit). '
          'Junels meldet sich erst wieder, wenn der Wert die Schwelle erneut ${item.alertOp == 'below' ? 'unterschreitet' : 'überschreitet'}.',
      links: [
        if (item.kind == WatchKind.page) {'title': item.title, 'link': item.target}
        else if (item.symbol.isNotEmpty) {'title': '${item.symbol} – Kursverlauf', 'link': 'https://finance.yahoo.com/quote/${Uri.encodeComponent(item.symbol)}'},
      ],
    ));
  }

  /// Aktueller Wert: Börsenkurs (Thema) bzw. Zahl auf der Seite.
  Future<double> currentValue(WatchItem item) async {
    if (item.kind == WatchKind.page) {
      var url = item.target.trim();
      if (!url.startsWith('http')) url = 'https://$url';
      final html = await fetcher(Uri.parse(url));
      final blocked = detectBlockPage(html);
      if (blocked != null) throw Exception(blocked);
      final v = numberOnPage(htmlToText(html), item.valueLabel);
      if (v == null) throw Exception(item.valueLabel.isEmpty ? 'Keine Zahl auf der Seite gefunden' : 'Keine Zahl bei „${item.valueLabel}“ gefunden');
      return v;
    }
    if (item.symbol.isEmpty) {
      final sym = await lookupSymbol(item.searchQuery);
      if (sym == null) throw Exception('Kein Börsenkürzel zu „${item.searchQuery}“ gefunden – im Eintrag ein Kürzel wie NVDA angeben');
      item.symbol = sym;
    }
    final (v, cur) = await quote(item.symbol);
    item.currency = cur;
    return v;
  }

  /// Zahl neben einer Beschriftung (oder die erste größere Zahl).
  static double? numberOnPage(String text, String label) {
    final num = RegExp(r'[-−]?\d{1,3}(?:[.,\s\u00a0]\d{3})*(?:[.,]\d+)?|[-−]?\d+(?:[.,]\d+)?');
    if (label.trim().isNotEmpty) {
      final i = text.toLowerCase().indexOf(label.toLowerCase().trim());
      if (i < 0) return null;
      final m = num.firstMatch(text.substring(i + label.trim().length, math.min(text.length, i + label.trim().length + 120)));
      return m == null ? null : parseNumber(m.group(0)!);
    }
    for (final m in num.allMatches(text)) {
      final v = parseNumber(m.group(0)!);
      if (v != null && m.group(0)!.length >= 2) return v;
    }
    return null;
  }

  /// Börsenkürzel suchen (Aktie, ETF, Index, Krypto, Währung).
  Future<String?> lookupSymbol(String q) async {
    final t = alertSubject(q).trim();
    if (RegExp(r'^[A-Z0-9^.=-]{1,12}$').hasMatch(t)) return t;
    final uri = Uri.https('query1.finance.yahoo.com', '/v1/finance/search', {'q': t.isEmpty ? q : t, 'quotesCount': '5', 'newsCount': '0'});
    final j = jsonDecode(await fetcher(uri)) as Map;
    final quotes = (j['quotes'] as List? ?? const []).cast<Map>();
    final best = quotes.where((x) => const {'EQUITY', 'ETF', 'INDEX', 'CRYPTOCURRENCY', 'CURRENCY', 'MUTUALFUND', 'FUTURE'}.contains(x['quoteType'])).firstOrNull ??
        quotes.firstOrNull;
    return best?['symbol'] as String?;
  }

  /// Letzter Kurs und Währung.
  Future<(double, String)> quote(String symbol) async {
    final uri = Uri.https('query1.finance.yahoo.com', '/v8/finance/chart/$symbol', {'range': '1d', 'interval': '1d'});
    final j = jsonDecode(await fetcher(uri)) as Map;
    final meta = (((j['chart'] as Map?)?['result'] as List?)?.firstOrNull as Map?)?['meta'] as Map?;
    final v = (meta?['regularMarketPrice'] as num?)?.toDouble();
    if (v == null) throw Exception('Kein Kurs für $symbol');
    return (v, (meta?['currency'] as String?) ?? '');
  }

  static String _cap(String s) => s.length > 40000 ? s.substring(0, 40000) : s;
  static String _short(String s) => s.length > 160 ? '${s.substring(0, 160)}…' : s;
}
