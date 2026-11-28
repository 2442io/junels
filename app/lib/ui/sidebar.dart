// Linke Seitenleiste: Marke, Modellstatus, Schnellaktionen, Arbeitsbereiche,
// Chats (durchsuchbar) und unten Einstellungen & Hilfe.

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_controller.dart';
import '../state/app_scope.dart';
import '../version.dart';
import 'conversation_page.dart';
import 'nav.dart';
import 'system_check.dart';
import 'chat_style.dart';
import 'theme.dart';
import 'update_page.dart';

class Sidebar extends StatefulWidget {
  const Sidebar({super.key, this.inDrawer = false});
  final bool inDrawer;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final _search = TextEditingController();
  String _query = '';
  final _openFolders = <String>{};
  bool _showAll = false;

  /// Aufgeklappte Gruppen – bleiben für die Sitzung gemerkt (Standard: alles zu, nur Chats offen)
  static final Set<String> _open = {'chats'};
  void _toggle(String g) => setState(() => _open.contains(g) ? _open.remove(g) : _open.add(g));

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _go(AppSection s) => openSection(context, s, fromDrawer: widget.inDrawer);

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final nav = ShellNav.maybeOf(context);
    final active = nav?.embedded == true ? nav!.section : null;

    final templates = app.prompts.where((p) => p.schedule == ScheduleKind.off).length;
    final q = _query.trim().toLowerCase();
    // Routinen (geplante Aufgaben, Prozesse) haben eine eigene Kategorie
    final routines = app.conversations.where(AppController.isRoutineChat).toList();
    final normal = app.conversations.where((c) => !AppController.isRoutineChat(c)).toList();
    final chats = q.isEmpty
        ? normal
        : app.conversations
            .where((c) =>
                c.title.toLowerCase().contains(q) || c.entries.any((e) => e.text.toLowerCase().contains(q)))
            .toList();
    final visible = _showAll || q.isNotEmpty ? chats.take(200).toList() : chats.take(12).toList();
    final pinned = normal.where((c) => c.pinned).toList();
    final folders = app.chatFolders;
    final looseAll = normal.where((c) => !c.pinned && c.folder == null).toList();
    final loose = _showAll ? looseAll.take(200).toList() : looseAll.take(5).toList();
    Widget row(Conversation conv) => _ChatRow(
          key: ValueKey(conv.id),
          conv: conv,
          selected: app.current?.id == conv.id && (active == null || active == AppSection.chat),
          running: app.running && app.runningConvId == conv.id,
          onTap: () {
            app.selectConversation(conv);
            _go(AppSection.chat);
          },
          onDelete: () => app.deleteConversation(conv),
        );

    Widget folder(String f) => _FolderGroup(
          key: ValueKey('folder:$f'),
          name: f,
          meta: app.folderMeta(f),
          count: normal.where((c) => c.folder == f).length,
          open: _openFolders.contains(f) || normal.any((c) => c.folder == f && c.id == app.current?.id),
          onToggle: () => setState(() => _openFolders.contains(f) ? _openFolders.remove(f) : _openFolders.add(f)),
          children: [for (final conv in normal.where((c) => c.folder == f && !c.pinned)) row(conv)],
        );

    Widget item(AppSection s, {String? count, bool dot = false}) => _NavItem(
          icon: s.icon,
          label: s.label,
          count: count,
          dot: dot,
          selected: active == s,
          onTap: () => _go(s),
        );

