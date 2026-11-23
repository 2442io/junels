// Benachrichtigungen & To-dos: alles, was auf dich wartet (Freigaben, Begleitungen, Erinnerungen, Gedächtnis),
// dazu alle Meldungen nach Art (Aktion, Warnung, Erinnerung, Ergebnis, Info) – nichts geht verloren.

import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/app_scope.dart';
import '../state/guide.dart';
import '../state/notifications.dart';
import 'nav.dart';
import 'notify_style.dart';
import 'slide_to_done.dart';
import 'theme.dart';

class InboxPage extends StatefulWidget {
  const InboxPage({super.key});

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  NotifyKind? _filter;
  bool _unreadOnly = false;
  bool _archive = false;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final n = app.notifier;
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    return ListenableBuilder(
      listenable: n,
      builder: (context, _) {
        final all = [
          for (final i in n.items)
            if (i.kind != NotifyKind.ruhig &&
                i.archived == _archive &&
                (_filter == null || i.kind == _filter) &&
                (!_unreadOnly || !i.read || i.waiting))
              i
        ];
        final waiting = all.where((i) => i.waiting).toList();
        final planned = all.where((i) => i.planned).toList()..sort((a, b) => a.due!.compareTo(b.due!));
        final now = DateTime.now();
        bool today(InboxItem i) => i.at.year == now.year && i.at.month == now.month && i.at.day == now.day;
        final rest = _archive ? all : all.where((i) => !i.waiting && !i.planned).toList();
        final todayList = rest.where(today).toList();
        final older = rest.where((i) => !today(i)).toList();

        Widget section(String title, List<InboxItem> list) => list.isEmpty
            ? const SizedBox.shrink()
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SectionLabel(title, padding: const EdgeInsets.fromLTRB(4, 14, 4, 6)),
                for (final i in list) _ItemTile(item: i),
              ]);

