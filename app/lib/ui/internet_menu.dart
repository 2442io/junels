// Schalter in der Kopfleiste: Internet für diesen Chat aus / fragen / erlaubt.

import 'package:flutter/material.dart';

import '../data/models.dart' show Conversation;
import '../state/app_controller.dart';
import '../state/app_scope.dart';
import 'settings_page.dart' show openSettings;
import 'theme.dart';

class InternetMenu extends StatelessWidget {
  const InternetMenu({super.key, this.compact = false});
  final bool compact;

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
    final offline = !app.deviceOnline;
    final color = offline
        ? c.red
        : switch (mode) {
            InternetMode.off => c.faint,
            InternetMode.ask => scheme.onSurface,
            InternetMode.allowed => c.amber,
          };
    return PopupMenuButton<InternetMode>(
      tooltip: offline ? 'Kein Netz – Junels antwortet mit dem Modell auf dem Gerät' : 'Internet: ${mode.label}',
      child: Container(
        height: 38,
        width: compact ? 38 : null,
        padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
        decoration: BoxDecoration(
          color: mode == InternetMode.allowed ? c.amberSoft : scheme.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: mode == InternetMode.allowed ? c.amber.withValues(alpha: 0.5) : c.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(offline ? Icons.wifi_off : iconFor(mode), size: 18, color: color),
          if (!compact) const SizedBox(width: 6),
          if (!compact)
            Text(offline ? 'Kein Netz' : switch (mode) {
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

/// KI-Modus für diesen Chat: Am Gerät, On-Prem, Cloud oder Hybrid.
class AiModeMenu extends StatelessWidget {
  const AiModeMenu({super.key, this.compact = false, this.target});
  final bool compact;

  /// Chat, für den der Modus gilt (Standard: der offene Chat; im Gespräch: dessen Chat)
  final Conversation? target;

  static IconData iconFor(String mode) => switch (mode) {
        'onprem' => Icons.dns_outlined,
        'cloud' => Icons.cloud_outlined,
        'hybrid' || 'hybrid-onprem' || 'hybrid-cloud' => Icons.alt_route,
        _ => Icons.phone_android,
      };

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final conv = target ?? app.current;
    final own = conv?.routing;
    final effective = own ?? (app.settings.routing == 'hybrid' ? 'hybrid-${app.settings.hybridTarget}' : app.settings.routing);
    final short = switch (app.routingOf(conv)) {
      'onprem' => 'On-Prem',
      'cloud' => 'Cloud',
      'hybrid' => 'Hybrid',
      _ => 'Gerät',
    };
    final color = switch (app.routingOf(conv)) {
      'cloud' => c.blue,
      'onprem' => c.violet,
      'hybrid' => c.amber,
      _ => scheme.onSurface,
    };
    PopupMenuItem<String> item(String mode, {bool enabled = true, String? sub}) => PopupMenuItem(
          value: mode,
          enabled: enabled,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(iconFor(mode), color: enabled ? null : c.faint),
            title: Text(AppController.routingName(mode)),
            subtitle: sub == null ? null : Text(sub, maxLines: 2),
            trailing: effective == mode && own != null ? Icon(Icons.check, color: c.mint, size: 18) : null,
          ),
        );
    final hasOnPrem = app.onPremProvider != null, hasCloud = app.cloudProvider != null;
    return PopupMenuButton<String>(
      tooltip: 'KI-Modus: ${AppController.routingName(effective)}',
      onSelected: (v) {
        if (v == '__settings') {
          openSettings(context, section: 'providers');
        } else {
          app.setChatRouting(v == '__default' ? null : v, conv: target);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: '__default',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.settings_suggest_outlined),
            title: const Text('Standard'),
            subtitle: Text('wie in den Einstellungen: ${AppController.routingName(app.settings.routing == 'hybrid' ? 'hybrid-${app.settings.hybridTarget}' : app.settings.routing)}'),
            trailing: own == null ? Icon(Icons.check, color: c.mint, size: 18) : null,
          ),
        ),
        const PopupMenuDivider(),
        item('local', enabled: app.status == EngineStatus.ready || app.models.isNotEmpty, sub: 'Alles bleibt auf diesem Gerät'),
        item('onprem', enabled: hasOnPrem, sub: hasOnPrem ? app.onPremProvider!.label : 'Kein Server eingerichtet'),
        item('cloud', enabled: hasCloud, sub: hasCloud ? app.cloudProvider!.label : 'Kein Cloud-Anbieter eingerichtet'),
        item('hybrid-onprem', enabled: hasOnPrem, sub: 'Erst am Gerät, klappt es nicht: dein Server'),
        item('hybrid-cloud', enabled: hasCloud, sub: 'Erst am Gerät, dann Cloud nach Freigabe'),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: '__settings',
          child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.tune), title: Text('Anbieter verwalten …')),
        ),
      ],
      child: Container(
        height: 38,
        width: compact ? 38 : null,
        padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: own != null ? color.withValues(alpha: 0.6) : c.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(iconFor(effective), size: 18, color: color),
          if (!compact) ...[
            const SizedBox(width: 6),
            Text(short, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: color)),
          ],
        ]),
      ),
    );
  }
}
