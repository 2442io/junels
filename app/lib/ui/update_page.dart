// Updates: Hinweis im Menü und Installation direkt aus der App.

import 'dart:io';

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/native_files.dart';
import '../state/update_service.dart';
import '../version.dart';
import 'info_pages.dart';
import 'theme.dart';
import 'quick_nav.dart';

Future<void> openUpdates(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const UpdatePage()));

/// Karte im Menü – nur sichtbar, wenn ein Update bereitliegt.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final up = AppScope.of(context).updates;
    return ValueListenableBuilder<UpdateInfo?>(
      valueListenable: up.available,
      builder: (context, info, _) {
        if (info == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Card(
          color: scheme.primaryContainer,
          child: ListTile(
            leading: Icon(Icons.system_update, color: scheme.onPrimaryContainer),
            title: Text('Update verfügbar: ${info.version}', style: TextStyle(color: scheme.onPrimaryContainer)),
            subtitle: Text('Installiert: $appVersion – tippen zum Aktualisieren',
                style: TextStyle(color: scheme.onPrimaryContainer)),
            onTap: () => openUpdates(context),
          ),
        );
      },
    );
  }
}

class UpdatePage extends StatefulWidget {
  const UpdatePage({super.key});

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  final _token = TextEditingController();
  bool _editToken = false;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final up = AppScope.of(context).updates;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: JAppBar(title: const Text('Updates & Neuigkeiten')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Installiert: Junels $appVersion (Build $appBuild)', style: t.titleMedium),
          const SizedBox(height: 8),
          if (!up.supported)
            const Text('Updates in der App gibt es auf Android und Mac.')
          else ...[
            ValueListenableBuilder<String>(
              valueListenable: up.status,
              builder: (context, s, _) => s.isEmpty ? const SizedBox.shrink() : Text(s, style: t.bodyMedium),
            ),
            ValueListenableBuilder<String?>(
              valueListenable: up.error,
              builder: (context, e, _) => e == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(e, style: t.bodyMedium?.copyWith(color: scheme.error)),
                    ),
            ),
            ValueListenableBuilder<double?>(
              valueListenable: up.progress,
              builder: (context, p, _) => p == null
                  ? const SizedBox(height: 12)
                  : Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: LinearProgressIndicator(value: p),
                    ),
            ),
            ValueListenableBuilder<UpdateInfo?>(
              valueListenable: up.available,
              builder: (context, info, _) => info == null
                  ? const SizedBox.shrink()
                  : Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Neu: ${info.version} (Build ${info.build})', style: t.titleMedium),
                          if (info.notes.isNotEmpty) ...[const SizedBox(height: 6), Text(info.notes)],
                          if (info.size > 0) Text('${(info.size / 1e6).toStringAsFixed(0)} MB', style: t.bodySmall),
                          const SizedBox(height: 12),
                          ValueListenableBuilder<double?>(
                            valueListenable: up.progress,
                            builder: (context, p, _) => FilledButton.icon(
                              icon: const Icon(Icons.download),
                              label: const Text('Jetzt aktualisieren'),
                              onPressed: p != null ? null : () => _install(context, up),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text('Deine Chats, Einstellungen und Modelle bleiben erhalten.', style: t.bodySmall),
                        ]),
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Nach Updates suchen'),
              onPressed: () => up.check(),
            ),
            if (!_editToken)
              TextButton(
                onPressed: () => setState(() => _editToken = true),
                child: Text(up.hasToken ? 'GitHub-Token ändern' : 'GitHub-Token eintragen (nur bei privatem Repository)'),
              )
            else ...[
              const SizedBox(height: 8),
              Text('GitHub-Token (optional)', style: t.titleSmall),
              const SizedBox(height: 6),
              const Text('Nur nötig, wenn das Junels-Repository privat ist. Der Token braucht reines Leserecht und '
                  'bleibt nur auf diesem Gerät.\n\n'
                  '1. Auf GitHub „Fine-grained token“ erstellen\n'
                  '2. Repository access: Only select repositories → 2442io/junels\n'
                  '3. Permissions → Repository → Contents: Read-only\n'
                  '4. Token kopieren und hier einfügen'),
              TextButton.icon(
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Token auf GitHub erstellen'),
                onPressed: () => NativeFiles.openUrl('https://github.com/settings/personal-access-tokens/new'),
              ),
              TextField(
                controller: _token,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'GitHub-Token', hintText: 'github_pat_…'),
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: () async {
                  await up.setToken(_token.text);
                  _token.clear();
                  if (mounted) setState(() => _editToken = false);
                },
                child: const Text('Speichern und prüfen'),
              ),
            ],
          ],
          const SectionLabel('Was ist neu', padding: EdgeInsets.fromLTRB(4, 24, 4, 8)),
          const ChangelogList(),
        ],
      ),
    );
  }

  /// Mac: Junels muss beendet sein, sonst lässt Finder die App nicht ersetzen.
  Future<void> _install(BuildContext context, UpdateService up) async {
    if (Platform.isMacOS) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Update installieren'),
          content: const Text('Die neue Version wird im Browser heruntergeladen, Junels beendet sich dann selbst.\n\n'
              '1. Im Ordner „Downloads“ Junels.dmg öffnen.\n'
              '2. Junels auf „Programme“ ziehen → „Ersetzen“.\n'
              '3. Beim ersten Start: Rechtsklick auf Junels → „Öffnen“ → „Öffnen“. '
              '(Falls nötig: Systemeinstellungen → Datenschutz & Sicherheit → „Dennoch öffnen“.)\n\n'
              'Chats, Einstellungen und Modelle bleiben erhalten.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Herunterladen und beenden')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await up.install(quitAfterOpen: Platform.isMacOS);
  }
}
