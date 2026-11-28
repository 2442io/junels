// Guardrails: Leitplanken für den Agenten einstellen (Aus / Standard / Streng, Aktionen, Budgets, Themen, eigene Regeln).

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../state/app_scope.dart';
import '../state/guardrails.dart';
import 'theme.dart';

void openGuardrails(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GuardrailsPage()));

class GuardrailsPage extends StatefulWidget {
  const GuardrailsPage({super.key});

  @override
  State<GuardrailsPage> createState() => _GuardrailsPageState();
}

class _GuardrailsPageState extends State<GuardrailsPage> {
  final _rule = TextEditingController();
  final _blocked = TextEditingController();

  @override
  void dispose() {
    _rule.dispose();
    _blocked.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final g = app.guard;
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    Future<void> save() async {
      await app.saveGuard();
      if (mounted) setState(() {});
    }

    Widget section(String title, String sub, List<Widget> children) => Card(
          margin: const EdgeInsets.only(bottom: 14),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: t.titleMedium),
              const SizedBox(height: 2),
              Text(sub, style: t.bodySmall?.copyWith(color: c.muted)),
              const SizedBox(height: 10),
              ...children,
            ]),
          ),
        );
    final on = g.on;
    String ruleLabel(String r) => switch (r) {
          'allow' => tr('erlaubt'),
          'ask' => tr('Rückfrage'),
          'block' => tr('gesperrt'),
          _ => tr('wie Stufe'),
        };
    return Scaffold(
      appBar: AppBar(title: const Text('Guardrails')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        Text(tr('Leitplanken für den Agenten: was er prüft, was er fragen muss und was er nie tut. Alles läuft auf dem Gerät.'),
            style: t.bodyMedium?.copyWith(color: c.muted)),
        const SizedBox(height: 14),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'off', label: Text(tr('Aus')), icon: const Icon(Icons.shield_outlined, size: 18)),
            ButtonSegment(value: 'standard', label: Text(tr('Standard')), icon: const Icon(Icons.shield, size: 18)),
            ButtonSegment(value: 'strict', label: Text(tr('Streng')), icon: const Icon(Icons.gpp_good, size: 18)),
          ],
          selected: {g.level},
          showSelectedIcon: false,
          onSelectionChanged: (s) {
            g.level = s.first;
            save();
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 14),
          child: Text(
            switch (g.level) {
              'strict' => tr('Streng: Nachrichten, Web-Aktionen, Apps, Termine und externe Dienste nur mit Rückfrage; eigene Dateien ändern gesperrt; '
                  'kleine Budgets; auch E-Mail-Adressen und Telefonnummern werden vor Cloud-Modellen geschwärzt.'),
              'standard' => tr('Standard: versteckte Anweisungen werden erkannt, sensible Daten vor Cloud-Modellen geschwärzt, '
                  'Dateien ändern und externe Dienste nur mit Rückfrage.'),
              _ => tr('Aus: keine zusätzlichen Prüfungen (die Grundregeln wie „nie bezahlen, nie Passwörter tippen“ gelten immer).'),
            },
            style: t.bodySmall,
          ),
        ),
        Text(tr('Einzelne Ordner können eine eigene Stufe haben (Ordner-Menü → Guardrails).'), style: t.bodySmall?.copyWith(color: c.faint)),
        const SizedBox(height: 14),
        AbsorbPointer(
          absorbing: !on,
          child: Opacity(
            opacity: on ? 1 : 0.45,
            child: Column(children: [
              // 1. Eingang
              section(tr('1 · Eingang'), tr('Bevor das Modell etwas sieht'), [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Versteckte Anweisungen erkennen')),
                  subtitle: Text(tr('Webseiten, Mails und Dateien, die „Ignoriere alle Regeln …“ o. Ä. enthalten, werden als Daten markiert.')),
                  value: g.injection,
                  onChanged: (v) {
                    g.injection = v;
                    save();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Sensible Daten vor Cloud-Modellen schwärzen')),
                  subtitle: Text(tr('IBAN, Kartennummern, SV-Nummer, Passwörter und API-Schlüssel verlassen das Gerät nicht. Lokal bleibt alles lesbar.')),
                  value: g.redactCloud,
                  onChanged: (v) {
                    g.redactCloud = v;
                    save();
                  },
                ),
              ]),
              // 2. Aktionen
              section(tr('2 · Aktionen'), tr('Was der Agent tun darf – je Art'), [
                for (final a in GuardAction.all)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(tr(a.label)),
                    subtitle: Text(tr(a.detail)),
                    trailing: DropdownButton<String>(
                      value: g.actions[a.id] ?? 'auto',
                      underline: const SizedBox.shrink(),
                      items: [
                        for (final r in const ['auto', 'allow', 'ask', 'block'])
                          DropdownMenuItem(
                            value: r,
                            child: Text(r == 'auto' ? '${ruleLabel(r)} (${ruleLabel(Guard.ruleFor(g, g.level, a.id))})' : ruleLabel(r)),
                          ),
                      ],
                      onChanged: (v) {
                        if (v == null || v == 'auto') {
                          g.actions.remove(a.id);
                        } else {
                          g.actions[a.id] = v;
                        }
                        save();
                      },
                    ),
                  ),
                const Divider(height: 24),
                Text(tr('Budgets je Auftrag'), style: t.labelLarge),
                const SizedBox(height: 4),
                _Budget(
                    label: tr('Werkzeug-Aufrufe'),
                    value: g.maxToolCalls,
                    auto: g.level == 'strict' ? 10 : 25,
                    onChanged: (v) {
                      g.maxToolCalls = v;
                      save();
                    }),
                _Budget(
                    label: tr('Nachrichten an andere'),
                    value: g.maxSends,
                    auto: g.level == 'strict' ? 1 : 5,
                    onChanged: (v) {
                      g.maxSends = v;
                      save();
                    }),
                _Budget(
                    label: tr('Web-Aktionen (Klicks, Eingaben)'),
                    value: g.maxWebActions,
                    auto: g.level == 'strict' ? 8 : 30,
                    onChanged: (v) {
                      g.maxWebActions = v;
                      save();
                    }),
                const Divider(height: 24),
                Text(tr('Gesperrte Ziele'), style: t.labelLarge),
                Text(tr('Domains, E-Mail-Adressen oder Nummern, die der Agent nie anfassen darf.'), style: t.bodySmall),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final b in g.blocked)
                    InputChip(
                      label: Text(b),
                      onDeleted: () {
                        g.blocked.remove(b);
                        save();
                      },
                    ),
                ]),
                TextField(
                  controller: _blocked,
                  decoration: InputDecoration(hintText: tr('z. B. amazon.de oder chef@firma.at'), suffixIcon: const Icon(Icons.add)),
                  onSubmitted: (v) {
                    if (v.trim().isEmpty) return;
                    g.blocked.add(v.trim());
                    _blocked.clear();
                    save();
                  },
                ),
              ]),
              // 3. Ausgang
              section(tr('3 · Ausgang'), tr('Bevor eine Antwort erscheint oder etwas rausgeht'), [
                Text(tr('Themen nur allgemein'), style: t.labelLarge),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final tp in GuardTopic.all)
                    FilterChip(
                      label: Text(tr(tp.label)),
                      selected: g.topics.contains(tp.id),
                      onSelected: (v) {
                        v ? g.topics.add(tp.id) : g.topics.remove(tp.id);
                        save();
                      },
                    ),
                ]),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(value: 'hint', label: Text(tr('Nur allgemein + Verweis'))),
                    ButtonSegment(value: 'block', label: Text(tr('Nicht beantworten'))),
                  ],
                  selected: {g.topicMode},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) {
                    g.topicMode = s.first;
                    save();
                  },
                ),
                const SizedBox(height: 6),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Sensible Daten in Nachrichten bestätigen')),
                  subtitle: Text(tr('Enthält eine Mail oder WhatsApp an andere IBAN, Passwörter & Co., fragt Junels vorher.')),
                  value: g.piiOutbound,
                  onChanged: (v) {
                    g.piiOutbound = v;
                    save();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('KI-Prüfung der Antwort')),
                  subtitle: Text(tr('Das Modell prüft jede Antwort gegen Themen und eigene Regeln – genauer, dauert aber etwas länger. '
                      'Standard: Hinweis über der Antwort; Streng: Antwort wird zurückgehalten.')),
                  value: g.aiCheck,
                  onChanged: (v) {
                    g.aiCheck = v;
                    save();
                  },
                ),
              ]),
              // 4. Eigene Regeln
              section(tr('4 · Eigene Regeln'), tr('In normaler Sprache – gelten in jedem Chat, Skill und Ablauf'), [
                for (final r in g.rules)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(Icons.rule, color: c.mint),
                    title: Text(r),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        g.rules.remove(r);
                        save();
                      },
                    ),
                  ),
                TextField(
                  controller: _rule,
                  decoration: InputDecoration(
                    hintText: tr('z. B. Keine Käufe über 50 € · Nie Kundennamen an Cloud-Modelle schicken'),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.add),
                      onPressed: () {
                        if (_rule.text.trim().isEmpty) return;
                        g.rules.add(_rule.text.trim());
                        _rule.clear();
                        save();
                      },
                    ),
                  ),
                  onSubmitted: (v) {
                    if (v.trim().isEmpty) return;
                    g.rules.add(v.trim());
                    _rule.clear();
                    save();
                  },
                ),
                const SizedBox(height: 6),
                Text(tr('Regeln zu Mails, Käufen, Dateien, Apps oder Terminen machen die passende Aktion automatisch rückfragepflichtig.'),
                    style: t.bodySmall?.copyWith(color: c.faint)),
              ]),
            ]),
          ),
        ),
        // Protokoll
        section(tr('Protokoll'), tr('Wann die Guardrails eingegriffen haben (ohne Inhalte)'), [
          if (app.guardEvents.isEmpty) Text(tr('Noch keine Eingriffe.'), style: t.bodySmall),
          for (final e in app.guardEvents.take(30))
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                  switch (e.kind) {
                    'input' => Icons.input,
                    'action' => Icons.back_hand_outlined,
                    'output' => Icons.output,
                    _ => Icons.rule,
                  },
                  size: 18),
              title: Text(e.what),
              subtitle: Text('${e.at.day}.${e.at.month}. ${e.at.hour.toString().padLeft(2, '0')}:${e.at.minute.toString().padLeft(2, '0')}'),
            ),
        ]),
      ]),
    );
  }
}

class _Budget extends StatelessWidget {
  const _Budget({required this.label, required this.value, required this.auto, required this.onChanged});
  final String label;
  final int value;
  final int auto;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final v = value > 0 ? value : auto;
    return Row(children: [
      Expanded(child: Text(label)),
      IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: v > 1 ? () => onChanged(v - 1) : null),
      SizedBox(width: 36, child: Text('$v${value > 0 ? '' : '*'}', textAlign: TextAlign.center)),
      IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => onChanged(v + 1)),
    ]);
  }
}