    return Container(
      color: c.panel,
      child: Column(children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
            children: [
              // ---- Marke
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
                child: Row(children: [
                  const BrandMark(size: 30),
                  const SizedBox(width: 10),
                  Text('Junels', style: t.titleMedium?.copyWith(fontSize: 18, letterSpacing: -0.4)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: c.amber.withValues(alpha: 0.6)),
                    ),
                    child: Text('v$appVersion',
                        style: TextStyle(fontFamily: Ui.mono, fontSize: 10.5, color: c.amber, fontWeight: FontWeight.w500)),
                  ),
                  if (widget.inDrawer) ...[
                    const Spacer(),
                    IconButton(
                      tooltip: 'Menü schließen',
                      icon: const Icon(Icons.close),
                      onPressed: () => Scaffold.maybeOf(context)?.closeDrawer(),
                    ),
                  ],
                ]),
              ),
              const UpdateBanner(),
              _ModelPill(app: app),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Neuer Chat'),
                    onPressed: () {
                      app.newConversation();
                      _go(AppSection.chat);
                      if (widget.inDrawer) Scaffold.maybeOf(context)?.closeDrawer();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                PillIconButton(
                  icon: Icons.graphic_eq,
                  tooltip: 'Gesprächsmodus',
                  onPressed: app.engine == null || app.running
                      ? null
                      : () {
                          if (widget.inDrawer) Navigator.of(context).maybePop();
                          openConversation(context);
                        },
                ),
              ]),
              if (routines.isNotEmpty) ...[
                const SizedBox(height: 8),
                // Alles, was von selbst läuft (Abläufe, geplante Aufgaben, Gespräche), an einem Ort
                _NavItem(
                  icon: Icons.inbox_outlined,
                  label: 'Ergebnisse',
                  count: app.feedUnread > 0 ? '${app.feedUnread}' : null,
                  dot: app.feedUnread > 0,
                  selected: app.current?.id == AppController.feedId && (active == null || active == AppSection.chat),
                  onTap: () {
                    app.openFeed();
                    _go(AppSection.chat);
                  },
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _search,
                onChanged: (v) => setState(() => _query = v),
                style: t.bodyMedium,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18, color: c.faint),
                  hintText: 'Chats durchsuchen …',
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () => setState(() {
                            _search.clear();
                            _query = '';
                          }),
                        ),
                ),
              ),

              // ---- Chats gleich unter der Suche
              _GroupHeader(
                label: q.isEmpty ? 'Chats' : 'Treffer',
                count: '${chats.length}',
                open: q.isNotEmpty || _open.contains('chats'),
                onTap: q.isNotEmpty ? null : () => _toggle('chats'),
              ),
              if (q.isNotEmpty || _open.contains('chats')) ...[
                if (chats.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Text(q.isEmpty ? 'Noch keine Chats.' : 'Nichts gefunden.', style: t.bodySmall),
                  ),
                if (q.isNotEmpty)
                  for (final conv in visible) row(conv)
                else ...[
                  // angeheftet: Ordner und Chats
                  if (pinned.isNotEmpty || folders.any(app.folderPinned))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
                      child: Row(children: [
                        Icon(Icons.push_pin, size: 12, color: c.faint),
                        const SizedBox(width: 6),
                        Text('Angeheftet', style: t.labelSmall?.copyWith(color: c.faint)),
                      ]),
                    ),
                  for (final f in folders.where(app.folderPinned)) folder(f),
                  for (final conv in pinned) row(conv),
                  if (pinned.isNotEmpty || folders.any(app.folderPinned)) Divider(height: 14, color: c.border),
                  // Ordner / Projekte
                  for (final f in folders.where((f) => !app.folderPinned(f))) folder(f),
                  for (final conv in loose) row(conv),
                ],
                if (q.isEmpty && looseAll.length > 5)
                  TextButton(
                    onPressed: () => setState(() => _showAll = !_showAll),
                    child: Text(_showAll ? 'Weniger anzeigen' : 'Alle ${looseAll.length} Chats anzeigen'),
                  ),
              ],

              if (q.isEmpty) ...[
                // ---- Skills & Abläufe: Anleitungen, Abläufe mit Auslöser, Beobachtungen und ihre Ergebnis-Chats
                _GroupHeader(
                  label: 'Skills & Abläufe',
                  open: _open.contains('auto'),
                  dot: app.watchlist.unseen > 0 ? c.amber : null,
                  onTap: () => _toggle('auto'),
                ),
                if (_open.contains('auto')) ...[
                  item(AppSection.skills,
                      count: app.watchlist.unseen > 0 || app.skills.own.isEmpty ? null : '${app.skills.own.length}',
                      dot: app.watchlist.unseen > 0),
                ],
                // ---- Wissen
                _GroupHeader(
                  label: 'Wissen & Vorlagen',
                  open: _open.contains('skills'),
                  dot: app.memory.pending.isNotEmpty ? c.amber : null,
                  onTap: () => _toggle('skills'),
                ),
                if (_open.contains('skills')) ...[
                  item(AppSection.prompts, count: templates == 0 ? null : '$templates'),
                  item(AppSection.knowledge, dot: app.memory.pending.isNotEmpty),
                ],
                // ---- Kontrolle
                _GroupHeader(
                  label: 'Kontrolle',
                  open: _open.contains('control'),
                  dot: app.runStats.records.isNotEmpty && app.runStats.records.last.status == 'error' ? c.red : null,
                  onTap: () => _toggle('control'),
                ),
                if (_open.contains('control')) ...[item(AppSection.activity), item(AppSection.analytics)],
              ],
            ],
          ),
        ),

        // ---- Fuß: Einstellungen & Hilfe
        Container(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Column(children: [
            item(AppSection.settings, dot: app.updates.available.value != null),
            item(AppSection.help),
          ]),
        ),
      ]),
    );
  }
}

