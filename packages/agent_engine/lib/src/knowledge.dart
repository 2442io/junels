// Lokale Wissensbasis für RAG: Quellen (Webseiten, Dateien) werden in
// Abschnitte zerlegt und per BM25 durchsucht. Kein Embedding-Modell nötig,
// alles offline nach dem einmaligen Laden.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'agent/network_tools.dart' show htmlToText, htmlDecode, httpGetText;

class KnowledgeChunk {
  KnowledgeChunk({required this.sourceId, required this.title, required this.url, required this.text});
  final String sourceId;
  final String title; // Seitentitel
  final String url; // genaue Seite
  final String text;

  Map<String, Object> toJson() => {'s': sourceId, 't': title, 'u': url, 'x': text};
  factory KnowledgeChunk.fromJson(Map<String, dynamic> j) => KnowledgeChunk(
      sourceId: j['s'] as String, title: j['t'] as String? ?? '', url: j['u'] as String? ?? '', text: j['x'] as String);
}

class KnowledgeSource {
  KnowledgeSource({
    required this.id,
    required this.name,
    required this.origin,
    required this.kind,
    this.pages = 0,
    this.chars = 0,
    DateTime? updated,
    this.crawl = false,
  }) : updated = updated ?? DateTime.now();

  final String id;
  String name;
  final String origin; // URL oder Dateiname
  final String kind; // web | file
  int pages;
  int chars;
  DateTime updated;
  final bool crawl;

  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'origin': origin,
        'kind': kind,
        'pages': pages,
        'chars': chars,
        'updated': updated.toIso8601String(),
        'crawl': crawl,
      };

  factory KnowledgeSource.fromJson(Map<String, dynamic> j) => KnowledgeSource(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        origin: j['origin'] as String? ?? '',
        kind: j['kind'] as String? ?? 'web',
        pages: (j['pages'] as num?)?.toInt() ?? 0,
        chars: (j['chars'] as num?)?.toInt() ?? 0,
        updated: DateTime.tryParse(j['updated'] as String? ?? ''),
        crawl: j['crawl'] as bool? ?? false,
      );
}

class KnowledgeHit {
  KnowledgeHit(this.chunk, this.score);
  final KnowledgeChunk chunk;
  final double score;
}

/// Wortzerlegung mit leichter deutscher/englischer Normalisierung.
List<String> knowledgeTokens(String text) {
  final out = <String>[];
  for (final m in RegExp(r'[\p{L}\p{N}]+', unicode: true).allMatches(text.toLowerCase())) {
    var w = m.group(0)!.replaceAll('ä', 'ae').replaceAll('ö', 'oe').replaceAll('ü', 'ue').replaceAll('ß', 'ss');
    if (w.length < 2 || _stop.contains(w)) continue;
    // einfache Endungs-Kürzung (verbessert Treffer bei Plural/Flexion)
    for (final suf in const ['ungen', 'ung', 'ern', 'en', 'er', 'es', 'e', 'n', 's']) {
      if (w.length > suf.length + 3 && w.endsWith(suf)) {
        w = w.substring(0, w.length - suf.length);
        break;
      }
    }
    out.add(w);
  }
  return out;
}

const _stop = {
  'der', 'die', 'das', 'und', 'oder', 'ist', 'sind', 'ein', 'eine', 'einen', 'einem', 'einer', 'den', 'dem', 'des',
  'zu', 'im', 'in', 'am', 'an', 'auf', 'mit', 'von', 'fuer', 'für', 'wie', 'was', 'wer', 'wo', 'es', 'ich', 'du', 'sie',
  'wir', 'ihr', 'er', 'nicht', 'auch', 'als', 'bei', 'aus', 'nach', 'so', 'dass', 'the', 'and', 'or', 'of', 'to', 'is',
  'are', 'for', 'on', 'with', 'by', 'it', 'this', 'that', 'be', 'at', 'from', 'as',
  // Fragewörter und Allerweltswörter – sagen nichts über das Thema
  'welch', 'welcher', 'welche', 'welches', 'welchen', 'wann', 'warum', 'wieso', 'weshalb', 'wieviel', 'wie viel',
  'man', 'mir', 'mich', 'mein', 'meine', 'dein', 'deine', 'uns', 'euch', 'kann', 'kannst', 'koennen', 'bitte', 'gibt',
  'mache', 'machen', 'macht', 'mach', 'tun', 'hat', 'habe', 'hast', 'haben', 'wird', 'werden', 'wurde', 'war', 'bin',
  'noch', 'schon', 'sehr', 'mal', 'jetzt', 'heute', 'gerade', 'etwas', 'alle', 'viel', 'mehr', 'gut', 'ja', 'nein',
  'sag', 'sage', 'sagen', 'erklaer', 'erklaere', 'zeig', 'zeige', 'gib', 'what', 'how', 'why', 'when', 'which', 'who',
  'do', 'does', 'can', 'you', 'me', 'my', 'today', 'please',
};

