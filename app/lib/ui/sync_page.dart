// Abgleich zwischen den eigenen Geräten: eigener Server oder WLAN.

import 'dart:async';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_scope.dart';
import '../state/sync_service.dart';
import 'quick_nav.dart';

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

  /// Verbindungsart: Server (überall) oder nur WLAN
  String? _via;

  Future<void> _setLevel(int v) async {
    final app = AppScope.read(context);
    final sync = app.sync;
    final cfg = sync.config;
    final lower = cfg.level > 1 && v < cfg.level;
    await sync.setLevel(v);
    if (lower && mounted && cfg.serverUrl.isNotEmpty) {
      final wipe = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Bereits gespeicherte Daten löschen?'),
          content: const Text('Auf dem Server liegen noch Daten der höheren Stufe (verschlüsselt). '
              'Sollen alle Daten dieses Kontos auf dem Server gelöscht werden? Was die neue Stufe erlaubt, '
              'wird beim nächsten Abgleich wieder hochgeladen. Deine Daten auf den Geräten bleiben erhalten.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Behalten')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Vom Server löschen')),
          ],
        ),
      );
      if (wipe == true) {
        try {
          await sync.wipeServer();
          _snack('Daten auf dem Server gelöscht.');
        } catch (e) {
          _snack('Löschen fehlgeschlagen: $e');
        }
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveServer() async {
    final sync = AppScope.read(context).sync;
    sync.config.serverUrl = _server.text.trim();
    await sync.saveConfig();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final sync = app.sync;
    final cfg = sync.config;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final level = cfg.level;
    final local = level == 0;
    final accountOnly = level == 1;
    final via = _via ?? (cfg.serverUrl.trim().isNotEmpty || accountOnly ? 'server' : (cfg.lanHost ? 'lan' : 'server'));
    final serverReady = cfg.serverUrl.trim().isNotEmpty;
    const ok = Icon(Icons.check_circle, color: Colors.green, size: 18);

    Widget step(int n, String title, String? done, List<Widget> children, {IconData? icon}) => Card(
          margin: const EdgeInsets.only(bottom: 14),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: done != null ? Colors.green.withValues(alpha: 0.2) : scheme.primaryContainer,
                  child: done != null ? const Icon(Icons.check, size: 16, color: Colors.green) : Text('$n', style: t.labelMedium),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: t.titleMedium)),
              ]),
              if (done != null) Padding(padding: const EdgeInsets.only(left: 36, top: 2), child: Text(done, style: t.bodySmall)),
              const SizedBox(height: 10),
              ...children,
            ]),
          ),
        );

    // ---- Status ganz oben: Wo stehe ich, was ist zu tun?
    final String headline;
    final String detail;
    final IconData statusIcon;
    if (local) {
      statusIcon = Icons.lock_outline;
      headline = 'Nur auf diesem Gerät';
      detail = 'Nichts verlässt das Gerät. Für Abgleich zwischen Mac und Handy unten eine Stufe wählen.';
    } else if (accountOnly) {
      statusIcon = sync.ssoSignedIn ? Icons.verified_user_outlined : Icons.badge_outlined;
      headline = sync.ssoSignedIn ? 'Angemeldet – es werden keine Daten gespeichert' : 'Konto ohne Daten';
      detail = sync.ssoSignedIn ? (cfg.ssoName.isNotEmpty ? cfg.ssoName : cfg.ssoEmail) : 'Noch nicht angemeldet – Schritt 2.';
    } else if (!sync.configured) {
      statusIcon = Icons.sync_disabled;
      headline = 'Abgleich noch nicht eingerichtet';
      detail = 'Noch 2 Schritte: Sync-Passwort festlegen und verbinden.';
    } else if (via == 'server' && !serverReady) {
      statusIcon = Icons.sync_disabled;
      headline = 'Fast fertig';
      detail = 'Noch die Verbindung einrichten (Schritt 3).';
    } else {
      statusIcon = Icons.cloud_done_outlined;
      headline = sync.lastSync == null ? 'Bereit zum Abgleich' : 'Abgleich aktiv';
      detail = [
        if (sync.lastSync != null) 'Zuletzt ${TimeOfDay.fromDateTime(sync.lastSync!).format(context)}',
        if (sync.ssoSignedIn) cfg.ssoName.isNotEmpty ? cfg.ssoName : cfg.ssoEmail,
        if (via == 'server' && cfg.auto) 'automatisch alle 15 Min.',
      ].join(' · ');
    }

    return Scaffold(
      appBar: JAppBar(title: const Text('Konto, Datenschutz & Abgleich')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: scheme.secondaryContainer.withValues(alpha: 0.5),
            margin: const EdgeInsets.only(bottom: 14),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: ValueListenableBuilder<bool>(
                valueListenable: sync.busy,
                builder: (context, busy, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(statusIcon),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(headline, style: t.titleSmall),
                        if (detail.isNotEmpty) Text(detail, style: t.bodySmall),
                      ]),
                    ),
                    if (!local && !accountOnly && sync.configured && via == 'server' && serverReady)
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.sync, size: 18),
                        label: const Text('Jetzt'),
                        onPressed: busy
                            ? null
                            : () async {
                                await _saveServer();
                                await sync.syncServer();
                              },
                      ),
                  ]),
                  if (busy) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
                  ValueListenableBuilder<String>(
                    valueListenable: sync.status,
                    // Laufende Meldungen („…“) nur während etwas passiert – sonst nur Ergebnisse
                    builder: (context, st, _) => st.isEmpty || (!busy && st.endsWith('…'))
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
                ]),
              ),
            ),
          ),

          // ---- 1. Was darf das Konto speichern?
          step(1, 'Was soll zwischen deinen Geräten mit?', null, [
            Text('Alles wird vorher auf dem Gerät verschlüsselt – Server und Netzwerk sehen nur unlesbare Daten. Modelle werden nie übertragen.',
                style: t.bodySmall),
            const SizedBox(height: 4),
            for (final l in PrivacyLevel.all)
              RadioListTile<int>(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: l.level,
                groupValue: level < 0 ? null : level,
                title: Text('${l.icon}  ${l.title}'),
                subtitle: Text(l.text, style: t.bodySmall),
                onChanged: (v) => v == null ? null : _setLevel(v),
              ),
            if (level >= 2 || level < 0)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(level < 0 ? 'Eigene Auswahl' : 'Einzeln anpassen', style: t.bodyMedium),
                initiallyExpanded: level < 0,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(spacing: 8, runSpacing: 4, children: [
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
                            setState(() {});
                          },
                        ),
                    ]),
                  ),
                ],
              ),
          ]),

          if (!local && !accountOnly)
            // ---- 2. Verschlüsselung
            step(2, 'Sync-Passwort', sync.configured ? 'Festgelegt – auf allen Geräten muss dasselbe stehen.' : null, [
              if (sync.configured)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Sync-Passwort ändern?'),
                          content: const Text('Der Abgleich wird auf diesem Gerät beendet, bis du ein neues Passwort festlegst. Deine Daten bleiben erhalten.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
                            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ändern')),
                          ],
                        ),
                      );
                      if (ok == true) await sync.forget();
                    },
                    child: const Text('Passwort ändern'),
                  ),
                )
              else ...[
                Text('Ein langes Passwort, auf jedem Gerät gleich. Es verlässt das Gerät nie und lässt sich nicht wiederherstellen.',
                    style: t.bodySmall),
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
                TextField(controller: _pass2, obscureText: !_show, decoration: const InputDecoration(labelText: 'Passwort wiederholen')),
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

          if (!local)
            // ---- 3. Verbindung (bei „Konto ohne Daten“: nur Anmeldung)
            step(accountOnly ? 2 : 3, accountOnly ? 'Anmelden' : 'Verbinden',
                accountOnly ? (sync.ssoSignedIn ? 'Angemeldet' : null) : (via == 'server' ? (serverReady ? 'Über ${Uri.tryParse(cfg.serverUrl)?.host ?? cfg.serverUrl}' : null) : (sync.hosting ? 'WLAN bereitgestellt' : null)),
                [
              if (!accountOnly) ...[
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'server', icon: Icon(Icons.cloud_outlined, size: 18), label: Text('Über Server')),
                    ButtonSegment(value: 'lan', icon: Icon(Icons.wifi, size: 18), label: Text('Nur im WLAN')),
                  ],
                  selected: {via},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) => setState(() => _via = v.first),
                ),
                const SizedBox(height: 6),
                Text(via == 'server' ? 'Funktioniert überall, auch unterwegs.' : 'Mac und Handy im selben WLAN – nichts läuft über das Internet.',
                    style: t.bodySmall),
                const SizedBox(height: 12),
              ],
              if (via == 'server' || accountOnly) ...[
                TextField(
                  controller: _server,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Server-Adresse', hintText: 'z. B. https://agent.2442.io'),
                  onChanged: (v) => cfg.serverUrl = v.trim(),
                  onSubmitted: (_) async {
                    await _saveServer();
                    setState(() {});
                  },
                  onEditingComplete: _saveServer,
                ),
                const SizedBox(height: 12),
                // Konto (SSO): optional bei Daten, Pflicht bei „Konto ohne Daten“
                if (sync.ssoSignedIn)
                  Row(children: [
                    ok,
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text('Angemeldet als ${cfg.ssoName.isNotEmpty ? cfg.ssoName : cfg.ssoEmail}', style: t.bodyMedium)),
                    TextButton(
                      onPressed: () async {
                        await sync.ssoLogout();
                        setState(() {});
                      },
                      child: const Text('Abmelden'),
                    ),
                  ])
                else
                  Row(children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.key_outlined),
                      label: const Text('Mit SSO anmelden'),
                      onPressed: _server.text.trim().isEmpty
                          ? null
                          : () async {
                              await _saveServer();
                              final has = await sync.serverHasSso();
                              if (has == false) {
                                _snack('Dieser Server hat kein SSO – Abgleich geht trotzdem, nur ohne Konto.');
                                return;
                              }
                              try {
                                await sync.ssoLogin();
                                if (mounted) setState(() {});
                              } catch (e) {
                                _snack('$e');
                              }
                            },
                    ),
                    const SizedBox(width: 10),
                    if (!accountOnly) Expanded(child: Text('optional – eigener Bereich je Person', style: t.bodySmall)),
                  ]),
                if (!accountOnly)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Automatisch abgleichen'),
                    subtitle: const Text('Beim Start und alle 15 Minuten'),
                    value: cfg.auto,
                    onChanged: (v) {
                      cfg.auto = v;
                      sync.saveConfig();
                      setState(() {});
                    },
                  ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('Eigenen Server einrichten', style: t.bodyMedium),
                  children: [
                    Text(
                      'Mit Konto (SSO), empfohlen:\n'
                      '1. Paket „Junels Agent-API“ (Weiche) auf den Webspace laden, eine Domain darauf zeigen lassen (z. B. agent.2442.io).\n'
                      '2. /control öffnen, einrichten, junels-api_v2.zip hochladen und zuweisen.\n'
                      '3. https://<domain>/login öffnen und „Mit SSO verbinden“.\n'
                      '4. Hier die Adresse eintragen und „Mit SSO anmelden“.\n\n'
                      'Ohne Konto: junels-sync.php (beim App-Download auf GitHub) auf den Webspace laden und deren Adresse eintragen.',
                      style: t.bodySmall,
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ] else ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Dieses Gerät bereitstellen'),
                  subtitle: Text(sync.hosting
                      ? 'Bereit unter ${_ownIps.isEmpty ? '–' : _ownIps.map((ip) => '$ip:$lanSyncPort').join(', ')}'
                      : 'Am besten am Mac einschalten – das Handy gleicht dann damit ab'),
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
                OutlinedButton.icon(
                  icon: _searching
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  label: const Text('Anderes Gerät suchen und abgleichen'),
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
                if (!sync.configured)
                  Padding(padding: const EdgeInsets.only(top: 6), child: Text('Zuerst das Sync-Passwort festlegen (Schritt 2).', style: t.bodySmall)),
                if (_peers != null && _peers!.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Kein Gerät gefunden. Ist es bereitgestellt und im selben WLAN?', style: t.bodySmall),
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
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('Gerät nicht gefunden? Adresse eingeben', style: t.bodyMedium),
                  children: [
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _lanAddr,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(labelText: 'Adresse des anderen Geräts', hintText: '192.168.1.20'),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: 'Abgleichen',
                        icon: const Icon(Icons.sync),
                        onPressed: !sync.configured || _lanAddr.text.trim().isEmpty ? null : () => sync.syncLan(_lanAddr.text),
                      ),
                    ]),
                    if (_ownIps.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 8),
                        child: InkWell(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: _ownIps.first));
                            _snack('Adresse kopiert');
                          },
                          child: Text('Adresse dieses Geräts: ${_ownIps.join(', ')} (antippen zum Kopieren)', style: t.bodySmall),
                        ),
                      ),
                  ],
                ),
              ],
              if (!accountOnly) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name dieses Geräts', hintText: 'z. B. Mac oder Pixel', isDense: true),
                  onSubmitted: (v) {
                    cfg.deviceName = v.trim();
                    sync.saveConfig();
                  },
                ),
              ],
            ]),
        ],
      ),
    );
  }
}
