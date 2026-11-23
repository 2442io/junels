// Mitteilungen: alle Benachrichtigungen nach Art (Aktion, Warnung, Erinnerung, Ergebnis, Info) – nichts geht verloren.

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/notifications.dart';
import 'notify_style.dart';
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
        final now = DateTime.now();
        bool today(InboxItem i) => i.at.year == now.year && i.at.month == now.month && i.at.day == now.day;
        final todayList = all.where((i) => !i.waiting && today(i)).toList();
        final older = all.where((i) => !i.waiting && !today(i)).toList();

        Widget section(String title, List<InboxItem> list) => list.isEmpty
            ? const SizedBox.shrink()
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SectionLabel(title, padding: const EdgeInsets.fromLTRB(4, 14, 4, 6)),
                for (final i in list) _ItemTile(item: i),
              ]);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Mitteilungen'),
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
            if (all.isEmpty)
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
            section('Wartet auf dich', waiting),
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
              Navigator.of(context).pop();
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
                    Text(_time(item.at), style: t.labelSmall?.copyWith(color: c.muted)),
                    const Spacer(),
                    if (!item.read) Container(width: 8, height: 8, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
                  ]),
                  const SizedBox(height: 4),
                  Text(item.title, style: t.titleSmall?.copyWith(fontWeight: item.read ? FontWeight.w500 : FontWeight.w700)),
                  if (item.body.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(item.body, maxLines: 3, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: c.muted)),
                  ],
                  if (item.waiting)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(spacing: 6, children: [
                        if (item.target != null)
                          FilledButton.tonal(
                            style: FilledButton.styleFrom(backgroundColor: c.violetSoft, foregroundColor: c.violet, visualDensity: VisualDensity.compact),
                            onPressed: () {
                              n.markRead(item);
                              Navigator.of(context).pop();
                              app.openConversationById(item.target!);
                            },
                            child: const Text('Öffnen'),
                          ),
                        TextButton(onPressed: () => n.markDone(item), child: const Text('Erledigt')),
                      ]),
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
