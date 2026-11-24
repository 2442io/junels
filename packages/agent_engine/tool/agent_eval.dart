// Live-Test des Agenten mit einem echten Modell (CI: .github/workflows/agent-eval.yml).
// dart run tool/agent_eval.dart <modell.gguf> [fall,fall,…]
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Aufruf: dart run tool/agent_eval.dart <modell.gguf> [fall,fall,…]');
    exit(2);
  }
  final only = args.length > 1 ? args[1].split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet() : <String>{};
  final cases = only.isEmpty ? agentCases : agentCases.where((c) => only.contains(c.id)).toList();
  final model = args[0].split('/').last;
  stdout.writeln('Lade $model …');
  final engine = await LlamaEngine.load(EngineConfig(
    modelPath: args[0],
    contextSize: int.tryParse(Platform.environment['EVAL_CTX'] ?? '') ?? 8192,
    threads: Platform.numberOfProcessors,
  ));
  final harness = Platform.environment['EVAL_HARNESS'] != '0';
  final ev = AgentEvaluator(
      backend: engine, systemPrompt: evalSystemPrompt, tools: evalToolSpecs, model: '$model${harness ? '' : ' (ohne Harness)'}', useHarness: harness);
  final rep = await ev.run(cases, onProgress: (done, total, r) {
    if (r == null) return;
    stdout.writeln('[$done/$total] ${r.passed ? 'OK  ' : (r.skipped ? 'SKIP' : 'FAIL')} ${r.c.id} '
        '(${(r.ms / 1000).toStringAsFixed(1)} s, ${r.called.isEmpty ? 'keine Werkzeuge' : r.called.join(', ')})'
        '${r.problems.isEmpty ? '' : ' – ${r.problems.join('; ')}'}');
  });
  final md = rep.toMarkdown();
  stdout.writeln('\n$md');
  final summary = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (summary != null && summary.isNotEmpty) File(summary).writeAsStringSync(md, mode: FileMode.append);
  File('agent_eval_report.md').writeAsStringSync(md);
  await engine.dispose();
  exit(0);
}
