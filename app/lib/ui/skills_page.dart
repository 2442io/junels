// Skills: eigene Fähigkeiten entwerfen, Basis-Skills anpassen, im Agent-Skills-Standard (SKILL.md) importieren und teilen.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_scope.dart';
import '../state/native_files.dart';
import '../state/skill_import.dart';
import '../state/skills.dart';
import 'quick_nav.dart';
import 'theme.dart';
import 'answer_views.dart' show OutputViewField, outputViewIcon;
import 'package:agent_engine/agent_engine.dart' show OutputView, Workflow;
import '../data/models.dart' show ScheduleKind, SavedPrompt, newId;
import '../state/app_controller.dart';
import 'flows_page.dart' show FlowCard, describeNewFlow, newEmptyFlow, FlowEditor;
import 'monitor_page.dart';
import 'tasks_page.dart' show TemplateCard;
import 'prompt_editor.dart' show editPrompt, runSavedPrompt;
import 'device_page.dart' show setupMorningBriefing;
import 'watchlist_page.dart' show showWatchDialog, WatchlistPage;

const skillIcons = <String, IconData>{
  'auto_awesome': Icons.auto_awesome,
  'slideshow': Icons.slideshow,
  'description': Icons.description_outlined,
  'alarm': Icons.alarm,
  'wb_sunny': Icons.wb_sunny_outlined,
  'travel_explore': Icons.travel_explore,
  'explore': Icons.explore_outlined,
  'account_balance': Icons.account_balance_outlined,
  'checklist': Icons.checklist,
  'music_note': Icons.music_note_outlined,
  'mail': Icons.mail_outline,
  'receipt': Icons.receipt_long_outlined,
  'flight': Icons.flight_takeoff,
  'shopping': Icons.shopping_bag_outlined,
  'school': Icons.school_outlined,
  'work': Icons.work_outline,
  'favorite': Icons.favorite_border,
  'code': Icons.code,
  'chart': Icons.insert_chart_outlined,
  'flow': Icons.account_tree_outlined,
};

IconData skillIcon(String name) => skillIcons[name] ?? Icons.auto_awesome;

class SkillsPage extends StatefulWidget {
  const SkillsPage({super.key, this.filter = 'all'});

  /// Start-Tab: all | schedule | skill | flow | watch (problem → Alle mit Problemen oben)
  final String filter;

  @override
  State<SkillsPage> createState() => _SkillsPageState();
}

/// Art eines Eintrags – bestimmt den Tab. Reihenfolge: geplant > beobachtet > Ablauf > Skill
String skillKind(AppController app, Skill s) {
  final wf = s.flowId == null ? null : app.flows.flows.where((f) => f.id == s.flowId).firstOrNull;
  final mode = wf?.trigger?.str('mode', 'manual');
  if (app.planOf(s) != null || mode == 'schedule') return 'schedule';
  if (mode == 'watch') return 'watch';
  if (s.runsFlow) return 'flow';
  return 'skill';
}

bool skillHasProblem(AppController app, Skill s) {
  final wf = s.flowId == null ? null : app.flows.flows.where((f) => f.id == s.flowId).firstOrNull;
  return wf != null && !app.flows.isRunning(wf.id) && (wf.lastStatus == 'Fehler' || app.flows.interrupted.containsKey(wf.id));
}

String _two(int v) => v.toString().padLeft(2, '0');

/// „heute 07:30“, „morgen 07:30“, „Mo 07:30“, „3.12. 07:30“
String whenLabel(DateTime d) {
  final now = DateTime.now();
  final day = DateTime(d.year, d.month, d.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = day.difference(today).inDays;
  final t = '${_two(d.hour)}:${_two(d.minute)}';
  if (diff == 0) return 'heute $t';
  if (diff == 1) return 'morgen $t';
  if (diff == -1) return 'gestern $t';
  if (diff > 1 && diff < 7) return '${const ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'][d.weekday - 1]} $t';
  return '${d.day}.${d.month}. $t';
}

class _SkillsPageState extends State<SkillsPage> {
  static const _tabs = [
    ('all', 'Alle', Icons.dashboard_outlined),
    ('schedule', 'Geplant', Icons.schedule),
    ('skill', 'Skills', Icons.auto_awesome),
    ('flow', 'Abläufe', Icons.account_tree_outlined),
    ('watch', 'Beobachtet', Icons.radar),
  ];
  bool _showBasis = false;
  bool _onlyProblems = false;

  @override
  void initState() {
    super.initState();
    _onlyProblems = widget.filter == 'problem';
  }

