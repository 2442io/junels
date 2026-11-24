import 'dart:convert';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/foundation.dart';

import 'app_controller.dart';

/// Kurzfassung eines Laufs für den Vergleich vorher/nachher.
class EvalRun {
  EvalRun(this.at, this.model, this.passed, this.counted, this.avgMs, this.failed);
  final DateTime at;
  final String model;
  final int passed;
  final int counted;
  final int avgMs;
  final Map<String, String> failed; // Fall → Problem

  Map<String, Object?> toJson() =>
      {'at': at.toIso8601String(), 'model': model, 'passed': passed, 'counted': counted, 'avgMs': avgMs, 'failed': failed};
  factory EvalRun.fromJson(Map<String, dynamic> j) => EvalRun(DateTime.tryParse('${j['at']}') ?? DateTime(2026), '${j['model'] ?? ''}',
      (j['passed'] as num?)?.toInt() ?? 0, (j['counted'] as num?)?.toInt() ?? 0, (j['avgMs'] as num?)?.toInt() ?? 0,
      ((j['failed'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')));
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
      model = be is RemoteBackend ? be.config.name : (app.loadedModel?.displayName ?? 'Lokal');
      final tools = [
        for (final t in app.activeTools)
          if (!t.name.contains('__')) EvalStubTool.of(t)
      ];
      final cases = only == null ? agentCases : agentCases.where((c) => only.contains(c.id)).toList();
      total = cases.length;
      final ev = _ev = AgentEvaluator(
        backend: be,
        systemPrompt: app.evalSystemText,
        tools: tools,
        model: model,
        maxSteps: app.activeProfile.maxSteps.clamp(3, 8),
      );
      final rep = await app.runExclusive('agent-eval', () => ev.run(cases, onProgress: (d, _, r) {
            done = d;
            if (r != null) results.add(r);
            notifyListeners();
          }));
      report = rep;
      if (only == null && rep.counted > 0) {
        history.insert(
            0,
            EvalRun(rep.started, model, rep.passed, rep.counted, rep.avgMs,
                {for (final r in rep.results) if (!r.passed && !r.skipped) r.c.id: r.problems.join('; ')}));
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
