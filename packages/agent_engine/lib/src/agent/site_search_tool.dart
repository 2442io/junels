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
    String withNotes(String s, String r) => '${notes.isEmpty ? '' : '${notes.join(' ')} Stattdessen $s.\n'}$r';
    try {
      final r = await _searchOn(site, q);
      if (r != null) return r;
      notes.add('Auf $site nichts Passendes gefunden.');
    } on ToolException catch (e) {
      notes.add('$site: ${e.message}.');
    }
    // Links auf die gewünschte Seite über eine Suchmaschine ("site:") – ohne Preise und Bilder
    final viaEngine = await _searchViaEngine(site, q);
    if (viaEngine != null) return withNotes('über eine Suchmaschine Links auf $site gefunden (ohne Preise)', viaEngine);
    if (shop) {
      for (final s in _shopFallback.where((f) => f != site)) {
        try {
          final r = await _searchOn(s, q);
          if (r != null) return withNotes('auf $s gesucht', r);
          notes.add('Auf $s nichts Passendes gefunden.');
        } on ToolException catch (e) {
          notes.add('$s: ${e.message}.');
        }
      }
    }
    return '${notes.join(' ')} Sag dem Nutzer den Grund und schlag die direkte Suche auf der Seite vor.';
  }

  Future<String?> _searchViaEngine(String site, String q) async {
    try {
      final (hits, _, _) = await WebSearchTool.searchAllEngines('site:$site $q', fetcher);
      final base = site.split('.').first;
      final items = relevantItems([
        for (final h in hits)
          if ((Uri.tryParse(h.url)?.host ?? '').contains(base)) PageItem(h.title, h.url, '', summary: h.snippet),
      ], q);
      if (items.isEmpty) return null;
      return '${formatCardItems(items.take(8))}\n'
          'Der Nutzer sieht die Treffer als Karten. Fasse kurz zusammen und nenne die 2–3 passendsten. Preise kennst du hier nicht.'
          '${items.length > 8 ? '$moreCardsMarker${formatCardItems(items.skip(8).take(24))}' : ''}';
    } catch (_) {
      return null;
    }
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
    // Nur Treffer, die zur Anfrage passen (keine Menü-, App-Store- oder Werbe-Links)
    final items = relevantItems(extractPageItems(html, url).where((i) => i.title.length > 8).toList(), q);
    if (items.isEmpty) return null;
    final b = StringBuffer('Suchergebnisse auf $site für „$q“ ($url):\n');
    b.write(formatCardItems(items.take(8)));
    b.writeln('\nDie Treffer sieht der Nutzer bereits als Karten mit Bild, Titel, Preis und Link. '
        'Fasse in 2–3 Sätzen zusammen und empfiehl die 2–3 passendsten (mit Preis). Keine vollständige Liste, '
        'keine Bilder und keine Adressen (URLs) in die Antwort – die Karten zeigen die Links. Preise können sich ändern.');
    if (items.length > 8) {
      b
        ..write(moreCardsMarker)
        ..write(formatCardItems(items.skip(8).take(32)));
    }
    return b.toString().trim();
  }
}