  int get _initialTab {
    final i = _tabs.indexWhere((t) => t.$1 == widget.filter);
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final lib = app.skills;
    return ListenableBuilder(
      listenable: lib,
      builder: (context, _) {
        final own = lib.own;
        int count(String k) => k == 'all' ? own.length : own.where((s) => skillKind(app, s) == k).length;
        final legacyPlans = [
          for (final p in app.prompts)
            if (p.schedule != ScheduleKind.off && lib.forPrompt(p.id) == null) p
        ];
        return DefaultTabController(
          length: _tabs.length,
          initialIndex: _initialTab,
          child: Scaffold(
            appBar: JAppBar(
              title: const Text('Skills & Abläufe'),
              actions: [
                PopupMenuButton<String>(
                  tooltip: 'Mehr',
                  onSelected: (v) async {
                    switch (v) {
                      case 'import':
                        await showSkillImport(context);
                      case 'export':
                        final list = [...lib.own, ...lib.basis.where((b) => b.edited)];
                        if (list.isEmpty) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(const SnackBar(content: Text('Noch keine eigenen oder angepassten Skills')));
                          return;
                        }
                        await shareSkillZip(list, 'junels-skills', flows: app.flows.flows);
                      case 'monitor':
                        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MonitorPage(source: 'flow')));
                      case 'results':
                        app.openFeed();
                        goHome(context);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'results', child: ListTile(leading: Icon(Icons.inbox_outlined), title: Text('Ergebnisse ansehen'))),
                    PopupMenuItem(value: 'monitor', child: ListTile(leading: Icon(Icons.insights_outlined), title: Text('Überwachung'))),
                    PopupMenuItem(value: 'import', child: ListTile(leading: Icon(Icons.download_outlined), title: Text('Importieren'))),
                    PopupMenuItem(value: 'export', child: ListTile(leading: Icon(Icons.ios_share), title: Text('Exportieren (ZIP)'))),
                  ],
                ),
              ],
              bottom: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  for (final t in _tabs)
                    Tab(
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(t.$3, size: 18),
                        const SizedBox(width: 6),
                        Text(t.$2),
                        if (count(t.$1) + (t.$1 == 'schedule' ? legacyPlans.length : 0) > 0) ...[
                          const SizedBox(width: 6),
                          Text('${count(t.$1) + (t.$1 == 'schedule' || t.$1 == 'all' ? legacyPlans.length : 0)}',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400)),
                        ],
                      ]),
                    ),
                ],
              ),
            ),
            floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
            floatingActionButton: Builder(
              builder: (context) => FloatingActionButton.extended(
                heroTag: null,
                icon: const Icon(Icons.add),
                label: const Text('Neu'),
                onPressed: () => showCreateSheet(context, preferred: _tabs[DefaultTabController.of(context).index].$1),
              ),
            ),
            body: TabBarView(children: [
              for (final t in _tabs) _tabBody(context, app, t.$1, legacyPlans),
            ]),
          ),
        );
      },
    );
  }

  Widget _tabBody(BuildContext context, AppController app, String tab, List<SavedPrompt> legacyPlans) {
    final lib = app.skills;
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final own = lib.own;
    final problems = own.where((s) => skillHasProblem(app, s)).toList();
    List<Skill> of(String k) => [
          for (final s in own)
            if (skillKind(app, s) == k && (!_onlyProblems || problems.contains(s))) s
        ];
    final intro = switch (tab) {
      'schedule' => 'Laufen von selbst zur eingestellten Zeit. Die Ergebnisse findest du gesammelt unter „Ergebnisse“.',
      'skill' => 'Anleitungen für wiederkehrende Aufgaben – im Chat mit /befehl aufrufen oder automatisch erkennen lassen.',
      'flow' => 'Mehrere Schritte hintereinander (z. B. suchen → zusammenfassen → als Word speichern → Push).',
      'watch' => 'Junels meldet sich, wenn sich auf einer Webseite oder zu einem Thema etwas ändert.',
      _ => 'Alles, was Junels für dich kann und von selbst erledigt – an einem Ort.',
    };
    Widget section(String title, List<Widget> children, {Widget? trailing}) => children.isEmpty
        ? const SizedBox.shrink()
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SectionLabel(title, padding: const EdgeInsets.fromLTRB(4, 18, 4, 8), trailing: trailing),
            ...children,
          ]);
    List<Widget> cards(List<Skill> list) => [for (final s in list) SkillCard(skill: s)];
    final legacyWatch = [for (final w in app.watchlist.items) if (w.flowId == null) w];
    Widget legacyWatchCard() => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Panel(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WatchlistPage())),
            child: Row(children: [
              const Icon(Icons.radar),
              const SizedBox(width: 12),
              Expanded(
                child: Text('${legacyWatch.length} ältere Beobachtung${legacyWatch.length == 1 ? '' : 'en'}: '
                    '${legacyWatch.map((w) => w.title).take(3).join(' · ')}', maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
              const Icon(Icons.chevron_right),
            ]),
          ),
        );
    final children = <Widget>[
      Text(intro, style: t.bodySmall?.copyWith(color: c.muted)),
      if (problems.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Panel(
            color: c.redSoft,
            borderColor: c.red.withValues(alpha: 0.3),
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            onTap: () => setState(() => _onlyProblems = !_onlyProblems),
            child: Row(children: [
              Icon(Icons.error_outline, color: c.red),
              const SizedBox(width: 10),
              Expanded(
                child: Text(_onlyProblems
                    ? 'Nur Einträge mit Problemen – tippen für alle'
                    : '${problems.length} ${problems.length == 1 ? 'braucht' : 'brauchen'} Aufmerksamkeit (Fehler oder unterbrochen)'),
              ),
              Icon(_onlyProblems ? Icons.close : Icons.filter_list, size: 20),
            ]),
          ),
        ),
    ];
    switch (tab) {
      case 'all':
        final groups = [('schedule', 'Geplant'), ('watch', 'Beobachtet'), ('flow', 'Abläufe'), ('skill', 'Skills')];
        final any = own.isNotEmpty || legacyPlans.isNotEmpty;
        if (!any) children.add(_welcome(context));
        for (final g in groups) {
          children.add(section(g.$2, [
            ...cards(of(g.$1)),
            if (g.$1 == 'schedule' && !_onlyProblems) for (final p in legacyPlans) _PlanPromptCard(prompt: p),
            if (g.$1 == 'watch' && legacyWatch.isNotEmpty && !_onlyProblems) legacyWatchCard(),
          ]));
        }
      case 'schedule':
        final list = of('schedule');
        if (list.isEmpty && legacyPlans.isEmpty) {
          children.add(Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Panel(
              child: EmptyHint(
                icon: Icons.alarm_add_outlined,
                title: 'Noch nichts geplant',
                text: 'Eine geplante Aufgabe ist ein Skill mit Uhrzeit – z. B. jeden Morgen die wichtigsten News als Tabelle.',
                action: FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Geplante Aufgabe anlegen'),
                  onPressed: () => openPlanEditor(context),
                ),
              ),
            ),
          ));
        }
        children.add(section('Geplant', [
          ...cards(list),
          if (!_onlyProblems) for (final p in legacyPlans) _PlanPromptCard(prompt: p),
        ]));
        children.add(_quickSetup(context, app));
      case 'skill':
        final list = of('skill');
        if (list.isEmpty) {
          children.add(Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Panel(
              child: EmptyHint(
                icon: Icons.auto_awesome,
                title: 'Noch keine eigenen Skills',
                text: 'Beschreib einmal, wie eine Aufgabe geht – danach reicht /befehl im Chat.',
                action: FilledButton.icon(
                    icon: const Icon(Icons.add), label: const Text('Skill entwerfen'), onPressed: () => openSkillEditor(context, null)),
              ),
            ),
          ));
        }
        children.add(section('Meine Skills', cards(list)));
        children.add(InkWell(
          onTap: () => setState(() => _showBasis = !_showBasis),
          child: SectionLabel('Basis-Skills (${lib.basis.length})',
              padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
              trailing: Icon(_showBasis ? Icons.expand_less : Icons.expand_more, size: 20, color: c.muted)),
        ));
        if (_showBasis) children.addAll([for (final s in lib.basis) SkillCard(skill: s)]);
      case 'flow':
        final list = of('flow');
        if (list.isEmpty) {
          children.add(Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Panel(
              child: EmptyHint(
                icon: Icons.account_tree_outlined,
                title: 'Noch keine Abläufe',
                text: 'Beschreib in einem Satz, was nacheinander passieren soll – Junels baut die Schritte.',
                action: FilledButton.icon(
                    icon: const Icon(Icons.auto_fix_high),
                    label: const Text('Ablauf beschreiben'),
                    onPressed: () => describeNewFlow(context)),
              ),
            ),
          ));
        }
        children.add(section('Abläufe', cards(list)));
      case 'watch':
        final list = of('watch');
        if (list.isEmpty && legacyWatch.isEmpty) {
          children.add(Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Panel(
              child: EmptyHint(
                icon: Icons.radar,
                title: 'Noch keine Beobachtungen',
                text: 'Preis, Termin, Webseite oder Thema – Junels schaut regelmäßig nach und meldet sich bei Änderungen.',
                action: FilledButton.icon(
                    icon: const Icon(Icons.add), label: const Text('Etwas beobachten'), onPressed: () => showWatchDialog(context)),
              ),
            ),
          ));
        }
        children.add(section('Beobachtet', [...cards(list), if (legacyWatch.isNotEmpty) legacyWatchCard()]));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ),
      ],
    );
  }

  Widget _welcome(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget option(IconData icon, String title, String text, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Panel(
            onTap: onTap,
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Icon(icon, size: 26),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: t.titleSmall),
                  const SizedBox(height: 2),
                  Text(text, style: t.bodySmall),
                ]),
              ),
              const Icon(Icons.chevron_right),
            ]),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Womit fangen wir an?', style: t.titleMedium),
        const SizedBox(height: 10),
        option(Icons.schedule, 'Etwas regelmäßig erledigen', 'z. B. jeden Morgen News, Wetter und Termine', () => openPlanEditor(context)),
        option(Icons.auto_awesome, 'Eine Aufgabe beibringen', 'Anleitung einmal schreiben, dann /befehl im Chat',
            () => openSkillEditor(context, null)),
        option(Icons.radar, 'Etwas beobachten', 'Melden, wenn sich Preis, Seite oder Thema ändert', () => showWatchDialog(context)),
        option(Icons.account_tree_outlined, 'Mehrere Schritte verbinden', 'Ablauf beschreiben – Junels baut ihn',
            () => describeNewFlow(context)),
      ]),
    );
  }

  Widget _quickSetup(BuildContext context, AppController app) {
    final hasPrep = app.prompts.any((p) => p.id == AppController.meetingPrepId);
    final hasMorning = app.prompts.any((p) => p.title == 'Morgen-Übersicht') || app.skills.own.any((s) => s.name == 'Morgen-Übersicht');
    final cards = <Widget>[
      TemplateCard(
        icon: Icons.wb_twilight,
        title: 'Morgen-Übersicht',
        text: 'Termine, Wetter und Nachrichten jeden Morgen.',
        done: hasMorning,
        onTap: () => setupMorningBriefing(context),
      ),
      TemplateCard(
        icon: Icons.event_note_outlined,
        title: 'Termine vorbereiten',
        text: 'Mo–Fr 7:30: pro Termin eine Notiz mit Firma, Webseite, Fragen und Zielen.',
        done: hasPrep,
        onTap: () async {
          await app.createMeetingPrep();
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('„Termine vorbereiten“ angelegt – läuft Mo–Fr um 7:30')));
          }
        },
      ),
      TemplateCard(
        icon: Icons.newspaper,
        title: 'News zu einem Thema',
        text: 'Täglich die wichtigsten Meldungen zu deinem Thema – z. B. als Karten.',
        onTap: () => openPlanEditor(context,
            name: 'News: …',
            task: 'Suche die wichtigsten aktuellen Nachrichten zum Thema „…“ und fasse sie in 5 Punkten zusammen.',
            output: OutputView.cards),
      ),
      TemplateCard(
        icon: Icons.summarize_outlined,
        title: 'Wochenrückblick',
        text: 'Freitags: woran du diese Woche gearbeitet hast und was offen ist.',
        onTap: () => openPlanEditor(context,
            name: 'Wochenrückblick',
            task: 'Fasse zusammen, woran ich diese Woche gearbeitet habe (Chats und Aktivitäten), und nenne offene Punkte.',
            kind: ScheduleKind.weekly,
            weekday: DateTime.friday,
            hour: 16,
            output: OutputView.list),
      ),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionLabel('Schnell einrichten', padding: EdgeInsets.fromLTRB(4, 22, 4, 8)),
      LayoutBuilder(builder: (context, box) {
        final cols = box.maxWidth >= 640 ? 2 : 1;
        final w = (box.maxWidth - (cols - 1) * 10) / cols;
        return Wrap(spacing: 10, runSpacing: 10, children: [for (final c in cards) SizedBox(width: w, child: c)]);
      }),
      const SizedBox(height: 10),
      Panel(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: SwitchListTile(
          title: const Text('Nach Terminen Folgemail vorschlagen'),
          subtitle: const Text('Push-Nachricht, sobald ein Termin vorbei ist – ein Tipp öffnet den Entwurf.'),
          value: app.settings.meetingFollowUp,
          onChanged: (v) => app.setMeetingFollowUp(v),
        ),
      ),
    ]);
  }
}

