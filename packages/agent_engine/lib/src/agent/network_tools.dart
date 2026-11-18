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
    final html = await fetcher(uri);
    final titleM = RegExp(r'<title[^>]*>(.*?)</title>', dotAll: true, caseSensitive: false).firstMatch(html);
    var text = htmlToText(html);
    if (text.length > maxChars) text = '${text.substring(0, maxChars)}\n[… gekürzt]';
    final title = titleM == null ? '' : '${htmlToText(titleM.group(1)!)}\n';
    return '$title$url\n\n$text';
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
