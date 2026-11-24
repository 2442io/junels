// Agenten-Schleife Thought → Action → Observation (SRS Abschnitt 5).

import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';

import '../llama_engine.dart';
import '../documents/design.dart' show designReferencesIn;
import '../documents/slide_plan.dart';
import 'grammar.dart';
import 'network_tools.dart' show moreCardsMarker;
import 'tool.dart';

// ---------------------------------------------------------------------------
// Ereignisse für die UI
// ---------------------------------------------------------------------------

sealed class AgentEvent {}

class StepStarted extends AgentEvent {
  StepStarted(this.step);
  final int step;
}

/// Laufender Zwischenstand eines Schritts (für Live-Anzeige).
class StepStreaming extends AgentEvent {
  StepStreaming(this.step, {this.thought, this.answer, required this.raw});
  final int step;
  final String? thought;
  final String? answer;
  final String raw;
}

class ToolCalled extends AgentEvent {
  ToolCalled(this.step, this.tool, this.args, this.thought);
  final int step;
  final String tool;
  final Map<String, dynamic> args;
  final String thought;
}

class ToolResult extends AgentEvent {
  ToolResult(this.step, this.tool, this.output, {this.isError = false, required this.duration});
  final int step;
  final String tool;
  final String output;
  final bool isError;
  final Duration duration;
}

class MetricsUpdate extends AgentEvent {
  MetricsUpdate(this.stats);
  final GenerationStats stats;
}

class FinalAnswer extends AgentEvent {
  FinalAnswer(this.text, {this.thought, this.truncated = false});
  final String text;
  final String? thought;
  final bool truncated;
}

/// Ein Kommentar des Nutzers, der während der Arbeit kam, wird ab jetzt berücksichtigt.
class NoteApplied extends AgentEvent {
  NoteApplied(this.step, this.text);
  final int step;
  final String text;
}

class AgentFinished extends AgentEvent {
  AgentFinished(this.reason, {this.message});
  final AgentStopReason reason;
  final String? message;
}

/// Harness: Plan für einen längeren Auftrag.
class PlanMade extends AgentEvent {
  PlanMade(this.steps);
  final List<String> steps;
}

/// Harness: Ergebnis der Prüfung „Ist der Auftrag erfüllt?“.
class AnswerChecked extends AgentEvent {
  AnswerChecked(this.ok, this.feedback);
  final bool ok;
  final String feedback;
}

/// Harness: Zeit- oder Token-Budget aufgebraucht.
class BudgetHit extends AgentEvent {
  BudgetHit(this.what);
  final String what;
}

enum AgentStopReason { answered, stopped, stepLimit, error }

// ---------------------------------------------------------------------------

class AgentRunner {
  AgentRunner({
    required this.engine,
    required this.systemPrompt,
    this.tools = const [],
    this.maxSteps = 8,
    this.maxTokensPerStep = 768,
    this.observationLimit = 2000,
    this.toolTimeout = const Duration(seconds: 20),
    this.sampling = SamplingParams.precise,
    this.chatSampling = const SamplingParams(),
    this.blockCjk = true,
    this.requiredTool,
  });

  /// Chinesische/japanische/koreanische Schriftzeichen in der Ausgabe sperren
  /// (verhindert das Abdriften von Qwen-Modellen ins Chinesische).
  final bool blockCjk;

  /// Der Nutzer will eine Datei (z. B. create_presentation): Der Agent darf nicht
  /// mit einer bloßen Beschreibung aufhören – erst nachhaken, notfalls selbst erstellen.
  final String? requiredTool;

  final AgentBackend engine;
  final String systemPrompt;
  final List<AgentTool> tools;
  final int maxSteps;
  final int maxTokensPerStep;
  final int observationLimit;
  final Duration toolTimeout;
  final SamplingParams sampling;
  final SamplingParams chatSampling;

  bool _stopped = false;

  /// true nach [stop].
  bool get isStopped => _stopped;

  void stop() {
    _stopped = true;
    engine.stop();
  }

  // ---- Kommentare während der Arbeit
  final List<String> _notes = [];
  bool _finished = false;
  bool _generating = false;
  bool _noteInterrupt = false;

  /// Noch nicht berücksichtigte Kommentare (nach dem Lauf: als neue Nachricht schicken).
  List<String> get pendingNotes => List.unmodifiable(_notes);

