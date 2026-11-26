// Antworttext aufräumen: wiederholte Frage und „lautes Denken“ am Anfang entfernen.

import 'dart:math' as math;

final _metaStart = RegExp(
    r'^(thought\b|der (nutzer|benutzer|user)\b|die (nutzerin|benutzerin)\b|du fragst|du hast gefragt|du möchtest wissen|'
    r'du willst wissen|sie fragen|sie haben gefragt|sie möchten wissen|die frage (ist|lautet|war)|deine frage|ihre frage|'
    r'zu deiner frage|zu ihrer frage|ich soll\b|ich sollte\b|ich muss (jetzt )?(die|eine|kurz)|lass mich|okay[,.! ]|ok[,.! ]|'
    r'alles klar[,.! ]|hmm|gut[,.] ich|also[,] (der|die) (nutzer|frage)|die antwort (ist|lautet)\s*:?\s*$)',
    caseSensitive: false);

/// Sätze, die über die Frage, die eigenen Anweisungen oder den Kontext reden statt zu antworten
/// („… basierend auf dem Kontext, den ich habe“, „Da die Frage keinen klaren Bezug hat, werde ich versuchen …“).
final _metaAny = RegExp(
    r'basierend auf (dem|meinem) (kontext|wissen|verfügbaren)|auf grundlage (des|meines) (kontext|wissens)|'
    r'(den|dem) kontext,? (den|der) ich (habe|kenne)|keinen (klaren |direkten )?bezug|wahrscheinlichste interpretation|'
    r'(meine[rn]?|den|die) (anweisungen|vorgaben|systemanweisung|instruktionen)|gesprächsmodus|vorgelesen wird|'
    r'(ich werde|ich versuche|ich will) (versuchen,? )?(die frage|deine frage|ihre frage|eine (kurze |passende |neutrale )?antwort|zu antworten|das zu beantworten)|'
    r'^da (die|deine|ihre) frage|^um (die|deine|ihre|diese) frage zu beantworten|^(die|deine|ihre) frage (scheint|ist (etwas )?unklar|ergibt)|'
    r'^es scheint,? (als|dass) (ob )?(die|deine|ihre|du|sie)|^ich interpretiere|^als (ki|sprachmodell|ki-assistent|assistent)\b|'
    r'^hier (ist|kommt) (meine|die) antwort|^(meine )?antwort\s*:',
    caseSensitive: false);

Set<String> _words(String t) => {
      for (final w in t.toLowerCase().split(RegExp(r'[^\p{L}\d]+', unicode: true)))
        if (w.length > 2) w,
    };

