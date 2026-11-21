// Geplante Aufgaben, Aktivitäten-Verlauf und Tresor-Übersicht.

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_controller.dart';
import '../state/app_scope.dart';
import '../state/vault.dart';
import 'chat_view.dart' show showMailAccountDialog;
import 'device_page.dart' show setupMorningBriefing;
import 'prompt_editor.dart';
import 'theme.dart';

Future<void> openTasks(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TasksPage()));

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
      appBar: AppBar(title: const Text('Geplante Aufgaben'), actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: FilledButton.icon(
            onPressed: () => editPrompt(context, initialText: '', scheduled: true),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Neue Aufgabe'),
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
                  title: 'Geplante Aufgaben',
                  subtitle: 'Der Agent erledigt diese Aufträge selbständig zur eingestellten Zeit und meldet sich per Push-Nachricht.',
                ),
                Row(children: [
                  _Stat(label: 'Aktiv', value: '$active', color: c.mint),
                  const SizedBox(width: 10),
                  _Stat(label: 'Pausiert', value: '${tasks.length - active}', color: c.faint),
                  const SizedBox(width: 10),
                  _Stat(
                    label: 'Nächster Lauf',
                    value: () {
                      final next = tasks
                          .where((p) => p.enabled)
                          .map((p) => p.nextAfter(now))
                          .whereType<DateTime>()
                          .fold<DateTime?>(null, (m, d) => m == null || d.isBefore(m) ? d : m);
                      return next == null ? '–' : _when(next);
                    }(),
                    color: c.blue,
                  ),
                ]),
                const SectionLabel('Aufgaben', padding: EdgeInsets.fromLTRB(4, 22, 4, 8)),
                if (tasks.isEmpty)
                  Panel(
                    child: EmptyHint(
                      icon: Icons.alarm_add_outlined,
                      title: 'Noch keine geplanten Aufgaben',
                      text: 'Leg eine eigene Aufgabe an oder starte mit einer Vorlage unten.',
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
                              const SizedBox(width: 8),
                              p.enabled
                                  ? StatusChip('Aktiv', color: c.mint, soft: c.mintSoft, dense: true)
                                  : StatusChip('Pausiert', color: c.muted, soft: c.raised, dense: true),
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
                          tooltip: 'Jetzt ausführen',
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
                const SectionLabel('Vorlagen', padding: EdgeInsets.fromLTRB(4, 22, 4, 8)),
                LayoutBuilder(builder: (context, box) {
                  final cols = box.maxWidth >= 640 ? 2 : 1;
                  final w = (box.maxWidth - (cols - 1) * 10) / cols;
                  final cards = <Widget>[
                    _TemplateCard(
                      icon: Icons.wb_twilight,
                      title: 'Morgen-Übersicht',
                      text: 'Termine, Wetter und Nachrichten jeden Morgen als Push-Nachricht.',
                      done: hasMorning,
                      onTap: () => setupMorningBriefing(context),
                    ),
                    _TemplateCard(
                      icon: Icons.event_note_outlined,
                      title: 'Termine vorbereiten',
                      text: 'Mo–Fr 7:30: pro Termin eine Notiz mit Firma, Webseite, Fragen und Zielen.',
                      done: hasPrep,
                      onTap: () async {
                        await app.createMeetingPrep();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('„Termine vorbereiten“ angelegt – läuft Mo–Fr um 7:30')));
                        }
                      },
                    ),
                    _TemplateCard(
                      icon: Icons.newspaper,
                      title: 'News zu einem Thema',
                      text: 'Täglich die wichtigsten Meldungen zu deinem Thema, kurz zusammengefasst.',
                      onTap: () => editPrompt(context,
                          initialText: 'Suche die wichtigsten aktuellen Nachrichten zum Thema „…“ und fasse sie in 5 Punkten zusammen.',
                          scheduled: true),
                    ),
                    _TemplateCard(
                      icon: Icons.summarize_outlined,
                      title: 'Wochenrückblick',
                      text: 'Freitags: was diese Woche in deinen Chats und Aktivitäten passiert ist.',
                      onTap: () => editPrompt(context,
                          initialText: 'Fasse zusammen, woran ich diese Woche gearbeitet habe (Chats und Aktivitäten), und nenne offene Punkte.',
                          scheduled: true),
                    ),
                  ];
                  return Wrap(spacing: 10, runSpacing: 10, children: [for (final c in cards) SizedBox(width: w, child: c)]);
                }),
                const SizedBox(height: 14),
                Panel(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: SwitchListTile(
                    title: const Text('Nach Terminen Folgemail vorschlagen'),
                    subtitle: const Text('Push-Nachricht, sobald ein Termin vorbei ist – ein Tipp öffnet den Entwurf.'),
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

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Expanded(
      child: Panel(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(), style: TextStyle(fontSize: 10.5, letterSpacing: 1.1, color: c.faint, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: Ui.mono, fontSize: 18, fontWeight: FontWeight.w500, color: color)),
        ]),
      ),
    );
  }
}

