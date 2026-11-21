// Schalter in der Kopfleiste: Internet für diesen Chat aus / fragen / erlaubt.

import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/app_scope.dart';
import 'theme.dart';

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
    final c = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final color = switch (mode) {
      InternetMode.off => c.faint,
      InternetMode.ask => scheme.onSurface,
      InternetMode.allowed => c.amber,
    };
    return PopupMenuButton<InternetMode>(
      tooltip: 'Internet: ${mode.label}',
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: mode == InternetMode.allowed ? c.amberSoft : scheme.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: mode == InternetMode.allowed ? c.amber.withValues(alpha: 0.5) : c.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(iconFor(mode), size: 18, color: color),
          const SizedBox(width: 6),
          Text(switch (mode) {
            InternetMode.off => 'Offline',
            InternetMode.ask => 'Fragen',
            InternetMode.allowed => 'Online',
          }, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: color)),
        ]),
      ),
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
              leading: Icon(iconFor(m), color: m == InternetMode.allowed ? c.amber : null),
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
