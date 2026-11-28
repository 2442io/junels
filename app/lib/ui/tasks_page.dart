// Geplante Aufgaben, Aktivitäten-Verlauf und Tresor-Übersicht.

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_controller.dart';
import '../state/app_scope.dart';
import '../state/vault.dart';
import 'chat_view.dart' show showMailAccountDialog;
import 'device_page.dart' show setupMorningBriefing;
import 'monitor_page.dart';
import 'prompt_editor.dart';
import 'theme.dart';
import 'quick_nav.dart';
import 'skills_page.dart' show SkillsPage;
import '../l10n.dart';

/// Geplante Aufgaben sind Skills mit Zeitplan → Skills & Abläufe, Tab „Geplant“
Future<void> openTasks(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SkillsPage(filter: 'schedule')));

Future<void> openActivity(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ActivityPage()));

Future<void> openVault(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VaultPage()));

String _two(int v) => v.toString().padLeft(2, '0');

String _when(DateTime d) => '${d.day}.${d.month}. ${_two(d.hour)}:${_two(d.minute)}';

/// Liste wiederkehrender Aufträge mit Schaltern und Vorlagen.
class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final tasks = app.prompts.where((p) => p.schedule != ScheduleKind.off).toList()
      ..sort((a, b) => (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute));
    final hasPrep = app.prompts.any((p) => p.id == AppController.meetingPrepId);
    final hasMorning = app.prompts.any((p) => p.title == 'Morgen-Übersicht');
    final now = DateTime.now();
    final active = tasks.where((p) => p.enabled).length;
    return Scaffold(
      appBar: JAppBar(title: Text(tr('Geplante Aufgaben')), actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: FilledButton.icon(
            onPressed: () => editPrompt(context, initialText: '', scheduled: true),
            icon: const Icon(Icons.add, size: 18),
            label: Text(tr('Neue Aufgabe')),
          ),
        ),
      ]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 48),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                PageHeader(
                  icon: Icons.schedule,
                  title: tr('Geplante Aufgaben'),
                  subtitle: (tr('Junels erledigt diese Aufträge zur eingestellten Zeit und meldet sich. ') + tr('Sie laufen auf jedem Gerät, auf dem sie eingeschaltet sind.')),
                ),
                SectionLabel(tr('Aufgaben'),
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                    trailing: Builder(builder: (_) {
                      final next = tasks
                          .where((p) => p.enabled)
                          .map((p) => p.nextAfter(now))
                          .whereType<DateTime>()
                          .fold<DateTime?>(null, (m, d) => m == null || d.isBefore(m) ? d : m);
                      return MonoText('$active aktiv${next == null ? '' : ' · nächste ${_when(next)}'}', color: c.faint);
                    })),
                if (tasks.isEmpty)
                  Panel(
                    child: EmptyHint(
                      icon: Icons.alarm_add_outlined,
                      title: tr('Noch keine geplanten Aufgaben'),
                      text: tr('Leg eine eigene Aufgabe an oder richte unten eine mit einem Tipp ein.'),
                    ),
                  ),
                for (final p in tasks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Panel(
                      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                      onTap: () => editPrompt(context, prompt: p),
                      child: Row(children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: p.enabled ? c.mintSoft : c.raised,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(_iconFor(p), size: 20, color: p.enabled ? c.mint : c.faint),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Flexible(
                                child: Text(p.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                              ),
                              if (!p.enabled) ...[
                                const SizedBox(width: 8),
                                StatusChip(tr('Pausiert'), color: c.muted, soft: c.raised, dense: true),
                              ],
                            ]),
                            const SizedBox(height: 4),
                            MonoText([
                              p.scheduleLabel,
                              if (p.enabled && p.nextAfter(now) != null) 'nächster ${_when(p.nextAfter(now)!)}',
                              if (p.lastRun != null) 'zuletzt ${_when(p.lastRun!)}',
                            ].join(' · ')),
                          ]),
                        ),
                        IconButton(
                          tooltip: tr('Jetzt ausführen'),
                          icon: const Icon(Icons.play_arrow_rounded),
                          onPressed: app.running ? null : () => runSavedPrompt(context, app, p),
                        ),
                        Switch(
                          value: p.enabled,
                          onChanged: (v) {
                            p.enabled = v;
                            app.savePrompt(p);
                          },
                        ),
                      ]),
                    ),
                  ),
                SectionLabel(tr('Schnell einrichten'), padding: EdgeInsets.fromLTRB(4, 22, 4, 8)),
                LayoutBuilder(builder: (context, box) {
                  final cols = box.maxWidth >= 640 ? 2 : 1;
                  final w = (box.maxWidth - (cols - 1) * 10) / cols;
                  final cards = <Widget>[
                    TemplateCard(
                      icon: Icons.wb_twilight,
                      title: tr('Morgen-Übersicht'),
                      text: tr('Termine, Wetter und Nachrichten jeden Morgen als Push-Nachricht.'),
                      done: hasMorning,
                      onTap: () => setupMorningBriefing(context),
                    ),
                    TemplateCard(
                      icon: Icons.event_note_outlined,
                      title: tr('Termine vorbereiten'),
                      text: tr('Mo–Fr 7:30: pro Termin eine Notiz mit Firma, Webseite, Fragen und Zielen.'),
                      done: hasPrep,
                      onTap: () async {
                        await app.createMeetingPrep();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(tr('„Termine vorbereiten“ angelegt – läuft Mo–Fr um 7:30'))));
                        }
                      },
                    ),
                    TemplateCard(
                      icon: Icons.newspaper,
                      title: tr('News zu einem Thema'),
                      text: tr('Täglich die wichtigsten Meldungen zu deinem Thema, kurz zusammengefasst.'),
                      onTap: () => editPrompt(context,
                          initialText: tr('Suche die wichtigsten aktuellen Nachrichten zum Thema „…“ und fasse sie in 5 Punkten zusammen.'),
                          scheduled: true),
                    ),
                    TemplateCard(
                      icon: Icons.summarize_outlined,
                      title: tr('Wochenrückblick'),
                      text: tr('Freitags: was diese Woche in deinen Chats und Aktivitäten passiert ist.'),
                      onTap: () => editPrompt(context,
                          initialText: tr('Fasse zusammen, woran ich diese Woche gearbeitet habe (Chats und Aktivitäten), und nenne offene Punkte.'),
                          scheduled: true),
                    ),
                  ];
                  return Wrap(spacing: 10, runSpacing: 10, children: [for (final c in cards) SizedBox(width: w, child: c)]);
                }),
                const SizedBox(height: 14),
                Panel(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: SwitchListTile(
                    title: Text(tr('Nach Terminen Folgemail vorschlagen')),
                    subtitle: Text(tr('Push-Nachricht, sobald ein Termin vorbei ist – ein Tipp öffnet den Entwurf.')),
                    value: app.settings.meetingFollowUp,
                    onChanged: (v) => app.setMeetingFollowUp(v),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(SavedPrompt p) {
    if (p.id == AppController.meetingPrepId) return Icons.event_note_outlined;
    if (p.title == 'Morgen-Übersicht') return Icons.wb_twilight;
    final t = p.title.toLowerCase();
    if (t.contains('news') || t.contains('nachricht')) return Icons.newspaper;
    if (t.contains('wetter')) return Icons.wb_sunny_outlined;
    return Icons.alarm;
  }
}

class TemplateCard extends StatelessWidget {
  const TemplateCard({required this.icon, required this.title, required this.text, required this.onTap, this.done = false});
  final IconData icon;
  final String title;
  final String text;
  final VoidCallback onTap;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    return Panel(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: c.mint, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(title, style: t.titleSmall)),
              if (done) ...[const SizedBox(width: 8), StatusChip(tr('Eingerichtet'), color: c.mint, soft: c.mintSoft, dense: true)],
            ]),
            const SizedBox(height: 4),
            Text(text, style: t.bodySmall),
          ]),
        ),
        Icon(done ? Icons.tune : Icons.add, size: 18, color: c.faint),
      ]),
    );
  }
}

