// Internet-Tools. Jeder Aufruf fragt vorher über ToolContext.ensureNetwork
// den Nutzer (nur diese Frage / ganzer Chat / ablehnen).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'tool.dart';

List<AgentTool> networkTools() => [WebSearchTool(), WebFetchTool()];

class SearchHit {
  SearchHit(this.title, this.url, this.snippet);
  final String title;
  final String url;
  final String snippet;
}

class WebSearchTool extends AgentTool {
  WebSearchTool({this.fetcher = httpGetText});

  /// Austauschbar für Tests.
  final Future<String> Function(Uri uri) fetcher;

  @override
  String get name => 'web_search';
  @override
  String get keywords => 'url web internet suche suchen google recherche news nachrichten aktuell heute neueste wetter preis';
  @override
  String get title => 'Websuche';
  @override
  String get description => 'Sucht im Internet und liefert Titel, Adresse und Kurztext der besten Treffer.';
  @override
  bool get requiresNetwork => true;
  @override
  List<ToolParam> get params => const [ToolParam('query', ParamType.string, 'Suchbegriffe')];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final q = (args['query'] ?? '').toString().trim();
    if (q.isEmpty) throw ToolException('query ist leer');
    await ctx.ensureNetwork('Websuche nach „$q“');
    List<SearchHit> hits = [];
    String? lastError;
    for (final engine in [
      (Uri.https('html.duckduckgo.com', '/html/', {'q': q}), parseDuckDuckGo),
      (Uri.https('www.mojeek.com', '/search', {'q': q}), parseMojeek),
    ]) {
      try {
        hits = engine.$2(await fetcher(engine.$1));
        if (hits.isNotEmpty) break;
      } catch (e) {
        lastError = e.toString();
      }
    }
    if (hits.isEmpty) {
      return lastError != null ? 'Suche fehlgeschlagen: $lastError' : 'Keine Treffer für "$q".';
    }
    return [
      for (final (i, h) in hits.take(6).indexed) '${i + 1}. ${h.title}\n   ${h.url}\n   ${h.snippet}',
    ].join('\n');
  }

  static List<SearchHit> parseDuckDuckGo(String html) {
    final hits = <SearchHit>[];
    final blocks = html.split('class="result__body"').skip(1);
    for (final b in blocks) {
      final a = RegExp(r'class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', dotAll: true).firstMatch(b);
      if (a == null) continue;
      var href = htmlDecode(a.group(1)!);
      final uddg = RegExp(r'[?&]uddg=([^&]+)').firstMatch(href);
      if (uddg != null) href = Uri.decodeComponent(uddg.group(1)!);
      if (href.startsWith('//')) href = 'https:$href';
      if (href.contains('duckduckgo.com/y.js')) continue; // Anzeigen
      final sn = RegExp(r'class="result__snippet"[^>]*>(.*?)</a>', dotAll: true).firstMatch(b);
      hits.add(SearchHit(htmlToText(a.group(2)!), href, sn == null ? '' : htmlToText(sn.group(1)!)));
    }
    return hits;
  }

  static List<SearchHit> parseMojeek(String html) {
    final hits = <SearchHit>[];
    for (final li in html.split('<li').skip(1)) {
      final a = RegExp(r'<a[^>]*class="title"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', dotAll: true).firstMatch(li) ??
          RegExp(r'<h2>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', dotAll: true).firstMatch(li);
      if (a == null) continue;
      final sn = RegExp(r'<p class="s">(.*?)</p>', dotAll: true).firstMatch(li);
      hits.add(SearchHit(htmlToText(a.group(2)!), htmlDecode(a.group(1)!), sn == null ? '' : htmlToText(sn.group(1)!)));
    }
    return hits;
  }
}

class WebFetchTool extends AgentTool {
  WebFetchTool({this.fetcher = httpGetText});
  final Future<String> Function(Uri uri) fetcher;
  static const maxChars = 6000;

