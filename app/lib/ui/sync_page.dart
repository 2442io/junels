// Abgleich zwischen den eigenen Geräten: eigener Server oder WLAN.

import 'dart:async';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_scope.dart';
import '../state/sync_service.dart';

Future<void> openSync(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SyncPage()));

class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  late final _server = TextEditingController(text: AppScope.read(context).sync.config.serverUrl);
  late final _name = TextEditingController(text: AppScope.read(context).sync.config.deviceName);
  final _lanAddr = TextEditingController();
  bool _show = false;
  List<String> _ownIps = const [];
  List<LanPeer>? _peers;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    LanSyncHost.localAddresses().then((v) {
      if (mounted) setState(() => _ownIps = v);
    });
  }

  @override
  void dispose() {
    _pass.dispose();
    _pass2.dispose();
    _server.dispose();
    _name.dispose();
    _lanAddr.dispose();
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final sync = app.sync;
    final cfg = sync.config;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    Widget section(String title, List<Widget> children, {IconData? icon}) => Card(
          margin: const EdgeInsets.only(bottom: 14),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
                Text(title, style: t.titleMedium),
              ]),
              const SizedBox(height: 10),
              ...children,
            ]),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Abgleich zwischen Geräten')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Chats, Gedächtnis, Prompts usw. zwischen Mac und Handy gleich halten. Alles wird auf dem Gerät '
            'mit deinem Sync-Passwort verschlüsselt – Server und Netzwerk sehen nur unlesbare Daten. '
            'Modelle werden nicht übertragen.',
            style: t.bodyMedium,
          ),
          const SizedBox(height: 14),
          // Status
          ValueListenableBuilder<bool>(
            valueListenable: sync.busy,
            builder: (context, busy, _) => Column(children: [
              if (busy) const LinearProgressIndicator(),
              ValueListenableBuilder<String>(
                valueListenable: sync.status,
                builder: (context, st, _) => st.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(padding: const EdgeInsets.only(top: 8), child: Text(st, style: t.bodySmall)),
              ),
              ValueListenableBuilder<String?>(
                valueListenable: sync.lastError,
                builder: (context, e, _) => e == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(e, style: t.bodySmall?.copyWith(color: scheme.error)),
                      ),
              ),
              const SizedBox(height: 10),
            ]),
          ),

          section('1. Sync-Passwort', icon: Icons.key, [
            if (sync.configured) ...[
              Row(children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 18),
                const SizedBox(width: 8),
                const Expanded(child: Text('Festgelegt. Auf allen Geräten muss dasselbe Passwort stehen.')),
                TextButton(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Sync-Passwort entfernen?'),
                        content: const Text('Der Abgleich wird auf diesem Gerät beendet. Deine Daten bleiben erhalten.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Entfernen')),
                        ],
                      ),
                    );
                    if (ok == true) await sync.forget();
                  },
                  child: const Text('Ändern'),
                ),
              ]),
            ] else ...[
              const Text('Wähle ein langes Passwort und gib es auf jedem Gerät gleich ein. '
                  'Es verlässt das Gerät nie und lässt sich nicht wiederherstellen.'),
              const SizedBox(height: 10),
              TextField(
                controller: _pass,
                obscureText: !_show,
                decoration: InputDecoration(
                  labelText: 'Sync-Passwort (mind. 8 Zeichen)',
                  suffixIcon: IconButton(
                    icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _show = !_show),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _pass2,
                obscureText: !_show,
                decoration: const InputDecoration(labelText: 'Passwort wiederholen'),
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: () async {
                  if (_pass.text != _pass2.text) return _snack('Die Passwörter stimmen nicht überein.');
                  try {
                    await sync.setPassphrase(_pass.text);
                    _pass.clear();
                    _pass2.clear();
                  } catch (e) {
                    _snack('$e');
                  }
                },
                child: const Text('Passwort festlegen'),
              ),
            ],
          ]),

          section('2. Was abgleichen?', icon: Icons.checklist, [
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final c in SyncCategory.values)
                FilterChip(
                  label: Text(c.label),
                  selected: cfg.categories.contains(c.prefix),
                  onSelected: (v) {
                    if (v) {
                      cfg.categories.add(c.prefix);
                    } else {
                      cfg.categories.remove(c.prefix);
                    }
                    sync.saveConfig();
                  },
                ),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name dieses Geräts', hintText: 'z. B. Mac oder Pixel'),
              onSubmitted: (v) {
                cfg.deviceName = v.trim();
                sync.saveConfig();
              },
            ),
          ]),

          section('3a. Über deinen Server', icon: Icons.cloud_sync_outlined, [
            const Text('Lade die Datei junels-sync.php (liegt beim App-Download auf GitHub) auf deinen Webspace, '
                'z. B. nach https://t24.2442.io/junels/ – und trage die Adresse hier ein. '
                'Funktioniert überall, auch unterwegs.'),
            const SizedBox(height: 10),
            TextField(
              controller: _server,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Server-Adresse',
                hintText: 'https://t24.2442.io/junels/junels-sync.php',
              ),
              onChanged: (v) => cfg.serverUrl = v.trim(),
              onSubmitted: (_) => sync.saveConfig(),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Automatisch abgleichen'),
              subtitle: const Text('Beim Start und alle 15 Minuten'),
              value: cfg.auto,
              onChanged: (v) {
                cfg.auto = v;
                sync.saveConfig();
              },
            ),
            ValueListenableBuilder<bool>(
              valueListenable: sync.busy,
              builder: (context, busy, _) => FilledButton.icon(
                icon: const Icon(Icons.sync),
                label: const Text('Jetzt mit Server abgleichen'),
                onPressed: busy || !sync.configured
                    ? null
                    : () async {
                        cfg.serverUrl = _server.text.trim();
                        await sync.saveConfig();
                        await sync.syncServer();
                      },
              ),
            ),
          ]),

          section('3b. Direkt im WLAN', icon: Icons.wifi, [
            const Text('Beide Geräte im selben WLAN, beide mit demselben Sync-Passwort. '
                'Ein Gerät stellt bereit (am besten der Mac), das andere gleicht damit ab. '
                'Es läuft nichts über das Internet.'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Dieses Gerät im WLAN bereitstellen'),
              subtitle: Text(sync.hosting
                  ? 'Bereit unter ${_ownIps.isEmpty ? '–' : _ownIps.map((ip) => '$ip:$lanSyncPort').join(', ')}'
                  : 'Aus'),
              value: cfg.lanHost && sync.hosting,
              onChanged: !sync.configured
                  ? null
                  : (v) async {
                      cfg.lanHost = v;
                      await sync.saveConfig();
                      if (v) {
                        await sync.startHost();
                      } else {
                        await sync.stopHost();
                      }
                    },
            ),
            const Divider(),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: _searching
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  label: const Text('Geräte suchen'),
                  onPressed: !sync.configured || _searching
                      ? null
                      : () async {
                          setState(() => _searching = true);
                          final p = await sync.discover();
                          if (mounted) {
                            setState(() {
                              _peers = p;
                              _searching = false;
                            });
                          }
                        },
                ),
              ),
            ]),
            if (_peers != null && _peers!.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Kein Gerät gefunden. Ist es bereitgestellt und im selben WLAN? '
                    'Sonst die Adresse unten eingeben.', style: t.bodySmall),
              ),
            for (final p in _peers ?? const <LanPeer>[])
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.devices),
                title: Text(p.name),
                subtitle: Text(p.address),
                trailing: FilledButton(
                  onPressed: sync.busy.value ? null : () => sync.syncLan('${p.address}:${p.port}'),
                  child: const Text('Abgleichen'),
                ),
              ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _lanAddr,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(labelText: 'Adresse des anderen Geräts', hintText: '192.168.1.20'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Abgleichen',
                icon: const Icon(Icons.sync),
                onPressed: !sync.configured
                    ? null
                    : () {
                        if (_lanAddr.text.trim().isEmpty) return;
                        sync.syncLan(_lanAddr.text);
                      },
              ),
            ]),
            if (_ownIps.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: InkWell(
                  onTap: () => Clipboard.setData(ClipboardData(text: _ownIps.first)),
                  child: Text('Adresse dieses Geräts: ${_ownIps.join(', ')}', style: t.bodySmall),
                ),
              ),
          ]),
          Text(
            'Hinweis: Geplante Prompts laufen auf jedem Gerät, auf dem sie aktiv sind. '
            'Soll das Morning Briefing nur auf einem Gerät laufen, stell den Zeitplan auf dem anderen auf „Nur per Klick“.',
            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
