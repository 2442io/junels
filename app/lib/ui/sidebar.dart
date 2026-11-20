// Linke Sidebar: Modell-Manager, Agent-Profile, Tool-Konfigurator, Chats.

import '../version.dart';
import 'info_pages.dart';
import 'conversation_page.dart';
import 'device_page.dart';
import 'sync_page.dart';
import 'update_page.dart';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_controller.dart';
import '../state/app_scope.dart';
import 'knowledge_page.dart';
import 'mcp_page.dart';
import 'prompt_editor.dart';
import 'model_import.dart';
import 'profile_editor.dart';
import 'system_check.dart';

class Sidebar extends StatelessWidget {
  const Sidebar({super.key, this.inDrawer = false});
  final bool inDrawer;

  void _closeDrawer(BuildContext context) {
    if (inDrawer) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final loaded = app.loadedModel;
    final enabledTools = app.activeTools.length;
    final voiceReady = app.sttModelPath != null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        const UpdateBanner(),
        _QuickHeader(app: app, onDone: () => _closeDrawer(context)),
        const SizedBox(height: 8),

        // ---- Täglich: Chats und Prompts
        _Group(
          id: 'chats',
          icon: Icons.forum_outlined,
          title: 'Chats',
          summary: app.conversations.isEmpty ? 'Noch keine Chats' : '${app.conversations.length} Chats',
          initiallyExpanded: true,
          child: _ChatSection(app: app, onSelect: () => _closeDrawer(context)),
        ),
        _Group(
          id: 'prompts',
          icon: Icons.bolt_outlined,
          title: 'Meine Prompts',
          summary: app.prompts.isEmpty
              ? 'Vorlagen & Zeitpläne'
              : '${app.prompts.length} gespeichert · ${app.prompts.where((p) => p.schedule != ScheduleKind.off).length} geplant',
          initiallyExpanded: true,
          child: _PromptSection(app: app),
        ),

        // ---- Wissen
        _Group(
          id: 'knowledge',
          icon: Icons.local_library_outlined,
          title: 'Wissen & Gedächtnis',
          summary: '${app.knowledge.sources.length} Quellen · ${app.memory.notes.length} Notizen',
          onTap: () => openKnowledge(context),
        ),

        const _ClusterLabel('Einrichten'),
        _Group(
          id: 'model',
          icon: Icons.memory,
          title: 'Modell',
          summary: loaded == null
              ? 'Kein Modell geladen'
              : '${loaded.displayName} · ${(app.engine?.contextSize ?? 0) ~/ 1024}K Context',
          child: _ModelSection(app: app),
        ),
        _Group(
          id: 'agent',
          icon: Icons.smart_toy_outlined,
          title: 'Agent & Werkzeuge',
          summary: 'Profil „${app.activeProfile.name}“ · $enabledTools Werkzeuge',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _ProfileSection(app: app),
            const SizedBox(height: 12),
            _ToolSection(app: app),
            const SizedBox(height: 8),
            _NavTile(
              icon: Icons.hub_outlined,
              title: 'MCP-Store & Server',
              subtitle: app.mcpServers.isEmpty
                  ? 'Weitere Werkzeuge anbinden'
                  : '${app.mcpServers.where((s) => s.enabled).length} aktiv · ${app.mcpTools.length} Werkzeuge',
              onTap: () => openMcp(context),
            ),
          ]),
        ),
        _Group(
          id: 'voice',
          icon: Icons.record_voice_over_outlined,
          title: 'Sprache',
          summary: voiceReady ? 'Spracheingabe bereit' : 'Noch nicht eingerichtet',
          child: _VoiceSection(app: app),
        ),
        _Group(
          id: 'device',
          icon: Icons.devices_other,
          title: 'Gerät & Verbindungen',
          summary: [
            if (app.settings.homeCity.isNotEmpty) app.settings.homeCity,
            if (app.sync.configured) 'Abgleich aktiv',
            if (app.settings.watchFolders.isNotEmpty) '${app.settings.watchFolders.length} Ordner',
          ].join(' · ').ifEmpty('Automatik, Abgleich, Ordner'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _NavTile(
              icon: Icons.tune,
              title: 'Gerät & Automatik',
              subtitle: 'Heimatort, Morgen-Übersicht, Schnellstart, Ordner',
              onTap: () => openDevicePage(context),
            ),
            _NavTile(
              icon: Icons.sync,
              title: 'Abgleich Mac ↔ Handy',
              subtitle: !app.sync.configured
                  ? 'Über eigenen Server oder WLAN'
                  : app.sync.lastSync == null
                      ? 'Eingerichtet'
                      : 'Zuletzt ${TimeOfDay.fromDateTime(app.sync.lastSync!).format(context)}',
              onTap: () => openSync(context),
            ),
          ]),
        ),
        _Group(
          id: 'app',
          icon: Icons.settings_outlined,
          title: 'App',
          summary: app.updates.available.value != null
              ? 'Update ${app.updates.available.value!.version} verfügbar'
              : 'Darstellung, Updates, Protokoll',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _SettingsSection(app: app),
            const SizedBox(height: 4),
            _NavTile(
              icon: Icons.system_update_outlined,
              title: 'Updates',
              subtitle: app.updates.available.value != null
                  ? 'Neue Version ${app.updates.available.value!.version} verfügbar'
                  : (app.updates.hasToken ? 'Automatische Prüfung aktiv' : 'In der App aktualisieren – einrichten'),
              onTap: () => openUpdates(context),
            ),
            _NavTile(
              icon: Icons.receipt_long_outlined,
              title: 'Protokoll',
              subtitle: 'Fehler und Zeiten einsehen',
              onTap: () => openLog(context),
            ),
            _NavTile(
              icon: Icons.history,
              title: 'Versionsverlauf',
              subtitle: 'Was ist neu?',
              onTap: () => openChangelog(context),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        Center(
          child: InkWell(
            onTap: () => openChangelog(context),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Text(
                'Junels $appVersion (Build $appBuild)',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

// ------------------------------------------------------------- Bausteine

/// Kopf: geladenes Modell und die zwei häufigsten Aktionen.
class _QuickHeader extends StatelessWidget {
  const _QuickHeader({required this.app, required this.onDone});
  final AppController app;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final m = app.loadedModel;
    final (color, state) = switch (app.status) {
      EngineStatus.ready => (Colors.green, 'bereit'),
      EngineStatus.loading => (Colors.orange, 'lädt …'),
      EngineStatus.error => (scheme.error, 'Fehler'),
      _ => (scheme.outline, 'nicht geladen'),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => openSystemCheck(context),
            child: Row(children: [
              Icon(Icons.circle, size: 10, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(m?.displayName ?? 'Kein Modell geladen', style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(m == null ? 'Tippen zum Auswählen' : 'Modell $state', style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ]),
              ),
              const Icon(Icons.chevron_right),
            ]),
          ),
          if (app.status == EngineStatus.loading) ...[const SizedBox(height: 8), const LinearProgressIndicator()],
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.add_comment_outlined, size: 18),
                label: const Text('Neuer Chat'),
                onPressed: app.running
                    ? null
                    : () {
                        app.newConversation();
                        onDone();
                      },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.record_voice_over_outlined, size: 18),
                label: const Text('Gespräch'),
                onPressed: app.engine == null
                    ? null
                    : () {
                        onDone();
                        openConversation(context);
                      },
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _ClusterLabel extends StatelessWidget {
  const _ClusterLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 18, 8, 6),
        child: Text(text.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 1.2, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

/// Markiert Inhalte innerhalb einer Gruppe: Abschnittstitel werden dort nicht wiederholt.
class _InGroup extends InheritedWidget {
  const _InGroup({required super.child});
  @override
  bool updateShouldNotify(_InGroup oldWidget) => false;
}

/// Aufklappbare Gruppe (bzw. Verweis auf eine eigene Seite, wenn [onTap] gesetzt ist).
class _Group extends StatelessWidget {
  const _Group({
    required this.id,
    required this.icon,
    required this.title,
    required this.summary,
    this.child,
    this.onTap,
    this.initiallyExpanded = false,
  });
  final String id;
  final IconData icon;
  final String title;
  final String summary;
  final Widget? child;
  final VoidCallback? onTap;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final sub = Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant));
    if (onTap != null) {
      return Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: ListTile(leading: Icon(icon), title: Text(title), subtitle: sub, trailing: const Icon(Icons.chevron_right), onTap: onTap),
      );
    }
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey('sidebar-$id'),
        leading: Icon(icon),
        title: Text(title),
        subtitle: sub,
        initiallyExpanded: initiallyExpanded,
        shape: const Border(),
        collapsedShape: const Border(),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [_InGroup(child: child ?? const SizedBox())],
      ),
    );
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

class _PromptSection extends StatelessWidget {
  const _PromptSection({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _SectionTitle('Meine Prompts',
          trailing: IconButton(
            tooltip: 'Neuer Prompt',
            icon: const Icon(Icons.add, size: 20),
            visualDensity: VisualDensity.compact,
            onPressed: () => editPrompt(context),
          )),
      if (app.prompts.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Text('Prompts speichern, per Klick starten oder täglich automatisch ausführen lassen.',
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      morningBriefingTile(context, app),
      for (final p in app.prompts)
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 4),
          leading: Icon(p.schedule == ScheduleKind.off ? Icons.bolt_outlined : Icons.alarm, size: 20),
          title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(p.scheduleLabel, style: t.labelSmall),
          onTap: () => editPrompt(context, prompt: p),
          trailing: IconButton(
            tooltip: 'Jetzt ausführen',
            icon: const Icon(Icons.play_circle_outline),
            onPressed: app.running ? null : () => runSavedPrompt(context, app, p),
          ),
        ),
    ]);
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final inGroup = context.getInheritedWidgetOfExactType<_InGroup>() != null;
    // In einer Gruppe steht der Titel schon im Kopf – nur Haupttitel weglassen,
    // Unterabschnitte (z. B. „Werkzeuge“ im Agent-Bereich) bleiben sichtbar.
    if (inGroup && const {'Chats', 'Meine Prompts', 'Modell', 'Sprache', 'Einstellungen'}.contains(text)) {
      return trailing == null || text == 'Chats'
          ? const SizedBox(height: 4)
          : Align(alignment: Alignment.centerRight, child: trailing);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(text.toUpperCase(),
                style: t.labelSmall?.copyWith(
                    letterSpacing: 1.1, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------- Modell

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
            trailing: IconButton(
              tooltip: 'Neues Profil',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add, size: 20),
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

  @override
  Widget build(BuildContext context) {
    final enabled = app.activeProfile.useTools;
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Lokale Tools'),
        if (!enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Text('Im Profil „${app.activeProfile.name}“ sind Tools ausgeschaltet.', style: t.bodySmall),
          ),
        for (final tool in app.tools)
          SwitchListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 8, right: 0),
            secondary: Icon(_icons[tool.name] ?? Icons.extension_outlined, size: 20),
            title: Text(tool.requiresNetwork ? '${tool.title} (Internet, fragt vorher)' : tool.title),
            subtitle: Text(tool.description, maxLines: 2, overflow: TextOverflow.ellipsis),
            value: app.settings.enabledTools.contains(tool.name),
            onChanged: !enabled || app.running ? null : (v) => app.setToolEnabled(tool.name, v),
          ),
      ],
    );
  }
}