  @override
  String get name => 'web_fetch';
  @override
  String get keywords => 'url http https www link seite webseite website öffnen aufrufen abrufen holen lesen news nachrichten artikel';
  @override
  String get title => 'Webseite lesen';
  @override
  String get description => 'Lädt eine Webseite und liefert ihren Text (gekürzt).';
  @override
  bool get requiresNetwork => true;
  @override
  List<ToolParam> get params => const [ToolParam('url', ParamType.string, 'vollständige https-Adresse')];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    var url = (args['url'] ?? '').toString().trim();
    if (!url.startsWith('http')) url = 'https://$url';
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) throw ToolException('Ungültige Adresse "$url"');
    if (_isPrivateHost(uri.host)) throw ToolException('Lokale Netzwerkadressen sind nicht erlaubt.');
    await ctx.ensureNetwork('Webseite lesen: ${uri.host}');
    var html = await fetcher(uri);
    var source = uri;
    // RSS/Atom direkt?
    var items = extractFeedItems(html, source);
    if (items.isEmpty) {
      items = extractPageItems(html, source);
      // Seite mit wenig Text (per JavaScript gebaut)? → verlinkten Feed probieren
      final feed = RegExp(r'<link[^>]+type=["\x27]application/(?:rss|atom)\+xml["\x27][^>]*>', caseSensitive: false)
          .firstMatch(html);
      if (feed != null && items.length < 3) {
        final href = RegExp(r'href=["\x27]([^"\x27]+)["\x27]').firstMatch(feed.group(0)!)?.group(1);
        if (href != null) {
          try {
            final feedUri = uri.resolve(htmlDecode(href));
            final xml = await fetcher(feedUri);
            final fi = extractFeedItems(xml, feedUri);
            if (fi.isNotEmpty) {
              items = fi;
              source = feedUri;
            }
          } catch (_) {}
        }
      }
    }
    final titleM = RegExp(r'<title[^>]*>(.*?)</title>', dotAll: true, caseSensitive: false).firstMatch(html);
    final title = titleM == null ? '' : '${htmlToText(titleM.group(1)!)}\n';
    final b = StringBuffer('$title$url\n');
    if (items.isNotEmpty) {
      b.writeln('\nEINTRÄGE (${items.length}${source != uri ? ', aus Feed $source' : ''}) – Titel / Bild / Link:');
      for (final i in items.take(20)) {
        b.writeln('- ${i.title}${i.date.isEmpty ? '' : ' (${i.date})'}');
        if (i.image.isNotEmpty) b.writeln('  Bild: ${i.image}');
        if (i.link.isNotEmpty) b.writeln('  Link: ${i.link}');
        if (i.summary.isNotEmpty) b.writeln('  ${i.summary}');
      }
      b.writeln('\nBilder in der Antwort als Markdown einbinden: ![Titel](Bild-URL)');
    }
    var text = htmlToText(html);
    final room = maxChars - b.length;
    if (room > 500) {
      if (text.length > room) text = '${text.substring(0, room)}\n[… gekürzt]';
      b.writeln('\nTEXT:\n$text');
    } else if (text.trim().isEmpty && items.isEmpty) {
      b.writeln('\n(Die Seite enthält keinen lesbaren Text – sie wird vermutlich per JavaScript aufgebaut.)');
    }
    return b.toString();
  }

  static bool _isPrivateHost(String h) =>
      h == 'localhost' ||
      h.endsWith('.local') ||
      RegExp(r'^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|0\.)').hasMatch(h) ||
      h == '::1';
}