  /// Kommentar des Nutzers während der Arbeit. Läuft gerade eine Ausgabe, wird sie
  /// abgebrochen und mit dem Kommentar neu begonnen. false = Lauf schon beendet.
  bool addNote(String text) {
    if (_finished || _stopped || text.trim().isEmpty) return false;
    _notes.add(text.trim());
    if (_generating) {
      _noteInterrupt = true;
      engine.stop();
    }
    return true;
  }

  /// Wartende Kommentare als Nachrichten für das Modell (und als Ereignis für die Oberfläche).
  List<ChatMessage> _takeNotes(int step, void Function(AgentEvent) emit) {
    if (_notes.isEmpty) return const [];
    final out = <ChatMessage>[];
    for (final n in _notes) {
      emit(NoteApplied(step, n));
      out.add(ChatMessage('user',
          'Ergänzung des Nutzers, während du gearbeitet hast: „$n“\nBerücksichtige das ab jetzt bei deiner Arbeit und in der Antwort.'));
    }
    _notes.clear();
    return out;
  }

  bool get agentMode => tools.isNotEmpty;

  /// Tools dieses Laufs (bei knappem Context ggf. weniger als [tools]).
  List<AgentTool>? _active;
  List<AgentTool> get activeTools => _active ?? tools;

  /// Bei kleinem Context: unpassende Tools weglassen, bis System-Prompt + Eingabe
  /// höchstens ~60 % des Budgets belegen. Tools, die zur Eingabe passen, bleiben.
  Future<void> _selectTools(String input, ToolContext ctx) async {
    _active = null;
    final budget = engine.contextSize - _reserve - 16;
    final lower = input.toLowerCase();
    final words = lower.split(RegExp(r'[^a-zäöüß0-9]+')).where((w) => w.length > 2).toSet();
    final hasUrl = RegExp(r'https?://|www\.|\b[a-z0-9-]+\.(?:com|at|de|ch|org|net|io|li|eu)\b').hasMatch(lower);
    int relevance(AgentTool t) {
      if (lower.contains(t.name)) return 100;
      if (hasUrl && t.name == 'web_fetch') return 100;
      final hay = '${t.name} ${t.title} ${t.description} ${t.keywords}'.toLowerCase();
      return words.where(hay.contains).length;
    }

    var list = List<AgentTool>.of(tools);
    while (list.length > 1) {
      _active = list;
      final n = await engine.countTokens(
          await engine.formatChat([ChatMessage('system', buildSystemPrompt(ctx)), ChatMessage('user', input)]));
      if (n <= budget * 0.6) return;
      // am wenigsten passendes Tool (bei Gleichstand das hinterste) entfernen
      var drop = list.length - 1;
      for (var i = list.length - 1; i >= 0; i--) {
        if (relevance(list[i]) < relevance(list[drop])) drop = i;
      }
      list = [...list]..removeAt(drop);
    }
    _active = list;
  }

  /// Platz für die Antwort eines Schritts – bei kleinem Context begrenzt.
  int get _reserve => math.min(maxTokensPerStep, (engine.contextSize * 0.35).round());

