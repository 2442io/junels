// Feste Werkzeuge mit verlässlichen Quellen: Wetter (Open-Meteo) und Nachrichten (RSS
// ausgewählter Redaktionen) – statt unsicherer Suchtreffer.

import 'dart:convert';

import 'network_tools.dart';
import 'tool.dart';

// ------------------------------------------------------------------ Wetter

const _wmo = <int, String>{
  0: 'klar', 1: 'überwiegend klar', 2: 'teils bewölkt', 3: 'bedeckt', 45: 'Nebel', 48: 'Raureif-Nebel',
  51: 'leichter Niesel', 53: 'Nieselregen', 55: 'starker Niesel', 56: 'gefrierender Niesel', 57: 'gefrierender Niesel',
  61: 'leichter Regen', 63: 'Regen', 65: 'starker Regen', 66: 'gefrierender Regen', 67: 'gefrierender Regen',
  71: 'leichter Schneefall', 73: 'Schneefall', 75: 'starker Schneefall', 77: 'Schneegriesel',
  80: 'leichte Regenschauer', 81: 'Regenschauer', 82: 'heftige Regenschauer', 85: 'Schneeschauer', 86: 'starke Schneeschauer',
  95: 'Gewitter', 96: 'Gewitter mit Hagel', 99: 'schweres Gewitter mit Hagel',
};

String weatherText(int? code) => _wmo[code] ?? 'unbekannt';

class WeatherTool extends AgentTool {
  WeatherTool({this.fetcher = httpGetText, String Function()? defaultLocation})
      : _defaultLocation = defaultLocation ?? (() => '');
  final Future<String> Function(Uri) fetcher;
  final String Function() _defaultLocation;

  @override
  String get name => 'weather';
  @override
  String get title => 'Wetter';
  @override
  String get keywords => 'wetter regen temperatur grad schnee sonne wind vorhersage schirm';
  @override
  String get description => 'Aktuelles Wetter und Vorhersage (Open-Meteo, verlässliche Messdaten) für einen Ort. '
      'location leer = Heimatort des Nutzers.';
  @override
  bool get requiresNetwork => true;
  @override
  List<ToolParam> get params => const [
        ToolParam('location', ParamType.string, 'Ort, z. B. "Wien" (leer = Heimatort)'),
        ToolParam('days', ParamType.integer, 'Tage Vorhersage, 1–7'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    var loc = (args['location'] ?? '').toString().trim();
    if (loc.isEmpty) loc = _defaultLocation().trim();
    if (loc.isEmpty) throw ToolException('Kein Ort angegeben und kein Heimatort eingestellt – frag nach dem Ort.');
    final days = (int.tryParse('${args['days'] ?? 3}') ?? 3).clamp(1, 7);
    await ctx.ensureNetwork('Wetter für „$loc“ abrufen (Open-Meteo)');
    final geo = jsonDecode(await fetcher(Uri.https('geocoding-api.open-meteo.com', '/v1/search',
        {'name': loc, 'count': '1', 'language': 'de', 'format': 'json'}))) as Map<String, dynamic>;
    final r = (geo['results'] as List?)?.cast<Map<String, dynamic>>();
    if (r == null || r.isEmpty) return 'Ort „$loc“ nicht gefunden.';
    final place = r.first;
    final w = jsonDecode(await fetcher(Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': '${place['latitude']}',
      'longitude': '${place['longitude']}',
      'current': 'temperature_2m,apparent_temperature,weather_code,wind_speed_10m,precipitation,relative_humidity_2m',
      'daily': 'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,sunrise,sunset',
      'timezone': 'auto',
      'forecast_days': '$days',
    }))) as Map<String, dynamic>;
    return formatWeather(place, w);
  }

  static String formatWeather(Map<String, dynamic> place, Map<String, dynamic> w) {
    String n(Object? v) => v == null ? '–' : (v as num).round().toString();
    final b = StringBuffer('Wetter für ${place['name']}${place['admin1'] != null ? ', ${place['admin1']}' : ''}'
        '${place['country'] != null ? ' (${place['country']})' : ''} – Quelle: Open-Meteo (open-meteo.com)\n');
    final c = w['current'] as Map<String, dynamic>?;
    if (c != null) {
      b.writeln('Jetzt: ${n(c['temperature_2m'])} °C (gefühlt ${n(c['apparent_temperature'])} °C), '
          '${weatherText((c['weather_code'] as num?)?.toInt())}, Wind ${n(c['wind_speed_10m'])} km/h, '
          'Luftfeuchte ${n(c['relative_humidity_2m'])} %');
    }
    final d = w['daily'] as Map<String, dynamic>?;
    if (d != null) {
      const wd = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
      final dates = (d['time'] as List).cast<String>();
      for (var i = 0; i < dates.length; i++) {
        final dt = DateTime.tryParse(dates[i]);
        final label = i == 0 ? 'Heute' : i == 1 ? 'Morgen' : dt == null ? dates[i] : '${wd[dt.weekday - 1]} ${dt.day}.${dt.month}.';
        b.writeln('$label: ${weatherText((d['weather_code'][i] as num?)?.toInt())}, '
            '${n(d['temperature_2m_min'][i])} bis ${n(d['temperature_2m_max'][i])} °C, '
            'Regenrisiko ${n(d['precipitation_probability_max'][i])} % (${(d['precipitation_sum'][i] as num?)?.toStringAsFixed(1) ?? '0'} mm)'
            '${i == 0 ? ', Sonne ${(d['sunrise'][i] as String).substring(11)}–${(d['sunset'][i] as String).substring(11)}' : ''}');
      }
    }
    return b.toString().trim();
  }
}

