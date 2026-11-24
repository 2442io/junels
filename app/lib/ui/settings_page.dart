// Einstellungen: alles, was man selten braucht, an einem Ort –
// links die Bereiche, rechts der Inhalt (auf dem Handy als Liste mit Unterseiten).

import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_controller.dart';
import '../state/app_scope.dart';
import '../version.dart';
import 'device_page.dart';
import 'info_pages.dart';
import 'connections_page.dart';
import 'mcp_page.dart';
import 'mcp_serve_page.dart';
import 'model_import.dart';
import 'profile_editor.dart';
import 'providers_page.dart';
import 'sync_page.dart';
import 'system_check.dart';
import 'tasks_page.dart';
import 'backup_page.dart';
import 'apps_page.dart';
import 'designs_page.dart';
import 'setups_page.dart';
import '../state/sync_service.dart' show PrivacyLevel;
import 'notify_settings_page.dart';
import 'self_test_page.dart';
import 'theme.dart';
import 'update_page.dart';
import 'quick_nav.dart';

/// Ein Eintrag der Einstellungen: entweder ein Bereich (eigener Inhalt) oder eine eigene Seite.
class SettingsEntry {
  const SettingsEntry(this.id, this.group, this.icon, this.title, this.subtitle, {this.keywords = const [], this.open});
  final String id;
  final String group;
  final IconData icon;
  final String title;
  final String subtitle;

  /// Begriffe, die in diesem Bereich vorkommen (für die Suche)
  final List<String> keywords;

  /// Eigene Seite statt Bereich
  final void Function(BuildContext context)? open;

  bool get isSection => open == null;
}

/// Alle Einstellungen, geordnet nach dem, was man erledigen will.
List<SettingsEntry> settingsEntries(AppController app) => [
      SettingsEntry('models', 'KI', Icons.memory, 'Modell auf dem Gerät',
          app.engine == null ? 'Kein Modell geladen · Systemcheck, Modelle laden' : 'Systemcheck, Modell laden, automatische Modellwahl',
          keywords: ['Systemcheck', 'Context', 'GGUF', 'schnelles Modell', 'starkes Modell', 'Download', 'lokal']),
      SettingsEntry('providers', 'KI', Icons.cloud_outlined, 'Cloud & eigene Server',
          app.providers.isEmpty ? 'OpenAI, Claude, Gemini, Ollama … verbinden' : '${app.providers.length} Anbieter · wann die Cloud helfen darf',
          keywords: ['KI-Anbieter', 'OpenAI', 'Anthropic', 'Claude', 'Gemini', 'Ollama', 'On-Prem', 'Hybrid', 'API-Schlüssel', 'Routing']),
      SettingsEntry('agent', 'KI', Icons.smart_toy_outlined, 'Agent & Werkzeuge', 'Profil, Persönlichkeit, welche Werkzeuge der Agent nutzt',
          keywords: ['Profil', 'Systemprompt', 'Werkzeuge', 'Tools', 'Websuche', 'Wetter']),
      SettingsEntry('voice', 'KI', Icons.graphic_eq, 'Sprache & Stimme', 'Spracheingabe, Stimme, Vorlesen',
          keywords: ['Whisper', 'Mikrofon', 'Vorlesen', 'Stimme', 'Wake-Word', 'Gesprächsmodus']),
      SettingsEntry('ext', 'Verbindungen', Icons.extension_outlined, 'Erweiterungen',
          'MCP-Server, Junels für andere Programme, Web-Zugänge, Apps steuern',
          keywords: ['MCP', 'MCP-Store', 'MCP-Server', 'Claude Desktop', 'n8n', 'Dify', 'Zugänge', 'OAuth', 'API', 'Spotify', 'Apps']),
      SettingsEntry('device', 'Verbindungen', Icons.event_outlined, 'Kalender, Gerät & Ordner',
          app.settings.homeCity.isEmpty ? 'Kalender-Abo, Heimatort, Schnellstart, beobachtete Ordner' : 'Heimatort ${app.settings.homeCity} · Kalender-Abo · Ordner',
          keywords: ['Kalender', 'iCal', 'Google Kalender', 'Kalender prüfen', 'Heimatort', 'Morgen-Übersicht', 'Ordner', 'Teilen', 'Schnellstart', 'Widget'],
          open: openDevicePage),
      SettingsEntry('vault', 'Verbindungen', Icons.lock_outline, 'Tresor & Mail-Konto',
          app.settings.smtpReady ? 'Mail-Konto ${app.settings.smtpUser}' : 'Passwörter und Schlüssel sicher ablegen, Mail direkt senden',
          keywords: ['Passwort', 'Schlüssel', 'SMTP', 'E-Mail', 'IMAP'], open: openVault),
      SettingsEntry('notify', 'Alltag', Icons.notifications_outlined, 'Benachrichtigungen', 'Arten an/aus, Ruhezeit, Infos gesammelt',
          keywords: ['Push', 'Ruhezeit', 'Erinnerung', 'Warnung', 'Ton'], open: openNotifySettings),
      SettingsEntry('app', 'Alltag', Icons.palette_outlined, 'Darstellung & Designs', 'Hell/Dunkel, eigene Designs für Präsentationen und PDFs',
          keywords: ['Dunkel', 'Hell', 'Theme', 'Design', 'CI', 'Präsentation', 'Schrift', 'Farben']),
      SettingsEntry('sync', 'Daten & Konto', Icons.shield_outlined, 'Konto, Datenschutz & Abgleich',
          app.sync.config.level >= 0
              ? 'Stufe ${app.sync.config.level}: ${PrivacyLevel.all[app.sync.config.level].title}'
                  '${app.sync.ssoSignedIn ? ' · ${app.sync.config.ssoName.isNotEmpty ? app.sync.config.ssoName : app.sync.config.ssoEmail}' : ''}'
              : 'Datenschutz-Stufe, SSO-Konto, Abgleich Mac ↔ Handy',
          keywords: ['SSO', 'Anmelden', 'Datenschutz', 'Sync', 'Abgleich', 'Server', 'WLAN', 'Konto'], open: openSync),
      SettingsEntry('data', 'Daten & Konto', Icons.archive_outlined, 'Sicherung & Geräte-Setups', 'Alles sichern oder wiederherstellen, Einstellungen je Gerät',
          keywords: ['Backup', 'Export', 'Import', 'Wiederherstellen', 'Setup', 'Desktop', 'Handy']),
      SettingsEntry('updates', 'Hilfe & Wartung', Icons.system_update_outlined, 'Updates & Neuigkeiten',
          app.updates.available.value != null ? 'Neue Version ${app.updates.available.value!.version} verfügbar' : 'Installiert: $appVersion · Was ist neu?',
          keywords: ['Version', 'Changelog', 'Aktualisieren'], open: openUpdates),
      SettingsEntry('selftest', 'Hilfe & Wartung', Icons.health_and_safety_outlined, 'Selbsttest', 'Junels prüft sich selbst – Bericht zum Teilen',
          keywords: ['Fehler', 'Test', 'Diagnose', 'funktioniert nicht'], open: openSelfTest),
      SettingsEntry('log', 'Hilfe & Wartung', Icons.receipt_long_outlined, 'Protokoll', 'Technische Fehler und Zeiten',
          keywords: ['Log', 'Fehler', 'Debug'], open: openLog),
    ];