        Widget chip(String label, bool selected, VoidCallback onTap, {IconData? icon, Color? color, Color? soft}) => Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                avatar: icon == null ? null : Icon(icon, size: 16, color: color),
                label: Text(label),
                selected: selected,
                showCheckmark: false,
                selectedColor: soft,
                onSelected: (_) => onTap(),
              ),
            );

        return Scaffold(
          appBar: AppBar(
            title: Text(_archive ? 'Archiv' : 'Benachrichtigungen'),
            leading: _archive ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _archive = false)) : null,
            actions: [
              if (!_archive)
                IconButton(tooltip: 'Alle als gelesen markieren', icon: const Icon(Icons.done_all), onPressed: n.unread == 0 ? null : n.markAllRead),
              PopupMenuButton<String>(
                tooltip: 'Mehr',
                onSelected: (v) {
                  switch (v) {
                    case 'unread':
                      n.markAllUnread();
                    case 'read':
                      n.markAllRead();
                    case 'archiveRead':
                      n.archiveRead();
                    case 'archive':
                      setState(() => _archive = true);
                    case 'clearArchive':
                      n.clearArchive();
                  }
                },
                itemBuilder: (_) => [
                  if (!_archive) ...[
                    const PopupMenuItem(value: 'read', child: ListTile(leading: Icon(Icons.mark_email_read_outlined), title: Text('Alle als gelesen'))),
                    const PopupMenuItem(value: 'unread', child: ListTile(leading: Icon(Icons.mark_email_unread_outlined), title: Text('Alle als ungelesen'))),
                    const PopupMenuItem(value: 'archiveRead', child: ListTile(leading: Icon(Icons.archive_outlined), title: Text('Gelesene archivieren'))),
                    PopupMenuItem(
                        value: 'archive',
                        child: ListTile(
                            leading: const Icon(Icons.inventory_2_outlined),
                            title: Text('Archiv (${n.items.where((i) => i.archived).length})'))),
                  ] else
                    const PopupMenuItem(value: 'clearArchive', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Archiv leeren'))),
                ],
              ),
            ],
          ),
          body: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 24), children: [
            if (!_archive)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  [
                    if (app.todoCount > 0) '${app.todoCount} offen',
                    '${n.unread} ungelesen',
                  ].join(' · '),
                  style: t.labelMedium?.copyWith(color: c.muted),
                ),
              ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                chip('Alle', _filter == null && !_unreadOnly, () => setState(() {
                      _filter = null;
                      _unreadOnly = false;
                    })),
                chip('Ungelesen', _unreadOnly, () => setState(() => _unreadOnly = !_unreadOnly), icon: Icons.markunread_outlined),
                for (final k in NotifyKind.values.where((k) => k != NotifyKind.ruhig))
                  chip(k.label, _filter == k, () => setState(() => _filter = _filter == k ? null : k),
                      icon: k.icon, color: k.colors(context).$1, soft: k.colors(context).$2),
              ]),
            ),
            if (all.isEmpty && (_archive || app.todoCount == 0))
              Padding(
                padding: const EdgeInsets.only(top: 60),
                child: Column(children: [
                  Icon(_archive ? Icons.inventory_2_outlined : Icons.notifications_none, size: 44, color: c.faint),
                  const SizedBox(height: 10),
                  Text(_archive ? 'Archiv ist leer' : (_unreadOnly ? 'Alles gelesen' : 'Keine Benachrichtigungen'), style: t.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                      _archive
                          ? 'Archivierte Meldungen bleiben 180 Tage und lassen sich wiederherstellen.'
                          : 'Hier landet alles, was Junels dir meldet – auch wenn du den Push weggewischt hast. Nichts verschwindet von selbst.',
                      textAlign: TextAlign.center,
                      style: t.bodySmall?.copyWith(color: c.muted)),
                ]),
              ),
            if (!_archive && (_filter == null || _filter == NotifyKind.aktion) && !_unreadOnly) _TodoSection(app: app, waiting: waiting),
            if (!_archive && (_filter != null && _filter != NotifyKind.aktion || _unreadOnly)) section('Wartet auf dich', waiting),
            if (!_archive) section('Geplant', planned),
            section('Heute', todayList),
            section(_archive ? 'Älter' : 'Früher', older),
            if (!_archive && all.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('Wischen: nach rechts = gelesen/ungelesen, nach links = archivieren. ⋮ für mehr.',
                    textAlign: TextAlign.center, style: t.bodySmall?.copyWith(color: c.faint)),
              ),
          ]),
        );
      },
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item});
  final InboxItem item;

  String _time(DateTime t) {
    final now = DateTime.now();
    final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (t.year == now.year && t.month == now.month && t.day == now.day) return hm;
    return '${t.day}.${t.month}. $hm';
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    final n = app.notifier;
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final (fg, _) = item.kind.colors(context);
    return Dismissible(
      key: ValueKey('${item.id}-${item.read}-${item.archived}'),
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        color: c.blueSoft,
        child: Icon(item.read ? Icons.mark_email_unread_outlined : Icons.mark_email_read_outlined, color: c.blue),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: c.raised,
        child: Icon(item.archived ? Icons.unarchive_outlined : Icons.archive_outlined, color: c.muted),
      ),
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          n.toggleRead(item); // bleibt in der Liste
          return false;
        }
        if (item.archived) {
          n.restore(item);
        } else {
          n.archive(item);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Archiviert: ${item.title}'),
            action: SnackBarAction(label: 'Rückgängig', onPressed: () => n.restore(item)),
          ));
        }
        return true;
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(Ui.r),
          border: Border(left: BorderSide(color: fg, width: 4), top: BorderSide(color: c.border), right: BorderSide(color: c.border), bottom: BorderSide(color: c.border)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(Ui.r),
          onTap: () {
            n.markRead(item);
            final target = item.target;
            if (target != null) {
              _leave(context);
              app.openConversationById(target);
            }
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              NotifyBadge(item.kind),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    NotifyChip(item.kind),
                    const SizedBox(width: 6),
                    Text(item.planned ? 'um ${_time(item.due!)}' : _time(item.at), style: t.labelSmall?.copyWith(color: c.muted)),
                    const Spacer(),
                    if (!item.read) Container(width: 8, height: 8, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
                    SizedBox(
                      width: 32,
                      height: 24,
                      child: PopupMenuButton<String>(
                        padding: EdgeInsets.zero,
                        iconSize: 18,
                        tooltip: 'Aktionen',
                        icon: Icon(Icons.more_vert, size: 18, color: c.muted),
                        onSelected: (v) {
                          switch (v) {
                            case 'open':
                              n.markRead(item);
                              _leave(context);
                              app.openConversationById(item.target!);
                            case 'read':
                              n.toggleRead(item);
                            case 'done':
                              n.markDone(item);
                            case 'snooze':
                              n.snooze(item, const Duration(hours: 1));
                            case 'archive':
                              item.archived ? n.restore(item) : n.archive(item);
                            case 'delete':
                              n.remove(item);
                          }
                        },
                        itemBuilder: (_) => [
                          if (item.target != null)
                            const PopupMenuItem(value: 'open', child: ListTile(leading: Icon(Icons.open_in_new), title: Text('Öffnen'))),
                          PopupMenuItem(
                              value: 'read',
                              child: ListTile(
                                  leading: Icon(item.read ? Icons.mark_email_unread_outlined : Icons.mark_email_read_outlined),
                                  title: Text(item.read ? 'Als ungelesen markieren' : 'Als gelesen markieren'))),
                          if (item.waiting || item.planned)
                            const PopupMenuItem(value: 'done', child: ListTile(leading: Icon(Icons.check_circle_outline), title: Text('Erledigt'))),
                          if (item.kind == NotifyKind.erinnerung && !item.done)
                            const PopupMenuItem(value: 'snooze', child: ListTile(leading: Icon(Icons.snooze), title: Text('Schlummern 1 Std'))),
                          PopupMenuItem(
                              value: 'archive',
                              child: ListTile(
                                  leading: Icon(item.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
                                  title: Text(item.archived ? 'Wiederherstellen' : 'Archivieren'))),
                          const PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Löschen'))),
                        ],
                      ),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Text(item.title,
                      style: t.titleSmall?.copyWith(
                          fontWeight: item.read ? FontWeight.w500 : FontWeight.w700, color: item.read ? c.muted : null)),
                  if (item.body.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(item.body, maxLines: 3, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: c.muted)),
                  ],
                  if (item.waiting || item.planned) ...[
                    const SizedBox(height: 8),
                    Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      if (item.target != null && item.waiting)
                        FilledButton.tonal(
                          style: FilledButton.styleFrom(backgroundColor: c.violetSoft, foregroundColor: c.violet, visualDensity: VisualDensity.compact),
                          onPressed: () {
                            n.markRead(item);
                            _leave(context);
                            app.openConversationById(item.target!);
                          },
                          child: const Text('Öffnen'),
                        ),
                      if (item.kind == NotifyKind.erinnerung) ...[
                        Icon(Icons.snooze, size: 16, color: c.muted),
                        for (final (label, d) in const [('10 Min', Duration(minutes: 10)), ('1 Std', Duration(hours: 1)), ('Morgen', Duration(hours: 24))])
                          ActionChip(
                            label: Text(label),
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              n.snooze(item, d);
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Geschlummert: ${item.title} ($label)')));
                            },
                          ),
                      ],
                    ]),
                    const SizedBox(height: 8),
                    SlideToDone(
                      label: item.planned ? 'Schon erledigt – schieben' : 'Erledigt – schieben',
                      color: fg,
                      soft: item.kind.colors(context).$2,
                      onDone: () => n.markDone(item),
                    ),
                  ],
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Raus aus der Seite (Handy: zurück; Desktop: in den Chat-Bereich).
void _leave(BuildContext context) {
  final nav = context.getInheritedWidgetOfExactType<ShellNav>();
  if (nav != null && nav.embedded) {
    nav.go(AppSection.chat);
  } else {
    Navigator.of(context).maybePop();
  }
}

/// „Zu tun“: alles, was auf dich wartet – aus Chats, Begleitungen, Gedächtnis und Erinnerungen.
class _TodoSection extends StatelessWidget {
  const _TodoSection({required this.app, required this.waiting});
  final AppController app;
  final List<InboxItem> waiting;

  @override
  Widget build(BuildContext context) {
    final approvals = app.pendingApprovals;
    final guides = app.activeGuides;
    final mem = app.memory.pending.length;
    final unseen = app.watchlist.unseen;
    final total = waiting.length + approvals.length + guides.length + mem;
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final cards = <Widget>[
      for (final (conv, entry, i) in approvals)
        _TodoCard(
          kind: NotifyKind.aktion,
          icon: Icons.fact_check_outlined,
          title: 'Freigabe: ${_actionLabel(entry.actions[i])}',
          detail: 'Im Chat „${conv.title}“ – wartet auf „Ausführen“ oder „Senden“',
          primary: ('Ansehen', () {
            _leave(context);
            app.selectConversation(conv);
          }),
          secondary: ('Verwerfen', () => app.updateAction(entry, i, {'status': 'discarded'})),
        ),
      for (final conv in guides)
        Builder(builder: (context) {
          final g = Guide.of(conv)!;
          final cur = g.current;
          return _TodoCard(
            kind: NotifyKind.aktion,
            icon: Icons.explore_outlined,
            title: 'Begleitung: ${g.goal}',
            detail: cur >= 0 ? 'Schritt ${cur + 1}/${g.steps.length}: ${g.steps[cur].text}${g.steps[cur].you ? ' (du)' : ''}' : g.note,
            primary: ('Weitermachen', () {
              _leave(context);
              app.selectConversation(conv);
            }),
            secondary: ('Beenden', () => app.endGuide(conv)),
          );
        }),
      if (mem > 0)
        _TodoCard(
          kind: NotifyKind.aktion,
          icon: Icons.psychology_outlined,
          title: '$mem ${mem == 1 ? 'Gedächtnis-Eintrag' : 'Gedächtnis-Einträge'} bestätigen',
          detail: 'Junels merkt sich das erst, wenn du es bestätigst',
          primary: ('Prüfen', () => openSection(context, AppSection.knowledge)),
        ),
      for (final i in waiting) _ItemTile(item: i),
      if (unseen > 0)
        _TodoCard(
          kind: NotifyKind.info,
          icon: Icons.radar,
          title: '$unseen neue ${unseen == 1 ? 'Meldung' : 'Meldungen'} in der Watchlist',
          detail: 'Noch nicht angesehen',
          primary: ('Ansehen', () => openSection(context, AppSection.watch)),
        ),
    ];
    if (cards.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel('Zu tun', padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
          trailing: total == 0 ? null : Text('$total offen', style: t.labelSmall?.copyWith(color: c.violet))),
      ...cards,
    ]);
  }

  static String _actionLabel(Map<String, String> a) => switch (a['type']) {
        'app' => a['body'] ?? 'App-Aktion',
        'email' => 'E-Mail an ${a['name']?.isNotEmpty == true ? a['name'] : a['to'] ?? ''}',
        'whatsapp' => 'WhatsApp an ${a['name']?.isNotEmpty == true ? a['name'] : a['to'] ?? ''}',
        _ => a['body'] ?? a['subject'] ?? a['type'] ?? 'Aktion',
      };
}