  /// Systemprompt inkl. Tool-Beschreibungen und Antwortformat.
  String buildSystemPrompt(ToolContext ctx) {
    final b = StringBuffer(systemPrompt.trim());
    b.writeln('\n\nAntworte immer in der Sprache, in der der Nutzer schreibt (meist Deutsch). '
        'Wechsle nie mitten in der Antwort die Sprache und verwende keine chinesischen Schriftzeichen.');
    final docs = ctx.allDocuments;
    if (agentMode) {
      b.writeln('\n');
      b.writeln('Du arbeitest in Schritten und antwortest IMMER mit genau einem JSON-Objekt.');
      b.writeln('Tool aufrufen: {"thought": "kurzer Gedanke", "action": "<tool>", "args": {...}}');
      b.writeln('Fertig: {"thought": "kurzer Gedanke", "final_answer": "Antwort an den Nutzer"}');
      b.writeln('\nVerfügbare Tools:');
      for (final t in activeTools) {
        b.writeln(t.describeForPrompt());
      }
      b.writeln('\nRegeln:');
      b.writeln('- Nutze ein Tool nur, wenn es nötig ist. Einfache Fragen direkt mit final_answer beantworten.');
      b.writeln('- Nach jedem Tool-Aufruf erhältst du eine Beobachtung. Erfinde keine Ergebnisse.');
      b.writeln(
          '- Schlägt ein Tool fehl, nenne dem Nutzer den konkreten Grund (z. B. „Amazon blockiert automatische Abrufe“) '
          'und probiere einen anderen Weg. Behaupte nie pauschal, du hättest keinen Zugriff.');
      b.writeln('- Rechne nie im Kopf, wenn calculator verfügbar ist.');
      b.writeln('- final_answer in der Sprache des Nutzers, Markdown erlaubt, keine LaTeX-Formeln (Zahlen normal schreiben, z. B. 409,50 €).');
      if (activeTools.any((t) => t.name == 'web_fetch' || t.name == 'web_search')) {
        b.writeln(
            '- Du KANNST das Internet nutzen: web_fetch liest eine Webseite (z. B. eine vom Nutzer genannte URL), '
            'web_search sucht im Web. Behaupte nie, du hättest keinen Internetzugriff.');
      }
      if (activeTools.any((t) => t.name.startsWith('create_'))) {
        b.writeln('- Dateien (PDF, Präsentation) nur erstellen, wenn der Nutzer ausdrücklich danach fragt. '
            'Fehler oder Hinweise nie als Datei, sondern in der final_answer.');
      }
      if (activeTools.any((t) => t.requiresNetwork)) {
        b.writeln('- Internet-Tools nur nutzen, wenn aktuelle oder externe Informationen nötig sind. '
            'Der Nutzer muss den Zugriff bestätigen. Nenne in der final_answer die genutzten Quellen (URL).');
      }
    }
    if (docs.isNotEmpty) {
      b.writeln('\nVerfügbare Dateien:');
      for (final d in docs) {
        b.writeln('- ${d.name} (${d.content.length} Zeichen)');
      }
    }
    return b.toString();
  }

  /// Führt einen Nutzer-Turn aus. [history] enthält frühere Nutzer-/Agent-Nachrichten.
  Stream<AgentEvent> run({
    required List<ChatMessage> history,
    required String userInput,
    required ToolContext context,
  }) {
    _stopped = false;
    if (context.userRequest.isEmpty) context.userRequest = userInput;
    final controller = StreamController<AgentEvent>();
    () async {
      try {
        if (agentMode) {
          await _runAgent(history, userInput, context, controller.add);
        } else {
          await _runChat(history, userInput, context, controller.add);
        }
      } catch (e) {
        controller.add(AgentFinished(AgentStopReason.error, message: e.toString()));
      } finally {
        _finished = true;
        _generating = false;
        await controller.close();
      }
    }();
    return controller.stream;
  }

  // ---------------------------------------------------------------- Chat-Modus

  Future<void> _runChat(
      List<ChatMessage> history, String input, ToolContext ctx, void Function(AgentEvent) emit) async {
    emit(StepStarted(1));
    final messages = [ChatMessage('system', buildSystemPrompt(ctx))];
    final extra = <ChatMessage>[];
    var raw = StringBuffer();
    GenerationStats? stats;
    FinishReason reason = FinishReason.done;
    String? error;
    for (var round = 0; round < 4; round++) {
      extra.addAll(_takeNotes(1, emit));
      final prompt = await _fitPrompt(
        system: messages.first.content,
        history: history,
        input: input,
        scratch: extra,
        reserve: math.min(maxTokensPerStep * 2, (engine.contextSize * 0.4).round()),
      );
      raw = StringBuffer();
      _generating = true;
      await for (final ev in engine.generate(skipThinking(prompt),
          grammar: blockCjk ? AgentGrammar.plainTextNoCjk() : null,
          sampling: chatSampling,
          maxTokens: math.min(maxTokensPerStep * 2, (engine.contextSize * 0.4).round()))) {
        switch (ev) {
          case TokenEvent(:final text):
            raw.write(text);
            emit(StepStreaming(1, answer: cleanModelText(raw.toString(), streaming: true), raw: raw.toString()));
          case DoneEvent():
            stats = ev.stats;
            reason = ev.reason;
            error = ev.error;
        }
      }
      _generating = false;
      // Kommentar kam während der Ausgabe: bisherigen Entwurf behalten und mit Kommentar überarbeiten
      if ((_noteInterrupt || _notes.isNotEmpty) && !_stopped && reason != FinishReason.error) {
        _noteInterrupt = false;
        final draft = cleanModelText(raw.toString()).trim();
        if (draft.isNotEmpty) extra.add(ChatMessage('assistant', draft));
        continue;
      }
      break;
    }
    if (stats != null) emit(MetricsUpdate(stats));
    if (reason == FinishReason.error) {
      emit(AgentFinished(AgentStopReason.error, message: error ?? 'Fehler bei der Generierung'));
      return;
    }
    emit(FinalAnswer(cleanModelText(raw.toString()),
        truncated: reason == FinishReason.maxTokens || reason == FinishReason.contextFull));
    emit(AgentFinished(reason == FinishReason.stopped ? AgentStopReason.stopped : AgentStopReason.answered));
  }