/// GET mit Zeitlimit, Größenlimit und Zeichensatz-Erkennung.
Future<String> httpGetText(Uri uri) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'Mozilla/5.0 (OfflineAgent; +local)';
  try {
    final req = await client.getUrl(uri);
    req.headers.set(HttpHeaders.acceptHeader, 'text/html,text/plain;q=0.9,*/*;q=0.5');
    req.headers.set(HttpHeaders.acceptLanguageHeader, 'de,en;q=0.8');
    final resp = await req.close().timeout(const Duration(seconds: 20));
    if (resp.statusCode >= 400) throw ToolException('HTTP ${resp.statusCode} von ${uri.host}');
    final type = resp.headers.contentType;
    if (type != null && !(type.primaryType == 'text' || type.subType.contains('json') || type.subType.contains('xml'))) {
      await resp.drain<void>();
      throw ToolException('Kein Text (${type.mimeType})');
    }
    final bytes = <int>[];
    await for (final c in resp.timeout(const Duration(seconds: 20))) {
      bytes.addAll(c);
      if (bytes.length > 3 * 1024 * 1024) break;
    }
    final charset = type?.charset?.toLowerCase();
    return charset == 'iso-8859-1' || charset == 'latin1' || charset == 'windows-1252'
        ? latin1.decode(bytes, allowInvalid: true)
        : utf8.decode(bytes, allowMalformed: true);
  } on TimeoutException {
    throw ToolException('Zeitüberschreitung bei ${uri.host}');
  } on SocketException catch (e) {
    throw ToolException('Keine Verbindung zu ${uri.host}: ${e.message}');
  } finally {
    client.close(force: true);
  }
}