/// „Neu“: was möchtest du anlegen?
Future<void> showCreateSheet(BuildContext context, {String preferred = 'all'}) async {
  final picked = await showSheet<String>(
    context: context,
    title: 'Neu anlegen',
    builder: (ctx) {
      final t = Theme.of(ctx).textTheme;
      Widget option(String v, IconData icon, String title, String text) => ListTile(
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(text, style: t.bodySmall),
            selected: v == preferred || (preferred == 'all' && v == 'schedule'),
            onTap: () => Navigator.pop(ctx, v),
          );
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          option('schedule', Icons.schedule, 'Geplante Aufgabe', 'Läuft von selbst zu einer Uhrzeit – Ergebnis unter „Ergebnisse“'),
          option('skill', Icons.auto_awesome, 'Skill', 'Anleitung für eine wiederkehrende Aufgabe, Aufruf per /befehl'),
          option('flow', Icons.account_tree_outlined, 'Ablauf', 'Mehrere Schritte – beschreiben, Junels baut ihn'),
          option('watch', Icons.radar, 'Beobachtung', 'Melden, wenn sich etwas ändert'),
          option('empty', Icons.add_box_outlined, 'Leerer Ablauf', 'Selbst aus Bausteinen bauen'),
          option('import', Icons.download_outlined, 'Importieren', 'SKILL.md, ZIP oder Link'),
        ]),
      );
    },
  );
  if (picked == null || !context.mounted) return;
  switch (picked) {
    case 'schedule':
      openPlanEditor(context);
    case 'skill':
      openSkillEditor(context, null);
    case 'flow':
      describeNewFlow(context);
    case 'watch':
      showWatchDialog(context);
    case 'empty':
      newEmptyFlow(context);
    case 'import':
      showSkillImport(context);
  }
}

