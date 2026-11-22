// Automatische Modellwahl: einfache Anfragen beantwortet das kleine, schnelle Modell,
// komplexe das größere. Die Einschätzung kommt ohne zusätzliches Modell aus (Regeln,
// < 1 ms), damit sie nichts kostet. Dazu ein Speicherplan: beide Modelle geladen lassen,
// wenn genug Arbeitsspeicher da ist – sonst bei Bedarf wechseln.

import 'device_profile.dart';
import 'gguf_header.dart';

enum TaskLevel { simple, complex }

class TaskAssessment {
  const TaskAssessment(this.level, this.score, this.reasons);
  final TaskLevel level;
  final int score;
  final List<String> reasons;
  bool get complex => level == TaskLevel.complex;
  @override
  String toString() => '${level.name} ($score: ${reasons.join(', ')})';
}

final _complexWords = RegExp(
    r'\b(analys\w*|vergleich\w*|bewert\w*|beurteil\w*|strategie\w*|konzept\w*|architektur\w*|begründ\w*|'
    r'herleit\w*|beweis\w*|optimier\w*|entwirf|entwerfen|plane|planen|planung|gliederung|wie gehe ich vor|'
    r'ausführlich\w*|detailliert\w*|schritt für schritt|vor- und nachteile|pro und contra|'
    r'programmier\w*|code|skript|script|funktion schreiben|sql|regex|debug\w*|refaktor\w*|algorithm\w*|'
    r'präsentation|folien|bericht|essay|aufsatz|konzeptpapier|businessplan|angebot schreiben|'
    r'zusammenfass\w*|übersetz\w*|korrigier\w*|umschreiben|formulier\w*|'
    r'warum|weshalb|wie funktioniert|erkläre|erklär mir)\b',
    caseSensitive: false);

final _simpleStart = RegExp(
    r'^\s*(hallo|hi|hey|servus|grüß|guten (morgen|tag|abend)|danke|ok|okay|ja|nein|super|passt|'
    r'wie spät|welcher tag|wetter|wie wird das wetter|stell(e)? (einen )?(timer|wecker)|erinnere mich|'
    r'was ist \d|rechne|wieviel ist|wie viel ist|news|nachrichten|öffne|ruf\w* .* an|termin)',
    caseSensitive: false);

final _followUp = RegExp(r'^\s*(und|noch|weiter|mehr|genauer|nochmal|also|aber|was ist mit|und (wie|was|wenn))\b', caseSensitive: false);

/// Schätzt, ob eine Anfrage das größere Modell braucht.
/// [docChars]: Länge angehängter Dokumente; [previousComplex]: vorige Frage im Chat war komplex.
TaskAssessment assessTask(String input, {int docChars = 0, bool previousComplex = false}) {
  final t = input.trim();
  var score = 0;
  final why = <String>[];
  void add(int s, String r) {
    score += s;
    why.add(r);
  }

  final words = _complexWords.allMatches(t).map((m) => m.group(0)!.toLowerCase()).toSet();
  if (words.isNotEmpty) add(words.length >= 2 ? 4 : 3, 'Aufgabe: ${words.take(3).join(', ')}');
  if (t.length > 900) {
    add(4, 'langer Text');
  } else if (t.length > 300) {
    add(2, 'längere Anfrage');
  }
  if (docChars > 3000) add(3, 'Dokument angehängt');
  final questions = '?'.allMatches(t).length;
  if (questions >= 2) add(questions >= 3 ? 2 : 1, 'mehrere Fragen');
  final listLines = RegExp(r'^\s*(\d+[.)]|[-*•])\s+', multiLine: true).allMatches(t).length;
  if (listLines >= 3) add(2, 'mehrteiliger Auftrag');
  if (t.contains('```') || RegExp(r'[{};]\s*$', multiLine: true).allMatches(t).length >= 3) add(4, 'Code');
  if (previousComplex && (t.length < 80 && _followUp.hasMatch(t))) add(3, 'Nachfrage zu komplexer Aufgabe');
  if (_simpleStart.hasMatch(t) && t.length < 140 && docChars == 0) add(-4, 'Alltagsfrage');
  if (t.length < 40 && words.isEmpty && !previousComplex && docChars == 0) add(-1, 'kurz');
  return TaskAssessment(score >= 3 ? TaskLevel.complex : TaskLevel.simple, score, why);
}

/// Wie zwei Modelle im Speicher gehalten werden.
enum Residency {
  /// Beide bleiben geladen – Wechsel ohne Wartezeit.
  both,

  /// Nur eines geladen; bei komplexen Aufgaben wird gewechselt (einige Sekunden).
  swap,

  /// Das große Modell passt nicht – nur das kleine.
  fastOnly,
}

class ModelPlan {
  const ModelPlan(this.residency, this.needBoth, this.budget, this.message);
  final Residency residency;
  final int needBoth;
  final int budget;
  final String message;
}

/// Entscheidet anhand des Arbeitsspeichers, ob beide Modelle geladen bleiben können.
/// Beide bleiben nur geladen, wenn danach noch ein Viertel des Budgets frei ist.
ModelPlan planResidency(DeviceProfile d, GgufInfo fast, int ctxFast, GgufInfo strong, int ctxStrong, {int? available}) {
  final a = d.checkFit(fast, ctxFast, availableOverride: available);
  final b = d.checkFit(strong, ctxStrong, availableOverride: available);
  final need = a.requiredBytes + b.requiredBytes;
  final budget = b.budgetBytes;
  String gb(int v) => '${(v / (1 << 30)).toStringAsFixed(1)} GB';
  if (b.level == FitLevel.refuse) {
    return ModelPlan(Residency.fastOnly, need, budget, 'Das große Modell passt nicht in den Speicher (${gb(b.requiredBytes)} von ${gb(budget)}).');
  }
  if (need <= budget * 0.75) {
    return ModelPlan(Residency.both, need, budget, 'Beide Modelle bleiben geladen (${gb(need)} von ${gb(budget)}) – kein Warten beim Wechsel.');
  }
  return ModelPlan(Residency.swap, need, budget,
      'Für beide zusammen reicht der Speicher nicht (${gb(need)} von ${gb(budget)}) – das große Modell wird bei Bedarf geladen und danach wieder freigegeben.');
}

/// Wählt aus installierten Modellen ein schnelles und ein starkes Paar (nach Dateigröße).
/// Liefert null, wenn es kein sinnvolles Paar gibt (zu ähnlich groß).
(T fast, T strong)? pickModelPair<T>(List<T> models, int Function(T) size, {bool Function(T)? fits}) {
  final usable = [for (final m in models) if (fits == null || fits(m)) m]..sort((a, b) => size(a).compareTo(size(b)));
  if (usable.length < 2) return null;
  final fast = usable.first;
  final strong = usable.last;
  if (size(strong) < size(fast) * 1.4) return null;
  return (fast, strong);
}
