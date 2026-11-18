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

/// Zerlegt in Sätze (max. ~300 Zeichen pro Stück, sehr kurze werden angehängt).
List<String> splitForSpeech(String text) {
  final parts = <String>[];
  for (final raw in text.split(RegExp(r'(?<=[.!?;:])\s+'))) {
    var p = raw.trim();
    if (p.isEmpty) continue;
    while (p.length > 300) {
      final cut = p.lastIndexOf(RegExp(r'[,\s]'), 300);
      final at = cut > 100 ? cut : 300;
      parts.add(p.substring(0, at).trim());
      p = p.substring(at).trim();
    }
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
    // nur bis zum letzten Satzende ausgeben (mind. 25 Zeichen, damit kurze Fragmente warten)
    final m = RegExp(r'[.!?;:](?=\s)').allMatches(rest).toList();
    if (m.isEmpty) return const [];
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