/// Gespeicherte Prompts ohne Zeitplan.
class PromptsPage extends StatelessWidget {
  const PromptsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    // Alle Vorlagen – auch die mit Zeitplan (die stehen zusätzlich unter „Geplant“)
    // Geplante Aufgaben, die Skills sind, stehen unter Skills & Abläufe → Geplant
    final list = app.prompts.where((p) => app.skills.forPrompt(p.id) == null).toList();
    return Scaffold(
      appBar: JAppBar(title: Text(tr('Vorlagen')), actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: FilledButton.icon(
            onPressed: () => editPrompt(context, initialText: ''),
            icon: const Icon(Icons.add, size: 18),
            label: Text(tr('Neue Vorlage')),
          ),
        ),
      ]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 48),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                PageHeader(
                  icon: Icons.bolt_outlined,
                  title: tr('Vorlagen'),
                  subtitle: tr('Häufige Aufträge mit einem Tipp starten. Mit Zeitplan werden sie zu geplanten Aufgaben.'),
                ),
                if (list.isEmpty)
                  Panel(
                    child: EmptyHint(
                      icon: Icons.bolt_outlined,
                      title: tr('Noch keine Vorlagen'),
                      text: tr('Im Chat über ⚡ → „Eingabe als Prompt speichern“ oder hier mit „Neue Vorlage“.'),
                    ),
                  ),
                for (final p in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Panel(
                      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                      onTap: () => editPrompt(context, prompt: p),
                      child: Row(children: [
                        Icon(Icons.bolt_outlined, color: c.amber),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(p.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                            if (p.schedule != ScheduleKind.off) ...[
                              const SizedBox(height: 4),
                              StatusChip('Zeitplan: ${p.scheduleLabel}', color: c.violet, icon: Icons.schedule, dense: true),
                            ],
                            const SizedBox(height: 2),
                            Text(p.text.replaceAll('\n', ' '),
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                          ]),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: app.running ? null : () => runSavedPrompt(context, app, p),
                          icon: const Icon(Icons.play_arrow_rounded, size: 18),
                          label: Text(tr('Starten')),
                        ),
                      ]),
                    ),
                  ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