// -------------------------------------------------------------------- Chats

class _ChatSection extends StatelessWidget {
  const _ChatSection({required this.app, required this.onSelect});
  final AppController app;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle('Chats',
            trailing: IconButton(
              tooltip: 'Neuer Chat',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add_comment_outlined, size: 20),
              onPressed: app.running
                  ? null
                  : () {
                      app.newConversation();
                      onSelect();
                    },
            )),
        if (app.conversations.isEmpty)
          Padding(
            padding: const EdgeInsets.all(4),
            child: Text('Noch keine Chats.', style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        for (final c in app.conversations.take(8)) _chatTile(context, c, scheme),
        if (app.conversations.length > 8)
          ExpansionTile(
            key: const PageStorageKey('sidebar-older-chats'),
            tilePadding: const EdgeInsets.only(left: 8, right: 4),
            title: Text('Ältere Chats (${app.conversations.length - 8})', style: Theme.of(context).textTheme.bodyMedium),
            shape: const Border(),
            collapsedShape: const Border(),
            children: [for (final c in app.conversations.skip(8).take(100)) _chatTile(context, c, scheme)],
          ),
      ],
    );
  }

  Widget _chatTile(BuildContext context, Conversation c, ColorScheme scheme) => ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            selected: app.current?.id == c.id,
            selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.5),
            title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${c.entries.length ~/ 2} Nachrichten · ${_date(c.updated)}'),
            onTap: app.running
                ? null
                : () {
                    app.selectConversation(c);
                    onSelect();
                  },
            trailing: IconButton(
              tooltip: 'Löschen',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: app.running && app.current?.id == c.id ? null : () => app.deleteConversation(c),
            ),
          );

  static String _date(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return '${two(d.hour)}:${two(d.minute)}';
    }
    return '${two(d.day)}.${two(d.month)}.';
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
        if (tts.isNotEmpty) ...[
          _row(context, 'Stimme', DropdownButton<String>(
            value: tts.any((e) => e.id == app.settings.ttsVoiceId) ? app.settings.ttsVoiceId : null,
            hint: const Text('wählen'),
            isDense: true,
            underline: const SizedBox(),
            items: [for (final e in tts) DropdownMenuItem(value: e.id, child: Text(e.name.replaceFirst('Piper ', '')))],
            onChanged: (v) => app.setVoiceSettings(ttsVoiceId: v),
          )),
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
        const _SectionTitle('Einstellungen'),
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
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 4),
          title: const Text('Letztes Modell beim Start laden'),
          value: app.settings.autoLoadLastModel,
          onChanged: app.setAutoLoad,
        ),
      ],
    );
  }
}