Future<void> openSettings(BuildContext context, {String? section}) => Navigator.of(context)
    .push(MaterialPageRoute(builder: (_) => SettingsPage(initial: section)));

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.initial});
  final String? initial;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late String _section = widget.initial ?? 'models';
  final _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Treffer der Suche: Eintrag + passender Begriff
  List<(SettingsEntry, String?)> _filtered(List<SettingsEntry> all) {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return [for (final e in all) (e, null)];
    return [
      for (final e in all)
        if (e.title.toLowerCase().contains(q) || e.subtitle.toLowerCase().contains(q))
          (e, null)
        else if (e.keywords.where((k) => k.toLowerCase().contains(q)).firstOrNull case final k?)
          (e, k)
    ];
  }

  void _activate(BuildContext context, SettingsEntry e, {required bool wide}) {
    if (e.open != null) {
      e.open!(context);
    } else if (wide) {
      setState(() => _section = e.id);
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => _SectionPage(id: e.id)));
    }
  }

  Widget _searchField(AppColors c) => TextField(
        controller: _search,
        onChanged: (v) => setState(() => _q = v),
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: Icon(Icons.search, size: 18, color: c.faint),
          hintText: 'Einstellung suchen – z. B. Kalender, Stimme, MCP',
          suffixIcon: _q.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => setState(() {
                    _search.clear();
                    _q = '';
                  })),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final app = AppScope.of(context);
    final all = settingsEntries(app);
    final hits = _filtered(all);
    final groups = <String>[for (final e in all) e.group].toSet().toList();
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 760;
      if (!wide) {
        if (widget.initial != null && all.any((e) => e.id == widget.initial && e.isSection)) return _SectionPage(id: widget.initial!);
        return Scaffold(
          appBar: JAppBar(title: const Text('Einstellungen')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
            children: [
              _searchField(c),
              if (hits.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Nichts gefunden. Tipp: in der Hilfe suchen.', style: Theme.of(context).textTheme.bodySmall),
                ),
              for (final g in groups)
                if (hits.any((h) => h.$1.group == g)) ...[
                  SectionLabel(g, padding: const EdgeInsets.fromLTRB(4, 18, 4, 8)),
                  Panel(
                    padding: EdgeInsets.zero,
                    child: Column(children: [
                      for (final (e, kw) in hits.where((h) => h.$1.group == g))
                        ListTile(
                          leading: _SectionIcon(e.icon),
                          title: Text(e.title),
                          subtitle: Text(kw == null ? e.subtitle : 'enthält „$kw“', maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _activate(context, e, wide: false),
                        ),
                    ]),
                  ),
                ],
              const SizedBox(height: 16),
              Center(child: MonoText('Junels $appVersion · Build $appBuild')),
            ],
          ),
        );
      }
      final current = all.firstWhere((e) => e.id == _section && e.isSection, orElse: () => all.first);
      return Scaffold(
        appBar: JAppBar(title: const Text('Einstellungen')),
        body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            width: 280,
            decoration: BoxDecoration(color: c.panel, border: Border(right: BorderSide(color: c.border))),
            child: ListView(padding: const EdgeInsets.all(10), children: [
              _searchField(c),
              for (final g in groups)
                if (hits.any((h) => h.$1.group == g)) ...[
                  SectionLabel(g, padding: const EdgeInsets.fromLTRB(8, 14, 8, 4)),
                  for (final (e, kw) in hits.where((h) => h.$1.group == g))
                    ListTile(
                      dense: true,
                      selected: e.id == current.id,
                      leading: Icon(e.icon, size: 20, color: e.id == current.id ? c.mint : null),
                      title: Text(e.title, style: const TextStyle(fontWeight: FontWeight.w500)),
                      subtitle: kw == null ? null : Text('enthält „$kw“', style: TextStyle(fontSize: 11, color: c.faint)),
                      trailing: e.open == null ? null : Icon(Icons.open_in_new, size: 14, color: c.faint),
                      onTap: () => _activate(context, e, wide: true),
                    ),
                ],
              const SizedBox(height: 16),
              Center(child: MonoText('Junels $appVersion · Build $appBuild', size: 10.5)),
            ]),
          ),
          Expanded(
            child: ListView(
              key: ValueKey(current.id),
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 48),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      PageHeader(title: current.title, subtitle: current.subtitle, icon: current.icon),
                      SettingsBody(id: current.id),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ]),
      );
    });
  }
}

