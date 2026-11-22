// Hilfen für gesprochene Ausgabe: Markdown bereinigen und gestreamten Text
// satzweise an die Sprachausgabe weiterreichen.

String cleanForSpeech(String md) {
  var s = md.replaceAll(RegExp(r'```.*?```', dotAll: true), ' (Codeblock ausgelassen) ');
  s = s.replaceAll(RegExp(r'```.*$', dotAll: true), ' '); // unvollständiger Codeblock
  s = s.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m[1]!);
  s = s.replaceAllMapped(RegExp(r'https?://([^/\s]+)\S*'), (m) => m[1]!);
  s = s.replaceAll(RegExp(r'^\s*\|.*\|\s*$', multiLine: true), ' ');
  s = s.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
  s = s.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '');
  s = s.replaceAll(RegExp(r'[*_`>#]'), '');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Abkürzungen, nach deren Punkt kein Satz endet.
const _abbrev = {
  'z', 'b', 'bzw', 'ca', 'usw', 'etc', 'evtl', 'ggf', 'inkl', 'exkl', 'nr', 'dr', 'prof', 'st', 'hl', 'vgl', 'bspw', 'd', 'h', 'u', 'a',
  'o', 'ä', 'mio', 'mrd', 'tel', 'str', 'abs', 'art', 'max', 'min', 'mind', 'sog', 'zb', 'zt', 'ugs', 'jh', 'jhd', 'kap', 'bzgl', 'gem',
  'mag', 'ing', 'dipl', 'mr', 'mrs', 'vs', 'okt', 'nov', 'dez', 'jan', 'feb', 'aug', 'sept', 'sep',
};

/// Endet bei [i] (Satzzeichen) wirklich ein Satz? Nicht nach „z.“, „Dr.“, „3.“ (Ordnungszahl) usw.
bool _realEnd(String text, int i) {
  final ch = text[i];
  if (ch != '.') return true;
  var j = i - 1;
  while (j >= 0 && RegExp(r'[\p{L}\d]', unicode: true).hasMatch(text[j])) {
    j--;
  }
  final word = text.substring(j + 1, i);
  if (word.isEmpty) return true;
  if (RegExp(r'^\d+$').hasMatch(word)) {
    // „am 3. Mai“ (Ordnungszahl) – aber „… waren es 30.“ am Satzende: nur, wenn ein Wort klein weitergeht oder ein Monat folgt
    final after = text.substring(i + 1).trimLeft();
    if (after.isEmpty) return false; // beim Streamen: abwarten, was folgt
    final month = RegExp(r'^(januar|jänner|februar|märz|april|mai|juni|juli|august|september|oktober|november|dezember)\b')
        .hasMatch(after.toLowerCase());
    final lower = RegExp(r'^\p{Ll}', unicode: true).hasMatch(after);
    return !(month || lower);
  }
  return !_abbrev.contains(word.toLowerCase());
}

/// Zerlegt in Sätze (max. ~220 Zeichen pro Stück, sehr kurze werden angehängt).
List<String> splitForSpeech(String text) {
  final parts = <String>[];
  final raw = <String>[];
  var from = 0;
  for (final m in RegExp(r'[.!?;:](?=\s)').allMatches(text)) {
    if (!_realEnd(text, m.start)) continue;
    raw.add(text.substring(from, m.end));
    from = m.end;
  }
  if (from < text.length) raw.add(text.substring(from));
  for (final r in raw) {
    var p = r.trim();
    if (p.isEmpty) continue;
    while (p.length > 220) {
      final comma = p.lastIndexOf(RegExp(r'[,–—]\s'), 220);
      final space = p.lastIndexOf(' ', 220);
      final at = comma > 80 ? comma + 1 : (space > 80 ? space : 220);
      parts.add(p.substring(0, at).trim());
      p = p.substring(at).trim();
    }
    if (p.isEmpty) continue;
    if (parts.isNotEmpty && parts.last.length < 40) {
      parts[parts.length - 1] = '${parts.last} $p';
    } else {
      parts.add(p);
    }
  }
  return parts;
}

/// Nimmt wachsenden Antworttext entgegen und gibt fertige Sätze heraus,
/// sobald sie abgeschlossen sind – so kann das Vorlesen vor dem Ende beginnen.
class SentenceStreamer {
  int _consumed = 0; // Zeichen des bereinigten Texts, die schon ausgegeben wurden
  String _lastClean = '';

  /// Neue fertige Sätze seit dem letzten Aufruf. [done]: Antwort ist komplett.
  List<String> feed(String fullText, {bool done = false}) {
    final clean = cleanForSpeech(fullText);
    _lastClean = clean;
    if (clean.length <= _consumed) return const [];
    final rest = clean.substring(_consumed);
    if (done) {
      _consumed = clean.length;
      return splitForSpeech(rest);
    }
    // nur bis zum letzten echten Satzende ausgeben (mind. 25 Zeichen, damit kurze Fragmente warten)
    final m = [for (final x in RegExp(r'[.!?;:](?=\s)').allMatches(rest)) if (_realEnd(rest, x.start)) x];
    if (m.isEmpty) {
      // Erster Satz noch nicht fertig, aber lang genug: schon am Komma starten (schnellere erste Worte) …
      if (_consumed == 0 && rest.length >= 30) {
        final c = RegExp(r'[,–—](?=\s)').allMatches(rest).where((x) => x.end >= 18).firstOrNull;
        if (c != null) {
          _consumed += c.end;
          return splitForSpeech(rest.substring(0, c.end));
        }
        // … oder bei sehr langem Satz ohne Komma an einer Wortgrenze
        if (rest.length >= 110) {
          final sp = rest.lastIndexOf(' ', 90);
          if (sp > 40) {
            _consumed += sp;
            return splitForSpeech(rest.substring(0, sp));
          }
        }
      }
      return const [];
    }
    final end = m.last.end;
    if (end < 25) return const [];
    _consumed += end;
    return splitForSpeech(rest.substring(0, end));
  }

