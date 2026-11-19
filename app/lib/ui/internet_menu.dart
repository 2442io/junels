// Schalter in der Kopfleiste: Internet für diesen Chat aus / fragen / erlaubt.

import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/app_scope.dart';

class InternetMenu extends StatelessWidget {
  const InternetMenu({super.key});

  static IconData iconFor(InternetMode m) => switch (m) {
        InternetMode.off => Icons.public_off,
        InternetMode.ask => Icons.public,
        InternetMode.allowed => Icons.public,
      };

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final mode = app.internetMode;
    final scheme = Theme.of(context).colorScheme;
    final color = switch (mode) {
      InternetMode.off => scheme.outline,
      InternetMode.ask => null,
      InternetMode.allowed => Colors.orange,
    };
    return PopupMenuButton<InternetMode>(
      tooltip: 'Internet: ${mode.label}',
      icon: Icon(iconFor(mode), color: color),
      initialValue: mode,
      onSelected: (m) async {
        if (m == InternetMode.allowed) {
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              icon: const Icon(Icons.public),
              title: const Text('Internet für diesen Chat erlauben?'),
              content: const Text('Der Agent darf dann ohne weitere Nachfrage Webseiten lesen und im Web suchen. '
                  'Es werden nur die Suchanfragen bzw. Adressen gesendet – das Sprachmodell läuft weiter lokal.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Erlauben')),
              ],
            ),
          );
          if (ok != true) return;
        }
        await app.setInternetMode(m);
      },
      itemBuilder: (_) => [
        for (final m in InternetMode.values)
          PopupMenuItem(
            value: m,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(iconFor(m), color: m == InternetMode.allowed ? Colors.orange : null),
              title: Text(m.label),
              subtitle: Text(switch (m) {
                InternetMode.off => 'Keine Websuche, keine Webseiten',
                InternetMode.ask => 'Vor jedem Zugriff nachfragen',
                InternetMode.allowed => 'Ohne Nachfrage',
              }),
              trailing: m == mode ? const Icon(Icons.check) : null,
            ),
          ),
      ],
    );
  }
}