// ------------------------------------------------------------------ Nachrichten

class NewsSource {
  const NewsSource(this.id, this.name, this.url, {this.tech = false});
  final String id;
  final String name;
  final String url;
  final bool tech;
}

const newsSources = <NewsSource>[
  NewsSource('orf', 'ORF', 'https://rss.orf.at/news.xml'),
  NewsSource('derstandard', 'Der Standard', 'https://www.derstandard.at/rss'),
  NewsSource('tagesschau', 'tagesschau', 'https://www.tagesschau.de/xml/rss2/'),
  NewsSource('futurezone', 'futurezone', 'https://futurezone.at/xml/rss', tech: true),
  NewsSource('heise', 'heise online', 'https://www.heise.de/rss/heise-atom.xml', tech: true),
  NewsSource('golem', 'Golem', 'https://rss.golem.de/rss.php?feed=RSS2.0', tech: true),
];

final _techTopic = RegExp(r'\b(ki|ai|it|tech\w*|digital\w*|computer|software|internet|smartphone|handy|apple|google|'
    r'microsoft|openai|chatgpt|künstliche intelligenz|cyber\w*|startup\w*|krypto\w*|game\w*)\b', caseSensitive: false);

/// Suchwörter für ein Thema (mit Synonymen für KI).
List<String> topicWords(String topic) {
  final t = topic.toLowerCase().trim();
  if (t.isEmpty) return const [];
  if (RegExp(r'^(ki|ai|künstliche intelligenz|artificial intelligence)$').hasMatch(t)) {
    return const ['ki', 'künstliche intelligenz', 'ai', 'openai', 'chatgpt', 'gpt', 'llm', 'sprachmodell', 'gemini',
        'claude', 'anthropic', 'copilot', 'deepseek', 'mistral', 'machine learning', 'nvidia'];
  }
  return t.split(RegExp(r'\s*(,|oder|und|/)\s*|\s+')).where((w) => w.length >= 2).toList();
}

bool matchesTopic(String text, List<String> words) {
  if (words.isEmpty) return true;
  final s = ' ${text.toLowerCase()} ';
  return words.any((w) => w.length <= 3 ? RegExp('(^|[^a-zäöüß])${RegExp.escape(w)}([^a-zäöüß]|\$)').hasMatch(s) : s.contains(w));
}

