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
  String get keywords => 'url web internet suche suchen google recherche aktuell heute neueste preis angebot';
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
    final (hits, used, errors) = await searchAllEngines(q, fetcher);
    if (hits.isEmpty) {
      return 'Websuche ohne Ergebnis (${errors.join('; ')}). '
          'Sag dem Nutzer den Grund. Für Produkte/Preise kann site_search (z. B. geizhals) helfen.';
    }
    String fmt(SearchHit h) => '- ${h.title}\n${h.snippet.isEmpty ? '' : '  ${h.snippet}\n'}  Link: ${h.url}';
    return [
      'Treffer ($used) – lies die passendsten mit web_fetch, bevor du antwortest. '
          'Der Nutzer sieht die Treffer als Karten.',
      for (final h in hits.take(6)) fmt(h),
      if (hits.length > 6) moreCardsMarker.trim(),
      for (final h in hits.skip(6).take(30)) fmt(h),
    ].join('\n');
  }

  /// Fragt die Suchmaschinen der Reihe nach ab: (Treffer, benutzte Maschine, Fehler).
  static Future<(List<SearchHit>, String, List<String>)> searchAllEngines(
      String q, Future<String> Function(Uri) fetcher) async {
    List<SearchHit> hits = [];
    final errors = <String>[];
    var used = '';
    for (final engine in [
      ('DuckDuckGo', Uri.https('html.duckduckgo.com', '/html/', {'q': q, 'kl': 'de-de'}), parseDuckDuckGo),
      ('DuckDuckGo Lite', Uri.https('lite.duckduckgo.com', '/lite/', {'q': q, 'kl': 'de-de'}), parseDuckDuckGoLite),
      ('Bing', Uri.https('www.bing.com', '/search', {'q': q, 'setlang': 'de', 'cc': 'AT'}), parseBing),
      ('Mojeek', Uri.https('www.mojeek.com', '/search', {'q': q}), parseMojeek),
    ]) {
      try {
        hits = engine.$3(await fetcher(engine.$2));
        if (hits.isNotEmpty) {
          used = engine.$1;
          break;
        }
        errors.add('${engine.$1}: keine Treffer');
      } catch (e) {
        errors.add('${engine.$1}: $e');
      }
    }
    return (hits, used, errors);
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

  static List<SearchHit> parseDuckDuckGoLite(String html) {
    final hits = <SearchHit>[];
    final links = RegExp(r"<a[^>]*class=.result-link.[^>]*href=.([^'\x22]+).[^>]*>(.*?)</a>", dotAll: true).allMatches(html).toList();
    final snippets = RegExp(r"class=.result-snippet.[^>]*>(.*?)</td>", dotAll: true).allMatches(html).toList();
    for (var i = 0; i < links.length; i++) {
      var href = htmlDecode(links[i].group(1)!);
      final uddg = RegExp(r'[?&]uddg=([^&]+)').firstMatch(href);
      if (uddg != null) href = Uri.decodeComponent(uddg.group(1)!);
      if (href.startsWith('//')) href = 'https:$href';
      if (href.contains('duckduckgo.com/y.js')) continue;
      hits.add(SearchHit(htmlToText(links[i].group(2)!), href, i < snippets.length ? htmlToText(snippets[i].group(1)!) : ''));
    }
    return hits;
  }

  static List<SearchHit> parseBing(String html) {
    final hits = <SearchHit>[];
    for (final b in html.split('<li class="b_algo"').skip(1)) {
      final a = RegExp(r'<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', dotAll: true).firstMatch(b);
      if (a == null) continue;
      var href = htmlDecode(a.group(1)!);
      // Bing-Weiterleitung (…/ck/a?…&u=a1<base64>) auflösen
      final u = RegExp(r'[?&]u=a1([^&]+)').firstMatch(href);
      if (u != null) {
        try {
          var b64 = u.group(1)!.replaceAll('-', '+').replaceAll('_', '/');
          while (b64.length % 4 != 0) {
            b64 += '=';
          }
          href = utf8.decode(base64.decode(b64));
        } catch (_) {}
      }
      final sn = RegExp(r'<p[^>]*>(.*?)</p>', dotAll: true).firstMatch(b);
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
      b.write(formatCardItems(items.take(12)));
      b.writeln('\nDie Einträge sieht der Nutzer bereits als Karten mit Bild, Titel und Link. '
          'Fasse zusammen bzw. beantworte die Frage, keine Bilder einbinden, die Überschrift EINTRÄGE nicht übernehmen.');
    }
    if (items.isEmpty) {
      // einzelne Seite als Karte (Titel, Vorschaubild, Beschreibung)
      String? meta(String prop) => RegExp('<meta[^>]+(?:property|name)=["\x27]$prop["\x27][^>]*content=["\x27]([^"\x27]+)',
              caseSensitive: false)
          .firstMatch(html)
          ?.group(1);
      final img = _abs(uri, meta('og:image') ?? meta('twitter:image'));
      final desc = htmlDecode(meta('og:description') ?? meta('description') ?? '');
      final t = htmlDecode(meta('og:title') ?? (titleM == null ? '' : htmlToText(titleM.group(1)!)));
      if (t.trim().isNotEmpty) {
        b.writeln('\nSEITE:');
        b.write(formatCardItems([PageItem(t.trim(), uri.toString(), img, summary: desc.length > 200 ? '${desc.substring(0, 197)}…' : desc)]));
      }
    }
    var text = htmlToText(html);
    final room = maxChars - b.length;
    if (room > 500) {
      if (text.length > room) text = '${text.substring(0, room)}\n[… gekürzt]';
      b.writeln('\nTEXT:\n$text');
    } else if (text.trim().isEmpty && items.isEmpty) {
      b.writeln('\n(Die Seite enthält keinen lesbaren Text – sie wird vermutlich per JavaScript aufgebaut.)');
    }
    if (items.length > 12) {
      b
        ..write(moreCardsMarker)
        ..write(formatCardItems(items.skip(12).take(30)));
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
    ..userAgent = browserUserAgent;
  try {
    final req = await client.getUrl(uri);
    req.headers.set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5');
    req.headers.set(HttpHeaders.acceptLanguageHeader, 'de-AT,de;q=0.9,en;q=0.7');
    final resp = await req.close().timeout(const Duration(seconds: 20));
    if (resp.statusCode == 503 || resp.statusCode == 429 || resp.statusCode == 403) {
      await resp.drain<void>();
      throw ToolException('${uri.host} blockiert automatische Abrufe (HTTP ${resp.statusCode})');
    }
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
    final text = charset == 'iso-8859-1' || charset == 'latin1' || charset == 'windows-1252'
        ? latin1.decode(bytes, allowInvalid: true)
        : utf8.decode(bytes, allowMalformed: true);
    final block = detectBlockPage(text);
    if (block != null) throw ToolException('${uri.host}: $block');
    return text;
  } on TimeoutException {
    throw ToolException('Zeitüberschreitung bei ${uri.host}');
  } on SocketException catch (e) {
    throw ToolException('Keine Verbindung zu ${uri.host}: ${e.message}');
  } finally {
    client.close(force: true);
  }
}

/// Wie ein normaler Handy-Browser – manche Seiten liefern sonst nichts.
const browserUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

/// Erkennt Captcha-/Sperrseiten (Amazon, DuckDuckGo, Cloudflare …).
String? detectBlockPage(String html) {
  final head = html.length > 20000 ? html.substring(0, 20000) : html;
  if (RegExp(r'api-services-support@amazon|Geben Sie die unten angezeigten Zeichen ein|Enter the characters you see below|'
          r'opfcaptcha|/errors/validateCaptcha', caseSensitive: false)
      .hasMatch(head)) {
    return 'blockiert automatische Abrufe (Captcha)';
  }
  if (RegExp(r'anomaly-modal|Unfortunately, bots use DuckDuckGo too|challenge-form|cf-chl-|Just a moment\.\.\.|Attention Required',
          caseSensitive: false)
      .hasMatch(head)) {
    return 'verlangt eine Bot-Prüfung (Captcha)';
  }
  return null;
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

/// Preis in einem HTML-Block (z. B. "19,99 €", "€ 24,90", "EUR 12.50").
String? findPrice(String block) {
  final off = RegExp(r'class="a-offscreen"[^>]*>([^<]+)<').firstMatch(block);
  if (off != null) return htmlToText(off.group(1)!).trim();
  final t = htmlToText(block);
  final m = RegExp(r'(?:€|EUR)\s?\d{1,5}(?:[.,]\d{2})?|\d{1,5}(?:[.,]\d{2})\s?(?:€|EUR)').firstMatch(t);
  return m?.group(0)?.trim();
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
  // Shop-Ergebnislisten (Amazon u. a.): jeder Treffer in einem eigenen Block
  final shop = clean.split(RegExp(r'<div[^>]+data-component-type="s-search-result"')).skip(1).toList();
  final isShop = shop.length >= 2;
  if (isShop) {
    blocks
      ..clear()
      ..addAll(shop.map((b) => b.length > 12000 ? b.substring(0, 12000) : b));
  }
  if (blocks.length < 3 && !isShop) {
    // Kopf-, Navigations- und Fußbereich enthalten keine Treffer (App-Store-Badges, Social-Links …)
    final body = clean.replaceAll(
        RegExp(r'<(header|nav|footer|aside)\b.*?</\1>', dotAll: true, caseSensitive: false), '');
    blocks
      ..clear()
      ..addAll([
        for (final m in RegExp(r'<a\b[^>]*href=[^>]*>.*?</a>', dotAll: true, caseSensitive: false).allMatches(body))
          if (RegExp(r'<img\b|<h[1-4]\b', caseSensitive: false).hasMatch(m.group(0)!)) m.group(0)!,
      ]);
  }
  final out = <PageItem>[];
  final seen = <String>{};
  for (final b in blocks) {
    final h = RegExp(r'<h[1-4]\b[^>]*>(.*?)</h[1-4]>', dotAll: true, caseSensitive: false).firstMatch(b)?.group(1);
    final hrefRe = RegExp(r'<a\b[^>]*href=["\x27]([^"\x27#][^"\x27]*)["\x27]', caseSensitive: false);
    // Link der Überschrift bevorzugen (Produktseite statt Bild-Link)
    final href = (h == null ? null : hrefRe.firstMatch(h)?.group(1)) ?? hrefRe.firstMatch(b)?.group(1);
    final link = _abs(base, href);
    final alt = RegExp(r'<img\b[^>]*alt=["\x27]([^"\x27]+)', caseSensitive: false).firstMatch(b)?.group(1);
    var title = htmlToText(h ?? '').trim();
    if (title.isEmpty) title = htmlToText(b).trim();
    if (title.isEmpty && alt != null) title = htmlDecode(alt);
    if (title.length > 160) title = '${title.substring(0, 157)}…';
    final key = link.isNotEmpty ? link : title;
    if (title.isEmpty || isJunkLink(link, title) || !seen.add(key)) continue;
    var summary = h == null ? '' : htmlToText(b.replaceFirst(h, '')).trim();
    if (summary.length > 160) summary = '${summary.substring(0, 157)}…';
    final price = findPrice(b);
    if (price != null && !summary.contains(price)) summary = 'Preis: $price${summary.isEmpty ? '' : ' · $summary'}';
    out.add(PageItem(title, link, _abs(base, _imgSrc(b)), summary: summary));
    if (out.length >= 30) break;
  }
  return out;
}

final _junkHost = RegExp(
    r'(^|\.)(apps\.apple\.com|itunes\.apple\.com|play\.google\.com|appgallery\.huawei\.com|appgallery\.cloud\.huawei\.com|'
    r'galaxy\.store|microsoft\.com|facebook\.com|instagram\.com|twitter\.com|x\.com|youtube\.com|tiktok\.com|'
    r'linkedin\.com|pinterest\.\w+|whatsapp\.com|t\.me|threads\.net)$');
final _junkTitle = RegExp(
    r'^(app ?store|apple|google play|play store|huawei|appgallery|app gallery|facebook|instagram|youtube|tiktok|'
    r'impressum|datenschutz\w*|agb|kontakt|cookie\w*|anmelden|login|registrieren|newsletter|hilfe|karriere|presse)\b',
    caseSensitive: false);

/// Links, die keine Inhalte sind: App-Stores, soziale Netzwerke, Rechtliches, Konto.
bool isJunkLink(String link, String title) {
  final host = Uri.tryParse(link)?.host.toLowerCase() ?? '';
  if (host.isNotEmpty && _junkHost.hasMatch(host)) return true;
  final t = title.trim();
  return t.length < 40 && _junkTitle.hasMatch(t);
}

/// Wortstämme einer Suchanfrage (für die Prüfung, ob ein Treffer passt).
List<String> queryStems(String q) => [
      for (final w in q.toLowerCase().split(RegExp(r'[^a-z0-9äöüß]+')))
        if (w.length >= 4 && !const {'eine', 'einen', 'einer', 'für', 'fuer', 'damit', 'gerne', 'soll', 'sein', 'mit', 'oder', 'von', 'auf', 'nach', 'link', 'links', 'amazon'}.contains(w))
          w.length >= 8 ? w.substring(0, 4) : (w.length > 6 ? w.substring(0, 6) : w),
    ];

/// Nur Treffer, die mindestens einen Begriff der Anfrage enthalten.
List<PageItem> relevantItems(List<PageItem> items, String q) {
  final stems = queryStems(q);
  if (stems.isEmpty) return items;
  return [
    for (final i in items)
      if (stems.any(('${i.title} ${i.summary} ${Uri.decodeFull(i.link)}').toLowerCase().contains)) i,
  ];
}

/// Ab hier folgen weitere Einträge nur für die Karten-Anzeige (nicht fürs Modell).
const moreCardsMarker = '\n<<<WEITERE-KARTEN>>>\n';

/// Einträge im einheitlichen Karten-Format ("- Titel", eingerückt Preis/Bild/Link/Text).
String formatCardItems(Iterable<PageItem> items, {String source = ''}) {
  final b = StringBuffer();
  for (final i in items) {
    b.writeln('- ${i.title}${i.date.isEmpty ? '' : ' (${source.isEmpty ? '' : '$source, '}${i.date})'}');
    if (i.summary.isNotEmpty) b.writeln('  ${i.summary}');
    if (i.image.isNotEmpty) b.writeln('  Bild: ${i.image}');
    if (i.link.isNotEmpty) b.writeln('  Link: ${i.link}');
  }
  return b.toString();
}

/// Ergebnis-Karte (für die Darstellung als Karussell im Chat).
class ResultCard {
  ResultCard({required this.title, this.link = '', this.image = '', this.price = '', this.note = ''});
  final String title;
  final String link;
  final String image;
  final String price;
  final String note;

  Map<String, String> toJson() => {
        'title': title,
        if (link.isNotEmpty) 'link': link,
        if (image.isNotEmpty) 'image': image,
        if (price.isNotEmpty) 'price': price,
        if (note.isNotEmpty) 'note': note,
      };
}

/// Liest Einträge aus der Ausgabe von site_search / news / web_fetch
/// ("- Titel", eingerückt "Preis: …", "Bild: …", "Link: …").
List<ResultCard> parseResultCards(String observation) {
  final out = <ResultCard>[];
  String? title;
  var link = '', image = '', price = '', note = '';
  void flush() {
    final t = title;
    if (t != null && t.trim().isNotEmpty && (link.isNotEmpty || image.isNotEmpty)) {
      out.add(ResultCard(title: t.trim(), link: link, image: image, price: price, note: note));
    }
    title = null;
    link = image = price = note = '';
  }

  for (final raw in observation.split('\n')) {
    if (raw.startsWith('- ')) {
      flush();
      title = raw.substring(2);
      continue;
    }
    if (title == null || !raw.startsWith('  ')) {
      if (raw.trim().isEmpty || !raw.startsWith(' ')) flush();
      continue;
    }
    final l = raw.trim();
    if (l.startsWith('Link: ')) {
      link = l.substring(6).trim();
    } else if (l.startsWith('Bild: ')) {
      image = l.substring(6).trim();
    } else if (l.startsWith('Preis: ')) {
      final p = l.substring(7);
      final i = p.indexOf(' · ');
      price = (i < 0 ? p : p.substring(0, i)).trim();
      if (i >= 0 && note.isEmpty) note = p.substring(i + 3).trim();
    } else if (note.isEmpty) {
      note = l;
    }
  }
  flush();
  return out;
}