  // -------------------------------------------------------------- Agenten-Modus

  Future<void> _runAgent(
      List<ChatMessage> history, String input, ToolContext ctx, void Function(AgentEvent) emit) async {
    await _selectTools(input, ctx);
    final system = buildSystemPrompt(ctx);
    final scratch = <ChatMessage>[];
    final grammar = AgentGrammar.build(activeTools, blockCjk: blockCjk);
    final finalOnly = AgentGrammar.build(activeTools, allowTools: false, blockCjk: blockCjk);
    String? lastCall;

    String? hint; // einmaliger Hinweis an das Modell (nicht Teil des Verlaufs)
    var answerNext = false; // Werkzeug meldet: Ergebnis reicht → nur noch antworten
    final seenCalls = <String, String>{}; // gleiche Aufrufe nicht wiederholen
    final failures = <String, int>{}; // erfolglose Aufrufe je Werkzeug
    // Mehrere erlaubt („edit_file|create_presentation“): das erste vorhandene ist das Ziel, jedes zählt
    final needs = [for (final n in (requiredTool ?? '').split('|')) if (n.isNotEmpty && activeTools.any((t) => t.name == n)) n];
    final need = needs.firstOrNull;
    var delivered = false; // Pflicht-Werkzeug erfolgreich genutzt
    var nudges = 0;

    for (var step = 1; step <= maxSteps + 1; step++) {
      if (_stopped) {
        emit(AgentFinished(AgentStopReason.stopped));
        return;
      }
      final forceFinal = step > maxSteps || answerNext;
      if (step > maxSteps) {
        hint = 'Schrittlimit erreicht. Gib jetzt mit den vorhandenen Informationen die final_answer.';
      } else if (answerNext) {
        hint = 'Das Ergebnis reicht. Gib jetzt direkt die final_answer.';
      }
      answerNext = false;
      emit(StepStarted(step));

      scratch.addAll(_takeNotes(step, emit));
      final prompt = await _fitPrompt(
        system: system,
        history: history,
        input: input,
        scratch: [...scratch, if (hint != null) ChatMessage('user', hint)],
        reserve: _reserve,
      );
      hint = null;
      _generating = true;

      final raw = StringBuffer();
      GenerationStats? stats;
      var reason = FinishReason.done;
      String? error;
      await for (final ev in engine.generate(prompt,
          grammar: forceFinal ? finalOnly : grammar, sampling: sampling, maxTokens: _reserve)) {
        switch (ev) {
          case TokenEvent(:final text):
            raw.write(text);
            final r = raw.toString();
            emit(StepStreaming(step,
                thought: extractPartialJsonString(r, 'thought'),
                answer: extractPartialJsonString(r, 'final_answer'),
                raw: r));
          case DoneEvent():
            stats = ev.stats;
            reason = ev.reason;
            error = ev.error;
        }
      }
      _generating = false;
      if (stats != null) emit(MetricsUpdate(stats));
      final text = raw.toString();

      // Kommentar kam mitten in der Ausgabe: diesen Schritt mit Kommentar wiederholen (zählt nicht als Schritt)
      if (_noteInterrupt && !_stopped) {
        _noteInterrupt = false;
        step--;
        continue;
      }

      if (reason == FinishReason.stopped || _stopped) {
        final partial = extractPartialJsonString(text, 'final_answer');
        if (partial != null && partial.isNotEmpty) emit(FinalAnswer(partial, truncated: true));
        emit(AgentFinished(AgentStopReason.stopped));
        return;
      }
      if (reason == FinishReason.error) {
        emit(AgentFinished(AgentStopReason.error, message: error ?? 'Fehler bei der Generierung'));
        return;
      }

      Map<String, dynamic>? obj;
      try {
        final d = jsonDecode(text);
        if (d is Map<String, dynamic>) obj = d;
      } on FormatException {
        obj = null;
      }

      if (obj == null) {
        // abgeschnitten (maxTokens / Context voll)
        final partial = extractPartialJsonString(text, 'final_answer');
        if (partial != null && partial.isNotEmpty) {
          emit(FinalAnswer(partial, thought: extractPartialJsonString(text, 'thought'), truncated: true));
          emit(AgentFinished(AgentStopReason.answered));
          return;
        }
        // abgeschnittene Ausgabe nicht in den Verlauf übernehmen
        hint = 'Deine letzte Antwort war zu lang und wurde abgeschnitten. '
            'Antworte kürzer mit genau einem JSON-Objekt.';
        continue;
      }

      final thought = (obj['thought'] ?? '').toString();
      if (obj.containsKey('final_answer') && _notes.isNotEmpty && step <= maxSteps) {
        // Kommentar kam genau jetzt: Entwurf behalten und überarbeiten lassen
        scratch.add(ChatMessage('assistant', text));
        continue;
      }
      if (obj.containsKey('final_answer')) {
        final answer = obj['final_answer'].toString();
        if (need != null && !delivered) {
          if (nudges < 2 && step < maxSteps) {
            // nur beschrieben statt erstellt → nachhaken
            nudges++;
            answerNext = false;
            scratch.add(ChatMessage('assistant', text));
            hint = _deliverHint(need, ctx);
            continue;
          }
          final made = await _deliverFallback(need, answer, input, ctx, emit, step);
          if (made != null) {
            emit(FinalAnswer(made, thought: thought));
            emit(AgentFinished(AgentStopReason.answered));
            return;
          }
        }
        emit(FinalAnswer(answer, thought: thought));
        emit(AgentFinished(step > maxSteps ? AgentStopReason.stepLimit : AgentStopReason.answered));
        return;
      }

      // Design-Vorlagen nicht im Browser öffnen – das Präsentations-Tool übernimmt sie selbst
      final callUrl = (obj['args'] is Map ? ((obj['args'] as Map)['url'] ?? (obj['args'] as Map)['query'] ?? '') : '').toString();
      if (need != null &&
          !delivered &&
          (obj['action'] == 'browser' || obj['action'] == 'web_fetch') &&
          callUrl.isNotEmpty &&
          designReferencesIn(callUrl).isNotEmpty) {
        scratch.add(ChatMessage('assistant', text));
        scratch.add(ChatMessage('user',
            'Beobachtung: Nicht nötig – Design-Vorlagen (auch Links) übernimmt $need selbst. ${_deliverHint(need, ctx)}'));
        continue;
      }

      final toolName = (obj['action'] ?? '').toString();
      final args = (obj['args'] is Map) ? Map<String, dynamic>.from(obj['args'] as Map) : <String, dynamic>{};
      emit(ToolCalled(step, toolName, args, thought));
      // Lange Argumente (z. B. ganzer Dokumentinhalt) nicht im Verlauf mitschleppen
      final compact = Map<String, dynamic>.from(obj);
      if (args.values.any((v) => v is String && v.length > 600)) {
        compact['args'] = {
          for (final e in args.entries)
            e.key: e.value is String && (e.value as String).length > 600
                ? '${(e.value as String).substring(0, 200)} … [${(e.value as String).length} Zeichen]'
                : e.value,
        };
      }
      scratch.add(ChatMessage('assistant', jsonEncode(compact)));

      final callKey = '$toolName ${jsonEncode(args)}';
      String observation;
      var isError = false;
      final sw = Stopwatch()..start();
      if (callKey == lastCall || seenCalls.containsKey(callKey)) {
        observation = 'Du hast dieses Tool gerade schon mit denselben Argumenten aufgerufen. '
            'Ergebnis damals: ${seenCalls[callKey] ?? ''}\nNutze das und gib jetzt die final_answer.';
        isError = true;
      } else {
        final tool = activeTools.where((t) => t.name == toolName).firstOrNull;
        if (tool == null) {
          observation = 'Unbekanntes Tool "$toolName".';
          isError = true;
        } else {
          try {
            ctx.answerNow = false;
            observation = await tool.run(args, ctx).timeout(tool.timeout ?? toolTimeout);
            if (ctx.answerNow) answerNext = true;
            ctx.answerNow = false;
          } on TimeoutException {
            observation = 'Fehler: Zeitüberschreitung nach ${(tool.timeout ?? toolTimeout).inSeconds} s.';
            isError = true;
          } catch (e) {
            observation = 'Fehler: $e';
            isError = true;
          }
        }
      }
      lastCall = callKey;
      sw.stop();
      seenCalls.putIfAbsent(
          callKey, () => observation.length > 300 ? '${observation.substring(0, 300)} …' : observation);
      // Zweimal erfolglos (Fehler oder „ohne Ergebnis“) → nicht weiter probieren, antworten
      if (isError ||
          RegExp(r'ohne Ergebnis|keine Treffer|nichts gefunden', caseSensitive: false)
              .hasMatch(observation.length > 200 ? observation.substring(0, 200) : observation)) {
        final n = (failures[toolName] ?? 0) + 1;
        failures[toolName] = n;
        if (n >= 2) answerNext = true;
      }
      // Weitere Ergebnis-Karten sieht nur die Oberfläche, nicht das Modell (kürzerer Prompt)
      final cut = observation.indexOf(moreCardsMarker);
      var extra = cut < 0 ? '' : observation.substring(cut);
      if (cut >= 0) observation = observation.substring(0, cut);
      if (extra.length > 40000) extra = extra.substring(0, 40000);
      // Die Oberfläche bekommt alles (Karten!), das Modell nur den gekürzten Teil
      final shown = '$observation$extra';
      if (observation.length > observationLimit) {
        observation = '${observation.substring(0, observationLimit)}\n[… gekürzt]';
      }
      if (needs.contains(toolName) && !isError && !observation.startsWith('Fehler') && args['aktion'] != 'anzeigen') delivered = true;
      emit(ToolResult(step, toolName, shown, isError: isError, duration: sw.elapsed));
      // Aktuelle Daten aus dem Netz gehen dem (veralteten) Wissen des Modells vor – im Test-Satz
      // antwortete es sonst trotz Suche mit einem früheren Stand
      final fresh = !isError && (activeTools.where((t) => t.name == toolName).firstOrNull?.requiresNetwork ?? false);
      scratch.add(ChatMessage('user',
          'Beobachtung ($toolName):\n$observation${fresh ? '\n[Das sind aktuelle Daten – sie gelten, auch wenn dein Wissen etwas anderes sagt. Antworte damit.]' : ''}'));
    }
    emit(AgentFinished(AgentStopReason.stepLimit,
        message: 'Das Modell hat nach ${maxSteps + 1} Schritten keine gültige Antwort geliefert.'));
  }

