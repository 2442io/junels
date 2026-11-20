// Suche direkt auf einer Webseite – wie ein Mensch: Suchfeld der Seite finden,
// Begriff eintragen, Ergebnisliste lesen. Für bekannte Shops/Seiten gibt es feste
// Such-Adressen, sonst wird das Suchformular der Startseite ausgewertet.

import 'network_tools.dart';
import 'tool.dart';

/// Bekannte Such-Adressen ({q} = Suchbegriff, URL-kodiert).
const siteSearchTemplates = <String, String>{
  'amazon.de': 'https://www.amazon.de/s?k={q}',
  'amazon.at': 'https://www.amazon.de/s?k={q}',
  'amazon.com': 'https://www.amazon.com/s?k={q}',
  'geizhals.at': 'https://geizhals.at/?fs={q}',
  'geizhals.de': 'https://geizhals.de/?fs={q}',
  'idealo.de': 'https://www.idealo.de/preisvergleich/MainSearchProductCategory.html?q={q}',
  'idealo.at': 'https://www.idealo.at/preisvergleich/MainSearchProductCategory.html?q={q}',
  'ebay.de': 'https://www.ebay.de/sch/i.html?_nkw={q}',
  'ebay.at': 'https://www.ebay.at/sch/i.html?_nkw={q}',
  'willhaben.at': 'https://www.willhaben.at/iad/kaufen-und-verkaufen/marktplatz?keyword={q}',
  'otto.de': 'https://www.otto.de/suche/{q}/',
  'mediamarkt.at': 'https://www.mediamarkt.at/de/search.html?query={q}',
  'thalia.at': 'https://www.thalia.at/suche?sq={q}',
  'chefkoch.de': 'https://www.chefkoch.de/rs/s0/{q}/Rezepte.html',
  'wikipedia.org': 'https://de.wikipedia.org/w/index.php?search={q}&fulltext=1',
  'github.com': 'https://github.com/search?q={q}',
};

/// Für Produkt-/Preissuchen: Ausweichen, wenn ein Shop blockiert.
const _shopFallback = ['geizhals.at', 'idealo.de'];

String normalizeSite(String site) {
  var s = site.trim().toLowerCase();
  s = s.replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'^www\.'), '');
  s = s.split('/').first;
  if (!s.contains('.')) {
    // "amazon" → amazon.de, "geizhals" → geizhals.at
    final k = siteSearchTemplates.keys.where((k) => k.startsWith('$s.')).firstOrNull;
    if (k != null) return k;
    s = '$s.com';
  }
  return s;
}

/// Sucht im HTML das Suchformular und baut die Ergebnis-Adresse (nur GET-Formulare).
Uri? searchUrlFromForm(String html, Uri base, String query) {
  final forms = RegExp(r'<form\b([^>]*)>(.*?)</form>', dotAll: true, caseSensitive: false).allMatches(html);
  const names = ['q', 'query', 'k', 's', 'search', 'searchterm', 'keyword', 'keywords', 'fs', 'sq', 'term', 'suche', 'text', 'w'];
  for (final f in forms) {
    final attrs = f.group(1)!;
    final method = RegExp(r'method=["\x27]?(\w+)', caseSensitive: false).firstMatch(attrs)?.group(1)?.toLowerCase() ?? 'get';
    if (method != 'get') continue;
    final inputs = RegExp(r'<input\b[^>]*>', caseSensitive: false).allMatches(f.group(2)!).map((m) => m.group(0)!).toList();
    String? field;
    final hidden = <String, String>{};
    for (final i in inputs) {
      final name = RegExp(r'name=["\x27]([^"\x27]+)', caseSensitive: false).firstMatch(i)?.group(1);
      if (name == null) continue;
      final type = RegExp(r'type=["\x27]?(\w+)', caseSensitive: false).firstMatch(i)?.group(1)?.toLowerCase() ?? 'text';
      if (type == 'hidden') {
        hidden[name] = htmlDecode(RegExp(r'value=["\x27]([^"\x27]*)', caseSensitive: false).firstMatch(i)?.group(1) ?? '');
      } else if (field == null && (type == 'search' || names.contains(name.toLowerCase()) || RegExp(r'such|search', caseSensitive: false).hasMatch(i))) {
        field = name;
      }
    }
    if (field == null) continue;
    final action = RegExp(r'action=["\x27]([^"\x27]*)', caseSensitive: false).firstMatch(attrs)?.group(1);
    final target = base.resolve(htmlDecode(action == null || action.isEmpty ? base.path : action));
    return target.replace(queryParameters: {...target.queryParameters, ...hidden, field: query});
  }
  return null;
}