/// Neue geplante Aufgabe = Skill mit Zeitplan (derselbe Editor, Zeitplan schon eingeschaltet)
void openPlanEditor(BuildContext context,
    {String name = '', String task = '', String output = '', ScheduleKind kind = ScheduleKind.daily, int weekday = DateTime.monday, int hour = 8}) {
  final draft = Skill(id: 'u-${DateTime.now().microsecondsSinceEpoch}', name: name, instructions: task, icon: 'alarm', auto: false, output: output);
  Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SkillEditor(draft: draft, plan: (kind: kind, hour: hour, minute: 0, weekday: weekday))));
}

/// Karte für einen Skill, Ablauf, eine geplante Aufgabe oder Beobachtung
class SkillCard extends StatelessWidget {
  const SkillCard({super.key, required this.skill});
  final Skill skill;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = skill;
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final wf = s.flowId == null ? null : app.flows.flows.where((f) => f.id == s.flowId).firstOrNull;
    // reiner Ablauf: Karte des Ablaufs (Status, Stoppen, Fortsetzen, Ein/Aus)
    if (s.runsFlow && wf != null) {
      return Padding(padding: const EdgeInsets.only(bottom: 8), child: FlowCard(app: app, wf: wf, command: s.command));
    }
    final plan = app.planOf(s);
    final now = DateTime.now();
    final running = wf != null && app.flows.isRunning(wf.id);
    final problem = skillHasProblem(app, s);
    final on = plan != null ? plan.enabled : s.enabled;
    final next = plan != null && plan.enabled ? plan.nextAfter(now) : null;
    final chips = <Widget>[
      if (plan != null) StatusChip(plan.scheduleLabel, color: on ? c.mint : c.muted, soft: on ? c.mintSoft : c.raised, icon: Icons.schedule, dense: true),
      if (wf?.trigger != null) StatusChip(wf!.trigger!.summary, color: c.violet, icon: Icons.bolt, dense: true),
      if (s.output.isNotEmpty) StatusChip(OutputView.labels[s.output] ?? s.output, color: c.blue, icon: outputViewIcon(s.output), dense: true),
      if (running) StatusChip('Läuft', color: c.amber, soft: c.amberSoft, dense: true),
      if (problem) StatusChip('Fehler', color: c.red, soft: c.redSoft, dense: true),
      if (s.edited) StatusChip('angepasst', color: c.amber, dense: true),
      if (plan != null && !on) StatusChip('Pausiert', color: c.muted, soft: c.raised, dense: true),
    ];
    final line = [
      if (next != null) 'nächster Lauf ${whenLabel(next)}',
      if (plan?.lastRun != null) 'zuletzt ${whenLabel(plan!.lastRun!)}',
      if (plan == null) s.when.isNotEmpty ? s.when : (s.instructions.split('\n').first),
    ].where((x) => x.trim().isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Panel(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        onTap: () => openSkillEditor(context, s),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: s.builtin ? c.raised : (plan != null ? (on ? c.mintSoft : c.raised) : c.amberSoft),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(skillIcon(s.icon), color: s.builtin ? c.muted : (plan != null ? (on ? c.mint : c.faint) : c.amber)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
                Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                MonoText('/${s.command}', color: c.faint),
              ]),
              if (line.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(line, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: c.muted)),
              ],
              if (chips.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: chips),
              ],
            ]),
          ),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Switch(
              value: on,
              onChanged: (v) async {
                if (plan != null) {
                  plan.enabled = v;
                  await app.savePrompt(plan);
                } else {
                  app.skills.setEnabled(s, v);
                }
              },
            ),
            IconButton(
              tooltip: plan != null ? 'Jetzt ausführen' : 'Im Chat starten',
              icon: const Icon(Icons.play_arrow_rounded),
              onPressed: app.running
                  ? null
                  : () {
                      if (plan != null) {
                        app.runPrompt(plan);
                        goHome(context);
                      } else {
                        goHome(context);
                        app.newConversation();
                        app.pendingInput.value = '/${s.command} ';
                      }
                    },
            ),
          ]),
        ]),
      ),
    );
  }
}

