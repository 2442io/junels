// Gespeicherte Prompts: bearbeiten, Zeitplan festlegen, starten.

import 'dart:io';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_controller.dart';
import '../state/app_scope.dart';
import 'notify_style.dart';
import 'quick_nav.dart';

Future<void> editPrompt(BuildContext context, {SavedPrompt? prompt, String? initialText, bool scheduled = false}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PromptEditor(prompt: prompt, initialText: initialText, scheduled: scheduled),
    ));

/// Startet einen Prompt und schließt ggf. die Seitenleiste.
Future<void> runSavedPrompt(BuildContext context, AppController app, SavedPrompt p) async {
  final messenger = ScaffoldMessenger.of(context);
  if (app.running) {
    messenger.showSnackBar(const SnackBar(content: Text('Der Agent arbeitet gerade – bitte kurz warten.')));
    return;
  }
  if (Scaffold.maybeOf(context)?.isDrawerOpen ?? false) Navigator.of(context).maybePop();
  await app.runPrompt(p);
}

class PromptEditor extends StatefulWidget {
  const PromptEditor({super.key, this.prompt, this.initialText, this.scheduled = false});
  final SavedPrompt? prompt;
  final String? initialText;
  final bool scheduled;

  @override
  State<PromptEditor> createState() => _PromptEditorState();
}

class _PromptEditorState extends State<PromptEditor> {
  late final SavedPrompt p = widget.prompt != null
      ? SavedPrompt.fromJson(widget.prompt!.toJson())
      : SavedPrompt(
          title: '',
          text: widget.initialText ?? '',
          schedule: widget.scheduled ? ScheduleKind.daily : ScheduleKind.off);
  late final _title = TextEditingController(text: p.title);
  late final _text = TextEditingController(text: p.text);

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _save({bool run = false}) async {
    final app = AppScope.read(context);
    final nav = Navigator.of(context);
    if (_text.text.trim().isEmpty) return;
    p
      ..title = _title.text.trim().isEmpty ? _text.text.trim().split('\n').first : _title.text.trim()
      ..text = _text.text.trim();
    if (p.title.length > 50) p.title = '${p.title.substring(0, 50)}…';
    await app.savePrompt(p);
    nav.pop();
    if (run) await app.runPrompt(p);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final t = Theme.of(context).textTheme;
    final isNew = widget.prompt == null;
    return Scaffold(
      appBar: JAppBar(
        title: Text(isNew ? 'Neuer Prompt' : 'Prompt bearbeiten'),
        actions: [
          if (!isNew)
            IconButton(
              tooltip: 'Löschen',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final nav = Navigator.of(context);
                await app.deletePrompt(widget.prompt!);
                nav.pop();
              },
            ),
          TextButton(onPressed: () => _save(), child: const Text('Speichern')),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Name', hintText: 'z. B. Morgen-Briefing'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _text,
                minLines: 5,
                maxLines: 14,
                decoration: const InputDecoration(
                  labelText: 'Prompt',
                  hintText: 'z. B. Fasse die wichtigsten Nachrichten aus Österreich von heute in 5 Punkten zusammen.',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: p.profileId,
                decoration: const InputDecoration(labelText: 'Agent-Profil'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Aktuelles Profil')),
                  for (final pr in app.profiles) DropdownMenuItem(value: pr.id, child: Text(pr.name)),
                ],
                onChanged: (v) => setState(() => p.profileId = v),
              ),
              const SizedBox(height: 24),
              Text('Zeitplan', style: t.titleMedium),
              const SizedBox(height: 8),
              SegmentedButton<ScheduleKind>(
                segments: const [
                  ButtonSegment(value: ScheduleKind.off, label: Text('Aus')),
                  ButtonSegment(value: ScheduleKind.daily, label: Text('Täglich')),
                  ButtonSegment(value: ScheduleKind.weekdays, label: Text('Mo–Fr')),
                  ButtonSegment(value: ScheduleKind.weekly, label: Text('Wöchentl.')),
                ],
                selected: {p.schedule},
                onSelectionChanged: (s) => setState(() => p.schedule = s.first),
              ),
              if (p.schedule != ScheduleKind.off) ...[
                const SizedBox(height: 12),
                Row(children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.schedule),
                    label: Text('um ${p.timeLabel} Uhr'),
                    onPressed: () async {
                      final r = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay(hour: p.hour, minute: p.minute),
                        builder: (ctx, child) => MediaQuery(
                          data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
                          child: child!,
                        ),
                      );
                      if (r != null) setState(() => p..hour = r.hour..minute = r.minute);
                    },
                  ),
                  const SizedBox(width: 12),
                  if (p.schedule == ScheduleKind.weekly)
                    DropdownButton<int>(
                      value: p.weekday,
                      items: [
                        for (var d = 1; d <= 7; d++) DropdownMenuItem(value: d, child: Text(SavedPrompt.weekdayNames[d - 1])),
                      ],
                      onChanged: (v) => setState(() => p.weekday = v ?? 1),
                    ),
                ]),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: p.notify,
                  onChanged: (v) => setState(() => p.notify = v),
                  title: const Text('Benachrichtigen, wenn fertig'),
                ),
                if (p.notify)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: NotifyKindField(value: p.notifyKind, onChanged: (v) => setState(() => p.notifyKind = v)),
                  ),
                Text(
                  Platform.isAndroid
                      ? 'Läuft auch bei geschlossener App. Das Ergebnis steht als neuer Chat bereit.'
                      : 'Läuft, solange die App geöffnet ist (Fenster schließen reicht – die App bleibt im Dock). '
                          'Verpasste Termine werden am selben Tag beim nächsten Start nachgeholt.',
                  style: t.bodySmall,
                ),
              ],
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: p.allowInternet,
                onChanged: (v) => setState(() => p.allowInternet = v),
                title: const Text('Internet ohne Nachfrage erlauben'),
                subtitle: const Text('Nötig, wenn der Prompt Websuche braucht und automatisch läuft.'),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: app.engine == null && app.models.isEmpty ? null : () => _save(run: true),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Speichern und jetzt ausführen'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