/// Zerlegt Text in überlappende Abschnitte an Absatz-/Satzgrenzen.
List<String> chunkText(String text, {int size = 900, int overlap = 150}) {
  final clean = text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  if (clean.length <= size) return clean.isEmpty ? [] : [clean];
  final chunks = <String>[];
  var start = 0;
  while (start < clean.length) {
    var end = math.min(clean.length, start + size);
    if (end < clean.length) {
      // am Absatz- oder Satzende schneiden
      final para = clean.lastIndexOf('\n', end);
      final sent = clean.lastIndexOf(RegExp(r'[.!?]\s'), end);
      final cut = para > start + size ~/ 2 ? para : (sent > start + size ~/ 2 ? sent + 1 : end);
      end = cut;
    }
    chunks.add(clean.substring(start, end).trim());
    if (end >= clean.length) break;
    start = math.max(end - overlap, start + 1);
  }
  return chunks.where((c) => c.length > 40).toList();
}

class KnowledgeBase {
  KnowledgeBase(this.dir);

  final Directory dir;
  final List<KnowledgeSource> sources = [];
  final List<KnowledgeChunk> chunks = [];

  // BM25-Index
  final List<Map<String, int>> _tf = [];
  final List<int> _len = [];
  final Map<String, int> _df = {};
  double _avgLen = 1;

  File get _file => File('${dir.path}/knowledge.json');

  bool get isEmpty => chunks.isEmpty;

  Future<void> load() async {
    sources.clear();
    chunks.clear();
    try {
      if (await _file.exists()) {
        final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
        sources.addAll([for (final s in j['sources'] as List) KnowledgeSource.fromJson((s as Map).cast())]);
        chunks.addAll([for (final c in j['chunks'] as List) KnowledgeChunk.fromJson((c as Map).cast())]);
      }
    } catch (_) {}
    _reindex();
  }

  Future<void> save() async {
    await dir.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'sources': sources.map((s) => s.toJson()).toList(),
      'chunks': chunks.map((c) => c.toJson()).toList(),
    }));
    await tmp.rename(_file.path);
  }

  void _reindex() {
    _tf.clear();
    _len.clear();
    _df.clear();
    var total = 0;
    for (final c in chunks) {
      final tf = <String, int>{};
      final toks = knowledgeTokens('${c.title} ${c.text}');
      for (final t in toks) {
        tf[t] = (tf[t] ?? 0) + 1;
      }
      for (final t in tf.keys) {
        _df[t] = (_df[t] ?? 0) + 1;
      }
      _tf.add(tf);
      _len.add(toks.length);
      total += toks.length;
    }
    _avgLen = chunks.isEmpty ? 1 : total / chunks.length;
  }

  /// Fügt Seiten einer Quelle hinzu (ersetzt vorhandene Abschnitte der Quelle).
  void putSource(KnowledgeSource source, List<({String title, String url, String text})> pages) {
    sources.removeWhere((s) => s.id == source.id);
    chunks.removeWhere((c) => c.sourceId == source.id);
    var chars = 0;
    for (final p in pages) {
      chars += p.text.length;
      for (final c in chunkText(p.text)) {
        chunks.add(KnowledgeChunk(sourceId: source.id, title: p.title, url: p.url, text: c));
      }
    }
    source
      ..pages = pages.length
      ..chars = chars
      ..updated = DateTime.now();
    sources.add(source);
    _reindex();
  }

  void removeSource(String id) {
    sources.removeWhere((s) => s.id == id);
    chunks.removeWhere((c) => c.sourceId == id);
    _reindex();
  }

  /// BM25-Suche. [minScore] filtert schwache Treffer.
  ///
  /// Ein Abschnitt zählt nur, wenn er den Großteil der Frage abdeckt
  /// ([minCoverage] = Anteil der Suchwörter). So liefert
  /// „Wie mache ich Spaghetti?“ keine Seite, nur weil dort „mache“ vorkommt.
  List<KnowledgeHit> search(String query, {int k = 4, double minScore = 0.5, double minCoverage = 0.5}) {
    final q = knowledgeTokens(query).toSet();
    if (q.isEmpty || chunks.isEmpty) return [];
    const k1 = 1.4, b = 0.75;
    final n = chunks.length;
    double idfOf(String t) {
      final df = _df[t] ?? 0;
      return math.log(1 + (n - df + 0.5) / (df + 0.5));
    }

    final hits = <KnowledgeHit>[];
    for (var i = 0; i < n; i++) {
      var score = 0.0;
      var matched = 0;
      for (final t in q) {
        final f = _tf[i][t];
        if (f == null) continue;
        final idf = idfOf(t);
        matched++;
        score += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * _len[i] / _avgLen));
      }
      if (score >= minScore && matched / q.length >= minCoverage) {
        hits.add(KnowledgeHit(chunks[i], score));
      }
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    // deutlich schwächere Treffer als der beste weglassen
    if (hits.isNotEmpty) {
      final top = hits.first.score;
      hits.removeWhere((h) => h.score < top * 0.4);
    }
    // höchstens 2 Abschnitte pro Seite, damit mehrere Quellen zu Wort kommen
    final perUrl = <String, int>{};
    final result = <KnowledgeHit>[];
    for (final h in hits) {
      final c = perUrl[h.chunk.url] = (perUrl[h.chunk.url] ?? 0) + 1;
      if (c <= 2) result.add(h);
      if (result.length >= k) break;
    }
    return result;
  }

  /// Kontextblock für den System-Prompt (RAG), begrenzt auf [maxChars].
  String contextFor(String query, {int k = 4, int maxChars = 3000}) {
    final hits = search(query, k: k);
    if (hits.isEmpty) return '';
    final b = StringBuffer('Auszüge aus der Wissensbasis des Nutzers (nutze sie, wenn sie zur Frage passen, '
        'und nenne die Quelle mit Adresse):\n');
    var used = 0;
    for (final (i, h) in hits.indexed) {
      final text = h.chunk.text.length > 1200 ? '${h.chunk.text.substring(0, 1200)} …' : h.chunk.text;
      final block = '\n[${i + 1}] ${h.chunk.title} – ${h.chunk.url}\n$text\n';
      if (used + block.length > maxChars) break;
      b.write(block);
      used += block.length;
    }
    return b.toString();
  }
}

