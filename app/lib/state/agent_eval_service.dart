import 'dart:convert';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/foundation.dart';

import 'app_controller.dart';

/// Kurzfassung eines Laufs für den Vergleich vorher/nachher.
class EvalRun {
  EvalRun(this.at, this.model, this.passed, this.counted, this.avgMs, this.failed, {this.level = 1});
  final int level;
  final DateTime at;
  final String model;
  final int passed;
  final int counted;
  final int avgMs;
  final Map<String, String> failed; // Fall → Problem

  Map<String, Object?> toJson() =>
      {'at': at.toIso8601String(), 'model': model, 'passed': passed, 'counted': counted, 'avgMs': avgMs, 'failed': failed, 'level': level};
  factory EvalRun.fromJson(Map<String, dynamic> j) => EvalRun(DateTime.tryParse('${j['at']}') ?? DateTime(2026), '${j['model'] ?? ''}',
      (j['passed'] as num?)?.toInt() ?? 0, (j['counted'] as num?)?.toInt() ?? 0, (j['avgMs'] as num?)?.toInt() ?? 0,
      ((j['failed'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')),
      level: (j['level'] as num?)?.toInt() ?? 1);
}

/// Agent-Test-Satz mit dem eingestellten Modell – Werkzeuge sind Attrappen (es wird nichts gesendet,
/// gebucht oder gespeichert). Misst, wie gut der Agent typische Aufträge löst.
class AgentEvalService extends ChangeNotifier {
  AgentEvalService(this.app, this._file);
  final AppController app;
  final File _file;

  final List<EvalRun> history = [];
  final List<CaseResult> results = [];
  bool running = false;
  int done = 0;
  int total = 0;
  String model = '';
  String? error;
  EvalReport? report;

  /// Gewählte Stufe: 0 = automatisch nach Modell
  int levelChoice = 0;

  /// Zuletzt ermittelte Stufe für das aktuelle Modell
  int autoLevel = 0;
  String autoModel = '';

  /// Stufe und Name für das Modell, das der Test benutzen würde (ohne zu laden)
  Future<(int, String)> detectLevel() async {
    final be = await app.evalBackend();
    if (be == null) return (2, '');
    final r = _tierOf(be);
    autoLevel = r.$1;
    autoModel = r.$2;
    if (be is RemoteBackend) be.close();
    notifyListeners();
    return r;
  }

  (int, String) _tierOf(AgentBackend be) {
    if (be is RemoteBackend) {
      final name = '${be.config.name} · ${be.config.model}';
      // eigener Server mit kleinem Modell (z. B. llama3.1:8b) → nach Größe, sonst Profi
      final hasSize = RegExp(r'\d+(\.\d+)?\s?b\b', caseSensitive: false).hasMatch(be.config.model);
      return (hasSize ? modelTier(be.config.model) : 3, name);
    }
    final m = app.loadedModel;
    final name = m?.displayName ?? 'Lokal';
    return (modelTier(name, bytes: m?.sizeBytes ?? 0), name);
  }

  /// Letzter Lauf mit gleichem Modell und gleicher Stufe (für einen fairen Vergleich)
  EvalRun? previousFor(String model, int level, {DateTime? except}) =>
      history.where((h) => h.model == model && h.level == level && h.at != except).firstOrNull;
  AgentEvaluator? _ev;

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final j = jsonDecode(await _file.readAsString()) as List;
      history
        ..clear()
        ..addAll([for (final x in j) EvalRun.fromJson((x as Map).cast())]);
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      await _file.writeAsString(jsonEncode([for (final r in history) r.toJson()]));
    } catch (_) {}
  }

  void cancel() => _ev?.cancel();

  Future<void> run({Set<String>? only}) async {
    if (running) return;
    running = true;
    error = null;
    results.clear();
    report = null;
    done = 0;
    notifyListeners();
    try {
      final be = await app.evalBackend();
      if (be == null) throw Exception('Kein Modell bereit – zuerst ein Modell laden oder einen KI-Anbieter einrichten.');
      final (tier, name) = _tierOf(be);
      model = name;
      autoLevel = tier;
      autoModel = name;
      final level = levelChoice == 0 ? tier : levelChoice;
      final tools = [
        for (final t in app.activeTools)
          if (!t.name.contains('__')) EvalStubTool.of(t)
      ];
      final cases = only == null ? casesForLevel(level) : agentCases.where((c) => only.contains(c.id)).toList();
      total = cases.length;
      final ev = _ev = AgentEvaluator(
        backend: be,
        systemPrompt: app.evalSystemText,
        tools: tools,
        model: model,
        maxSteps: app.activeProfile.maxSteps.clamp(3, 8),
      );
      final rep = await app.runExclusive('agent-eval', () => ev.run(cases, level: level, onProgress: (d, _, r) {
            done = d;
            if (r != null) results.add(r);
            notifyListeners();
          }));
      report = rep;
      if (only == null && rep.counted > 0) {
        history.insert(
            0,
            EvalRun(rep.started, model, rep.passed, rep.counted, rep.avgMs,
                {for (final r in rep.results) if (!r.passed && !r.skipped) r.c.id: r.problems.join('; ')},
                level: level));
        if (history.length > 12) history.removeRange(12, history.length);
        await _save();
      }
      if (be is RemoteBackend) be.close();
    } catch (e) {
      error = '$e'.replaceFirst('Exception: ', '');
    } finally {
      running = false;
      _ev = null;
      notifyListeners();
    }
  }
}