  String _deliverHint(String tool, ToolContext ctx) {
    final refs = designReferencesIn(ctx.userRequest);
    return switch (tool) {
      'create_presentation' => 'Der Nutzer will eine fertige PowerPoint-Datei – keine Beschreibung, keinen Folienplan und keine Anleitung. '
          'Rufe JETZT create_presentation auf: title = Titel; content = alle Folien in Markdown, jede Folie beginnt mit "# Folientitel", '
          'darunter der echte Folientext als Stichpunkte (keine Angaben wie Layout, Grafik-Idee oder Stil)'
          '${refs.isEmpty ? '' : '; vorlage = ${refs.join(' ')}'}. Das Design übernimmt das Tool.',
      'create_document' || 'create_word' => 'Der Nutzer will eine fertige Datei – keine Beschreibung. Rufe JETZT $tool mit title und dem '
          'vollständigen Inhalt in Markdown auf.',
      'create_excel' => 'Der Nutzer will eine fertige Excel-Datei – keine Beschreibung. Rufe JETZT create_excel auf: title und content = '
          'Markdown-Tabelle(n) mit Kopfzeile (je Blatt "## Name" davor), Summen als Formel, z. B. =SUMME(B2:B9).',
      'edit_file' => 'Der Nutzer will die erstellte Datei ändern – nicht beschreiben, sondern ändern. Rufe JETZT edit_file auf '
          '(erst aktion "anzeigen" für den aktuellen Inhalt, dann "ersetzen"/"einfuegen"/"loeschen").',
      'calendar_list' || 'mail_inbox' || 'contacts_search' => 'Der Nutzer fragt nach seinen eigenen Daten – nicht raten oder erfinden. '
          'Rufe JETZT $tool auf und antworte dann mit dem Ergebnis.',
      'remember' => 'Der Nutzer will, dass du dir das merkst. Rufe JETZT remember auf.',
      'calendar_add' || 'send_notification' => 'Der Nutzer hat das ausdrücklich beauftragt. Rufe JETZT $tool auf – '
          'er bestätigt den Vorschlag danach selbst, du musst nicht vorher nachfragen.',
      'web_search' => 'Das ändert sich laufend – dein Wissen kann veraltet sein. Rufe JETZT web_search auf und antworte mit dem Ergebnis.',
      _ => 'Der Nutzer will ein Ergebnis als Datei. Rufe JETZT $tool auf.',
    };
  }

