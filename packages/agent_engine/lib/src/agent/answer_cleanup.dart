// Antworttext aufräumen: wiederholte Frage und „lautes Denken“ am Anfang entfernen.

import 'dart:math' as math;

final _metaStart = RegExp(
    r'^(thought\b|der (nutzer|benutzer|user)\b|die (nutzerin|benutzerin)\b|du fragst|du hast gefragt|du möchtest wissen|'
    r'du willst wissen|sie fragen|sie haben gefragt|sie möchten wissen|die frage (ist|lautet|war)|deine frage|ihre frage|'
    r'zu deiner frage|zu ihrer frage|ich soll\b|ich sollte\b|ich muss (jetzt )?(die|eine|kurz)|lass mich|okay[,.! ]|ok[,.! ]|'
    r'alles klar[,.! ]|hmm|gut[,.] ich|also[,] (der|die) (nutzer|frage)|die antwort (ist|lautet)\s*:?\s*$)',
    caseSensitive: false);

Set<String> _words(String t) => {
      for (final w in t.toLowerCase().split(RegExp(r'[^\p{L}\d]+', unicode: true)))
        if (w.length > 2) w,
    };

/// Wiederholt der Satz nur die Frage oder ist es lautes Denken?
bool looksLikePreamble(String sentence, String question) {
  final s = sentence.trim().replaceFirst(RegExp(r'^[*_#>\s]+'), '');
  if (_metaStart.hasMatch(s)) return true;
  final q = _words(question), w = _words(s);
  if (q.length < 3 || w.isEmpty) return false;
  final overlap = w.intersection(q).length;
  // fast nur Wörter der Frage, z. B. „Wie wird das Wetter morgen in Wien?“ → „Das Wetter morgen in Wien.“
  return overlap >= q.length * 0.6 && overlap >= w.length * 0.7;
}

/// Antwort ohne Vorspann. null = noch warten (der erste Satz ist noch unklar), nur solange [done] false ist.
String? stripAnswerPreamble(String full, String question, {bool done = true}) {
  var cut = 0;
  while (true) {
    final rest = full.substring(math.min(cut, full.length));
    final lead = rest.trimLeft();
    final skip = rest.length - lead.length;
    if (RegExp(r'^thought\b', caseSensitive: false).hasMatch(lead)) {
      final nl = lead.indexOf('\n');
      if (nl < 0) {
        if (!done) return null;
        break;
      }
      cut += skip + nl + 1;
      continue;
    }
    final m = RegExp(r'^[^.!?\n]*[.!?:\n]+(?=\s|$)').firstMatch(lead);
    if (m == null) {
      final words = lead.split(RegExp(r'\s+')).where((x) => x.isNotEmpty).length;
      if (!done && (words < 5 || _metaStart.hasMatch(lead))) return null;
      break;
    }
    final sentence = m.group(0)!;
    if (looksLikePreamble(sentence, question)) {
      if (lead.substring(sentence.length).trim().isNotEmpty) {
        cut += skip + sentence.length;
        continue;
      }
      if (!done) return null;
    }
    break;
  }
  return full.substring(math.min(cut, full.length)).trimLeft();
}
