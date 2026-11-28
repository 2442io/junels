// Auswertung: Nutzung, Themen, Funktionen, Tokens, Zeit – und geschätzte Ersparnis an Arbeitsstunden.

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/native_files.dart';
import '../state/usage_stats.dart';
import 'theme.dart';

class AnalyticsPage extends StatelessWidget {
  const AnalyticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = UsageStats.compute(app);
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final sync = app.sync;
    Widget kpi(String v, String label, Color color, IconData icon) => Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: c.panel, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(Ui.rLg)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 8),
            Text(v, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            Text(label, style: t.bodySmall?.copyWith(color: c.muted)),
          ]),
        );
    final local = s.local + s.cloud == 0 ? 0 : (s.local * 100 / (s.local + s.cloud)).round();
    return Scaffold(
      appBar: AppBar(title: const Text('Auswertung')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        Text('Berechnet auf diesem Gerät aus deinen Chats${s.first != null ? ' seit ${s.first!.day}.${s.first!.month}.${s.first!.year}' : ''}.',
            style: t.bodySmall?.copyWith(color: c.muted)),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, box) {
          final cols = box.maxWidth > 700 ? 4 : 2;
          return GridView.count(
            crossAxisCount: cols,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.55,
            children: [
              kpi(UsageStats.fmtHours(s.savedHours), 'Arbeitszeit gespart (geschätzt)', c.mint, Icons.savings_outlined),
              kpi(UsageStats.fmtHours(s.usageHours), 'Nutzungszeit', c.blue, Icons.schedule),
              kpi(UsageStats.fmtNum(s.messages), 'Anfragen in ${s.chats} Chats', c.violet, Icons.forum_outlined),
              kpi(UsageStats.fmtNum(s.tokens), 'Tokens (ca.)', c.amber, Icons.token_outlined),
              kpi('${s.activeDays}', 'aktive Tage', c.blue, Icons.calendar_today_outlined),
              kpi(UsageStats.fmtHours(s.agentHours), 'Rechenzeit der KI', c.violet, Icons.memory),
              kpi('${s.docs}', 'Dokumente erstellt', c.amber, Icons.description_outlined),
              kpi('$local %', 'auf dem Gerät beantwortet', c.mint, Icons.phone_android),
            ],
          );
        }),
        _Section('Verlauf (12 Wochen)', child: _Weeks(s.lastWeeks)),
        _Section('Themengebiete', child: _Bars(s.topTopics, c.violet)),
        _Section('Funktionen', child: _Bars(s.topFeatures, c.blue)),
        _Section('Gesparte Zeit nach Art', child: _Bars(s.topSaved, c.mint, hours: true)),
        if (s.topSkills.isNotEmpty) _Section('Skills', child: _Bars(s.topSkills, c.amber)),
        _Section('Tageszeit', child: _Hours(s.hours)),
        const SizedBox(height: 8),
        Text('Ersparnis: grobe Schätzung je Antwort (z. B. Web-Recherche 8 min, Word-Dokument 25 min, Präsentation 40 min, '
            'Mitschrift 1,5 × Gesprächsdauer, einfache Antwort 2 min). Tokens aus Tempo × Dauer.',
            style: t.bodySmall?.copyWith(color: c.faint)),
        const Divider(height: 32),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Im Admin-Bereich anzeigen'),
          subtitle: const Text('Beim Abgleich nur diese Zahlen an deine Agent-API senden – keine Inhalte, keine Chat-Titel.'),
          value: sync.config.shareStats,
          onChanged: (v) async {
            sync.config.shareStats = v;
            await sync.saveConfig();
            app.refreshUi();
            if (v) await sync.uploadStats();
          },
        ),
        if (sync.config.serverUrl.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                await sync.uploadStats();
                await NativeFiles.openUrl('${sync.accountPage}#analytics');
              },
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Admin-Bereich öffnen'),
            ),
          ),
      ]),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, {required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: t.titleMedium),
        const SizedBox(height: 10),
        child,
      ]),
    );
  }
}

class _Bars extends StatelessWidget {
  const _Bars(this.items, this.color, {this.hours = false});
  final List<MapEntry<String, num>> items;
  final Color color;
  final bool hours;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    if (items.isEmpty) return Text('Noch keine Daten.', style: t.bodySmall?.copyWith(color: c.muted));
    final max = items.map((e) => e.value).fold<num>(0, (a, b) => b > a ? b : a);
    return Column(children: [
      for (final e in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            SizedBox(width: 150, child: Text(e.key, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyMedium)),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(value: max == 0 ? 0 : e.value / max, minHeight: 10, color: color, backgroundColor: c.raised),
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(hours ? UsageStats.fmtHours(e.value.toDouble()) : '${e.value}', textAlign: TextAlign.right, style: t.bodySmall),
            ),
          ]),
        ),
    ]);
  }
}

class _Weeks extends StatelessWidget {
  const _Weeks(this.weeks);
  final List<(String, int, double)> weeks;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final max = weeks.fold<int>(1, (a, w) => w.$2 > a ? w.$2 : a);
    return SizedBox(
      height: 150,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (final w in weeks)
          Expanded(
            child: Tooltip(
              message: '${w.$1}: ${w.$2} Anfragen · ${UsageStats.fmtHours(w.$3)} gespart',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  if (w.$2 > 0) Text('${w.$2}', style: t.labelSmall?.copyWith(color: c.muted)),
                  const SizedBox(height: 2),
                  Container(
                    height: 110 * w.$2 / max + 2,
                    decoration: BoxDecoration(color: c.blue, borderRadius: BorderRadius.circular(4)),
                  ),
                  const SizedBox(height: 4),
                  Text(w.$1.split('-W').last, style: t.labelSmall?.copyWith(color: c.faint)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

class _Hours extends StatelessWidget {
  const _Hours(this.hours);
  final List<int> hours;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final max = hours.fold<int>(1, (a, b) => b > a ? b : a);
    return SizedBox(
      height: 90,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (var h = 0; h < 24; h++)
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
              Container(
                height: 60 * hours[h] / max + 2,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                decoration: BoxDecoration(color: c.violet.withValues(alpha: 0.35 + 0.65 * hours[h] / max), borderRadius: BorderRadius.circular(3)),
              ),
              const SizedBox(height: 4),
              Text(h % 6 == 0 ? '$h' : '', style: t.labelSmall?.copyWith(color: c.faint)),
            ]),
          ),
      ]),
    );
  }
}