/// Geplanter Eintrag ohne Skill (z. B. „Termine vorbereiten“)
class _PlanPromptCard extends StatelessWidget {
  const _PlanPromptCard({required this.prompt});
  final SavedPrompt prompt;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final p = prompt;
    final next = p.enabled ? p.nextAfter(DateTime.now()) : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Panel(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        onTap: () => editPrompt(context, prompt: p),
        child: Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: p.enabled ? c.mintSoft : c.raised, borderRadius: BorderRadius.circular(12)),
            child: Icon(p.id == AppController.meetingPrepId ? Icons.event_note_outlined : Icons.alarm, color: p.enabled ? c.mint : c.faint),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 3),
              Text([
                p.scheduleLabel,
                if (next != null) 'nächster Lauf ${whenLabel(next)}',
                if (p.lastRun != null) 'zuletzt ${whenLabel(p.lastRun!)}',
              ].join(' · '), style: t.bodySmall?.copyWith(color: c.muted)),
            ]),
          ),
          Switch(
            value: p.enabled,
            onChanged: (v) {
              p.enabled = v;
              app.savePrompt(p);
            },
          ),
          IconButton(
            tooltip: 'Jetzt ausführen',
            icon: const Icon(Icons.play_arrow_rounded),
            onPressed: app.running ? null : () => runSavedPrompt(context, app, p),
          ),
        ]),
      ),
    );
  }
}

/// Skills als Standard-Paket (ZIP mit <name>/SKILL.md + Dateien) teilen
Future<void> shareSkillZip(List<Skill> skills, String fileName, {List<Workflow> flows = const []}) async {
  final f = File('${Directory.systemTemp.path}/$fileName.zip');
  await f.writeAsBytes(SkillImport.toZip(skills, flows: flows));
  await NativeFiles.share(f.path);
}

void openSkillEditor(BuildContext context, Skill? skill, {Skill? draft}) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SkillEditor(skill: skill, draft: draft)));

/// Skills importieren: Datei(en), Link oder Text. Ein Skill → Editor zum Prüfen; mehrere → Auswahl.
Future<void> showSkillImport(BuildContext context) async {
  final app = AppScope.read(context);
  final m = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  final linkCtrl = TextEditingController();
  final textCtrl = TextEditingController();
  final tools = app.activeTools;
  final result = await showSheet<List<Skill>>(
    context: context,
    isScrollControlled: true,
    title: 'Skills importieren',
    builder: (ctx) {
      var busy = false;
      String? err;
      return StatefulBuilder(builder: (ctx, set) {
        final t = Theme.of(ctx).textTheme;
        Future<void> run(Future<List<Skill>> Function() f) async {
          set(() {
            busy = true;
            err = null;
          });
          try {
            final list = await f();
            if (list.isEmpty) throw Exception('Keine gültige SKILL.md gefunden');
            if (ctx.mounted) Navigator.pop(ctx, list);
          } catch (e) {
            set(() {
              busy = false;
              err = '$e'.replaceFirst('Exception: ', '');
            });
          }
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Text('SKILL.md nach dem Agent-Skills-Standard (Claude, Codex, Cursor, Gemini CLI …), auch als ZIP/.skill mit '
                  'mehreren Skills. Werkzeugnamen werden übersetzt; references/ & Co. bleiben als Dateien erhalten. '
                  'Skripte werden nur als Text übernommen und nie ausgeführt.',
                  style: t.bodySmall),
              const SizedBox(height: 14),
              FilledButton.icon(
                icon: const Icon(Icons.folder_open),
                label: const Text('Datei(en) wählen – .md, .zip, .skill'),
                onPressed: busy
                    ? null
                    : () => run(() async {
                          final pick = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any, withData: true);
                          if (pick == null) return const <Skill>[];
                          final out = <Skill>[];
                          for (final f in pick.files) {
                            final bytes = f.bytes ?? await File(f.path!).readAsBytes();
                            out.addAll(SkillImport.fromFile(f.name, bytes, available: tools));
                          }
                          return out;
                        }),
              ),
              const SizedBox(height: 18),
              Text('Von einem Link', style: t.titleSmall),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: linkCtrl,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(isDense: true, hintText: 'github.com/…/SKILL.md, Ordner oder .zip'),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: busy ? null : () => run(() => SkillImport.fromLink(linkCtrl.text, available: tools)),
                  child: const Text('Laden'),
                ),
              ]),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Lädt nur diese eine Adresse aus dem Internet.', style: t.bodySmall),
              ),
              const SizedBox(height: 18),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Text einfügen'),
                children: [
                  TextField(
                    controller: textCtrl,
                    minLines: 4,
                    maxLines: 10,
                    decoration: const InputDecoration(hintText: '---\nname: …\ndescription: …\n---\nAnleitung …', alignLabelWithHint: true),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      onPressed: busy
                          ? null
                          : () => run(() async => [
                                if (SkillImport.fromText(textCtrl.text, available: tools) case final s?) s,
                              ]),
                      child: const Text('Übernehmen'),
                    ),
                  ),
                ],
              ),
              if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
              if (err != null)
                Padding(padding: const EdgeInsets.only(top: 12), child: Text(err!, style: t.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.error))),
            ]),
          ),
        );
      });
    },
  );
  linkCtrl.dispose();
  textCtrl.dispose();
  if (result == null || result.isEmpty) return;
  // Befehle eindeutig machen
  for (final s in result) {
    final base = s.command;
    for (var i = 2; app.skills.all.any((o) => o.command == s.command) || result.any((o) => o != s && o.command == s.command && result.indexOf(o) < result.indexOf(s)); i++) {
      s.slug = '$base-$i';
    }
  }
  // Mitgelieferte Abläufe (aus Junels exportiert) wieder aufbauen – pausiert, bis du sie geprüft hast
  final withFlow = <Skill>{};
  for (final s in result) {
    final wf = SkillImport.flowFromSkill(s, newId());
    if (wf == null) continue;
    app.skills.upsert(s);
    await app.flows.upsert(wf);
    withFlow.add(s);
  }
  if (result.length == 1) {
    // einzeln: im Editor prüfen (Werkzeuge, Internet, Modell) und dann speichern
    final one = result.first;
    if (withFlow.contains(one) && one.runsFlow) {
      await nav.push(MaterialPageRoute(builder: (_) => FlowEditor(id: one.flowId!)));
    } else {
      await nav.push(MaterialPageRoute(builder: (_) => withFlow.contains(one) ? SkillEditor(skill: one) : SkillEditor(draft: one)));
    }
    if (withFlow.isNotEmpty) m.showSnackBar(const SnackBar(content: Text('Ablauf übernommen – pausiert, bis du ihn einschaltest')));
    return;
  }
  for (final s in result) {
    app.skills.upsert(s);
  }
  m.showSnackBar(SnackBar(content: Text('${result.length} Skills importiert – Werkzeuge bitte kurz prüfen')));
}

