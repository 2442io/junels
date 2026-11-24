import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/run_stats.dart';
import 'flows_page.dart';
import 'quick_nav.dart';
import 'theme.dart';

String _dur(int ms) {
  if (ms < 1000) return '$ms ms';
  final s = ms / 1000;
  if (s < 60) return '${s.toStringAsFixed(s < 10 ? 1 : 0)} s';
  final m = s ~/ 60;
  return '$m min ${(s % 60).round()} s';
}

String _num(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return b.toString();
}

String _pct(double r) => '${(r * 100).round()} %';

String _when(DateTime d) {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final time = '${two(d.hour)}:${two(d.minute)}';
  if (d.year == n.year && d.month == n.month && d.day == n.day) return 'heute $time';
  final y = n.subtract(const Duration(days: 1));
  if (d.year == y.year && d.month == y.month && d.day == y.day) return 'gestern $time';
  return '${d.day}.${d.month}. $time';
}

/// Überwachung: Läufe, Erfolgsquote, Dauer und Tokens je Prozess und externem Aufruf.
class MonitorPage extends StatefulWidget {
  const MonitorPage({super.key, this.source});
  final String? source; // null = alle, flow, mcp

  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> {
  int _days = 7;
  String? _source;

  @override
  void initState() {
    super.initState();
    _source = widget.source;
  }

  DateTime get _from => DateTime.now().subtract(Duration(days: _days));

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: app.runStats,
      builder: (context, _) {
        final runs = [for (final r in app.runStats.since(_from)) if (_source == null || r.source == _source) r];
        final sums = [for (final s in app.runStats.summaries(_from)) if (_source == null || s.source == _source) s];
        final all = RunSummary('', '', '')..runs.addAll(runs);
        final issues = <(RunSummary, String)>[
          for (final s in sums)
            if (s.count >= 3 && s.rate < 0.8)
              (s, 'nur ${_pct(s.rate)} erfolgreich')
            else if (s.last?.status == 'error')
              (s, 'letzter Lauf fehlgeschlagen: ${s.last!.error}')
            else if (s.avgMs > 180000)
              (s, 'langsam: Ø ${_dur(s.avgMs)}'),
        ];
        return Scaffold(
          appBar: JAppBar(title: const Text('Überwachung'), actions: [
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v != 'clear') return;
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Verlauf löschen?'),
                    content: const Text('Alle aufgezeichneten Läufe werden gelöscht. Prozesse und Chats bleiben.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Löschen')),
                    ],
                  ),
                );
                if (ok == true) await app.runStats.clear();
              },
              itemBuilder: (_) => const [PopupMenuItem(value: 'clear', child: Text('Verlauf löschen'))],
            ),
          ]),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
                Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 1, label: Text('24 h')),
                      ButtonSegment(value: 7, label: Text('7 Tage')),
                      ButtonSegment(value: 30, label: Text('30 Tage')),
                    ],
                    selected: {_days},
                    onSelectionChanged: (v) => setState(() => _days = v.first),
                  ),
                  for (final (v, l) in const [(null, 'Alle'), ('flow', 'Prozesse'), ('mcp', 'Externe Aufrufe')])
                    ChoiceChip(label: Text(l), selected: _source == v, onSelected: (_) => setState(() => _source = v)),
                ]),
                const SizedBox(height: 12),
                _Tiles(sum: all),
                const SizedBox(height: 12),
                if (runs.isNotEmpty) _Chart(runs: runs, days: _days),
                if (issues.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Auffällig', style: t.titleSmall),
                  const SizedBox(height: 6),
                  for (final (s, why) in issues)
                    Card(
                      color: c.amberSoft,
                      child: ListTile(
                        leading: Icon(Icons.warning_amber_rounded, color: c.amber),
                        title: Text(s.name),
                        subtitle: Text(why, maxLines: 2, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(context, s),
                      ),
                    ),
                ],
                const SizedBox(height: 16),
                Text(sums.isEmpty ? 'Noch keine Läufe im Zeitraum' : 'Nach Prozess / Werkzeug', style: t.titleSmall),
                if (sums.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Sobald Prozesse laufen oder andere Programme Junels über MCP aufrufen, erscheinen hier Dauer, '
                        'Erfolgsquote und verbrauchte Tokens.', style: t.bodySmall),
                  ),
                const SizedBox(height: 6),
                for (final s in sums)
                  Card(
                    child: ListTile(
                      leading: Icon(s.source == 'mcp' ? Icons.cable_outlined : Icons.account_tree_outlined),
                      title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          '${s.count} Läufe · Ø ${_dur(s.avgMs)}${s.tokens > 0 ? ' · ${_num(s.tokens)} Tokens' : ''}'
                          '${s.last == null ? '' : ' · zuletzt ${_when(s.last!.start)}'}',
                          maxLines: 2),
                      trailing: Text(_pct(s.rate),
                          style: t.titleSmall?.copyWith(color: s.rate >= 0.95 ? c.mint : (s.rate >= 0.8 ? c.amber : c.red))),
                      onTap: () => _open(context, s),
                    ),
                  ),
                const SizedBox(height: 12),
                Text(
                    'Tokens werden bei Cloud- und Server-Modellen vom Anbieter gemeldet, beim lokalen Modell gezählt. '
                    'Die Aufzeichnung bleibt auf dem Gerät (90 Tage).',
                    style: t.bodySmall),
              ]),
            ),
          ),
        );
      },
    );
  }

  void _open(BuildContext context, RunSummary s) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => _RunDetailPage(refId: s.refId, source: s.source, name: s.name, days: _days)));
}

