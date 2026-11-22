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
  bool _showAll = false;
  bool _showAllRoutines = false;

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

    final scheduled = app.prompts.where((p) => p.schedule != ScheduleKind.off).toList();
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

              // ---- Arbeitsbereich
              const SectionLabel('Automatik'),
              item(AppSection.tasks,
                  count: scheduled.where((p) => p.enabled).isEmpty ? null : '${scheduled.where((p) => p.enabled).length}'),
              // Watchlist ist Teil der Prozesse (Beobachten-Auslöser im Canvas)
              item(AppSection.flows,
                  count: app.watchlist.unseen > 0 || app.flows.flows.isEmpty ? null : '${app.flows.flows.length}',
                  dot: app.watchlist.unseen > 0),
              const SectionLabel('Arbeitsbereich'),
              item(AppSection.prompts, count: templates == 0 ? null : '$templates'),
              item(AppSection.knowledge, dot: app.memory.pending.isNotEmpty),
              item(AppSection.activity),

              // ---- Routinen: je Aufgabe bzw. Prozess ein Chat mit allen Ergebnissen
              if (q.isEmpty && routines.isNotEmpty) ...[
                SectionLabel('Routinen', trailing: MonoText('${routines.length}', size: 11, color: c.faint)),
                for (final conv in routines.take(_showAllRoutines ? 50 : 5))
                  _ChatRow(
                    conv: conv,
                    selected: app.current?.id == conv.id && (active == null || active == AppSection.chat),
                    running: app.running && app.runningConvId == conv.id,
                    onTap: () {
                      app.selectConversation(conv);
                      _go(AppSection.chat);
                    },
                    onDelete: () => app.deleteConversation(conv),
                  ),
                if (routines.length > 5)
                  TextButton(
                    onPressed: () => setState(() => _showAllRoutines = !_showAllRoutines),
                    child: Text(_showAllRoutines ? 'Weniger anzeigen' : 'Alle ${routines.length} Routinen'),
                  ),
              ],

              // ---- Chats
              SectionLabel(
                q.isEmpty ? 'Chats' : 'Treffer',
                trailing: MonoText('${chats.length}', size: 11, color: c.faint),
              ),
              if (chats.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Text(q.isEmpty ? 'Noch keine Chats.' : 'Nichts gefunden.', style: t.bodySmall),
                ),
              for (final conv in visible)
                _ChatRow(
                  conv: conv,
                  selected: app.current?.id == conv.id && (active == null || active == AppSection.chat),
                  running: app.running && app.runningConvId == conv.id,
                  onTap: () {
                    app.selectConversation(conv);
                    _go(AppSection.chat);
                  },
                  onDelete: () => app.deleteConversation(conv),
                ),
              if (q.isEmpty && chats.length > 12)
                TextButton(
                  onPressed: () => setState(() => _showAll = !_showAll),
                  child: Text(_showAll ? 'Weniger anzeigen' : 'Alle ${chats.length} Chats anzeigen'),
                ),
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
                    tooltip: 'Löschen',
                    visualDensity: VisualDensity.compact,
                    iconSize: 17,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: widget.onDelete,
                  )
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
    final r = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(widget.conv.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Chat löschen'),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
        ]),
      ),
    );
    if (r == 'delete') widget.onDelete();
  }
}