  /// Letzter Ausweg: Aus der Antwort (z. B. Folienplan) selbst die Datei erstellen.
  Future<String?> _deliverFallback(
      String need, String answer, String input, ToolContext ctx, void Function(AgentEvent) emit, int step) async {
    final tool = activeTools.where((t) => t.name == need).firstOrNull;
    if (tool == null) return null;
    final args = <String, dynamic>{};
    if (need == 'create_presentation') {
      final slides = slidesFromPlan(answer);
      if (slides.title.isEmpty && slides.content.isEmpty) return null;
      args['title'] = slides.title.isNotEmpty ? slides.title : _titleFrom(input);
      args['content'] = slides.content;
      final refs = designReferencesIn(ctx.userRequest);
      if (refs.isNotEmpty) args['vorlage'] = refs.join(' ');
    } else if (need == 'create_excel') {
      if (!answer.contains('|')) return null;
      args['title'] = _titleFrom(input);
      args['content'] = answer;
    } else if (need == 'create_document' || need == 'create_word') {
      if (answer.trim().length < 80) return null;
      args['title'] = _titleFrom(input);
      args['content'] = answer;
    } else {
      return null;
    }
    emit(ToolCalled(step, need, args, 'Datei aus dem Entwurf erstellen'));
    final sw = Stopwatch()..start();
    try {
      final obs = await tool.run(args, ctx).timeout(tool.timeout ?? toolTimeout);
      emit(ToolResult(step, need, obs, duration: sw.elapsed));
      return obs.startsWith('Fehler') ? null : obs.split(moreCardsMarker).first.trim();
    } catch (e) {
      emit(ToolResult(step, need, 'Fehler: $e', isError: true, duration: sw.elapsed));
      return null;
    }
  }

