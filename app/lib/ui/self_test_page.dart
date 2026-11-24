// Selbsttest: Junels prüft sich auf diesem Gerät und erstellt einen Bericht zum Teilen.

import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_scope.dart';
import '../state/native_files.dart';
import '../state/self_test.dart';
import 'agent_eval_page.dart';
import 'quick_nav.dart';
import 'theme.dart';

void openSelfTest(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SelfTestPage()));

class SelfTestPage extends StatefulWidget {
  const SelfTestPage({super.key});

  @override
  State<SelfTestPage> createState() => _SelfTestPageState();
}

class _SelfTestPageState extends State<SelfTestPage> {
  SelfTest? _test;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final t = SelfTest(AppScope.read(context));
    setState(() {
      _test = t;
      _running = true;
    });
    await t.run(onProgress: () {
      if (mounted) setState(() {});
    });
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final t = _test;
    final results = t?.results ?? const <CheckResult>[];
    String? area;
    return Scaffold(
      appBar: JAppBar(title: const Text('Selbsttest'), actions: [
        IconButton(
          tooltip: 'Bericht kopieren',
          icon: const Icon(Icons.copy),
          onPressed: t == null || _running
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: t.report()));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Bericht kopiert')));
                },
        ),
        IconButton(
          tooltip: 'Bericht teilen',
          icon: Icon(Platform.isMacOS ? Icons.ios_share : Icons.share),
          onPressed: t == null || _running
              ? null
              : () async {
                  final f = File('${Directory.systemTemp.path}/junels-selbsttest.txt');
                  await f.writeAsString(t.report());
                  await NativeFiles.share(f.path);
                },
        ),
      ]),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
        Panel(
          child: Row(children: [
            _running
                ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3))
                : Icon(
                    t == null || t.failed > 0 ? Icons.error_outline : (t.warned > 0 ? Icons.warning_amber_rounded : Icons.verified_outlined),
                    size: 30,
                    color: t == null || t.failed > 0 ? c.red : (t.warned > 0 ? c.amber : c.mint)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                _running
                    ? 'Prüfe … (${results.length} erledigt)'
                    : t!.failed > 0
                        ? '${t.failed} Problem${t.failed == 1 ? '' : 'e'}, ${t.warned} Hinweis${t.warned == 1 ? '' : 'e'}'
                        : (t.warned > 0 ? 'Läuft – ${t.warned} Hinweis${t.warned == 1 ? '' : 'e'}' : 'Alles in Ordnung'),
                style: tt.titleMedium,
              ),
            ),
            if (!_running) OutlinedButton(onPressed: _run, child: const Text('Erneut')),
          ]),
        ),
        const SizedBox(height: 6),
        Text('Läuft nach jedem Update automatisch. Bei Problemen: Bericht teilen und mir schicken.',
            style: tt.bodySmall?.copyWith(color: c.muted)),
        const SizedBox(height: 10),
        Card(
          child: ListTile(
            leading: const Icon(Icons.fact_check_outlined),
            title: const Text('Agent-Test-Satz'),
            subtitle: Text(AppScope.of(context).agentEval.history.isEmpty
                ? 'Typische Aufträge mit deinem Modell lösen lassen – Stufe passend zur Modellgröße'
                : 'Zuletzt ${AppScope.of(context).agentEval.history.first.passed}/${AppScope.of(context).agentEval.history.first.counted} '
                    'bestanden (${AppScope.of(context).agentEval.history.first.model}, ${evalLevels[AppScope.of(context).agentEval.history.first.level]})'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AgentEvalPage())),
          ),
        ),
        for (final r in results) ...[
          if (r.area != area) ...[
            Builder(builder: (_) {
              area = r.area;
              return SectionLabel(r.area, padding: const EdgeInsets.fromLTRB(4, 16, 4, 4));
            }),
          ],
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              switch (r.state) {
                CheckState.ok => Icons.check_circle,
                CheckState.warn => Icons.warning_amber_rounded,
                CheckState.fail => Icons.cancel,
                CheckState.skip => Icons.remove_circle_outline,
              },
              color: switch (r.state) {
                CheckState.ok => c.mint,
                CheckState.warn => c.amber,
                CheckState.fail => c.red,
                CheckState.skip => c.faint,
              },
            ),
            title: Text(r.name),
            subtitle: Text(r.detail, maxLines: 4, overflow: TextOverflow.ellipsis),
            trailing: r.ms > 1500 ? MonoText('${(r.ms / 1000).toStringAsFixed(1)} s', color: c.muted) : null,
          ),
        ],
      ]),
    );
  }
}
