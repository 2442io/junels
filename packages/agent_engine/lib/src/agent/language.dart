// Sprache einer Nachricht grob erkennen (Füllwörter zählen) – damit der Agent in der
// Sprache des Nutzers antwortet, auch wenn System-Prompt und Werkzeuge deutsch sind.

const _stop = <String, Set<String>>{
  'de': {'der', 'die', 'das', 'und', 'ist', 'nicht', 'ich', 'du', 'wie', 'was', 'mit', 'für', 'auf', 'ein', 'eine', 'von', 'zu', 'im', 'mir', 'bitte', 'aktuellen', 'nach', 'wo', 'wer', 'warum', 'kannst', 'gibt'},
  'en': {'the', 'and', 'is', 'are', 'what', 'how', 'you', 'for', 'of', 'to', 'in', 'on', 'with', 'please', 'can', 'my', 'from', 'current', 'find', 'show', 'which', 'where', 'why', 'flights', 'price', 'prices'},
  'fr': {'le', 'la', 'les', 'des', 'de', 'du', 'et', 'est', 'sont', 'pour', 'quels', 'quelles', 'quel', 'quelle', 'sur', 'vous', 'je', 'une', 'un', 'dans', 'avec', 'regarde', 'actuels', 'vols', 'tarifs', 'à', 'au', 'peux', 'moi', "c'est"},
  'it': {'il', 'lo', 'gli', 'della', 'delle', 'e', 'è', 'sono', 'per', 'che', 'come', 'quali', 'quale', 'cerca', 'voli', 'prezzi', 'di', 'da', 'con', 'una', 'un', 'puoi'},
  'es': {'el', 'los', 'las', 'del', 'y', 'es', 'son', 'para', 'que', 'cómo', 'cuáles', 'cuál', 'busca', 'vuelos', 'precios', 'de', 'desde', 'con', 'una', 'un', 'puedes', 'por'},
};

/// 'de' | 'en' | 'fr' | 'it' | 'es' oder null (zu kurz/unklar).
String? detectLanguage(String text) {
  final words = text.toLowerCase().split(RegExp(r"[^\p{L}']+", unicode: true)).where((w) => w.isNotEmpty).toList();
  if (words.length < 3) return null;
  final score = <String, int>{for (final k in _stop.keys) k: 0};
  for (final w in words) {
    for (final e in _stop.entries) {
      if (e.value.contains(w)) score[e.key] = score[e.key]! + 1;
    }
  }
  // Umlaute/ß sprechen fürs Deutsche, Akzente für Romanisches
  if (RegExp(r'[äöüß]').hasMatch(text.toLowerCase())) score['de'] = score['de']! + 2;
  if (RegExp(r'[éèêàçù]').hasMatch(text.toLowerCase())) score['fr'] = score['fr']! + 1;
  if (RegExp(r'[ñ¿¡]').hasMatch(text.toLowerCase())) score['es'] = score['es']! + 2;
  final best = score.entries.reduce((a, b) => b.value > a.value ? b : a);
  final second = score.entries.where((e) => e.key != best.key).fold(0, (m, e) => e.value > m ? e.value : m);
  if (best.value < 2 || best.value - second < 1) return null;
  return best.key;
}

/// Anweisung an das Modell, in dieser Sprache zu antworten.
String languageHint(String lang) => switch (lang) {
      'fr' => 'Réponds en français. (Antworte auf Französisch.)',
      'en' => 'Answer in English. (Antworte auf Englisch.)',
      'it' => 'Rispondi in italiano. (Antworte auf Italienisch.)',
      'es' => 'Responde en español. (Antworte auf Spanisch.)',
      _ => 'Antworte auf Deutsch.',
    };