class _Tiles extends StatelessWidget {
  const _Tiles({required this.sum});
  final RunSummary sum;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    Widget tile(String label, String value, {Color? color}) => Container(
          width: 150,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(Ui.r)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: t.titleLarge?.copyWith(color: color)),
            const SizedBox(height: 2),
            Text(label, style: t.bodySmall),
          ]),
        );
    return Wrap(spacing: 8, runSpacing: 8, children: [
      tile('Läufe', '${sum.count}'),
      tile('erfolgreich', sum.count == 0 ? '–' : _pct(sum.rate),
          color: sum.count == 0 ? null : (sum.rate >= 0.95 ? c.mint : (sum.rate >= 0.8 ? c.amber : c.red))),
      tile('Ø Dauer', sum.count == 0 ? '–' : _dur(sum.avgMs)),
      tile('Tokens', _num(sum.tokens)),
      tile('Modellaufrufe', _num(sum.calls)),
    ]);
  }
}

/// Balken je Stunde (24 h) oder Tag: grün erfolgreich, rot Fehler.
class _Chart extends StatelessWidget {
  const _Chart({required this.runs, required this.days});
  final List<RunRecord> runs;
  final int days;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final now = DateTime.now();
    final hourly = days == 1;
    final n = hourly ? 24 : days;
    final ok = List.filled(n, 0), bad = List.filled(n, 0);
    for (final r in runs) {
      final idx = hourly
          ? n - 1 - now.difference(r.start).inHours
          : n - 1 - DateTime(now.year, now.month, now.day).difference(DateTime(r.start.year, r.start.month, r.start.day)).inDays;
      if (idx < 0 || idx >= n) continue;
      r.ok ? ok[idx]++ : bad[idx]++;
    }
    var max = 1;
    for (var i = 0; i < n; i++) {
      if (ok[i] + bad[i] > max) max = ok[i] + bad[i];
    }
    String label(int i) {
      if (hourly) return '${now.subtract(Duration(hours: n - 1 - i)).hour}';
      final d = now.subtract(Duration(days: n - 1 - i));
      return '${d.day}.';
    }