/// Wandelt HTML in lesbaren Text um.
String htmlToText(String html) {
  var s = html
      .replaceAll(RegExp(r'<(script|style|noscript|svg|head)[^>]*>.*?</\1>', dotAll: true, caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ')
      .replaceAll(RegExp(r'<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)[^>]*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '\n• ')
      .replaceAll(RegExp(r'<[^>]+>'), ' ');
  s = htmlDecode(s);
  s = s.replaceAll(RegExp(r'[ \t\r\f]+'), ' ').replaceAll(RegExp(r' *\n *'), '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}

String htmlDecode(String s) => s.replaceAllMapped(RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z]+);'), (m) {
      final e = m.group(1)!;
      if (e.startsWith('#x') || e.startsWith('#X')) {
        return String.fromCharCode(int.tryParse(e.substring(2), radix: 16) ?? 63);
      }
      if (e.startsWith('#')) return String.fromCharCode(int.tryParse(e.substring(1)) ?? 63);
      return const {
            'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ',
            'auml': 'ä', 'ouml': 'ö', 'uuml': 'ü', 'Auml': 'Ä', 'Ouml': 'Ö', 'Uuml': 'Ü', 'szlig': 'ß',
            'euro': '€', 'ndash': '–', 'mdash': '—', 'hellip': '…', 'laquo': '«', 'raquo': '»',
          }[e] ??
          m.group(0)!;
    });

/// Eintrag einer News-/Übersichtsseite.
class PageItem {
  PageItem(this.title, this.link, this.image, {this.summary = '', this.date = ''});
  final String title;
  final String link;
  final String image;
  final String summary;
  final String date;
}

String _abs(Uri base, String? u) {
  if (u == null) return '';
  final v = htmlDecode(u.trim());
  if (v.isEmpty || v.startsWith('data:') || v.startsWith('javascript:')) return '';
  try {
    return base.resolve(v).toString();
  } catch (_) {
    return '';
  }
}

String? _imgSrc(String block) {
  final img = RegExp(r'<img\b[^>]*>', caseSensitive: false).firstMatch(block)?.group(0);
  if (img != null) {
    for (final attr in ['data-src', 'data-lazy-src', 'src', 'data-original']) {
      final m = RegExp('\\b$attr=["\x27]([^"\x27]+)["\x27]', caseSensitive: false).firstMatch(img);
      if (m != null && !m.group(1)!.startsWith('data:')) return m.group(1);
    }
    final set = RegExp(r'srcset=["\x27]([^"\x27\s,]+)', caseSensitive: false).firstMatch(img);
    if (set != null) return set.group(1);
  }
  return RegExp(r'background(?:-image)?\s*:\s*url\(\s*["\x27]?([^"\x27)]+)', caseSensitive: false).firstMatch(block)?.group(1);
}

/// Einträge aus RSS/Atom.
List<PageItem> extractFeedItems(String xml, Uri base) {
  final head = xml.length > 600 ? xml.substring(0, 600) : xml;
  if (!RegExp(r'<(rss|feed|rdf:RDF)\b', caseSensitive: false).hasMatch(head)) return const [];
  String tag(String block, String name) {
    final m = RegExp('<$name\\b[^>]*>(.*?)</$name>', dotAll: true, caseSensitive: false).firstMatch(block);
    if (m == null) return '';
    var v = m.group(1)!.trim();
    final cdata = RegExp(r'^<!\[CDATA\[(.*)\]\]>$', dotAll: true).firstMatch(v);
    if (cdata != null) v = cdata.group(1)!;
    return v;
  }

  final out = <PageItem>[];
  for (final m in RegExp(r'<(item|entry)\b[^>]*>(.*?)</\1>', dotAll: true, caseSensitive: false).allMatches(xml)) {
    final b = m.group(2)!;
    var link = tag(b, 'link');
    if (link.isEmpty) {
      link = RegExp(r'<link\b[^>]*href=["\x27]([^"\x27]+)', caseSensitive: false).firstMatch(b)?.group(1) ?? '';
    }
    final desc = tag(b, 'description').isNotEmpty ? tag(b, 'description') : tag(b, 'summary');
    final img = RegExp(r'<(?:media:content|media:thumbnail|enclosure)\b[^>]*url=["\x27]([^"\x27]+)', caseSensitive: false)
            .firstMatch(b)
            ?.group(1) ??
        _imgSrc(htmlDecode(desc)) ??
        _imgSrc(tag(b, 'content:encoded'));
    final summary = htmlToText(htmlDecode(desc));
    out.add(PageItem(
      htmlToText(htmlDecode(tag(b, 'title'))),
      _abs(base, link),
      _abs(base, img),
      summary: summary.length > 200 ? '${summary.substring(0, 197)}…' : summary,
      date: tag(b, 'pubDate').isNotEmpty ? tag(b, 'pubDate') : tag(b, 'updated'),
    ));
  }
  return out;
}

/// Einträge einer HTML-Übersichtsseite: Artikel bzw. Links mit Bild oder Überschrift.
List<PageItem> extractPageItems(String html, Uri base) {
  final clean = html
      .replaceAll(RegExp(r'<script\b.*?</script>', dotAll: true, caseSensitive: false), '')
      .replaceAll(RegExp(r'<style\b.*?</style>', dotAll: true, caseSensitive: false), '');
  final blocks = <String>[
    for (final m in RegExp(r'<article\b.*?</article>', dotAll: true, caseSensitive: false).allMatches(clean)) m.group(0)!,
  ];
  if (blocks.length < 3) {
    blocks
      ..clear()
      ..addAll([
        for (final m in RegExp(r'<a\b[^>]*href=[^>]*>.*?</a>', dotAll: true, caseSensitive: false).allMatches(clean))
          if (RegExp(r'<img\b|<h[1-4]\b', caseSensitive: false).hasMatch(m.group(0)!)) m.group(0)!,
      ]);
  }
  final out = <PageItem>[];
  final seen = <String>{};
  for (final b in blocks) {
    final href = RegExp(r'<a\b[^>]*href=["\x27]([^"\x27#][^"\x27]*)["\x27]', caseSensitive: false).firstMatch(b)?.group(1);
    final link = _abs(base, href);
    final h = RegExp(r'<h[1-4]\b[^>]*>(.*?)</h[1-4]>', dotAll: true, caseSensitive: false).firstMatch(b)?.group(1);
    final alt = RegExp(r'<img\b[^>]*alt=["\x27]([^"\x27]+)', caseSensitive: false).firstMatch(b)?.group(1);
    var title = htmlToText(h ?? '').trim();
    if (title.isEmpty) title = htmlToText(b).trim();
    if (title.isEmpty && alt != null) title = htmlDecode(alt);
    if (title.length > 160) title = '${title.substring(0, 157)}…';
    final key = link.isNotEmpty ? link : title;
    if (title.isEmpty || !seen.add(key)) continue;
    final summary = h == null ? '' : htmlToText(b.replaceFirst(h, '')).trim();
    out.add(PageItem(title, link, _abs(base, _imgSrc(b)),
        summary: summary.length > 160 ? '${summary.substring(0, 157)}…' : summary));
    if (out.length >= 30) break;
  }
  return out;
}