class _SectionIcon extends StatelessWidget {
  const _SectionIcon(this.icon);
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(color: c.mintSoft, borderRadius: BorderRadius.circular(10)),
      child: Icon(icon, color: c.mint, size: 20),
    );
  }
}

class _SectionPage extends StatelessWidget {
  const _SectionPage({required this.id});
  final String id;
  @override
  Widget build(BuildContext context) {
    final s = settingsEntries(AppScope.read(context)).firstWhere((x) => x.id == id);
    return Scaffold(
      appBar: JAppBar(title: Text(s.title)),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [SettingsBody(id: id)]),
    );
  }
}

/// Inhalt eines Einstellungsbereichs.
class SettingsBody extends StatelessWidget {
  const SettingsBody({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    Widget group(String? title, List<Widget> children) => Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (title != null) SectionLabel(title, padding: const EdgeInsets.fromLTRB(4, 0, 4, 8)),
            Panel(padding: const EdgeInsets.fromLTRB(12, 8, 12, 8), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)),
          ]),
        );
    switch (id) {
      case 'models':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          group(null, [_ModelSection(app: app)]),
          group('Automatische Modellwahl', [_AutoModelSection(app: app)]),
          group('Beim Start', [
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              title: const Text('Letztes Modell beim Start laden'),
              subtitle: const Text('Antworten sind sofort bereit, braucht aber Arbeitsspeicher'),
              value: app.settings.autoLoadLastModel,
              onChanged: app.setAutoLoad,
            ),
          ]),
        ]);
      case 'providers':
        return const ProvidersSettings();
      case 'agent':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          group('Profil', [_ProfileSection(app: app)]),
          group('Werkzeuge', [_ToolSection(app: app)]),
        ]);
      case 'voice':
        return group(null, [_VoiceSection(app: app)]);
      case 'ext':
        return group(null, [
          _NavTile(
            icon: Icons.hub_outlined,
            title: 'MCP-Store & Server',
            subtitle: app.mcpServers.isEmpty
                ? 'Weitere Werkzeuge anbinden (Slack, Gmail, Notion, GitHub …)'
                : '${app.mcpServers.where((s) => s.enabled).length} aktiv · ${app.mcpTools.length} Werkzeuge',
            onTap: () => openMcp(context),
          ),
          _NavTile(
            icon: Icons.cable_outlined,
            title: 'Junels für andere Programme',
            subtitle: app.mcpServe.running
                ? 'An · ${app.mcpServe.url}'
                : 'Aus · Claude Desktop, n8n, Dify … deine Skills und Prozesse nutzen lassen',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const McpServePage())),
          ),
          _NavTile(
            icon: Icons.key_outlined,
            title: 'Web-Zugänge',
            subtitle: app.connections.items.isEmpty
                ? 'Anmeldungen für Web-APIs und Plattformen (API-Schlüssel, Google, SSO)'
                : '${app.connections.items.length} Zugänge',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConnectionsPage())),
          ),
          _NavTile(
            icon: Icons.apps,
            title: 'Apps steuern',
            subtitle: app.allowedApps.isEmpty
                ? 'Welche Apps (z. B. Spotify) der Agent öffnen und steuern darf'
                : '${app.allowedApps.map((a) => a.name).join(', ')} freigegeben',
            onTap: () => openAppsPage(context),
          ),
        ]);
      case 'app':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          group('Darstellung', [_SettingsSection(app: app)]),
          group('Designs', [
            _NavTile(
              icon: Icons.palette_outlined,
              title: 'Eigene Designs',
              subtitle: DesignLibrary.user.isEmpty
                  ? 'Firmen-CI oder Lieblingsstil für Präsentationen und PDFs speichern'
                  : '${DesignLibrary.user.length} gespeichert${DesignLibrary.standard != null ? ' · Standard: ${DesignLibrary.standard!.name}' : ''}',
              onTap: () => openDesigns(context),
            ),
          ]),
        ]);
      case 'data':
        return group(null, [
          _NavTile(
            icon: Icons.archive_outlined,
            title: 'Sicherung',
            subtitle: 'Alle Chats, Prozesse und Einstellungen exportieren oder wiederherstellen',
            onTap: () => openBackup(context),
          ),
          _NavTile(
            icon: Icons.devices_outlined,
            title: 'Geräte-Setups',
            subtitle: 'Einstellungen als „Desktop“, „Handy“ … speichern und anwenden',
            onTap: () => openSetups(context),
          ),
        ]);
    }
    return const SizedBox();
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    // Der Bereich hat schon eine Überschrift – Haupttitel nicht wiederholen.
    if (const {'Modell', 'Sprache', 'Einstellungen', 'Lokale Tools', 'Agent-Profil'}.contains(text)) {
      return trailing == null ? const SizedBox(height: 4) : Align(alignment: Alignment.centerRight, child: trailing);
    }
    return SectionLabel(text, trailing: trailing, padding: const EdgeInsets.fromLTRB(4, 4, 0, 8));
  }
}

