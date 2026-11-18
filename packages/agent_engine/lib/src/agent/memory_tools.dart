// Gedächtnis- und Wissens-Tools. Die Daten liegen in der App; die Tools
// bekommen nur Funktionen zum Lesen/Schreiben.

import '../knowledge.dart';
import 'tool.dart';

/// Langfristige Notiz über den Nutzer speichern.
class RememberTool extends AgentTool {
  RememberTool(this.save);
  final Future<void> Function(String fact) save;

  @override
  String get name => 'remember';
  @override
  String get title => 'Merken';
  @override
  String get description =>
      'Speichert dauerhaft eine wichtige Information über den Nutzer (Vorlieben, Fakten, Absprachen) für spätere Gespräche.';
  @override
  List<ToolParam> get params => const [ToolParam('fact', ParamType.string, 'kurzer Satz, was gemerkt werden soll')];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final f = (args['fact'] ?? '').toString().trim();
    if (f.length < 3) throw ToolException('fact ist leer');
    await save(f);
    return 'Gemerkt: $f';
  }
}

/// Durchsucht frühere Gespräche (Text- und Sprachchats).
class HistorySearchTool extends AgentTool {
  HistorySearchTool(this.search);
  final List<String> Function(String query) search;

  @override
  String get name => 'search_history';
  @override
  String get title => 'Frühere Gespräche';
  @override
  String get description => 'Durchsucht frühere Gespräche mit dem Nutzer nach einem Thema.';
  @override
  List<ToolParam> get params => const [ToolParam('query', ParamType.string, 'Suchbegriffe')];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final q = (args['query'] ?? '').toString().trim();
    if (q.isEmpty) throw ToolException('query ist leer');
    final hits = search(q);
    return hits.isEmpty ? 'Nichts zu "$q" in früheren Gesprächen gefunden.' : hits.take(6).join('\n---\n');
  }
}

/// Gezielte Suche in der Wissensbasis (zusätzlich zur automatischen Einbindung).
class KnowledgeSearchTool extends AgentTool {
  KnowledgeSearchTool(this.kb);
  final KnowledgeBase kb;

  @override
  String get name => 'knowledge_search';
  @override
  String get title => 'Wissensbasis';
  @override
  String get description => 'Durchsucht die vom Nutzer hinterlegten Webseiten und Dokumente.';
  @override
  List<ToolParam> get params => const [ToolParam('query', ParamType.string, 'Suchbegriffe')];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final q = (args['query'] ?? '').toString().trim();
    if (kb.isEmpty) return 'Die Wissensbasis ist leer.';
    final hits = kb.search(q, k: 5, minScore: 0.2);
    if (hits.isEmpty) return 'Keine passenden Abschnitte zu "$q".';
    return [
      for (final h in hits)
        '${h.chunk.title} – ${h.chunk.url}\n${h.chunk.text.length > 900 ? '${h.chunk.text.substring(0, 900)} …' : h.chunk.text}'
    ].join('\n---\n');
  }
}

/// Einfache Suche über Gesprächsverläufe (für HistorySearchTool).
/// [conversations]: (Titel, Datum, Liste von (Rolle, Text)).
List<String> searchConversations(
  String query,
  Iterable<({String title, DateTime date, List<({String role, String text})> messages})> conversations, {
  String? excludeTitle,
}) {
  final q = knowledgeTokens(query).toSet();
  if (q.isEmpty) return [];
  final scored = <(double, String)>[];
  for (final c in conversations) {
    for (var i = 0; i < c.messages.length; i++) {
      final m = c.messages[i];
      final toks = knowledgeTokens(m.text);
      if (toks.isEmpty) continue;
      final hit = toks.where(q.contains).length;
      if (hit == 0) continue;
      final score = hit / (1 + toks.length / 50);
      // Frage und Antwort zusammen zeigen
      final pair = StringBuffer('${c.date.day}.${c.date.month}.${c.date.year} „${c.title}“\n');
      final from = m.role == 'assistant' && i > 0 ? i - 1 : i;
      for (var j = from; j <= from + 1 && j < c.messages.length; j++) {
        final t = c.messages[j].text;
        pair.writeln('${c.messages[j].role == 'user' ? 'Nutzer' : 'Agent'}: ${t.length > 400 ? '${t.substring(0, 400)} …' : t}');
      }
      scored.add((score, pair.toString().trim()));
    }
  }
  scored.sort((a, b) => b.$1.compareTo(a.$1));
  final seen = <String>{};
  return [for (final s in scored) if (seen.add(s.$2)) s.$2];
}