class SiteSearchTool extends AgentTool {
  SiteSearchTool({this.fetcher = httpGetText});
  final Future<String> Function(Uri) fetcher;

  @override
  String get name => 'site_search';
  @override
  String get title => 'Auf Webseite suchen';
  @override
  String get keywords => 'amazon ebay geizhals idealo willhaben shop kaufen angebot produkt preis suche seite';
  @override
  String get description => 'Sucht direkt auf einer Webseite über deren Suchfeld (z. B. amazon.de, geizhals.at, idealo.de, '
      'ebay.de, willhaben.at, wikipedia.org oder jede andere Seite) und liefert die Ergebnisliste mit Titel, Preis, Bild '
      'und Link. Für Produkte und Preise besser als die allgemeine Websuche.';
  @override
  bool get requiresNetwork => true;
  @override
  List<ToolParam> get params => const [
        ToolParam('site', ParamType.string, 'Webseite, z. B. "amazon.de" oder "geizhals"'),
        ToolParam('query', ParamType.string, 'Suchbegriffe'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final site = normalizeSite((args['site'] ?? '').toString());
    final q = (args['query'] ?? '').toString().trim();
    if (q.isEmpty) throw ToolException('query ist leer');
    if (site.isEmpty || site == '.com') throw ToolException('site ist leer');
    await ctx.ensureNetwork('Auf $site nach „$q“ suchen');
    final notes = <String>[];
    final shop = RegExp(r'amazon|ebay|otto|mediamarkt|thalia').hasMatch(site);
    for (final s in [site, if (shop) ..._shopFallback.where((f) => f != site)]) {
      try {
        final r = await _searchOn(s, q);
        if (r != null) {
          return '${notes.isEmpty ? '' : '${notes.join(' ')} Stattdessen auf $s gesucht.\n'}$r';
        }
        notes.add('Auf $s nichts Brauchbares gefunden.');
      } on ToolException catch (e) {
        notes.add('$s: ${e.message}.');
      }
      if (!shop) break;
    }
    return '${notes.join(' ')} Sag dem Nutzer den Grund und schlag die direkte Suche auf der Seite vor.';
  }

  Future<String?> _searchOn(String site, String q) async {
    Uri? url;
    final tpl = siteSearchTemplates[site];
    if (tpl != null) {
      url = Uri.parse(tpl.replaceAll('{q}', Uri.encodeQueryComponent(q)));
    } else {
      final home = Uri.parse('https://$site/');
      url = searchUrlFromForm(await fetcher(home), home, q);
      if (url == null) throw ToolException('kein Suchfeld auf der Startseite gefunden');
    }
    final html = await fetcher(url);
    final items = extractPageItems(html, url).where((i) => i.title.length > 8).toList();
    if (items.isEmpty) return null;
    final b = StringBuffer('Suchergebnisse auf $site für „$q“ ($url):\n');
    for (final i in items.take(10)) {
      b.writeln('- ${i.title}');
      if (i.summary.isNotEmpty) b.writeln('  ${i.summary}');
      if (i.image.isNotEmpty) b.writeln('  Bild: ${i.image}');
      if (i.link.isNotEmpty) b.writeln('  Link: ${i.link}');
    }
    b.writeln('\nDie Treffer sieht der Nutzer bereits als Karten mit Bild, Titel, Preis und Link. '
        'Fasse in 2–3 Sätzen zusammen und empfiehl die 2–3 passendsten (mit Preis). Keine vollständige Liste, '
        'keine Bilder einbinden. Preise können sich ändern.');
    return b.toString().trim();
  }
}