class _ModelSection extends StatelessWidget {
  const _ModelSection({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final busy = app.status == EngineStatus.loading || app.running || app.importProgress != null;
    final loadedCtx = app.engine?.contextSize;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Modell'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (app.status == EngineStatus.loading) const LinearProgressIndicator(),
                if (app.statusMessage != null) ...[
                  if (app.status == EngineStatus.loading) const SizedBox(height: 8),
                  Text(app.statusMessage!,
                      style: t.bodySmall?.copyWith(
                          color: app.status == EngineStatus.error ? scheme.error : scheme.onSurfaceVariant)),
                  const SizedBox(height: 10),
                ],
                FilledButton.icon(
                  onPressed: () => openSystemCheck(context),
                  icon: const Icon(Icons.speed_outlined),
                  label: const Text('Systemcheck & Modelle'),
                ),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => pickAndImportModel(context),
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('Eigene Datei laden'),
                ),
                if (Platform.isIOS) const SizedBox(height: 6),
                if (Platform.isIOS)
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () async {
                            final messenger = ScaffoldMessenger.of(context);
                            final r = await app.scanDocumentsFolder();
                            messenger.showSnackBar(SnackBar(
                              content: Text(r.added > 0
                                  ? '${r.added} Modell(e) aus dem App-Ordner übernommen.'
                                  : r.errors.isNotEmpty
                                      ? r.errors.first
                                      : 'Keine neuen .gguf-Dateien im App-Ordner gefunden.'),
                            ));
                          },
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text('Aus App-Ordner übernehmen'),
                  ),
                const SizedBox(height: 4),
                Text(
                    Platform.isIOS
                        ? '.gguf-Datei per Finder (USB) in den Ordner „Offline Agent“ legen und übernehmen – ohne Kopie. '
                            'Oder über „Modell laden“ aus der Dateien-App wählen.'
                        : '.gguf-Datei per USB, AirDrop oder Dateimanager aufs Gerät kopieren, dann hier wählen.',
                    style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
        if (app.models.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final m in app.models)
            _ModelTile(
              model: m,
              tooBig: app.loadedModel?.id != m.id && !app.modelFitsMemory(m),
              loaded: app.loadedModel?.id == m.id,
              busy: busy,
              onLoad: () => app.loadModel(m),
              onUnload: app.unloadModel,
              onDelete: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Modell entfernen?'),
                    content: Text('${m.displayName} (${m.sizeLabel}) wird vom Gerät gelöscht.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Löschen')),
                    ],
                  ),
                );
                if (ok == true) await app.deleteModel(m);
              },
            ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Text('Context', style: t.bodyMedium),
            const Spacer(),
            DropdownButton<int>(
              value: app.settings.contextAuto
                  ? 0
                  : app.contextOptions.contains(app.settings.contextSize)
                      ? app.settings.contextSize
                      : app.contextOptions.last,
              underline: const SizedBox(),
              borderRadius: BorderRadius.circular(12),
              items: [
                DropdownMenuItem(value: 0, child: Text('Auto (${app.device.maxContext ~/ 1024}K)')),
                for (final c in app.contextOptions)
                  DropdownMenuItem(value: c, child: Text('${c ~/ 1024}K Tokens')),
              ],
              onChanged: busy ? null : (v) => v == null ? null : app.setContextSize(v),
            ),
          ],
        ),
        if (loadedCtx != null && loadedCtx < app.contextTarget && (app.loadedModel?.trainedContext ?? 1 << 30) > loadedCtx)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: busy ? null : () => app.loadModel(app.loadedModel!),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text('Neu laden (aktuell ${loadedCtx ~/ 1024}K)'),
            ),
          ),
        Text(
          'Gerät: Klasse ${app.device.deviceClass.label}, '
          '${(app.device.totalMemory / (1 << 30)).toStringAsFixed(1)} GB RAM, '
          '${app.device.threads} Threads, ${app.device.gpuLayers != 0 ? 'Metal-GPU' : 'CPU'}',
          style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.model,
    this.tooBig = false,
    required this.loaded,
    required this.busy,
    required this.onLoad,
    required this.onUnload,
    required this.onDelete,
  });
  final StoredModel model;
  final bool tooBig;
  final bool loaded;
  final bool busy;
  final VoidCallback onLoad;
  final VoidCallback onUnload;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      selected: loaded,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.5),
      leading: Icon(loaded ? Icons.memory : Icons.memory_outlined, color: loaded ? scheme.primary : null),
      iconColor: tooBig ? scheme.outline : null,
      title: Text(model.displayName,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tooBig ? scheme.outline : null)),
      subtitle: Text(
          tooBig
              ? '${model.sizeLabel} · zu groß für den Arbeitsspeicher'
              : '${model.quantization} · ${model.sizeLabel}',
          style: TextStyle(color: tooBig ? scheme.outline : null)),
      onTap: busy || loaded || tooBig ? null : onLoad,
      trailing: PopupMenuButton<String>(
        enabled: !busy,
        onSelected: (v) => switch (v) {
          'load' => onLoad(),
          'unload' => onUnload(),
          'delete' => onDelete(),
          _ => null,
        },
        itemBuilder: (_) => [
          if (!loaded && !tooBig) const PopupMenuItem(value: 'load', child: Text('Laden')),
          if (loaded) const PopupMenuItem(value: 'unload', child: Text('Entladen')),
          const PopupMenuItem(value: 'delete', child: Text('Vom Gerät löschen')),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ Profile

class _ProfileSection extends StatelessWidget {
  const _ProfileSection({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final p = app.activeProfile;
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle('Agent-Profil',
            trailing: TextButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Neues Profil'),
              onPressed: app.running
                  ? null
                  : () => editProfile(context,
                      AgentProfile(id: newId(), name: 'Eigenes Profil', systemPrompt: p.systemPrompt)),
            )),
        DropdownButtonFormField<String>(
          key: ValueKey(p.id),
          initialValue: p.id,
          isExpanded: true,
          decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
          items: [
            for (final x in app.profiles) DropdownMenuItem(value: x.id, child: Text(x.name)),
          ],
          onChanged: app.running ? null : (v) => v == null ? null : app.selectProfile(v),
        ),
        const SizedBox(height: 6),
        Text(p.systemPrompt, maxLines: 3, overflow: TextOverflow.ellipsis, style: t.bodySmall),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: app.running ? null : () => editProfile(context, p),
            icon: const Icon(Icons.tune, size: 18),
            label: Text(
                '${p.useTools ? 'Agent, max. ${p.maxSteps} Schritte' : 'Nur Chat'} · Temp. ${p.temperature.toStringAsFixed(1)}'),
          ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------------- Tools

class _ToolSection extends StatelessWidget {
  const _ToolSection({required this.app});
  final AppController app;

  static const _icons = {
    'text_search': Icons.search,
    'read_file': Icons.description_outlined,
    'json_query': Icons.data_object,
    'calculator': Icons.calculate_outlined,
    'write_artifact': Icons.note_add_outlined,
    'datetime': Icons.schedule,
    'web_search': Icons.travel_explore,
    'web_fetch': Icons.public,
    'remember': Icons.bookmark_add_outlined,
    'create_document': Icons.picture_as_pdf_outlined,
    'create_presentation': Icons.slideshow_outlined,
    'edit_file': Icons.edit_document,
    'find_loose_ends': Icons.pending_actions_outlined,
    'mail_inbox': Icons.inbox_outlined,
    'control_app': Icons.apps,
    'begleiten': Icons.explore_outlined,
    'skill_erstellen': Icons.auto_awesome,
    'create_chart': Icons.bar_chart,
    'generate_image': Icons.brush_outlined,
    'look_at_image': Icons.visibility_outlined,
    'send_notification': Icons.notifications_active_outlined,
    'site_search': Icons.manage_search,
    'browser': Icons.travel_explore,
    'weather': Icons.wb_sunny_outlined,
    'news': Icons.newspaper,
    'compose_email': Icons.mail_outline,
    'compose_whatsapp': Icons.chat_outlined,
    'call_phone': Icons.call_outlined,
    'calendar_add': Icons.event_available_outlined,
    'calendar_list': Icons.event_note_outlined,
    'contacts_search': Icons.contacts_outlined,
    'file_search': Icons.find_in_page_outlined,
    'file_rename': Icons.drive_file_rename_outline,
    'file_move': Icons.drive_file_move_outline,
    'save_prompt': Icons.bookmark_add_outlined,
    'search_history': Icons.history,
    'knowledge_search': Icons.local_library_outlined,
  };

  static const _groups = [
    ('Internet', ['web_search', 'web_fetch', 'news', 'weather', 'site_search', 'browser', 'begleiten', 'mail_inbox']),
    ('Erstellen', ['create_document', 'create_presentation', 'create_chart', 'write_artifact', 'edit_file', 'generate_image', 'skill_erstellen', 'save_prompt']),
    ('Wissen & Dateien', ['text_search', 'read_file', 'knowledge_search', 'search_history', 'remember', 'look_at_image', 'json_query', 'file_search', 'file_rename', 'file_move']),
    ('Gerät & Apps', ['calendar_list', 'calendar_add', 'contacts_search', 'compose_email', 'compose_whatsapp', 'call_phone', 'control_app', 'send_notification']),
    ('Rechnen & Ordnen', ['calculator', 'datetime', 'find_loose_ends']),
  ];

  static String _groupOf(String name) {
    for (final (g, names) in _groups) {
      if (names.contains(name)) return g;
    }
    return 'Weitere';
  }

  @override
  Widget build(BuildContext context) {
    final enabled = app.activeProfile.useTools;
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Text('Im Profil „${app.activeProfile.name}“ sind Werkzeuge ausgeschaltet.', style: t.bodySmall),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
          child: Text(
              '${app.tools.where((x) => app.settings.enabledTools.contains(x.name)).length} von ${app.tools.length} Werkzeugen an. '
              'Werkzeuge mit 🌐 gehen ins Internet und fragen vorher.',
              style: t.bodySmall),
        ),
        for (final (group, _) in [..._groups, ('Weitere', const <String>[])])
          if (app.tools.any((x) => _groupOf(x.name) == group))
            ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 4),
              title: Text(group),
              subtitle: Text(
                () {
                  final ts = [for (final x in app.tools) if (_groupOf(x.name) == group) x];
                  final on = ts.where((x) => app.settings.enabledTools.contains(x.name)).length;
                  return '$on von ${ts.length} an · ${ts.map((x) => x.title).take(3).join(', ')}${ts.length > 3 ? ' …' : ''}';
                }(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.bodySmall,
              ),
              children: [
                for (final tool in app.tools)
                  if (_groupOf(tool.name) == group)
                    SwitchListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.only(left: 8, right: 0),
                      secondary: Icon(_icons[tool.name] ?? Icons.extension_outlined, size: 20),
                      title: Text(tool.requiresNetwork ? '${tool.title} 🌐' : tool.title),
                      subtitle: Text(tool.description.split(RegExp(r'(?<=[.!?])\s')).first, maxLines: 1, overflow: TextOverflow.ellipsis),
                      value: app.settings.enabledTools.contains(tool.name),
                      onChanged: !enabled || app.running ? null : (v) => app.setToolEnabled(tool.name, v),
                    ),
              ],
            ),
      ],
    );
  }
}

