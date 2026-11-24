/// Agent-Harness: eine gemeinsame Schicht um den Agenten für Chat, Prozesse, Team und MCP.
/// - einheitliche Werkzeug-Auswahl und Rechte ([prepare])
/// - Budget für Zeit und Tokens
/// - bei längeren Aufträgen erst ein kurzer Plan, am Ende eine Prüfung mit einer Nachbesserung
library;

import 'dart:async';

import '../agent/agent_runner.dart';
import '../agent/grammar.dart';
import '../agent/tool.dart';
import '../llama_engine.dart';
import 'routing.dart';

class HarnessBudget {
  const HarnessBudget({this.maxTime = const Duration(minutes: 8), this.maxTokens = 120000});
  final Duration maxTime;

  /// Tokens aller Modellaufrufe zusammen (Eingabe + Ausgabe)
  final int maxTokens;
}

enum CheckMode { off, auto, always }

class HarnessOptions {
  const HarnessOptions({
    this.budget = const HarnessBudget(),
    this.plan = CheckMode.auto,
    this.verify = CheckMode.auto,
    this.source = 'chat',
  });
  final HarnessBudget budget;
  final CheckMode plan;
  final CheckMode verify;

  /// chat | flow | team | mcp – für Protokoll und Überwachung
  final String source;
}

/// Ergebnis von [AgentHarness.prepare]: Werkzeuge und Pflicht-Werkzeug für einen Auftrag.
typedef HarnessTools = ({List<AgentTool> tools, String? requiredTool});

class AgentHarness {
  AgentHarness({required this.backend, this.onRunner});

  final AgentBackend backend;

  /// Aktueller Runner (für Stopp und Kommentare während der Arbeit)
  final void Function(AgentRunner runner)? onRunner;
  AgentRunner? _current;
  bool _stopped = false;

  void stop() {
    _stopped = true;
    _current?.stop();
  }

  /// Einheitliche Regeln, welche Werkzeuge ein Auftrag bekommt:
  /// [only] = feste Auswahl (Skill), sonst nach Nachricht; ohne Internet-Freigabe keine Netz-Werkzeuge;
  /// [exclude] z. B. Browser bei Hintergrund-Aufgaben.
  static HarnessTools prepare({
    required List<AgentTool> available,
    required String input,
    String? gateText,
    bool hasImages = false,
    bool hasDocs = false,
    bool hasFiles = false,
    Set<String>? only,
    String? requiredTool,
    bool network = true,
    Set<String> exclude = const {},
  }) {
    final text = gateText ?? input;
    var tools = only != null
        ? [for (final t in available) if (only.contains(t.name)) t]
        : ToolRouter.select(available, (t) => (name: t.name, title: t.title, description: t.description), text,
            hasImages: hasImages, hasDocs: hasDocs);
    tools = [for (final t in tools) if (!exclude.contains(t.name) && (network || !t.requiresNetwork)) t];
    var req = requiredTool ?? ToolRouter.requiredToolFor(text, hasFiles: hasFiles);
    if (req != null && req.isNotEmpty && !req.split('|').any((x) => tools.any((t) => t.name == x))) req = null;
    return (tools: tools, requiredTool: (req ?? '').isEmpty ? null : req);
  }

  /// Werkzeuge mit Wirkung (erstellen, senden, steuern, merken). Wurde eines davon benutzt, wird nicht
  /// nachgebessert – sonst entstehen doppelte Entwürfe, Dateien oder Befehle (im Test-Satz gesehen).
  static bool isAction(String tool) =>
      tool.startsWith('create_') ||
      tool.startsWith('compose_') ||
      tool.contains('__') ||
      const {
        'calendar_add', 'call_phone', 'send_notification', 'control_app', 'remember', 'skill_erstellen', 'edit_file',
        'generate_image', 'save_prompt', 'file_rename', 'file_move', 'write_artifact', 'browser', 'begleiten',
      }.contains(tool);

  /// Klingt der Auftrag nach mehreren Schritten?
  static bool looksComplex(String input) {
    final t = input.toLowerCase();
    if (t.length > 160) return true;
    final joins = RegExp(r'\b(und dann|danach|anschließend|außerdem|zusätzlich|zuerst|schließlich)\b').allMatches(t).length;
    final verbs = RegExp(r'\b(such|finde|vergleich|erstell|schreib|schick|trag|fass|recherchier|berechne|plane?)\w*').allMatches(t).length;
    return joins >= 1 && verbs >= 2 || verbs >= 3;
  }

