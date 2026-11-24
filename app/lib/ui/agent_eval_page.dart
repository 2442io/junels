import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_scope.dart';
import '../state/native_files.dart';
import 'quick_nav.dart';
import 'theme.dart';

/// Agent-Test-Satz mit dem eigenen Modell: 34 typische Aufträge, Werkzeuge ohne Wirkung.
class AgentEvalPage extends StatefulWidget {
  const AgentEvalPage({super.key});

  @override
  State<AgentEvalPage> createState() => _AgentEvalPageState();
}

class _AgentEvalPageState extends State<AgentEvalPage> {
  @override
  void initState() {
    super.initState();
    AppScope.read(context).agentEval.detectLevel();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final ev = app.agentEval;
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: ev,
      builder: (context, _) {
        final rep = ev.report;
        final level = ev.levelChoice == 0 ? (ev.autoLevel == 0 ? 2 : ev.autoLevel) : ev.levelChoice;
        // fair vergleichen: nur gleiches Modell und gleiche Stufe
        final prev = rep == null ? null : ev.previousFor(rep.model, rep.level, except: rep.started);
        final passedNow = ev.results.where((r) => r.passed).length;
        final countedNow = ev.results.where((r) => !r.skipped).length;
        return Scaffold(
          appBar: JAppBar(title: const Text('Agent-Test-Satz'), actions: [
            if (rep != null)
              IconButton(
                tooltip: 'Bericht teilen',
                icon: Icon(Platform.isMacOS ? Icons.ios_share : Icons.share),
                onPressed: () async {
                  final f = File('${Directory.systemTemp.path}/junels-agent-test.md');
                  await f.writeAsString(rep.toMarkdown());
                  await NativeFiles.share(f.path);
                },
              ),
            if (rep != null)
              IconButton(
                tooltip: 'Bericht kopieren',
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: rep.toMarkdown()));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Bericht kopiert')));
                },
              ),
          ]),
          body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
            Text(
                '${casesForLevel(level).length} typische Aufträge – Wetter, Kalender, Mail, Spotify, Präsentation, Rechnen … '
                'Junels löst sie mit deinem eingestellten Modell. Die Werkzeuge sind Attrappen: Es wird nichts gesendet, '
                'gebucht oder gespeichert. Geprüft wird, ob das richtige Werkzeug benutzt wird und das Ergebnis in der Antwort steht.',
                style: t.bodySmall?.copyWith(color: c.muted)),
            const SizedBox(height: 12),
            Text('Stufe', style: t.labelLarge),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ChoiceChip(
                label: Text(ev.autoLevel == 0 ? 'Automatisch' : 'Automatisch: ${evalLevels[ev.autoLevel]}'),
                selected: ev.levelChoice == 0,
                onSelected: ev.running ? null : (_) => setState(() => ev.levelChoice = 0),
              ),
              for (final e in evalLevels.entries)
                ChoiceChip(
                  label: Text('${e.value} (${casesForLevel(e.key).length})'),
                  selected: ev.levelChoice == e.key,
                  onSelected: ev.running ? null : (_) => setState(() => ev.levelChoice = e.key),
                ),
            ]),
            const SizedBox(height: 6),
            Text(
                '${switch (level) {
                  1 => 'Basis: einfache Aufträge mit einem Werkzeug – passend für kleine Modelle bis ca. 4B.',
                  2 => 'Fortgeschritten: zusätzlich Folgefragen, mehrere Aufrufe, leere Ergebnisse – ab ca. 7B.',
                  _ => 'Profi: zusätzlich Aufträge über mehrere Werkzeuge, Bezug auf den Verlauf, unklare Aufträge – ab ca. 10B und Cloud.',
                }}${ev.autoModel.isEmpty ? '' : '\nModell: ${ev.autoModel}'}',
                style: t.bodySmall?.copyWith(color: c.muted)),
            const SizedBox(height: 12),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        ev.running
                            ? 'Läuft … ${ev.done}/${ev.total}'
                            : rep != null
                                ? '${rep.passed}/${rep.counted} bestanden (${(rep.score * 100).round()} %)'
                                : (ev.history.isEmpty ? 'Noch nicht gelaufen' : 'Zuletzt ${ev.history.first.passed}/${ev.history.first.counted}'),
                        style: t.titleMedium,
                      ),
                      if (ev.running && countedNow > 0) Text('bisher $passedNow/$countedNow bestanden', style: t.bodySmall),
                      if (rep != null)
                        Text('${rep.model} · Stufe ${evalLevels[rep.level]} · Ø ${(rep.avgMs / 1000).toStringAsFixed(1)} s je Auftrag',
                            style: t.bodySmall),
                      if (prev != null && rep != null)
                        Text(
                            'Vorher (gleiches Modell, gleiche Stufe): ${prev.passed}/${prev.counted} – '
                            '${rep.passed - prev.passed >= 0 ? '+' : ''}${rep.passed - prev.passed}',
                            style: t.bodySmall?.copyWith(color: rep.passed >= prev.passed ? c.mint : c.red)),
                    ]),
                  ),
                  if (ev.running)
                    OutlinedButton(onPressed: ev.cancel, child: const Text('Stopp'))
                  else
                    FilledButton.icon(
                      onPressed: () => ev.run(),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(rep == null ? 'Starten' : 'Erneut'),
                    ),
                ]),
                if (ev.running) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(value: ev.total == 0 ? null : ev.done / ev.total),
                  const SizedBox(height: 6),
                  Text('Dauert mit einem lokalen Modell ca. ${(ev.total * 10 / 60).round()}–${(ev.total * 30 / 60).round()} Minuten. '
                      'Junels kann währenddessen nicht chatten.',
                      style: t.bodySmall),
                ],
                if (ev.error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(ev.error!, style: t.bodySmall?.copyWith(color: c.red))),
              ]),
            ),
            if (rep != null) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final e in rep.byArea.entries)
                  Chip(
                    label: Text('${e.key} ${e.value.$1}/${e.value.$2}'),
                    backgroundColor: e.value.$1 == e.value.$2 ? c.mintSoft : null,
                  ),
              ]),
            ],
            const SizedBox(height: 12),
            for (final r in ev.results.reversed)
              Card(
                child: ExpansionTile(
                  leading: Icon(
                    r.skipped ? Icons.remove_circle_outline : (r.passed ? Icons.check_circle : Icons.cancel),
                    color: r.skipped ? c.faint : (r.passed ? c.mint : c.red),
                  ),
                  title: Text(r.c.prompt, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      r.skipped
                          ? 'übersprungen – ${r.problems.join('; ')}'
                          : '${(r.ms / 1000).toStringAsFixed(1)} s · ${r.called.isEmpty ? 'ohne Werkzeug' : r.called.join(', ')}'
                              '${r.problems.isEmpty ? '' : '\n${r.problems.join('; ')}'}',
                      style: t.bodySmall?.copyWith(color: r.passed || r.skipped ? null : c.red)),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Antwort:', style: t.labelSmall),
                    Text(r.answer.isEmpty ? '–' : r.answer, style: t.bodySmall),
                    const SizedBox(height: 6),
                    Text('Angeboten: ${r.offered.isEmpty ? 'keine Werkzeuge' : r.offered.join(', ')} · ${r.steps} Schritte · ${r.tokens} Tokens',
                        style: t.labelSmall?.copyWith(color: c.faint)),
                  ],
                ),
              ),
            if (ev.history.length > 1 && !ev.running) ...[
              const SectionLabel('Verlauf', padding: EdgeInsets.fromLTRB(4, 16, 4, 6)),
              for (final h in ev.history)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${h.passed}/${h.counted} · ${h.model} · ${evalLevels[h.level]}'),
                  subtitle: Text('${h.at.day}.${h.at.month}. ${h.at.hour}:${h.at.minute.toString().padLeft(2, '0')} · Ø ${(h.avgMs / 1000).toStringAsFixed(1)} s'
                      '${h.failed.isEmpty ? '' : ' · nicht bestanden: ${h.failed.keys.join(', ')}'}'),
                ),
            ],
          ]),
        );
      },
    );
  }
}