class _TemplateCard extends StatelessWidget {
  const _TemplateCard({required this.icon, required this.title, required this.text, required this.onTap, this.done = false});
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
              if (done) ...[const SizedBox(width: 8), StatusChip('Eingerichtet', color: c.mint, soft: c.mintSoft, dense: true)],
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
    final list = app.prompts.where((p) => p.schedule == ScheduleKind.off).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Prompt-Vorlagen'), actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: FilledButton.icon(
            onPressed: () => editPrompt(context, initialText: ''),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Neue Vorlage'),
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
                const PageHeader(
                  icon: Icons.bolt_outlined,
                  title: 'Prompt-Vorlagen',
                  subtitle: 'Häufige Aufträge mit einem Tipp starten. Mit Zeitplan werden sie zu geplanten Aufgaben.',
                ),
                if (list.isEmpty)
                  Panel(
                    child: EmptyHint(
                      icon: Icons.bolt_outlined,
                      title: 'Noch keine Vorlagen',
                      text: 'Im Chat über ⚡ → „Eingabe als Prompt speichern“ oder hier mit „Neue Vorlage“.',
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
                            const SizedBox(height: 2),
                            Text(p.text.replaceAll('\n', ' '),
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                          ]),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: app.running ? null : () => runSavedPrompt(context, app, p),
                          icon: const Icon(Icons.play_arrow_rounded, size: 18),
                          label: const Text('Starten'),
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
      if (d.year == n.year && d.month == n.month && d.day == n.day) return 'Heute';
      final y = n.subtract(const Duration(days: 1));
      if (d.year == y.year && d.month == y.month && d.day == y.day) return 'Gestern';
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
      appBar: AppBar(title: const Text('Was hat der Agent getan?'), actions: [
        if (items.isNotEmpty)
          IconButton(
            tooltip: 'Verlauf leeren',
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
          Card(
            color: scheme.primaryContainer.withValues(alpha: 0.5),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                '${app.settings.routing == 'local' ? 'Alles läuft auf diesem Gerät – keine Cloud-KI, keine Kosten. ' : 'Antworten kommen ${app.routingLabel ?? 'lokal'}; alle Aktionen bleiben hier protokolliert. '}'
                '${items.length} Aktion${items.length == 1 ? '' : 'en'} im Verlauf.',
                style: t.bodyMedium,
              ),
            ),
          ),
          ...rows,
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Noch keine Aktionen. Hier erscheint z. B. „E-Mail an Sara gesendet – du hast ‚Senden‘ getippt“.',
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
      appBar: AppBar(title: const Text('Tresor & Konten')),
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
                        ? 'Passwörter und Anmelde-Schlüssel liegen verschlüsselt im ${Theme.of(context).platform == TargetPlatform.macOS ? 'macOS-Schlüsselbund' : 'Android-Keystore'} – '
                            'nicht in den App-Dateien und nicht im Abgleich. Der Agent hat kein Werkzeug, das den Tresor liest: '
                            'Nur der Mailversand und die Anmeldung bei MCP-Diensten holen sich gezielt, was sie brauchen.'
                        : 'Auf diesem System gibt es keinen Tresor.',
                    style: t.bodyMedium,
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Icons.mail_outline),
            title: const Text('E-Mail direkt senden'),
            subtitle: Text(app.settings.smtpReady ? '${app.settings.smtpUser} · ${app.settings.smtpHost}' : 'Nicht eingerichtet'),
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
            Padding(padding: const EdgeInsets.all(8), child: Text('Leer.', style: TextStyle(color: scheme.onSurfaceVariant))),
        ],
      ),
    );
  }
}