// ------------------------------------------------------------------ Sprache

class _VoiceSection extends StatelessWidget {
  const _VoiceSection({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final stt = modelCatalog.where((e) => e.kind == ModelKind.stt && app.installedPath(e) != null).toList();
    final tts = modelCatalog.where((e) => e.kind == ModelKind.tts && app.installedPath(e) != null).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Sprache'),
        if (stt.isEmpty && tts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('Noch kein Whisper-Modell und keine Stimme installiert – im Systemcheck herunterladen.',
                style: t.bodySmall),
          ),
        if (stt.isNotEmpty) ...[
          _row(context, 'Erkennung', DropdownButton<String>(
            value: stt.any((e) => e.id == app.settings.sttModelId) ? app.settings.sttModelId : null,
            hint: const Text('wählen'),
            isDense: true,
            underline: const SizedBox(),
            items: [for (final e in stt) DropdownMenuItem(value: e.id, child: Text(e.name.replaceFirst('Whisper ', '')))],
            onChanged: (v) => app.setVoiceSettings(sttModelId: v),
          )),
          _row(context, 'Sprache', DropdownButton<String>(
            value: app.settings.sttLanguage,
            isDense: true,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: 'auto', child: Text('Automatisch')),
              DropdownMenuItem(value: 'de', child: Text('Deutsch')),
              DropdownMenuItem(value: 'en', child: Text('Englisch')),
            ],
            onChanged: (v) => app.setVoiceSettings(sttLanguage: v),
          )),
          SwitchListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 4),
            title: const Text('Nach Spracheingabe sofort senden'),
            value: app.settings.sendAfterVoice,
            onChanged: (v) => app.setVoiceSettings(sendAfterVoice: v),
          ),
        ],
        ...[
          _row(context, 'Stimme', DropdownButton<String>(
            value: app.settings.ttsVoiceId == '__system__' || tts.any((e) => e.id == app.settings.ttsVoiceId) ? app.settings.ttsVoiceId : null,
            hint: const Text('wählen'),
            isDense: true,
            underline: const SizedBox(),
            items: [
              const DropdownMenuItem(value: '__system__', child: Text('Stimme des Geräts (schnell)')),
              for (final e in tts) DropdownMenuItem(value: e.id, child: Text(e.name.replaceFirst('Piper ', ''))),
            ],
            onChanged: (v) => app.setVoiceSettings(ttsVoiceId: v),
          )),
          if (app.settings.ttsVoiceId == '__system__' || app.ttsVoicePath == null)
            _row(
              context,
              'Gerätestimme',
              TextButton(
                onPressed: () => _pickSystemVoice(context, app),
                child: Text(app.settings.systemVoice.isEmpty ? 'Standard – ändern' : app.settings.systemVoice.split('|').first,
                    overflow: TextOverflow.ellipsis),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 4, bottom: 4),
            child: Row(children: [
              Expanded(
                child: Text(
                  () {
                    final id = app.settings.ttsVoiceId ?? '';
                    if (id == '__system__') {
                      return 'Spricht die Sprachausgabe des Geräts: kein Warten, keine Pausen. Am Handy meist die beste Wahl '
                          '(Android: „Sprachausgabe von Google“, Stimme mit hoher Qualität offline laden).';
                    }
                    if (app.voice.output.engineLabel == 'Systemstimme') {
                      return 'Zuletzt sprach die Systemstimme (die gewählte Stimme war nicht verfügbar).';
                    }
                    if (id.startsWith('kokoro')) return 'Kokoro: die natürlichste Stimme.';
                    if (id == 'piper-de-thorsten-high') return 'Thorsten HD: klar und schnell.';
                    return 'Klingt es blechern? Im Systemcheck „Kokoro Deutsch – Martin/Victoria“ oder „Thorsten HD“ laden – deutlich natürlicher.';
                  }(),
                  style: t.bodySmall,
                ),
              ),
              TextButton.icon(
                onPressed: () => app.speakText('Hallo! So klinge ich. Um 14:30 Uhr sind es z. B. 21 °C – ca. 5 % wärmer als gestern.'),
                icon: const Icon(Icons.volume_up_outlined, size: 18),
                label: const Text('Probehören'),
              ),
            ]),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 4),
            title: const Text('Antworten automatisch vorlesen'),
            value: app.settings.autoSpeak,
            onChanged: (v) => app.setVoiceSettings(autoSpeak: v),
          ),
        ],
      ],
    );
  }

  Future<void> _pickSystemVoice(BuildContext context, AppController app) async {
    final lang = app.settings.sttLanguage == 'en' ? 'en' : 'de';
    final voices = await app.voice.output.systemVoices(lang);
    if (!context.mounted) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Stimme des Geräts'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Standard der Sprache')),
          if (voices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Keine Stimmen gefunden. Android: Einstellungen → Sprachausgabe → „Sprachausgabe von Google“ → Sprachdaten installieren.'),
            ),
          for (final (name, loc) in voices)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, '$name|$loc'),
              child: Row(children: [
                Expanded(child: Text(name, overflow: TextOverflow.ellipsis)),
                if (name.contains('network')) const Text('  online', style: TextStyle(fontSize: 11)),
                if (name.contains('local')) const Text('  offline', style: TextStyle(fontSize: 11)),
              ]),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await app.setVoiceSettings(systemVoice: picked);
    await app.speakText('Hallo! So klinge ich.');
  }

  Widget _row(BuildContext context, String label, Widget child) => Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Row(children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(width: 12),
          Expanded(child: Align(alignment: Alignment.centerRight, child: child)),
        ]),
      );
}