  /// Führt einen Auftrag aus. [first] ist der vorbereitete Runner (Werkzeuge, Sampling …),
  /// [again] baut einen gleichartigen für die Nachbesserung.
  Stream<AgentEvent> run({
    required AgentRunner first,
    required AgentRunner Function() again,
    required List<ChatMessage> history,
    required String input,
    required ToolContext context,
    HarnessOptions options = const HarnessOptions(),
  }) {
    final out = StreamController<AgentEvent>();
    () async {
      final sw = Stopwatch()..start();
      var tokens = 0;
      String? budgetHit;
      final called = <String>[];
      var answer = '';
      AgentFinished? finished;
      _stopped = false;

      Future<void> pass(AgentRunner r, List<ChatMessage> hist, String text) async {
        _current = r;
        onRunner?.call(r);
        final deadline = options.budget.maxTime - sw.elapsed;
        if (deadline <= Duration.zero) {
          budgetHit ??= 'Zeit';
          return;
        }
        final timer = Timer(deadline, () {
          budgetHit ??= 'Zeit (${options.budget.maxTime.inMinutes} min)';
          r.stop();
        });
        try {
          await for (final ev in r.run(history: hist, userInput: text, context: context)) {
            switch (ev) {
              case MetricsUpdate(:final stats):
                tokens += stats.promptTokens + stats.generatedTokens;
                if (tokens > options.budget.maxTokens && budgetHit == null) {
                  budgetHit = 'Tokens (${options.budget.maxTokens})';
                  r.stop();
                }
              case ToolCalled(:final tool):
                called.add(tool);
              case FinalAnswer(:final text):
                answer = text;
              case AgentFinished():
                finished = ev;
                continue; // erst ganz am Ende melden
              default:
                break;
            }
            out.add(ev);
          }
        } finally {
          timer.cancel();
        }
      }

      try {
        var text = input;
        // ---- Plan (nur bei mehrteiligen Aufträgen mit Werkzeugen)
        final planOn = options.plan == CheckMode.always ||
            (options.plan == CheckMode.auto && first.tools.length >= 2 && looksComplex(input));
        if (planOn && !_stopped) {
          final steps = await _plan(input, first.tools);
          if (steps.length >= 2) {
            out.add(PlanMade(steps));
            text = '$input\n\n[Dein Plan – arbeite ihn Schritt für Schritt ab, ohne ihn zu wiederholen:\n'
                '${[for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n')}]';
          }
        }
        await pass(first, history, text);

        // ---- Prüfen und einmal nachbessern
        final verifyOn = !_stopped &&
            budgetHit == null &&
            finished?.reason == AgentStopReason.answered &&
            answer.trim().isNotEmpty &&
            !called.any(isAction) &&
            (options.verify == CheckMode.always ||
                (options.verify == CheckMode.auto && (called.length >= 2 || (planOn && called.isNotEmpty))));
        if (verifyOn) {
          final (ok, feedback) = await _check(input, answer, called);
          out.add(AnswerChecked(ok, feedback));
          if (!ok && feedback.isNotEmpty && !_stopped && sw.elapsed < options.budget.maxTime * 0.8) {
            finished = null;
            await pass(again(), [...history, ChatMessage('user', input), ChatMessage('assistant', answer)],
                'Prüfung deiner Antwort: Es fehlt noch: $feedback\nErgänze oder korrigiere das. Nutze Werkzeuge nur, um fehlende '
                'Informationen zu holen – wiederhole keine Abfrage und keine Aktion, die schon erledigt ist. '
                'Gib dann die vollständige, verbesserte Antwort.');
          }
        }
        if (budgetHit != null) out.add(BudgetHit(budgetHit!));
        out.add(budgetHit != null && answer.trim().isEmpty
            ? AgentFinished(AgentStopReason.stopped, message: 'Budget aufgebraucht: $budgetHit')
            : finished ?? AgentFinished(_stopped ? AgentStopReason.stopped : AgentStopReason.answered));
      } catch (e) {
        out.add(AgentFinished(AgentStopReason.error, message: '$e'));
      } finally {
        _current = null;
        await out.close();
      }
    }();
    return out.stream;
  }

  Future<String> _generate(String system, String user, {int maxTokens = 220}) async {
    final prompt = await backend.formatChat([ChatMessage('system', system), ChatMessage('user', user)]);
    final b = StringBuffer();
    await for (final ev in backend.generate(skipThinking(prompt),
        grammar: AgentGrammar.plainTextNoCjk(), sampling: SamplingParams.precise, maxTokens: maxTokens)) {
      if (ev is TokenEvent) b.write(ev.text);
      if (_stopped) break;
    }
    return cleanModelText(b.toString()).trim();
  }

  Future<List<String>> _plan(String input, List<AgentTool> tools) async {
    try {
      final t = await _generate(
          'Du planst Aufträge für einen KI-Agenten. Antworte nur mit einer nummerierten Liste von 2 bis 5 kurzen Schritten, '
              'ohne Einleitung. Nenne bei jedem Schritt das passende Werkzeug in Klammern.',
          'Werkzeuge: ${tools.map((x) => x.name).join(', ')}\nAuftrag: $input');
      return [
        for (final line in t.split('\n'))
          if (RegExp(r'^\s*(\d+[.)]|[-*•])\s+').hasMatch(line)) line.replaceFirst(RegExp(r'^\s*(\d+[.)]|[-*•])\s+'), '').trim()
      ].where((s) => s.isNotEmpty).take(5).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Prüfer: erste Zeile „OK“ oder „FEHLT: …“
  Future<(bool, String)> _check(String input, String answer, List<String> called) async {
    try {
      final t = await _generate(
          'Du prüfst, ob eine Antwort einen Auftrag vollständig erfüllt. Sei streng, aber fair: Kleinigkeiten zählen nicht. '
              'Antworte in der ersten Zeile nur mit OK – oder mit FEHLT: und dann in einem Satz, was konkret fehlt.',
          'Auftrag: $input\n\nGenutzte Werkzeuge: ${called.isEmpty ? 'keine' : called.toSet().join(', ')}\n\nAntwort:\n'
              '${answer.length > 2500 ? '${answer.substring(0, 2500)} …' : answer}',
          maxTokens: 120);
      final first = t.split('\n').first.trim();
      if (RegExp(r'^\W*ok\b', caseSensitive: false).hasMatch(first)) return (true, '');
      final m = RegExp(r'fehlt\s*[:\-–]?\s*(.*)', caseSensitive: false, dotAll: true).firstMatch(t);
      if (m == null) return (true, ''); // unklar → nicht unnötig nachbessern
      final fb = m.group(1)!.trim();
      return (fb.isEmpty, fb.length > 300 ? fb.substring(0, 300) : fb);
    } catch (_) {
      return (true, '');
    }
  }
}