  String _titleFrom(String input) {
    final m = RegExp(r'(?:über|zu|zum|zur|für|mit dem titel|titel)\s+[„"]?([^.!?\n„"“]{3,60})', caseSensitive: false).firstMatch(input);
    return (m?.group(1) ?? 'Präsentation').trim();
  }

  /// Baut den Prompt und kürzt, bis er in den Context passt:
  /// 1. älteste Verlaufsnachrichten, 2. älteste Agenten-Schritte (paarweise,
  /// der letzte Schritt bleibt), 3. lange Inhalte. System-Prompt und
  /// Nutzereingabe bleiben immer erhalten.
  Future<String> _fitPrompt({
    required String system,
    required List<ChatMessage> history,
    required String input,
    required List<ChatMessage> scratch,
    required int reserve,
  }) async {
    final budget = engine.contextSize - reserve - 16;
    final hist = List<ChatMessage>.of(history);
    final work = List<ChatMessage>.of(scratch);
    var inputText = input;
    var shortenedOnce = false;
    // Kurzfassung von allem, was aus Platzgründen herausfällt – statt es spurlos zu verlieren
    final earlier = <String>[];
    final steps = <String>[];
    String digest(List<String> xs, int max) {
      final b = <String>[];
      var len = 0;
      for (final x in xs.reversed) {
        if (len + x.length > max) break;
        b.insert(0, x);
        len += x.length;
      }
      return b.join('\n');
    }

    while (true) {
      final msgs = [
        ChatMessage('system', system),
        if (earlier.isNotEmpty) ChatMessage('user', '[Früher in diesem Chat (gekürzt):\n${digest(earlier, 600)}]'),
        ...hist,
        ChatMessage('user', inputText),
        if (steps.isNotEmpty) ChatMessage('user', '[Deine bisherigen Schritte (gekürzt):\n${digest(steps, 700)}]'),
        ...work,
      ];
      final prompt = await engine.formatChat(msgs);
      final n = await engine.countTokens(prompt);
      if (n <= budget) return prompt;

      if (hist.isNotEmpty) {
        final m = hist.removeAt(0);
        earlier.add('${m.role == 'user' ? 'Nutzer' : 'Du'}: ${compactLine(m.content, 140)}');
        continue;
      }
      // ältesten Schritt (assistant + Beobachtung) entfernen, der letzte bleibt – als Kurzfassung
      if (work.length > 2) {
        final a = work.removeAt(0);
        final o = work.length > 2 && work.first.role == 'user' ? work.removeAt(0) : null;
        steps.add(stepDigest(a.content, o?.content));
        continue;
      }
      if (!shortenedOnce) {
        shortenedOnce = true;
        String cut(String t) => t.length > 1200 ? '${t.substring(0, 1000)}\n[… gekürzt]' : t;
        for (var i = 0; i < work.length; i++) {
          work[i] = ChatMessage(work[i].role, cut(work[i].content));
        }
        inputText = cut(inputText);
        continue;
      }
      throw EngineException('Die Anfrage ist zu lang für das Context-Fenster ($n Tokens, Budget $budget). '
          'Bitte kürzen oder einen größeren Context wählen.');
    }
  }
}