// ---------------------------------------------------------- Einstellungen

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Erscheinungsbild'),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('System'), icon: Icon(Icons.brightness_auto, size: 18)),
            ButtonSegment(value: 1, label: Text('Hell'), icon: Icon(Icons.light_mode_outlined, size: 18)),
            ButtonSegment(value: 2, label: Text('Dunkel'), icon: Icon(Icons.dark_mode_outlined, size: 18)),
          ],
          selected: {
            switch (app.settings.darkMode) {
              null => 0,
              false => 1,
              true => 2,
            }
          },
          showSelectedIcon: false,
          onSelectionChanged: (s) => app.setDarkMode(switch (s.first) {
            1 => false,
            2 => true,
            _ => null,
          }),
        ),
      ],
    );
  }
}


/// Einfache Fragen → schnelles Modell, komplexe → starkes Modell.
class _AutoModelSection extends StatefulWidget {
  const _AutoModelSection({required this.app});
  final AppController app;
  @override
  State<_AutoModelSection> createState() => _AutoModelSectionState();
}

class _AutoModelSectionState extends State<_AutoModelSection> {
  @override
  void initState() {
    super.initState();
    widget.app.refreshModelPlan().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final pair = app.modelPair;
    final plan = app.modelPlan;
    final models = [...app.models]..sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));
    String gb(int b) => '${(b / (1 << 30)).toStringAsFixed(1)} GB';
    Widget pick(String label, String? value, String hint, ValueChanged<String> onChanged) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: DropdownButtonFormField<String>(
            initialValue: models.any((m) => m.id == value) ? value : '',
            isExpanded: true,
            decoration: InputDecoration(labelText: label, helperText: hint),
            items: [
              const DropdownMenuItem(value: '', child: Text('Automatisch')),
              for (final m in models) DropdownMenuItem(value: m.id, child: Text('${m.displayName} · ${gb(m.sizeBytes)}', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => onChanged(v ?? ''),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        title: const Text('Modell je Aufgabe wählen'),
        subtitle: const Text('Alltagsfragen beantwortet das schnelle Modell, Analysen, Code, Präsentationen und lange Texte das starke. '
            'Scheitert das schnelle, übernimmt automatisch das starke.'),
        value: app.settings.autoModel,
        onChanged: (v) => app.setAutoModel(enabled: v),
      ),
      if (app.settings.autoModel) ...[
        if (models.length < 2)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text('Dafür braucht es zwei Sprachmodelle unterschiedlicher Größe – z. B. Qwen (schnell) und Gemma (stark). '
                'Im Systemcheck ein zweites laden.', style: t.bodySmall?.copyWith(color: c.amber)),
          )
        else ...[
          const SizedBox(height: 8),
          pick('Schnell (Alltag)', app.settings.fastModelId, pair == null ? '' : 'Jetzt: ${pair.$1.displayName}',
              (v) => app.setAutoModel(fastId: v)),
          DropdownButtonFormField<String>(
            initialValue: models.any((m) => m.id == app.settings.strongModelId) ? app.settings.strongModelId : '',
            isExpanded: true,
            decoration: InputDecoration(labelText: 'Stark (komplexe Aufgaben)', helperText: pair == null ? '' : 'Jetzt: ${pair.$2.displayName}'),
            items: [
              const DropdownMenuItem(value: '', child: Text('Automatisch')),
              for (final m in models) DropdownMenuItem(value: m.id, child: Text('${m.displayName} · ${gb(m.sizeBytes)}', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => app.setAutoModel(strongId: v ?? ''),
          ),
          const SizedBox(height: 12),
          if (pair == null)
            Text('Die installierten Modelle sind zu ähnlich groß oder das größte passt nicht in den Speicher.', style: t.bodySmall)
          else if (plan != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: plan.residency == Residency.both ? c.mintSoft : c.raised,
                borderRadius: BorderRadius.circular(Ui.r),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(
                    plan.residency == Residency.both
                        ? Icons.layers_outlined
                        : (plan.residency == Residency.swap ? Icons.swap_horiz : Icons.warning_amber_rounded),
                    size: 20,
                    color: plan.residency == Residency.both ? c.mint : c.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                        switch (plan.residency) {
                          Residency.both => 'Beide geladen',
                          Residency.swap => 'Wechsel bei Bedarf',
                          Residency.fastOnly => 'Nur das schnelle Modell',
                        },
                        style: t.titleSmall),
                    const SizedBox(height: 2),
                    Text(plan.message, style: t.bodySmall),
                    if (plan.residency == Residency.swap)
                      Text('Schon beim Tippen einer komplexen Anfrage wird gewechselt; nach einigen Minuten Pause geht es zurück zum schnellen Modell.',
                          style: t.bodySmall),
                    if (app.strongResident != null) ...[
                      const SizedBox(height: 4),
                      MonoText('geladen: ${app.loadedModel?.displayName ?? '–'} + ${app.strongResident!.displayName}'),
                    ],
                  ]),
                ),
              ]),
            ),
        ],
      ],
    ]);
  }
}
