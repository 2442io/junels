// Geräte-Setups: gerätebezogene Einstellungen (Modell, Stimme, Werkzeuge, KI-Modus …)
// als „Desktop“, „Handy“ usw. speichern und auf jedem Gerät anwenden.

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import 'theme.dart';

Future<void> openSetups(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SetupsPage()));

class SetupsPage extends StatelessWidget {
  const SetupsPage({super.key});

  Future<String?> _ask(BuildContext context, String title, String initial) async {
    final ctrl = TextEditingController(text: initial);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
            controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: 'z. B. Desktop, Handy, Büro-Mac'),
            onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Speichern')),
        ],
      ),
    );
    ctrl.dispose();
    return r == null || r.trim().isEmpty ? null : r.trim();
  }

  String _summary(Map<String, dynamic> s) {
    final parts = <String>[];
    final model = s['lastModelId'];
    if (model is String && model.isNotEmpty) parts.add('Modell: ${model.length > 28 ? '${model.substring(0, 28)}…' : model}');
    final voice = s['ttsVoiceId'];
    parts.add('Stimme: ${voice is String && voice.isNotEmpty ? voice : 'Gerät'}');
    final r = s['routing'];
    if (r is String && r.isNotEmpty) parts.add('KI-Modus: $r');
    final tools = s['enabledTools'];
    if (tools is List) parts.add('${tools.length} Werkzeuge');
    final saved = DateTime.tryParse('${s['_saved'] ?? ''}');
    if (saved != null) parts.add('gespeichert ${saved.day}.${saved.month}.${saved.year}');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final setups = app.settings.setups;
    final mine = app.deviceSetupName;
    return Scaffold(
      appBar: AppBar(title: const Text('Geräte-Setups')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(
                  'Ein Setup merkt sich, was zum Gerät gehört: Sprachmodell, Modellwahl, Stimme und Spracherkennung, '
                  'Werkzeuge, KI-Modus, Gesprächs-Einstellungen. Chats, Gedächtnis und Konten gehören zu dir und bleiben gleich. '
                  'Nach einer Sicherung oder beim Abgleich bekommt jedes Gerät automatisch wieder sein eigenes Setup.',
                  style: t.bodySmall,
                ),
                const SizedBox(height: 16),
                Panel(
                  child: Row(children: [
                    Icon(Icons.devices_outlined, color: c.mint),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Dieses Gerät', style: t.labelSmall),
                        Text(mine, style: t.titleMedium),
                      ]),
                    ),
                    FilledButton.tonal(
                      onPressed: () async {
                        await app.saveSetup(mine, asThisDevice: true);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Aktuelle Einstellungen als „$mine“ gespeichert.')));
                        }
                      },
                      child: const Text('Jetzt speichern'),
                    ),
                  ]),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Als neues Setup speichern …'),
                    onPressed: () async {
                      final n = await _ask(context, 'Name des Setups', '');
                      if (n != null) await app.saveSetup(n);
                    },
                  ),
                ),
                const SizedBox(height: 8),
                if (setups.isEmpty)
                  const Panel(
                      child: EmptyHint(
                          icon: Icons.tune, title: 'Noch keine Setups', text: 'Tippe auf „Jetzt speichern“, um dieses Gerät als Setup zu sichern.')),
                for (final e in setups.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Panel(
                      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                      child: Row(children: [
                        Icon(e.value['_device'] == 'android' ? Icons.smartphone : Icons.laptop_mac, color: c.muted),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Flexible(child: Text(e.key, style: t.titleSmall, overflow: TextOverflow.ellipsis)),
                              if (e.key == mine) ...[
                                const SizedBox(width: 8),
                                StatusChip('dieses Gerät', color: c.mint, soft: c.mintSoft, dense: true),
                              ],
                            ]),
                            const SizedBox(height: 2),
                            Text(_summary(e.value), style: t.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                          ]),
                        ),
                        PopupMenuButton<String>(
                          onSelected: (v) async {
                            final messenger = ScaffoldMessenger.of(context);
                            switch (v) {
                              case 'apply':
                                final skipped = await app.applySetup(e.key);
                                messenger.showSnackBar(SnackBar(
                                    content: Text('„${e.key}“ angewendet'
                                        '${skipped.isEmpty ? '.' : ' – nicht vorhanden hier: ${skipped.join(', ')} (bleibt wie bisher).'}')));
                              case 'mine':
                                await app.setDeviceSetup(e.key);
                              case 'update':
                                await app.saveSetup(e.key);
                              case 'delete':
                                await app.deleteSetup(e.key);
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'apply', child: Text('Auf diesem Gerät anwenden')),
                            if (e.key != mine) const PopupMenuItem(value: 'mine', child: Text('Als Setup dieses Geräts festlegen')),
                            const PopupMenuItem(value: 'update', child: Text('Mit aktuellen Einstellungen überschreiben')),
                            const PopupMenuItem(value: 'delete', child: Text('Löschen')),
                          ],
                        ),
                      ]),
                    ),
                  ),
                const SizedBox(height: 8),
                Text('Tipp: Mit dem Abgleich („Geräte-Setups“) oder einer Sicherung kommen die Setups auf deine anderen Geräte.',
                    style: t.bodySmall),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