  /// Bisher bereits gesprochener (ausgegebener) Text.
  String get spokenSoFar => _lastClean.substring(0, _consumed.clamp(0, _lastClean.length));

  void reset() {
    _consumed = 0;
    _lastClean = '';
  }
}

// ------------------------------------------------------------------ Aussprache

const _units = <String, String>{
  'km/h': 'Kilometer pro Stunde',
  'km': 'Kilometer',
  'm²': 'Quadratmeter',
  'qm': 'Quadratmeter',
  'kg': 'Kilo',
  'mm': 'Millimeter',
  'cm': 'Zentimeter',
  'ml': 'Milliliter',
  'kWh': 'Kilowattstunden',
  'kW': 'Kilowatt',
  'GB': 'Gigabyte',
  'MB': 'Megabyte',
  'TB': 'Terabyte',
  'min': 'Minuten',
  'Std': 'Stunden',
  'Mio': 'Millionen',
  'Mrd': 'Milliarden',
};

const _abbrevSpoken = <String, String>{
  r'z\.\s?B\.': 'zum Beispiel',
  r'd\.\s?h\.': 'das heißt',
  r'u\.\s?a\.': 'unter anderem',
  r'o\.\s?ä\.': 'oder Ähnliches',
  r'u\.\s?U\.': 'unter Umständen',
  r'bzw\.': 'beziehungsweise',
  r'usw\.': 'und so weiter',
  r'etc\.': 'et cetera',
  r'ca\.': 'circa',
  r'evtl\.': 'eventuell',
  r'ggf\.': 'gegebenenfalls',
  r'inkl\.': 'inklusive',
  r'vgl\.': 'vergleiche',
  r'bspw\.': 'beispielsweise',
  r'bzgl\.': 'bezüglich',
  r'Nr\.': 'Nummer',
  r'Dr\.': 'Doktor',
  r'Prof\.': 'Professor',
  r'Str\.': 'Straße',
  r'max\.': 'maximal',
  r'mind\.': 'mindestens',
  r'sog\.': 'sogenannte',
};

/// Macht einen Satz für die Sprachausgabe (espeak/Piper/Kokoro) gut aussprechbar:
/// Abkürzungen, Einheiten, Uhrzeiten, Zeichen, Emojis.
String normalizeForSpeech(String s, {String language = 'de'}) {
  var t = s;
  // Emojis und Bildzeichen entfernen
  t = t.replaceAll(RegExp(r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}]', unicode: true), '');
  t = t.replaceAll(RegExp(r'[•·▪►→←↑↓✓✔✗✘]'), ', ');
  if (language != 'en') {
    for (final e in _abbrevSpoken.entries) {
      t = t.replaceAll(RegExp('(?<![\\p{L}])${e.key}', unicode: true), e.value);
    }
    // Uhrzeiten: 14:30 → 14 Uhr 30, 9:00 Uhr → 9 Uhr
    t = t.replaceAllMapped(RegExp(r'\b([01]?\d|2[0-3])[:.]([0-5]\d)(\s*Uhr)?\b'), (m) {
      final min = int.parse(m.group(2)!);
      return '${int.parse(m.group(1)!)} Uhr${min == 0 ? '' : ' $min'}';
    });
    // Temperaturen, Prozent, Währung
    t = t.replaceAllMapped(RegExp(r'(-?\d+(?:[.,]\d+)?)\s?°\s?C\b'), (m) => '${m.group(1)!.replaceFirst('-', 'minus ')} Grad');
    t = t.replaceAll(RegExp(r'°'), ' Grad');
    t = t.replaceAllMapped(RegExp(r'(\d)\s?%'), (m) => '${m.group(1)} Prozent');
    t = t.replaceAllMapped(RegExp(r'€\s?(\d+(?:[.,]\d+)?)'), (m) => '${m.group(1)} Euro');
    t = t.replaceAllMapped(RegExp(r'(\d)\s?€'), (m) => '${m.group(1)} Euro');
    t = t.replaceAllMapped(RegExp(r'\$\s?(\d+(?:[.,]\d+)?)'), (m) => '${m.group(1)} Dollar');
    // Spannen: 3–5 → 3 bis 5
    t = t.replaceAllMapped(RegExp(r'(\d)\s?[–-]\s?(\d)'), (m) => '${m.group(1)} bis ${m.group(2)}');
    // Einheiten nach Zahlen
    for (final e in _units.entries) {
      t = t.replaceAllMapped(RegExp('(\\d)\\s?${RegExp.escape(e.key)}(?![\\p{L}])', unicode: true), (m) => '${m.group(1)} ${e.value}');
    }
    t = t.replaceAll('&', ' und ');
  } else {
    t = t.replaceAll('&', ' and ');
  }
  // Klammern als kurze Pause, Schrägstriche zwischen Wörtern als „oder“
  t = t.replaceAll(RegExp(r'\s*[()\[\]]\s*'), ', ');
  t = t.replaceAllMapped(RegExp(r'(\p{L})/(\p{L})', unicode: true), (m) => '${m.group(1)} ${language == 'en' ? 'or' : 'oder'} ${m.group(2)}');
  t = t.replaceAll(RegExp(r'["„“”«»]'), '');
  t = t.replaceAll(RegExp(r'\s*,\s*(,\s*)+'), ', ').replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'^[,\s]+'), '').trim();
  return t;
}