// ---------------------------------------------------------------------------
// Webseiten laden
// ---------------------------------------------------------------------------

class FetchedPage {
  FetchedPage(this.url, this.title, this.text, this.links);
  final String url;
  final String title;
  final String text;
  final List<Uri> links;
}

/// Lädt eine Seite und extrahiert Titel, Haupttext und Links.
Future<FetchedPage> fetchPage(Uri uri, {Future<String> Function(Uri)? fetcher}) async {
  final html = await (fetcher ?? httpGetText)(uri);
  final titleM = RegExp(r'<title[^>]*>(.*?)</title>', dotAll: true, caseSensitive: false).firstMatch(html);
  final title = titleM == null ? uri.host : htmlToText(titleM.group(1)!);
  // Hauptinhalt bevorzugen, Navigation/Fußzeile entfernen
  var body = html;
  final main = RegExp(r'<(main|article)[^>]*>(.*?)</\1>', dotAll: true, caseSensitive: false).firstMatch(html);
  if (main != null && main.group(2)!.length > 500) body = main.group(2)!;
  body = body.replaceAll(
      RegExp(r'<(nav|footer|header|aside|form)[^>]*>.*?</\1>', dotAll: true, caseSensitive: false), ' ');
  final links = <Uri>[];
  for (final m in RegExp(r'''<a\s[^>]*href=["']([^"'#]+)''', caseSensitive: false).allMatches(html)) {
    final href = htmlDecode(m.group(1)!.trim());
    if (href.startsWith('mailto:') || href.startsWith('javascript:') || href.startsWith('tel:')) continue;
    final u = uri.resolve(href);
    if (u.isScheme('http') || u.isScheme('https')) links.add(u.removeFragment());
  }
  return FetchedPage(uri.toString(), title, htmlToText(body), links);
}

/// Lädt eine Seite und optional Unterseiten derselben Website (Breitensuche).
Future<List<FetchedPage>> crawlSite(
  Uri start, {
  bool followLinks = false,
  int maxPages = 30,
  void Function(int done, String url)? onProgress,
  Future<String> Function(Uri)? fetcher,
  bool Function()? cancelled,
}) async {
  final seen = <String>{};
  final queue = <Uri>[start];
  final pages = <FetchedPage>[];
  final skipExt = RegExp(r'\.(pdf|jpe?g|png|gif|svg|webp|zip|gz|mp4|mp3|css|js|xml|ico|woff2?)$', caseSensitive: false);
  // nur Pfade unterhalb des Startpfads
  final basePath = start.path.endsWith('/') ? start.path : start.path.substring(0, start.path.lastIndexOf('/') + 1);
  while (queue.isNotEmpty && pages.length < maxPages) {
    if (cancelled?.call() ?? false) break;
    final u = queue.removeAt(0);
    final key = u.replace(query: '').toString().replaceAll(RegExp(r'/$'), '');
    if (!seen.add(key)) continue;
    try {
      final p = await fetchPage(u, fetcher: fetcher);
      if (p.text.length > 80) pages.add(p);
      onProgress?.call(pages.length, u.toString());
      if (followLinks) {
        for (final l in p.links) {
          if (l.host == start.host && l.path.startsWith(basePath) && !skipExt.hasMatch(l.path)) {
            queue.add(l);
          }
        }
      }
    } catch (_) {
      if (pages.isEmpty && u == start) rethrow; // Startseite muss klappen
    }
  }
  return pages;
}