/// Eintrag der Hauptnavigation.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.count,
    this.dot = false,
    this.selected = false,
  });
  final IconData icon;
  final String label;
  final String? count;
  final bool dot;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? c.mintSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(children: [
              Icon(icon, size: 19, color: selected ? c.mint : c.muted),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                        color: scheme.onSurface)),
              ),
              if (dot)
                Container(width: 8, height: 8, decoration: BoxDecoration(color: c.amber, shape: BoxShape.circle)),
              if (count != null) ...[
                const SizedBox(width: 6),
                MonoText(count!, size: 11, color: c.faint),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// Geladenes Modell bzw. aktiver Anbieter – Tipp öffnet den Systemcheck.
class _ModelPill extends StatelessWidget {
  const _ModelPill({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final m = app.loadedModel;
    final (color, state) = switch (app.status) {
      EngineStatus.ready => (c.mint, 'bereit'),
      EngineStatus.loading => (c.amber, 'lädt …'),
      EngineStatus.error => (c.red, 'Fehler'),
      _ => (c.faint, 'nicht geladen'),
    };
    final route = app.routingLabel;
    return Panel(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      onTap: () => openSystemCheck(context),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle, boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 6),
            ]),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m?.displayName ?? 'Kein Modell geladen',
                  style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              MonoText(m == null ? 'Tippen zum Einrichten' : 'lokal · $state${route == null ? '' : ' · $route'}', size: 10.5),
            ]),
          ),
          Icon(Icons.chevron_right, size: 18, color: c.faint),
        ]),
        if (app.status == EngineStatus.loading) ...[
          const SizedBox(height: 8),
          ClipRRect(borderRadius: BorderRadius.circular(4), child: const LinearProgressIndicator(minHeight: 3)),
        ],
      ]),
    );
  }
}

class _ChatRow extends StatefulWidget {
  const _ChatRow({
    super.key,
    required this.conv,
    required this.selected,
    required this.running,
    required this.onTap,
    required this.onDelete,
  });
  final Conversation conv;
  final bool selected;
  final bool running;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  State<_ChatRow> createState() => _ChatRowState();
}

class _ChatRowState extends State<_ChatRow> {
  bool _hover = false;