    final every = n <= 8 ? 1 : (n <= 24 ? 4 : 5);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(Ui.r)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(hourly ? 'Läufe je Stunde' : 'Läufe je Tag', style: t.labelMedium),
          const Spacer(),
          Container(width: 10, height: 10, color: c.mint),
          const SizedBox(width: 4),
          Text('ok', style: t.labelSmall),
          const SizedBox(width: 10),
          Container(width: 10, height: 10, color: c.red),
          const SizedBox(width: 4),
          Text('Fehler', style: t.labelSmall),
        ]),
        const SizedBox(height: 10),
        SizedBox(
          height: 90,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (var i = 0; i < n; i++)
              Expanded(
                child: Tooltip(
                  message: '${label(i)}${hourly ? ' Uhr' : ''}: ${ok[i]} ok, ${bad[i]} Fehler',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1.5),
                    child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                      if (bad[i] > 0)
                        Container(height: 86 * bad[i] / max, decoration: BoxDecoration(color: c.red, borderRadius: BorderRadius.circular(2))),
                      if (ok[i] > 0)
                        Container(height: 86 * ok[i] / max, decoration: BoxDecoration(color: c.mint, borderRadius: BorderRadius.circular(2))),
                      if (ok[i] + bad[i] == 0) Container(height: 2, color: c.border),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 4),
        Row(children: [
          for (var i = 0; i < n; i++)
            Expanded(
              child: Text(i % every == (n - 1) % every ? label(i) : '',
                  textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.visible, style: t.labelSmall?.copyWith(fontSize: 10)),
            ),
        ]),
      ]),
    );
  }
}

class _RunDetailPage extends StatelessWidget {
  const _RunDetailPage({required this.refId, required this.source, required this.name, required this.days});
  final String refId;
  final String source;
  final String name;
  final int days;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: app.runStats,
      builder: (context, _) {
        final from = DateTime.now().subtract(Duration(days: days));
        final s = RunSummary(refId, name, source)
          ..runs.addAll([for (final r in app.runStats.since(from)) if (r.refId == refId && r.source == source) r]);
        final isFlow = source == 'flow' && app.flows.flows.any((f) => f.id == refId);
        final models = {for (final r in s.runs) ...r.models};
        return Scaffold(
          appBar: JAppBar(title: Text(name, overflow: TextOverflow.ellipsis)),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
                Text('Letzte $days ${days == 1 ? 'Tag' : 'Tage'}${models.isEmpty ? '' : ' · Modelle: ${models.join(', ')}'}', style: t.bodySmall),
                const SizedBox(height: 8),
                _Tiles(sum: s),
                if (isFlow) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FlowEditor(id: refId))),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Prozess öffnen'),
                    ),
                  ),
                ],
                if (s.nodeStats.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Bausteine (langsamste zuerst)', style: t.titleSmall),
                  const SizedBox(height: 6),
                  Card(
                    child: Column(children: [
                      for (final n in s.nodeStats)
                        ListTile(
                          dense: true,
                          title: Text(n.title),
                          subtitle: Text('${n.count}× · ${n.type}'),
                          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text('Ø ${_dur(n.avgMs)}', style: t.bodyMedium),
                            if (n.errors > 0) Text('${n.errors} Fehler', style: t.labelSmall?.copyWith(color: c.red)),
                          ]),
                        ),
                    ]),
                  ),
                ],
                const SizedBox(height: 16),
                Text('Läufe', style: t.titleSmall),
                const SizedBox(height: 6),
                for (final r in s.runs.reversed.take(60))
                  Card(
                    child: ListTile(
                      leading: Icon(
                          r.ok ? Icons.check_circle_outline : (r.status == 'stopped' ? Icons.stop_circle_outlined : Icons.error_outline),
                          color: r.ok ? c.mint : (r.status == 'stopped' ? c.muted : c.red)),
                      title: Text('${_when(r.start)} · ${_dur(r.ms)}'),
                      subtitle: Text(
                          [
                            if (r.trigger.isNotEmpty) r.trigger,
                            if (r.calls > 0) '${r.calls} Modellaufrufe',
                            if (r.tokensIn + r.tokensOut > 0) '${_num(r.tokensIn)} → ${_num(r.tokensOut)} Tokens',
                            if (r.tools > 0) '${r.tools} Werkzeuge${r.toolErrors > 0 ? ' (${r.toolErrors} Fehler)' : ''}',
                            if (r.error.isNotEmpty) r.error,
                          ].join(' · '),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ),
              ]),
            ),
          ),
        );
      },
    );
  }
}