class SkillEditor extends StatefulWidget {
  const SkillEditor({super.key, this.skill, this.draft, this.plan});
  final Skill? skill; // bearbeiten
  final Skill? draft; // neuer Skill mit Vorbelegung (z. B. aus einem Chat)
  /// Neue geplante Aufgabe: Zeitplan schon eingeschaltet
  final ({ScheduleKind kind, int hour, int minute, int weekday})? plan;

  @override
  State<SkillEditor> createState() => _SkillEditorState();
}

class _SkillEditorState extends State<SkillEditor> {
  late Skill s;
  late final TextEditingController _name, _slug, _when, _steps, _inputs, _knowledge;
  bool _isNew = false;

  // Zeitplan (geplante Aufgabe = Skill mit Zeitplan)
  bool _planOn = false;
  ScheduleKind _kind = ScheduleKind.daily;
  int _hour = 8, _minute = 0, _weekday = DateTime.monday;
  bool _notify = true;
  bool _planEnabled = true;

  @override
  void initState() {
    super.initState();
    _isNew = widget.skill == null;
    s = (widget.skill ?? widget.draft)?.copy() ?? Skill(id: 'u-${DateTime.now().microsecondsSinceEpoch}', name: '');
    final existing = AppScope.read(context).planOf(s);
    if (existing != null) {
      _planOn = true;
      _kind = existing.schedule;
      _hour = existing.hour;
      _minute = existing.minute;
      _weekday = existing.weekday;
      _notify = existing.notify;
      _planEnabled = existing.enabled;
    } else if (widget.plan case final p?) {
      _planOn = true;
      _kind = p.kind;
      _hour = p.hour;
      _minute = p.minute;
      _weekday = p.weekday;
    }
    _name = TextEditingController(text: s.name);
    _slug = TextEditingController(text: s.slug);
    _when = TextEditingController(text: s.when);
    _steps = TextEditingController(text: s.instructions);
    _inputs = TextEditingController(text: s.inputs);
    _knowledge = TextEditingController(text: s.knowledge);
  }

  void _apply() {
    s
      ..name = _name.text.trim()
      ..slug = Skill.slugify(_slug.text.trim().isEmpty ? _name.text : _slug.text)
      ..when = _when.text.trim()
      ..instructions = _steps.text.trim()
      ..inputs = _inputs.text.trim()
      ..knowledge = _knowledge.text.trim();
  }