  static String _date(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) return '${two(d.hour)}:${two(d.minute)}';
    final y = now.subtract(const Duration(days: 1));
    if (d.year == y.year && d.month == y.month && d.day == y.day) return 'gestern';
    return '${two(d.day)}.${two(d.month)}.';
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final conv = widget.conv;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 1),
        child: Material(
          color: widget.selected ? c.raised : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: widget.onTap,
            onLongPress: () => _menu(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
              child: Row(children: [
                if (styleMark(context, icon: conv.icon, color: conv.color) case final m?) ...[m, const SizedBox(width: 10)],
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(conv.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13.5,
                            color: scheme.onSurface,
                            fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400)),
                    const SizedBox(height: 1),
                    MonoText('${_date(conv.updated)} · ${conv.entries.length ~/ 2} Nachr.', size: 10.5, color: c.faint),
                  ]),
                ),
                if (widget.running)
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else if (_hover || widget.selected)
                  IconButton(
                    tooltip: 'Mehr',
                    visualDensity: VisualDensity.compact,
                    iconSize: 17,
                    icon: const Icon(Icons.more_horiz),
                    onPressed: () => _menu(context),
                  )
                else if (conv.pinned)
                  Padding(padding: const EdgeInsets.all(12), child: Icon(Icons.push_pin, size: 14, color: c.faint))
                else
                  const SizedBox(width: 40),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context) async {
    final app = AppScope.read(context);
    final conv = widget.conv;
    final r = await showSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(conv.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ListTile(
            leading: Icon(conv.pinned ? Icons.push_pin_outlined : Icons.push_pin),
            title: Text(conv.pinned ? 'Lösen' : 'Anheften'),
            onTap: () => Navigator.pop(ctx, 'pin'),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Symbol & Farbe …'),
            onTap: () => Navigator.pop(ctx, 'style'),
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(conv.folder == null ? 'In Ordner verschieben …' : 'Ordner: ${conv.folder} – ändern …'),
            onTap: () => Navigator.pop(ctx, 'folder'),
          ),
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Umbenennen'), onTap: () => Navigator.pop(ctx, 'rename')),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Chat löschen'), onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (!context.mounted) return;
    switch (r) {
      case 'pin':
        await app.setPinned(conv, !conv.pinned);
      case 'style':
        final r = await pickStyle(context, title: conv.title, icon: conv.icon, color: conv.color);
        if (r != null) await app.setChatStyle(conv, icon: r.$1, color: r.$2);
      case 'folder':
        final f = await _pickFolder(context, app.chatFolders, conv.folder);
        if (f != null) await app.setFolder(conv, f == '-' ? null : f);
      case 'rename':
        final t = await _askText(context, 'Chat umbenennen', conv.title);
        if (t != null) await app.renameConversation(conv, t);
      case 'delete':
        widget.onDelete();
    }
  }
}


/// Ordner wählen oder neu anlegen. '-' = aus dem Ordner nehmen.
Future<String?> _pickFolder(BuildContext context, List<String> folders, String? current) => showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('In Ordner verschieben'),
        children: [
          for (final f in folders)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, f),
              child: Row(children: [
                Icon(f == current ? Icons.folder : Icons.folder_outlined, size: 18),
                const SizedBox(width: 10),
                Expanded(child: Text(f)),
              ]),
            ),
          SimpleDialogOption(
            onPressed: () async {
              final name = await _askText(ctx, 'Neuer Ordner', '');
              if (ctx.mounted) Navigator.pop(ctx, name);
            },
            child: const Row(children: [Icon(Icons.create_new_folder_outlined, size: 18), SizedBox(width: 10), Text('Neuer Ordner …')]),
          ),
          if (current != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, '-'),
              child: const Row(children: [Icon(Icons.folder_off_outlined, size: 18), SizedBox(width: 10), Text('Aus dem Ordner nehmen')]),
            ),
        ],
      ),
    );

Future<String?> _askText(BuildContext context, String title, String initial) async {
  final ctrl = TextEditingController(text: initial);
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctrl, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('OK')),
      ],
    ),
  );
  ctrl.dispose();
  return r == null || r.trim().isEmpty ? null : r.trim();
}

/// Ordner in der Chat-Liste (aufklappbar) – mit Symbol, Farbe, Anheften.
class _FolderGroup extends StatefulWidget {
  const _FolderGroup({
    super.key,
    required this.name,
    required this.meta,
    required this.count,
    required this.open,
    required this.onToggle,
    required this.children,
  });
  final String name;
  final Map<String, dynamic> meta;
  final int count;
  final bool open;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  State<_FolderGroup> createState() => _FolderGroupState();
}

class _FolderGroupState extends State<_FolderGroup> {
  bool _hover = false;