/// „Was hat der Agent getan?“
class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key});

  static IconData iconFor(String kind) => switch (kind) {
        'mail' => Icons.mail_outline,
        'whatsapp' => Icons.chat_outlined,
        'calendar' => Icons.event_outlined,
        'file' => Icons.folder_outlined,
        'browser' => Icons.travel_explore,
        'memory' => Icons.bookmark_border,
        'internet' => Icons.public,
        'call' => Icons.call_outlined,
        'flow' => Icons.account_tree_outlined,
        _ => Icons.task_alt,
      };

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final items = app.activity.items.reversed.toList();
    String day(DateTime d) {
      final n = DateTime.now();
      if (d.year == n.year && d.month == n.month && d.day == n.day) return tr('Heute');
      final y = n.subtract(const Duration(days: 1));
      if (d.year == y.year && d.month == y.month && d.day == y.day) return tr('Gestern');
      return '${d.day}.${d.month}.${d.year}';
    }

    final rows = <Widget>[];
    String? lastDay;
    for (final a in items) {
      final dl = day(a.time);
      if (dl != lastDay) {
        rows.add(Padding(padding: const EdgeInsets.fromLTRB(4, 16, 4, 4), child: Text(dl, style: t.titleSmall)));
        lastDay = dl;
      }
      rows.add(ListTile(
        dense: true,
        leading: Icon(iconFor(a.kind), size: 20),
        title: Text(a.title),
        subtitle: Text([
          '${_two(a.time.hour)}:${_two(a.time.minute)}',
          if (a.approval.isNotEmpty) a.approval,
          if (a.detail.isNotEmpty) a.detail.replaceAll('\n', ' '),
        ].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Text('lokal', style: t.labelSmall?.copyWith(color: scheme.primary)),
        onTap: a.conversationId == null
            ? null
            : () {
                app.openConversationById(a.conversationId!);
                Navigator.of(context).popUntil((r) => r.isFirst);
              },
      ));
    }
    return Scaffold(
      appBar: JAppBar(title: Text(tr('Aktivität & Überwachung')), actions: [
        if (items.isNotEmpty)
          IconButton(
            tooltip: tr('Verlauf leeren'),
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await app.activity.clear();
              app.refreshUi();
            },
          ),
      ]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
            child: Text(
              tr('Alles, was Junels für dich getan hat – und wie zuverlässig deine Abläufe laufen. ') +
                  (app.settings.routing == 'local' ? tr('Es läuft alles auf diesem Gerät.') : 'KI: ${app.routingLabel ?? 'lokal'}.'),
              style: t.bodySmall,
            ),
          ),
          Builder(builder: (context) {
            final week = app.runStats.since(DateTime.now().subtract(const Duration(days: 7)));
            final bad = week.where((r) => r.status == 'error').length;
            return Card(
              child: ListTile(
                leading: const Icon(Icons.insights_outlined),
                title: Text(tr('Überwachung')),
                subtitle: Text(week.isEmpty
                    ? tr('Dauer, Erfolgsquote und Tokens deiner Prozesse und externen Aufrufe')
                    : '${week.length} Läufe in 7 Tagen · ${bad == 0 ? 'alle erfolgreich' : '$bad mit Fehler'}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MonitorPage())),
              ),
            );
          }),
          SectionLabel(tr('Was der Agent getan hat'), padding: EdgeInsets.fromLTRB(4, 16, 4, 8)),
          ...rows,
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(tr('Noch keine Aktionen. Hier erscheint z. B. „E-Mail an Sara gesendet – du hast ‚Senden‘ getippt“.'),
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }
}

/// Was liegt im Tresor? Nur Namen, nie Werte.
class VaultPage extends StatefulWidget {
  const VaultPage({super.key});

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  List<String> _keys = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final k = await Vault.keys();
    if (mounted) setState(() => _keys = k);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    String label(String k) {
      if (k.startsWith('smtp:')) return 'Mail-Konto ${k.substring(5)} (Passwort)';
      if (k.startsWith('mcp:')) {
        final id = k.substring(4);
        final s = app.mcpServers.where((m) => m.id == id).firstOrNull;
        return 'Anmeldung ${s?.name ?? id} (MCP)';
      }
      return k;
    }

    return Scaffold(
      appBar: JAppBar(title: Text(tr('Tresor & Mail-Konto'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.lock_outline, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    Vault.secure
                        ? (isEnglish
                            ? 'Passwords and sign-in keys are stored encrypted in the ${Theme.of(context).platform == TargetPlatform.macOS ? 'macOS Keychain' : 'Android Keystore'} – '
                                'not in the app files and not in sync. The agent has no tool that reads the vault: '
                                'only sending mail and signing in to MCP services fetch exactly what they need.'
                            : 'Passwörter und Anmelde-Schlüssel liegen verschlüsselt im ${Theme.of(context).platform == TargetPlatform.macOS ? 'macOS-Schlüsselbund' : 'Android-Keystore'} – '
                                'nicht in den App-Dateien und nicht im Abgleich. Der Agent hat kein Werkzeug, das den Tresor liest: '
                                'Nur der Mailversand und die Anmeldung bei MCP-Diensten holen sich gezielt, was sie brauchen.')
                        : tr('Auf diesem System gibt es keinen Tresor.'),
                    style: t.bodyMedium,
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Icons.mail_outline),
            title: Text(tr('E-Mail direkt senden')),
            subtitle: Text(app.settings.smtpReady ? '${app.settings.smtpUser} · ${app.settings.smtpHost}' : tr('Nicht eingerichtet')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await showMailAccountDialog(context);
              await _load();
            },
          ),
          const Divider(),
          Text('Im Tresor (${_keys.length})', style: t.titleSmall),
          for (final k in _keys)
            ListTile(dense: true, leading: const Icon(Icons.key_outlined, size: 18), title: Text(label(k)), subtitle: const Text('••••••••')),
          if (_keys.isEmpty)
            Padding(padding: const EdgeInsets.all(8), child: Text(tr('Leer.'), style: TextStyle(color: scheme.onSurfaceVariant))),
        ],
      ),
    );
  }
}