  bool _save() {
    _apply();
    if (s.name.isEmpty || s.instructions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name und Anleitung ausfüllen')));
      return false;
    }
    final clash = AppScope.read(context).skills.all.where((o) => o.id != s.id && o.command == s.command).firstOrNull;
    if (clash != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('/${s.command} gibt es schon („${clash.name}“) – anderen Befehl wählen')));
      return false;
    }
    final app = AppScope.read(context);
    app.skills.upsert(s);
    // Zeitplan speichern (an, geändert oder entfernt)
    if (_planOn || app.planOf(s) != null) {
      unawaited(app.setSkillPlan(s,
        kind: _planOn ? _kind : ScheduleKind.off,
        hour: _hour,
        minute: _minute,
        weekday: _weekday,
        notify: _notify,
        enabled: _planEnabled));
    }
    return true;
  }

  Widget _planSection(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    String two(int v) => v.toString().padLeft(2, '0');
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(Icons.schedule, color: _planOn ? c.mint : c.muted),
          title: const Text('Automatisch ausführen'),
          subtitle: Text(_planOn ? 'Geplante Aufgabe – Ergebnis kommt in „Ergebnisse“' : 'Nur wenn du es startest (/befehl oder ▶)'),
          value: _planOn,
          onChanged: s.builtin ? null : (v) => setState(() => _planOn = v),
        ),
        if (_planOn) ...[
          const SizedBox(height: 4),
          SegmentedButton<ScheduleKind>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ScheduleKind.daily, label: Text('Täglich')),
              ButtonSegment(value: ScheduleKind.weekdays, label: Text('Mo–Fr')),
              ButtonSegment(value: ScheduleKind.weekly, label: Text('Wöchentlich')),
            ],
            selected: {_kind},
            onSelectionChanged: (v) => setState(() => _kind = v.first),
          ),
          const SizedBox(height: 10),
          Row(children: [
            if (_kind == ScheduleKind.weekly) ...[
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _weekday,
                  isDense: true,
                  decoration: const InputDecoration(labelText: 'Tag', isDense: true),
                  items: [
                    for (var i = 1; i <= 7; i++) DropdownMenuItem(value: i, child: Text(SavedPrompt.weekdayNames[i - 1])),
                  ],
                  onChanged: (v) => setState(() => _weekday = v ?? _weekday),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.access_time, size: 18),
                label: Text('${two(_hour)}:${two(_minute)} Uhr'),
                onPressed: () async {
                  final r = await showTimePicker(context: context, initialTime: TimeOfDay(hour: _hour, minute: _minute));
                  if (r != null) {
                    setState(() {
                      _hour = r.hour;
                      _minute = r.minute;
                    });
                  }
                },
              ),
            ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Push-Nachricht, wenn fertig'),
            value: _notify,
            onChanged: (v) => setState(() => _notify = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Internet ohne Rückfrage'),
            subtitle: Text('Beim geplanten Lauf ist niemand da, der „Ja“ sagt', style: t.bodySmall),
            value: s.internet == 'allow',
            onChanged: (v) => setState(() => s.internet = v ? 'allow' : 'ask'),
          ),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final tools = [for (final x in app.tools) if (x.name != 'skill_erstellen' && x.name != 'skill') x];
    final known = {for (final x in tools) x.name};
    return Scaffold(
      appBar: JAppBar(
        title: Text(_isNew ? (_planOn ? 'Neue geplante Aufgabe' : 'Neuer Skill') : s.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              final nav = Navigator.of(context);
              final m = ScaffoldMessenger.of(context);
              switch (v) {
                case 'copy':
                  _apply();
                  await Clipboard.setData(ClipboardData(text: s.toMarkdown()));
                  m.showSnackBar(const SnackBar(content: Text('SKILL.md kopiert')));
                case 'share':
                  _apply();
                  await shareSkillZip([s], s.specName, flows: AppScope.read(context).flows.flows);
                case 'check':
                  _apply();
                  final probs = SkillImport.validate(s.toMarkdown());
                  m.showSnackBar(SnackBar(
                      content: Text(probs.isEmpty
                          ? 'Entspricht dem Agent-Skills-Standard (Name: ${s.specName})'
                          : 'Nicht standardkonform: ${probs.join('; ')}')));
                case 'dup':
                  _apply();
                  final d = s.copy(id: 'u-${DateTime.now().microsecondsSinceEpoch}', builtin: false)
                    ..name = '${s.name} (Kopie)'
                    ..slug = ''
                    ..edited = false
                    ..flowId = null;
                  nav.pushReplacement(MaterialPageRoute(builder: (_) => SkillEditor(draft: d)));
                case 'reset':
                  app.skills.reset(s);
                  nav.pop();
                case 'delete':
                  final wf = s.flowId == null ? null : app.flows.flows.where((f) => f.id == s.flowId).firstOrNull;
                  if (wf != null) {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text('„${s.name}“ löschen?'),
                        content: const Text('Der Skill und sein Ablauf (Auslöser, Schritte, Verlauf) werden gelöscht.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Löschen')),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    await app.flows.remove(wf);
                  }
                  await app.removeSkillPlan(s);
                  app.skills.remove(s);
                  nav.pop();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'copy', child: ListTile(leading: Icon(Icons.copy), title: Text('Als SKILL.md kopieren'))),
              const PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.ios_share), title: Text('Teilen (Skill-Paket .zip)'))),
              const PopupMenuItem(value: 'check', child: ListTile(leading: Icon(Icons.verified_outlined), title: Text('Standard prüfen'))),
              const PopupMenuItem(value: 'dup', child: ListTile(leading: Icon(Icons.copy_all_outlined), title: Text('Duplizieren'))),
              if (s.builtin && s.edited)
                const PopupMenuItem(value: 'reset', child: ListTile(leading: Icon(Icons.restart_alt), title: Text('Zurücksetzen'))),
              if (!s.builtin && !_isNew)
                const PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Löschen'))),
            ],
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 120), children: [
        Row(children: [
          PopupMenuButton<String>(
            tooltip: 'Symbol',
            onSelected: (v) => setState(() => s.icon = v),
            itemBuilder: (_) => [
              for (final e in skillIcons.entries) PopupMenuItem(value: e.key, child: Icon(e.value)),
            ],
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: c.amberSoft, borderRadius: BorderRadius.circular(12)),
              child: Icon(skillIcon(s.icon), color: c.amber),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'z. B. Rechnungen sammeln'),
              onChanged: (v) => setState(() {}),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        TextField(
          controller: _steps,
          minLines: 5,
          maxLines: 14,
          decoration: const InputDecoration(
            labelText: 'Was soll Junels tun?',
            helperText: 'Auftrag oder Anleitung in eigenen Worten – Schritte helfen',
            helperMaxLines: 2,
            alignLabelWithHint: true,
            hintText: '1. Suche im Postfach nach Rechnungen dieses Monats\n2. Liste Betrag, Absender, Datum\n3. Erstelle ein Dokument „Rechnungen <Monat>“',
          ),
        ),
        const SizedBox(height: 18),
        Text('Wann', style: t.titleSmall),
        const SizedBox(height: 8),
        _planSection(context),
        const SizedBox(height: 18),
        Text('Darstellung', style: t.titleSmall),
        const SizedBox(height: 8),
        OutputViewField(
          value: s.output,
          label: 'So soll das Ergebnis aussehen',
          onChanged: (v) => setState(() {
            s.output = v;
            // Datei-Format: passendes Werkzeug gleich mit auswählen
            final tool = OutputView.requiredTool(v);
            if (tool != null && !s.tools.contains(tool)) s.tools.add(tool);
          }),
        ),
        const SizedBox(height: 12),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          initiallyExpanded: _isNew && !_planOn,
          title: const Text('Aufruf im Chat'),
          subtitle: Text('/${s.command}${s.auto ? ' · erkennt passende Nachrichten' : ''}'),
          children: [
        const SizedBox(height: 10),
        TextField(
          controller: _slug,
          decoration: InputDecoration(
            labelText: 'Befehl im Chat',
            prefixText: '/',
            hintText: Skill.slugify(_name.text),
            helperText: 'Leer = aus dem Namen · auch der Name im Standard (a-z, 0-9, -)',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _when,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(
              labelText: 'Wann nutzen', hintText: 'z. B. Wenn ich meine Rechnungen vom Monat zusammenstellen will'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Automatisch erkennen'),
          subtitle: const Text('Junels nutzt den Skill, wenn deine Nachricht zur Beschreibung passt – sonst nur per /befehl'),
          value: s.auto,
          onChanged: (v) => setState(() => s.auto = v),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _inputs,
          decoration: const InputDecoration(labelText: 'Angaben, nach denen gefragt wird', hintText: 'z. B. Monat, Konto'),
        ),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          initiallyExpanded: false,
          title: const Text('Werkzeuge, Internet & Modell'),
          subtitle: Text(s.tools.isEmpty ? 'Werkzeuge automatisch wie im Chat' : '${s.tools.length} Werkzeuge'),
          children: [
        const SizedBox(height: 16),
        Text('Werkzeuge', style: t.titleSmall),
        const SizedBox(height: 2),
        Text('Keins gewählt = automatisch wie im Chat. Gewählt = nur diese (verlässlicher).', style: t.bodySmall?.copyWith(color: c.muted)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final x in tools)
            FilterChip(
              label: Text(x.title),
              avatar: x.requiresNetwork ? Icon(Icons.public, size: 14, color: c.blue) : null,
              selected: s.tools.contains(x.name),
              onSelected: (v) => setState(() {
                if (v) {
                  s.tools.add(x.name);
                } else {
                  s.tools.remove(x.name);
                  if (s.requiredTool == x.name) s.requiredTool = '';
                }
              }),
            ),
          for (final unknown in s.tools.where((n) => !known.contains(n)))
            Chip(label: Text('$unknown (nicht verfügbar)'), backgroundColor: c.redSoft),
        ]),
        if (s.unmapped.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Aus dem Original nicht übertragbar: ${s.unmapped.join(', ')} – dafür hat Junels kein Werkzeug.',
                style: t.bodySmall?.copyWith(color: c.muted)),
          ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: s.tools.contains(s.requiredTool) ? s.requiredTool : '',
          decoration: const InputDecoration(labelText: 'Ergebnis muss entstehen mit'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Frei – Antwort im Chat')),
            for (final n in s.tools.where(known.contains))
              DropdownMenuItem(value: n, child: Text(tools.firstWhere((x) => x.name == n).title)),
          ],
          onChanged: (v) => setState(() => s.requiredTool = v ?? ''),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: s.internet,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Internet', helperText: 'Gilt nur, wenn dieser Skill läuft'),
          items: [
            for (final e in Skill.internetLabels.entries)
              DropdownMenuItem(
                value: e.key,
                child: Row(children: [
                  Icon(e.key == 'allow' ? Icons.public : (e.key == 'block' ? Icons.public_off : Icons.help_outline), size: 18),
                  const SizedBox(width: 8),
                  Flexible(child: Text(e.value, overflow: TextOverflow.ellipsis)),
                ]),
              ),
          ],
          onChanged: (v) => setState(() => s.internet = v ?? 'ask'),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: s.model,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Modell (KI-Weiche)',
            helperText: s.model == 'cloud' || s.model == 'hybrid-cloud'
                ? 'Cloud: Inhalte gehen an ${AppScope.read(context).cloudProvider?.name ?? 'den Cloud-Anbieter (noch nicht eingerichtet)'}'
                : (s.model == 'onprem' || s.model == 'hybrid-onprem')
                    ? 'Eigener Server: ${AppScope.read(context).onPremProvider?.name ?? 'noch nicht eingerichtet'}'
                    : 'Wie im Chat eingestellt oder fest für diesen Skill',
          ),
          items: [
            for (final e in Skill.modelLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => s.model = v ?? ''),
        ),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          initiallyExpanded: false,
          title: const Text('Auslöser & weitere Schritte'),
          subtitle: Text(s.flowId == null ? 'z. B. bei Änderung, danach als Word speichern' : 'Ablauf verbunden'),
          children: [
        const SizedBox(height: 4),
        Text('Soll der Skill auch von selbst laufen – nach Zeitplan, wenn sich etwas ändert, oder mit weiteren Schritten danach?',
            style: t.bodySmall?.copyWith(color: c.muted)),
        const SizedBox(height: 8),
        Builder(builder: (context) {
          final wf = s.flowId == null ? null : app.flows.flows.where((f) => f.id == s.flowId).firstOrNull;
          if (wf == null) {
            return Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.account_tree_outlined, size: 18),
                label: const Text('Auslöser oder Schritte hinzufügen'),
                onPressed: s.builtin
                    ? null
                    : () async {
                        if (!_save()) return;
                        final made = await newEmptyFlow(context, skill: s);
                        if (mounted) setState(() => s.flowId = made.id);
                      },
              ),
            );
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FlowCard(app: app, wf: wf),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.link_off, size: 18),
                label: const Text('Ablauf entfernen'),
                onPressed: () async {
                  await app.flows.remove(wf);
                  if (mounted) setState(() => s.flowId = null);
                },
              ),
            ),
          ]);
        }),
          ],
        ),
        const SizedBox(height: 6),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Wissen & Beispiele (optional)'),
          children: [
            TextField(
              controller: _knowledge,
              minLines: 3,
              maxLines: 12,
              decoration: const InputDecoration(
                hintText: 'Fakten, Formulierungen, ein Beispiel-Ergebnis – wird bei jeder Nutzung mitgegeben',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('Dateien (${s.files.length})'),
          subtitle: const Text('references/, scripts/, assets/ – liest Junels nur bei Bedarf'),
          children: [
            for (final f in s.files.keys.toList()..sort())
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(f.startsWith('scripts/') ? Icons.code : Icons.article_outlined, size: 20),
                title: MonoText(f),
                subtitle: Text('${(s.files[f]!.length / 1000).ceil()} KB${f.startsWith('scripts/') ? ' · wird nie ausgeführt' : ''}'),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(f),
                    content: SizedBox(width: 560, child: SingleChildScrollView(child: SelectableText(s.files[f]!))),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Schließen'))],
                  ),
                ),
                trailing: IconButton(
                  tooltip: 'Entfernen',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => s.files.remove(f)),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Datei hinzufügen'),
                onPressed: () async {
                  final m = ScaffoldMessenger.of(context);
                  final pick = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any, withData: true);
                  if (pick == null) return;
                  var skipped = 0;
                  for (final f in pick.files) {
                    final bytes = f.bytes ?? await File(f.path!).readAsBytes();
                    final dir = RegExp(r'\.(py|sh|bash|js|mjs|ts|rb|ps1)$').hasMatch(f.name.toLowerCase()) ? 'scripts' : 'references';
                    if (!s.addFile('$dir/${f.name}', utf8.decode(bytes, allowMalformed: true))) skipped++;
                  }
                  setState(() {});
                  if (skipped > 0) m.showSnackBar(SnackBar(content: Text('$skipped Datei(en) zu groß (max. 200 KB je Datei, 1 MB gesamt)')));
                },
              ),
            ),
          ],
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Testen'),
                onPressed: () {
                  if (!_save()) return;
                  final app = AppScope.read(context);
                  goHome(context);
                  app.newConversation();
                  app.pendingInput.value = '/${s.command} ';
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.check),
                label: const Text('Speichern'),
                onPressed: () {
                  if (_save()) Navigator.of(context).pop();
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