/// Gemma 4 und Qwen „denken“ sonst erst laut nach. Ein leerer Gedanken-Block am
/// Anfang der Antwort schaltet das ab (schneller, kein Gedankentext im Chat).
String skipThinking(String prompt) {
  if (RegExp(r'<\|turn>model\s*$').hasMatch(prompt)) return '$prompt<|channel>thought\n<channel|>';
  return prompt;
}

/// Entfernt Denk-Abschnitte und Steuer-Marker aus Modelltext.
String cleanModelText(String raw, {bool streaming = false}) {
  var t = raw;
  // Gemma 4: "<|channel>thought …<channel|>Antwort"
  final ch = t.lastIndexOf('<channel|>');
  if (ch >= 0) t = t.substring(ch + '<channel|>'.length);
  if (streaming && ch < 0 && t.contains('<|channel>')) return '';
  // Qwen/DeepSeek: "<think>…</think>"
  t = t.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '');
  final open = t.indexOf('<think>');
  if (open >= 0) t = t.substring(0, open);
  final close = t.lastIndexOf('</think>');
  if (close >= 0) t = t.substring(close + '</think>'.length);
  // übrig gebliebene Steuer-Marker
  t = t.replaceAll(RegExp(r'<\|?(channel|turn|im_start|im_end|end_of_turn|start_of_turn|eot_id)\|?>'), '');
  return streaming ? t.trimLeft() : t.trim();
}


/// Eine Zeile, höchstens [max] Zeichen (für Kurzfassungen).
String compactLine(String t, int max) {
  final one = t.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > max ? '${one.substring(0, max)} …' : one;
}

/// Kurzfassung eines Agenten-Schritts: Werkzeug, Argumente, Kern der Beobachtung.
String stepDigest(String assistant, String? observation) {
  String head;
  try {
    final j = jsonDecode(assistant);
    if (j is Map && j['action'] != null) {
      final args = j['args'] is Map ? (j['args'] as Map).values.map((v) => '$v').join(', ') : '';
      head = '${j['action']}(${compactLine(args, 60)})';
    } else {
      head = compactLine(assistant, 80);
    }
  } catch (_) {
    head = compactLine(assistant, 80);
  }
  final obs = observation == null ? '' : ' → ${compactLine(observation.replaceFirst(RegExp(r'^\s*(Beobachtung|Ergebnis)[^:]*:\s*'), ''), 160)}';
  return '- $head$obs';
}
