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

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final n = app.notifier;
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    return ListenableBuilder(
      listenable: n,
      builder: (context, _) {
        final all = [for (final i in n.items) if (i.kind != NotifyKind.ruhig && (_filter == null || i.kind == _filter)) i];
        final waiting = all.where((i) => i.waiting).toList();
        final planned = all.where((i) => i.planned).toList()..sort((a, b) => a.due!.compareTo(b.due!));
        final now = DateTime.now();
        bool today(InboxItem i) => i.at.year == now.year && i.at.month == now.month && i.at.day == now.day;
        final todayList = all.where((i) => !i.waiting && !i.planned && today(i)).toList();
        final older = all.where((i) => !i.waiting && !i.planned && !today(i)).toList();

        Widget section(String title, List<InboxItem> list) => list.isEmpty
            ? const SizedBox.shrink()
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SectionLabel(title, padding: const EdgeInsets.fromLTRB(4, 14, 4, 6)),
                for (final i in list) _ItemTile(item: i),
              ]);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Benachrichtigungen'),
            actions: [
              IconButton(tooltip: 'Alle gelesen', icon: const Icon(Icons.done_all), onPressed: n.unread == 0 ? null : n.markAllRead),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'clear') n.clearRead();
                },
                itemBuilder: (_) => const [PopupMenuItem(value: 'clear', child: Text('Gelesene entfernen'))],
              ),
            ],
          ),
          body: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 24), children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(label: const Text('Alle'), selected: _filter == null, onSelected: (_) => setState(() => _filter = null)),
                ),
                for (final k in NotifyKind.values.where((k) => k != NotifyKind.ruhig))
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      avatar: Icon(k.icon, size: 16, color: k.colors(context).$1),
                      label: Text(k.label),
                      selected: _filter == k,
                      selectedColor: k.colors(context).$2,
                      onSelected: (_) => setState(() => _filter = _filter == k ? null : k),
                    ),
                  ),
              ]),
            ),
            if (all.isEmpty && app.todoCount == 0)
              Padding(
                padding: const EdgeInsets.only(top: 60),
                child: Column(children: [
                  Icon(Icons.notifications_none, size: 44, color: c.faint),
                  const SizedBox(height: 10),
                  Text('Keine Mitteilungen', style: t.titleSmall),
                  const SizedBox(height: 4),
                  Text('Hier landet alles, was Junels dir meldet – auch wenn du den Push weggewischt hast.',
                      textAlign: TextAlign.center, style: t.bodySmall?.copyWith(color: c.muted)),
                ]),
              ),
            if (_filter == null || _filter == NotifyKind.aktion) _TodoSection(app: app, waiting: waiting),
            if (_filter != null && _filter != NotifyKind.aktion) section('Wartet auf dich', waiting),
            section('Geplant', planned),
            section('Heute', todayList),
            section('Früher', older),
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
      key: ValueKey(item.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: c.redSoft,
        child: Icon(Icons.delete_outline, color: c.red),
      ),
      onDismissed: (_) => n.remove(item),
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
                  ]),
                  const SizedBox(height: 4),
                  Text(item.title, style: t.titleSmall?.copyWith(fontWeight: item.read ? FontWeight.w500 : FontWeight.w700)),
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
