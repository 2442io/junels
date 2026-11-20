// Agenten-Schleife Thought → Action → Observation (SRS Abschnitt 5).

import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';

import '../llama_engine.dart';
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

class AgentFinished extends AgentEvent {
  AgentFinished(this.reason, {this.message});
  final AgentStopReason reason;
  final String? message;
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
  });

  /// Chinesische/japanische/koreanische Schriftzeichen in der Ausgabe sperren
  /// (verhindert das Abdriften von Qwen-Modellen ins Chinesische).
  final bool blockCjk;

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
      final n = await engine.countTokens(await engine.formatChat(
          [ChatMessage('system', buildSystemPrompt(ctx)), ChatMessage('user', input)]));
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
      b.writeln('- Schlägt ein Tool fehl, nenne dem Nutzer den konkreten Grund (z. B. „Amazon blockiert automatische Abrufe“) '
          'und probiere einen anderen Weg. Behaupte nie pauschal, du hättest keinen Zugriff.');
      b.writeln('- Rechne nie im Kopf, wenn calculator verfügbar ist.');
      b.writeln('- final_answer in der Sprache des Nutzers, Markdown erlaubt.');
      if (activeTools.any((t) => t.name == 'web_fetch' || t.name == 'web_search')) {
        b.writeln('- Du KANNST das Internet nutzen: web_fetch liest eine Webseite (z. B. eine vom Nutzer genannte URL), '
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
        await controller.close();
      }
    }();
    return controller.stream;
  }

  // ---------------------------------------------------------------- Chat-Modus

  Future<void> _runChat(List<ChatMessage> history, String input, ToolContext ctx,
      void Function(AgentEvent) emit) async {
    emit(StepStarted(1));
    final messages = [ChatMessage('system', buildSystemPrompt(ctx))];
    final prompt = await _fitPrompt(
      system: messages.first.content,
      history: history,
      input: input,
      scratch: const [],
      reserve: math.min(maxTokensPerStep * 2, (engine.contextSize * 0.4).round()),
    );
    final raw = StringBuffer();
    GenerationStats? stats;
    FinishReason reason = FinishReason.done;
    String? error;
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

  Future<void> _runAgent(List<ChatMessage> history, String input, ToolContext ctx,
      void Function(AgentEvent) emit) async {
    await _selectTools(input, ctx);
    final system = buildSystemPrompt(ctx);
    final scratch = <ChatMessage>[];
    final grammar = AgentGrammar.build(activeTools, blockCjk: blockCjk);
    final finalOnly = AgentGrammar.build(activeTools, allowTools: false, blockCjk: blockCjk);
    String? lastCall;

    String? hint; // einmaliger Hinweis an das Modell (nicht Teil des Verlaufs)

    for (var step = 1; step <= maxSteps + 1; step++) {
      if (_stopped) {
        emit(AgentFinished(AgentStopReason.stopped));
        return;
      }
      final forceFinal = step > maxSteps;
      if (forceFinal) {
        hint = 'Schrittlimit erreicht. Gib jetzt mit den vorhandenen Informationen die final_answer.';
      }
      emit(StepStarted(step));

      final prompt = await _fitPrompt(
        system: system,
        history: history,
        input: input,
        scratch: [...scratch, if (hint != null) ChatMessage('user', hint)],
        reserve: _reserve,
      );
      hint = null;

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
      if (stats != null) emit(MetricsUpdate(stats));
      final text = raw.toString();

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
      if (obj.containsKey('final_answer')) {
        emit(FinalAnswer(obj['final_answer'].toString(), thought: thought));
        emit(AgentFinished(forceFinal ? AgentStopReason.stepLimit : AgentStopReason.answered));
        return;
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
      if (callKey == lastCall) {
        observation = 'Du hast dieses Tool gerade mit denselben Argumenten aufgerufen. '
            'Nutze das bisherige Ergebnis und gib die final_answer.';
        isError = true;
      } else {
        final tool = activeTools.where((t) => t.name == toolName).firstOrNull;
        if (tool == null) {
          observation = 'Unbekanntes Tool "$toolName".';
          isError = true;
        } else {
          try {
            observation = await tool.run(args, ctx).timeout(toolTimeout);
          } on TimeoutException {
            observation = 'Fehler: Zeitüberschreitung nach ${toolTimeout.inSeconds} s.';
            isError = true;
          } catch (e) {
            observation = 'Fehler: $e';
            isError = true;
          }
        }
      }
      lastCall = callKey;
      sw.stop();
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
      emit(ToolResult(step, toolName, shown, isError: isError, duration: sw.elapsed));
      scratch.add(ChatMessage('user', 'Beobachtung ($toolName):\n$observation'));
    }
    emit(AgentFinished(AgentStopReason.stepLimit,
        message: 'Das Modell hat nach ${maxSteps + 1} Schritten keine gültige Antwort geliefert.'));
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
    var summarized = false;
    while (true) {
      final msgs = [
        ChatMessage('system', system),
        ...hist,
        ChatMessage('user', inputText),
        if (summarized)
          const ChatMessage('user', '[Frühere Schritte wurden aus Platzgründen gekürzt.]'),
        ...work,
      ];
      final prompt = await engine.formatChat(msgs);
      final n = await engine.countTokens(prompt);
      if (n <= budget) return prompt;

      if (hist.isNotEmpty) {
        hist.removeAt(0);
        continue;
      }
      // ältesten Schritt (assistant + Beobachtung) entfernen, der letzte bleibt
      if (work.length > 2) {
        work.removeAt(0);
        if (work.length > 2 && work.first.role == 'user') work.removeAt(0);
        summarized = true;
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
      throw EngineException(
          'Die Anfrage ist zu lang für das Context-Fenster ($n Tokens, Budget $budget). '
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
