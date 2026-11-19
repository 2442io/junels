// Updates: Hinweis im Menü und Installation direkt aus der App.

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/native_files.dart';
import '../state/update_service.dart';
import '../version.dart';
import 'info_pages.dart';

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
      appBar: AppBar(title: const Text('Updates')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Installiert: Junels $appVersion (Build $appBuild)', style: t.titleMedium),
          TextButton(onPressed: () => openChangelog(context), child: const Text('Versionsverlauf ansehen')),
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
                              onPressed: p != null ? null : up.install,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text('Deine Chats, Einstellungen und Modelle bleiben erhalten.', style: t.bodySmall),
                        ]),
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            if (up.hasToken && !_editToken) ...[
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Nach Updates suchen'),
                onPressed: () => up.check(),
              ),
              TextButton(onPressed: () => setState(() => _editToken = true), child: const Text('GitHub-Token ändern')),
            ] else ...[
              const SizedBox(height: 8),
              Text('Einmalig einrichten', style: t.titleSmall),
              const SizedBox(height: 6),
              const Text('Das Junels-Repository ist privat. Damit die App neue Versionen findet, braucht sie einen '
                  'GitHub-Token mit reinem Leserecht. Er bleibt nur auf diesem Gerät.\n\n'
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
        ],
      ),
    );
  }
}