class NewsTool extends AgentTool {
  NewsTool({this.fetcher = httpGetText});
  final Future<String> Function(Uri) fetcher;

  @override
  String get name => 'news';
  @override
  String get title => 'Nachrichten';
  @override
  String get keywords => 'news nachrichten schlagzeilen neuigkeiten aktuell meldungen';
  @override
  String get description => 'Aktuelle Nachrichten aus verlässlichen Redaktionen (ORF, Der Standard, tagesschau, '
      'futurezone, heise, Golem) – optional zu einem Thema. Liefert Titel, Link, Bild und Kurztext.';
  @override
  bool get requiresNetwork => true;
  @override
  List<ToolParam> get params => [
        const ToolParam('topic', ParamType.string, 'Thema, z. B. "KI", "Wirtschaft" (leer = Top-Meldungen)'),
        ToolParam('source', ParamType.enumeration, 'Quelle', values: ['auto', for (final s in newsSources) s.id]),
        const ToolParam('count', ParamType.integer, 'Anzahl Meldungen, 1–10'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final topic = (args['topic'] ?? '').toString().trim();
    final src = (args['source'] ?? 'auto').toString();
    final count = (int.tryParse('${args['count'] ?? 6}') ?? 6).clamp(1, 10);
    final tech = _techTopic.hasMatch(topic);
    final sources = src != 'auto' && newsSources.any((s) => s.id == src)
        ? newsSources.where((s) => s.id == src).toList()
        : tech
            ? newsSources.where((s) => s.tech).toList()
            : newsSources.where((s) => s.id == 'orf' || s.id == 'derstandard').toList();
    await ctx.ensureNetwork('Nachrichten${topic.isEmpty ? '' : ' zu „$topic“'} von ${sources.map((s) => s.name).join(', ')} abrufen');
    final words = topicWords(topic);
    final all = <(NewsSource, PageItem)>[];
    final errors = <String>[];
    for (final s in sources) {
      try {
        final items = extractFeedItems(await fetcher(Uri.parse(s.url)), Uri.parse(s.url));
        for (final i in items.take(40)) {
          all.add((s, i));
        }
      } catch (e) {
        errors.add('${s.name}: $e');
      }
    }
    if (all.isEmpty) return 'Keine Nachrichten abrufbar. ${errors.join('; ')}';
    var hits = [for (final x in all) if (matchesTopic('${x.$2.title} ${x.$2.summary}', words)) x];
    var note = '';
    if (hits.isEmpty) {
      note = 'Zu „$topic“ gibt es gerade keine Meldung – hier die neuesten allgemein:\n';
      hits = all;
    }
    // abwechselnd aus den Quellen
    final bySource = <String, List<(NewsSource, PageItem)>>{};
    for (final h in hits) {
      (bySource[h.$1.id] ??= []).add(h);
    }
    final picked = <(NewsSource, PageItem)>[];
    for (var i = 0; picked.length < count && bySource.values.any((l) => l.length > i); i++) {
      for (final l in bySource.values) {
        if (l.length > i && picked.length < count) picked.add(l[i]);
      }
    }
    final b = StringBuffer(note);
    b.writeln('Nachrichten${topic.isEmpty ? '' : ' zu „$topic“'} (Quellen: ${sources.map((s) => s.name).join(', ')}):');
    for (final (s, i) in picked) {
      b.writeln('- ${i.title} (${s.name}${i.date.isEmpty ? '' : ', ${i.date}'})');
      if (i.link.isNotEmpty) b.writeln('  Link: ${i.link}');
      if (i.image.isNotEmpty) b.writeln('  Bild: ${i.image}');
      if (i.summary.isNotEmpty) b.writeln('  ${i.summary}');
    }
    b.writeln('\nIn der Antwort je Meldung: Titel, darunter ggf. "![Titel](Bild-URL)", dann "[Zum Artikel](Link)".');
    return b.toString().trim();
  }
}