class _TodoCard extends StatelessWidget {
  const _TodoCard({required this.kind, required this.icon, required this.title, required this.detail, required this.primary, this.secondary});
  final NotifyKind kind;
  final IconData icon;
  final String title, detail;
  final (String, VoidCallback) primary;
  final (String, VoidCallback)? secondary;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final (fg, bg) = kind.colors(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(Ui.r),
        border: Border(left: BorderSide(color: fg, width: 4), top: BorderSide(color: c.border), right: BorderSide(color: c.border), bottom: BorderSide(color: c.border)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 36, height: 36, decoration: BoxDecoration(color: bg, shape: BoxShape.circle), child: Icon(icon, size: 20, color: fg)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            NotifyChip(kind),
            const SizedBox(height: 4),
            Text(title, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: c.muted)),
            ],
            const SizedBox(height: 6),
            Wrap(spacing: 6, children: [
              FilledButton.tonal(
                style: FilledButton.styleFrom(backgroundColor: bg, foregroundColor: fg, visualDensity: VisualDensity.compact),
                onPressed: primary.$2,
                child: Text(primary.$1),
              ),
              if (secondary != null) TextButton(onPressed: secondary!.$2, child: Text(secondary!.$1)),
            ]),
          ]),
        ),
      ]),
    );
  }
}