/// Wiederholt der Satz nur die Frage oder ist es lautes Denken?
bool looksLikePreamble(String sentence, String question) {
  final s = sentence.trim().replaceFirst(RegExp(r'^[*_#>\s]+'), '');
  if (_metaStart.hasMatch(s) || _metaAny.hasMatch(s)) return true;
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

/// Besteht der Text nur aus Vorspann/Meta-Sätzen (keine eigentliche Antwort)?
bool onlyPreamble(String text, String question) {
  final sentences = RegExp(r'[^.!?\n]+[.!?\n]*').allMatches(text.trim()).map((m) => m.group(0)!.trim()).where((x) => x.length > 2).toList();
  return sentences.isNotEmpty && sentences.every((x) => looksLikePreamble(x, question));
}

/// Was der Sprachmodus sagt, wenn das Modell nur über die Frage redet (z. B. weil die Spracherkennung sich verhört hat)
const voiceNotUnderstood = 'Das habe ich leider nicht richtig verstanden. Kannst du es noch einmal sagen?';

// ------------------------------------------------------------------ Reaktionen statt Antworten

final _emojiOnly = RegExp(
    r'^(?:\p{Extended_Pictographic}(?:️|‍\p{Extended_Pictographic}|\p{Emoji_Modifier})*\s*){1,3}$',
    unicode: true);
final _leadEmoji =
    RegExp(r'^((?:\p{Extended_Pictographic}(?:️|‍\p{Extended_Pictographic}|\p{Emoji_Modifier})*){1,3})\s*', unicode: true);
final _ackWords = RegExp(
    r'^(alles klar|alles klar,? (ich )?(hab|habe) (es|das|dir das|mir das) (mir )?(gemerkt|notiert)|gemerkt|notiert|verstanden|ok(ay)?|'
    r'danke( dir)?( für die info)?|super|passt|gut zu wissen|(ich )?(hab|habe) (es|das) (mir )?(gemerkt|notiert)|'
    r'(ist )?(gemerkt|notiert)|got it|noted)[\s.!]*$',
    caseSensitive: false);

/// Antwort ist nur eine Reaktion (👍, „👍 Notiert.“, bei einer Mitteilung auch „Alles klar.“) → das Emoji, sonst null.
String? reactionOf(String answer, {bool infoGiven = false}) {
  final t = answer.replaceAll(RegExp(r'[*_]'), '').trim();
  if (t.isEmpty || t.length > 80) return null;
  if (_emojiOnly.hasMatch(t)) return t.replaceAll(RegExp(r'\s+'), '');
  final m = _leadEmoji.firstMatch(t);
  if (m != null && _ackWords.hasMatch(t.substring(m.end).trim())) return m.group(1);
  if (infoGiven && _ackWords.hasMatch(t)) return '👍';
  return null;
}

/// Kurze Bestätigung/Dank („danke“, „ok“, „passt“, „super“) – braucht keine Antwort, nur eine Reaktion.
String? ackReaction(String input) {
  final t = input.trim().toLowerCase().replaceAll(RegExp(r'[\s.!]+$'), '');
  if (t.isEmpty || t.length > 40) return null;
  if (RegExp(r'^(danke|dankeschön|danke schön|vielen dank|danke dir|thx|thanks|merci)( dir| sehr| vielmals| für (die|deine) hilfe)?( ?[🙏😊👍]+)?$').hasMatch(t)) {
    return '🙏';
  }
  if (RegExp(r'^(ok|okay|oki|passt|super|perfekt|top|cool|alles klar|gut|sehr gut|prima|klasse|genial|toll|👍|👌)( danke)?$').hasMatch(t)) {
    return '👍';
  }
  return null;
}

final _askOrTask = RegExp(
    r'\?|\bbitte\b|\b(kannst|könntest|kann|könnte|würdest|sollst|soll|sollte|magst|hilf|hilfst|weißt)\b|'
    r'^(was|wie|wo|wohin|woher|wann|wer|wen|wem|warum|wieso|weshalb|welche[rsmn]?|ob)\b|'
    r'\b(erstell|schreib|such|find|zeig|sag|erklär|gib|öffne|spiel|plan|rechne|übersetz|fass|lies|schick|send|buch|bestell|'
    r'recherchier|vergleich|prüf|check|mach|hol|starte|stopp|lösch|erinnere mich)\w*\b.*\b(mir|mich|uns|du)\b|'
    r'\bich (möchte|will|würde gern|hätte gern|brauche|suche|frage mich|weiß nicht)\b|'
    r'\b(problem|fehler|kaputt|geht nicht|funktioniert nicht|hilfe|weiß nicht wie|keine ahnung)\b|'
    r'https?://|^/',
    caseSensitive: false);
final _statementStart = RegExp(
    r'^(ich|mein\w*|wir|unser\w*|übrigens|zur info|nur zur info|nur so|fyi|info:|notiz:|merk dir|merke dir|'
    r'heute|morgen|übermorgen|gestern|nächste woche|diese woche|am (montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|wochenende)|'
    r'ab (jetzt|sofort|morgen|montag|nächster woche))\b',
    caseSensitive: false);

/// Reine Mitteilung („Ich bin morgen im Büro“, „Mein Zahnarzttermin ist am Freitag“, „Merk dir: …“) –
/// keine Frage, kein Auftrag. Bewusst vorsichtig: im Zweifel false.
bool isInfoOnly(String input) {
  final t = input.trim();
  if (t.length < 8 || t.length > 400 || t.contains('\n\n')) return false;
  if (_askOrTask.hasMatch(t)) {
    // „Merk dir …“ ist immer eine Mitteilung, auch wenn darin „du“ vorkommt
    if (!RegExp(r'^(merk|merke) (dir|es dir)', caseSensitive: false).hasMatch(t) || t.contains('?')) return false;
  }
  return _statementStart.hasMatch(t);
}
