// Geplante Aufgaben, Aktivitäten-Verlauf und Tresor-Übersicht.

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_controller.dart';
import '../state/app_scope.dart';
import '../state/vault.dart';
import 'chat_view.dart' show showMailAccountDialog;
import 'prompt_editor.dart';

Future<void> openTasks(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TasksPage()));

Future<void> openActivity(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ActivityPage()));

Future<void> openVault(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VaultPage()));

String _two(int v) => v.toString().padLeft(2, '0');

/// Liste wiederkehrender Aufträge mit Schaltern.
class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final tasks = app.prompts.where((p) => p.schedule != ScheduleKind.off).toList()
      ..sort((a, b) => (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute));
    final hasPrep = app.prompts.any((p) => p.id == AppController.meetingPrepId);
    final hasMorning = app.prompts.any((p) => p.title == 'Morgen-Übersicht');
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(title: const Text('Geplante Aufgaben')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => editPrompt(context, initialText: ''),
        icon: const Icon(Icons.add),
        label: const Text('Neue Aufgabe'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Text('Der Agent erledigt diese Aufträge selbständig zur eingestellten Zeit und meldet sich per Push-Nachricht.',
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          for (final p in tasks)
            Card(
              child: ListTile(
                leading: Icon(p.id == AppController.meetingPrepId ? Icons.event_note_outlined : Icons.schedule),
                title: Text(p.title),
                subtitle: Text([
                  p.scheduleLabel,
                  if (p.enabled && p.nextAfter(now) != null)
                    'nächster Lauf ${p.nextAfter(now)!.day}.${p.nextAfter(now)!.month}. ${_two(p.nextAfter(now)!.hour)}:${_two(p.nextAfter(now)!.minute)}',
                  if (p.lastRun != null) 'zuletzt ${p.lastRun!.day}.${p.lastRun!.month}. ${_two(p.lastRun!.hour)}:${_two(p.lastRun!.minute)}',
                ].join(' · ')),
                onTap: () => editPrompt(context, prompt: p),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: 'Jetzt ausführen',
                    icon: const Icon(Icons.play_arrow),
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
          if (tasks.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Noch keine geplanten Aufgaben.', style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          const SizedBox(height: 16),
          Text('Vorlagen', style: t.titleSmall),
          const SizedBox(height: 6),
          if (!hasPrep)
            Card(
              child: ListTile(
                leading: const Icon(Icons.event_note_outlined),
                title: const Text('Termine vorbereiten (Mo–Fr 7:30)'),
                subtitle: const Text('Pro Termin eine einseitige Notiz: Firma, Webseite, mögliche Fragen, Ziele.'),
                trailing: const Icon(Icons.add),
                onTap: () async {
                  await app.createMeetingPrep();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('„Termine vorbereiten“ angelegt – läuft Mo–Fr um 7:30')));
                  }
                },
              ),
            ),
          if (!hasMorning)
            Card(
              child: ListTile(
                leading: const Icon(Icons.wb_sunny_outlined),
                title: const Text('Morgen-Übersicht (täglich 7:00)'),
                subtitle: const Text('Termine, Wetter und Nachrichten in einer Push-Nachricht.'),
                trailing: const Icon(Icons.add),
                onTap: () => app.createMorningBriefing(city: app.settings.homeCity.isEmpty ? 'Wien' : app.settings.homeCity),
              ),
            ),
          SwitchListTile(
            title: const Text('Nach Terminen Folgemail vorschlagen'),
            subtitle: const Text('Push-Nachricht, sobald ein Termin vorbei ist – ein Tipp öffnet den Entwurf.'),
            value: app.settings.meetingFollowUp,
            onChanged: (v) => app.setMeetingFollowUp(v),
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
        trailing: Text('lokal · 0 €', style: t.labelSmall?.copyWith(color: scheme.primary)),
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
                'Alles läuft auf diesem Gerät – keine Cloud-KI, keine Kosten. '
                '${items.length} Aktion${items.length == 1 ? '' : 'en'} im Verlauf, Kosten: 0 €.',
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