  Future<void> _menu(BuildContext context) async {
    final app = AppScope.read(context);
    final f = widget.name;
    final pinned = widget.meta['pinned'] == true;
    final r = await showSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.folder_outlined), title: Text(f, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ListTile(
            leading: Icon(pinned ? Icons.push_pin_outlined : Icons.push_pin),
            title: Text(pinned ? 'Lösen' : 'Anheften'),
            onTap: () => Navigator.pop(ctx, 'pin'),
          ),
          ListTile(leading: const Icon(Icons.palette_outlined), title: const Text('Symbol & Farbe …'), onTap: () => Navigator.pop(ctx, 'style')),
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Umbenennen'), onTap: () => Navigator.pop(ctx, 'rename')),
          ListTile(
            leading: const Icon(Icons.folder_off_outlined),
            title: const Text('Ordner auflösen'),
            subtitle: const Text('Die Chats bleiben erhalten, nur ohne Ordner'),
            onTap: () => Navigator.pop(ctx, 'dissolve'),
          ),
        ]),
      ),
    );
    if (!context.mounted) return;
    switch (r) {
      case 'pin':
        await app.setFolderPinned(f, !pinned);
      case 'style':
        final s = await pickStyle(context, title: f, icon: widget.meta['icon'] as String?, color: widget.meta['color'] as String?);
        if (s != null) await app.setFolderStyle(f, icon: s.$1, color: s.$2);
      case 'rename':
        final t = await _askText(context, 'Ordner umbenennen', f);
        if (t != null) await app.renameFolder(f, t);
      case 'dissolve':
        await app.dissolveFolder(f);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final open = widget.open;
    final icon = widget.meta['icon'] as String?;
    final color = widget.meta['color'] as String?;
    final tint = tagColor(color);
    final mark = styleMark(context, icon: icon, color: color, size: 17) ??
        Icon(open ? Icons.folder_open_outlined : Icons.folder_outlined, size: 17, color: c.muted);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: widget.onToggle,
          onLongPress: () => _menu(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 3, 4, 3),
            child: Row(children: [
              // nur Farbe ohne Symbol: Ordner-Symbol in der Farbe
              if (icon == null && tint != null) Icon(open ? Icons.folder_open : Icons.folder, size: 17, color: tint) else mark,
              const SizedBox(width: 10),
              Expanded(
                child: Text(widget.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
              ),
              MonoText('${widget.count}', size: 11, color: c.faint),
              IconButton(
                tooltip: 'Ordner-Menü',
                visualDensity: VisualDensity.compact,
                iconSize: 17,
                icon: Icon(Icons.more_horiz, color: _hover ? null : c.faint.withValues(alpha: 0.6)),
                onPressed: () => _menu(context),
              ),
              Icon(open ? Icons.expand_less : Icons.expand_more, size: 17, color: c.faint),
            ]),
          ),
        ),
      ),
      if (open)
        Padding(
          padding: const EdgeInsets.only(left: 14),
          child: Container(
            decoration: tint == null ? null : BoxDecoration(border: Border(left: BorderSide(color: tint.withValues(alpha: 0.5), width: 2))),
            padding: EdgeInsets.only(left: tint == null ? 0 : 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children),
          ),
        ),
    ]);
  }
}


/// Aufklappbare Gruppen-Überschrift im Seitenmenü.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label, required this.open, this.onTap, this.count, this.dot});
  final String label;
  final bool open;
  final VoidCallback? onTap;
  final String? count;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
          child: Row(children: [
            Text(label.toUpperCase(),
                style: TextStyle(fontSize: 11, letterSpacing: 0.9, fontWeight: FontWeight.w600, color: c.faint)),
            if (dot != null && !open) ...[
              const SizedBox(width: 8),
              Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
            ],
            const Spacer(),
            if (count != null) MonoText(count!, size: 11, color: c.faint),
            if (onTap != null) Icon(open ? Icons.expand_less : Icons.expand_more, size: 18, color: c.faint),
          ]),
        ),
      ),
    );
  }
}
