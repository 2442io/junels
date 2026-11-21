// Watchlist: Webseiten und Themen beobachten.

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_scope.dart';
import 'markdown_lite.dart';
import 'theme.dart';

String _two(int v) => v.toString().padLeft(2, '0');

String _ago(DateTime? d) {
  if (d == null) return 'noch nie';
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return 'gerade eben';
  if (diff.inMinutes < 60) return 'vor ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'vor ${diff.inHours} h';
  return '${d.day}.${d.month}. ${_two(d.hour)}:${_two(d.minute)}';
}

class WatchlistPage extends StatelessWidget {
  const WatchlistPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final items = app.watchlist.items;
    final next = app.watchlist.nextDue;
    return Scaffold(
      appBar: AppBar(title: const Text('Watchlist'), actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: FilledButton.icon(
            onPressed: () => editWatch(context),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Beobachten'),
          ),
        ),
      ]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 48),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const PageHeader(
                  icon: Icons.radar,
                  title: 'Watchlist',
                  subtitle: 'Junels prüft Webseiten und Themen regelmäßig und meldet sich, wenn es Neues gibt.',
                ),
                Row(children: [
                  _Stat('Beobachtet', '${items.length}', c.mint),
                  const SizedBox(width: 10),
                  _Stat('Neu', '${app.watchlist.unseen}', app.watchlist.unseen > 0 ? c.amber : c.faint),
                  const SizedBox(width: 10),
                  _Stat('Nächste Prüfung',
                      next == null ? '–' : (next.isBefore(DateTime.now()) ? 'jetzt' : '${_two(next.hour)}:${_two(next.minute)}'), c.blue),
                ]),
                const SectionLabel('Einträge', padding: EdgeInsets.fromLTRB(4, 22, 4, 8)),
                if (items.isEmpty)
                  Panel(
                    child: EmptyHint(
                      icon: Icons.radar,
                      title: 'Noch nichts in der Watchlist',
                      text: 'Beobachte z. B. eine Produktseite, einen Blog, eine Stellenbörse – oder ein Thema wie „Anthropic“ oder „Wiener Linien Störung“.',
                      action: FilledButton.icon(
                        onPressed: () => editWatch(context),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Ersten Eintrag anlegen'),
                      ),
                    ),
                  ),
                for (final i in items) Padding(padding: const EdgeInsets.only(bottom: 8), child: _WatchCard(item: i)),
                const SizedBox(height: 12),
                Text(
                  'Geprüft wird, solange Junels läuft – am Mac auch im Hintergrund, unter Android über den Hintergrunddienst. '
                  'Mit dem Anlegen erlaubst du den Abruf genau dieser Seite bzw. Suche.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.color);
  final String label;
  final String value;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Expanded(
      child: Panel(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(), style: TextStyle(fontSize: 10.5, letterSpacing: 1.1, color: c.faint, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(fontFamily: Ui.mono, fontSize: 18, fontWeight: FontWeight.w500, color: color)),
        ]),
      ),
    );
  }
}

class _WatchCard extends StatelessWidget {
  const _WatchCard({required this.item});
  final WatchItem item;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final checking = app.watchlist.checkingId == item.id;
    final page = item.kind == WatchKind.page;
    final chip = item.lastError != null
        ? StatusChip('Fehler', color: c.red, soft: c.redSoft, dense: true)
        : item.unseen > 0
            ? StatusChip('${item.unseen} neu', color: c.amber, soft: c.amberSoft, dense: true)
            : (!item.enabled
                ? StatusChip('Pausiert', color: c.muted, soft: c.raised, dense: true)
                : StatusChip('Aktuell', color: c.mint, soft: c.mintSoft, dense: true));
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _WatchDetail(id: item.id))),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: page ? c.blueSoft : c.violetSoft, borderRadius: BorderRadius.circular(11)),
          child: Icon(page ? Icons.language : Icons.tag, color: page ? c.blue : c.violet, size: 21),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall)),
              const SizedBox(width: 8),
              chip,
            ]),
            const SizedBox(height: 3),
            MonoText('${page ? (Uri.tryParse(item.target)?.host.isNotEmpty == true ? Uri.parse(item.target).host : item.target) : '„${item.target}“'}'
                ' · ${item.intervalLabel} · geprüft ${_ago(item.lastCheck)}'),
            if (item.events.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(item.events.first.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall),
            ],
          ]),
        ),
        checking
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            : IconButton(
                tooltip: 'Jetzt prüfen',
                icon: const Icon(Icons.refresh),
                onPressed: () => app.watchlist.check(item),
              ),
        Switch(
          value: item.enabled,
          onChanged: (v) {
            item.enabled = v;
            app.watchlist.upsert(item, checkNow: false);
          },
        ),
      ]),
    );
  }
}

class _WatchDetail extends StatefulWidget {
  const _WatchDetail({required this.id});
  final String id;
  @override
  State<_WatchDetail> createState() => _WatchDetailState();
}

class _WatchDetailState extends State<_WatchDetail> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = AppScope.read(context);
      final item = app.watchlist.items.where((x) => x.id == widget.id).firstOrNull;
      if (item != null) app.watchlist.markSeen(item);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final item = app.watchlist.items.where((x) => x.id == widget.id).firstOrNull;
    if (item == null) return const Scaffold();
    final checking = app.watchlist.checkingId == item.id;
    return Scaffold(
      appBar: AppBar(title: Text(item.title), actions: [
        IconButton(tooltip: 'Bearbeiten', icon: const Icon(Icons.edit_outlined), onPressed: () => editWatch(context, existing: item)),
        IconButton(
          tooltip: 'Entfernen',
          icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            final nav = Navigator.of(context);
            await app.watchlist.remove(item);
            nav.pop();
          },
        ),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: FilledButton.tonalIcon(
            onPressed: checking ? null : () => app.watchlist.check(item),
            icon: checking
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh, size: 18),
            label: const Text('Jetzt prüfen'),
          ),
        ),
      ]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Panel(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      StatusChip(item.kind == WatchKind.page ? 'Webseite' : 'Thema',
                          color: item.kind == WatchKind.page ? c.blue : c.violet, dense: true),
                      const SizedBox(width: 8),
                      StatusChip(item.intervalLabel, color: c.muted, soft: c.raised, dense: true),
                      if (item.summarize) ...[
                        const SizedBox(width: 8),
                        StatusChip('mit Zusammenfassung', color: c.mint, soft: c.mintSoft, dense: true),
                      ],
                    ]),
                    const SizedBox(height: 10),
                    SelectableText(item.target, style: TextStyle(fontFamily: Ui.mono, fontSize: 13, color: c.muted)),
                    const SizedBox(height: 6),
                    Text('Zuletzt geprüft: ${_ago(item.lastCheck)}', style: t.bodySmall),
                    if (item.lastError != null) ...[
                      const SizedBox(height: 6),
                      Text('Letzter Fehler: ${item.lastError}', style: t.bodySmall?.copyWith(color: c.red)),
                    ],
                  ]),
                ),
                const SectionLabel('Verlauf', padding: EdgeInsets.fromLTRB(4, 22, 4, 8)),
                if (item.events.isEmpty)
                  Panel(
                    child: EmptyHint(
                      icon: Icons.hourglass_empty,
                      title: 'Noch keine Änderungen',
                      text: item.lastCheck == null
                          ? 'Die erste Prüfung merkt sich den Ausgangsstand.'
                          : 'Seit dem Ausgangsstand hat sich nichts geändert.',
                    ),
                  ),
                for (final e in item.events)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Panel(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          Expanded(child: Text(e.title, style: t.titleSmall)),
                          MonoText('${e.time.day}.${e.time.month}. ${_two(e.time.hour)}:${_two(e.time.minute)}', size: 11),
                        ]),
                        if (e.detail.isNotEmpty) ...[const SizedBox(height: 8), MarkdownLite(e.detail)],
                        if (e.links.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          for (final l in e.links.take(12))
                            ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                              leading: Icon(Icons.north_east, size: 16, color: c.mint),
                              title: Text(l['title'] ?? l['link'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
                              subtitle: MonoText(Uri.tryParse(l['link'] ?? '')?.host ?? '', size: 10.5),
                              onTap: l['link'] == null ? null : () => openExternalLink(context, l['link']!),
                            ),
                        ],
                      ]),
                    ),
                  ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

/// Eintrag anlegen oder bearbeiten.
Future<void> editWatch(BuildContext context, {WatchItem? existing}) async {
  final app = AppScope.read(context);
  var kind = existing?.kind ?? WatchKind.page;
  final title = TextEditingController(text: existing?.title ?? '');
  final target = TextEditingController(text: existing?.target ?? '');
  var interval = existing?.intervalMinutes ?? 360;
  var summarize = existing?.summarize ?? true;
  var notify = existing?.notify ?? true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text(existing == null ? 'Beobachten' : 'Eintrag bearbeiten'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SegmentedButton<WatchKind>(
                segments: const [
                  ButtonSegment(value: WatchKind.page, label: Text('Webseite'), icon: Icon(Icons.language, size: 18)),
                  ButtonSegment(value: WatchKind.topic, label: Text('Thema'), icon: Icon(Icons.tag, size: 18)),
                ],
                selected: {kind},
                showSelectedIcon: false,
                onSelectionChanged: (v) => set(() => kind = v.first),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: target,
                autofocus: existing == null,
                keyboardType: kind == WatchKind.page ? TextInputType.url : TextInputType.text,
                decoration: InputDecoration(
                  labelText: kind == WatchKind.page ? 'Adresse' : 'Suchbegriffe',
                  hintText: kind == WatchKind.page ? 'https://beispiel.at/jobs' : 'z. B. Anthropic Claude',
                ),
              ),
              const SizedBox(height: 12),
              TextField(controller: title, decoration: const InputDecoration(labelText: 'Name (optional)')),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: const [60, 180, 360, 720, 1440, 10080].contains(interval) ? interval : 360,
                decoration: const InputDecoration(labelText: 'Prüfen'),
                items: const [
                  DropdownMenuItem(value: 60, child: Text('stündlich')),
                  DropdownMenuItem(value: 180, child: Text('alle 3 Stunden')),
                  DropdownMenuItem(value: 360, child: Text('alle 6 Stunden')),
                  DropdownMenuItem(value: 720, child: Text('alle 12 Stunden')),
                  DropdownMenuItem(value: 1440, child: Text('täglich')),
                  DropdownMenuItem(value: 10080, child: Text('wöchentlich')),
                ],
                onChanged: (v) => set(() => interval = v ?? interval),
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Änderungen zusammenfassen'),
                subtitle: const Text('Der Agent beschreibt kurz, was neu ist.'),
                value: summarize,
                onChanged: (v) => set(() => summarize = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Push-Nachricht bei Neuem'),
                value: notify,
                onChanged: (v) => set(() => notify = v),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Speichern')),
        ],
      ),
    ),
  );
  if (ok != true || target.text.trim().isEmpty) return;
  var tgt = target.text.trim();
  if (kind == WatchKind.page && !tgt.startsWith('http')) tgt = 'https://$tgt';
  String name = title.text.trim();
  if (name.isEmpty) {
    name = kind == WatchKind.page ? (Uri.tryParse(tgt)?.host.replaceFirst('www.', '') ?? tgt) : tgt;
  }
  final changedTarget = existing != null && (existing.target != tgt || existing.kind != kind);
  final item = existing ?? WatchItem(id: newId(), kind: kind, title: name, target: tgt);
  item
    ..kind = kind
    ..title = name
    ..target = tgt
    ..intervalMinutes = interval
    ..summarize = summarize
    ..notify = notify;
  if (changedTarget) {
    item
      ..fingerprint = null
      ..snapshot = ''
      ..seenLinks.clear();
  }
  await app.watchlist.upsert(item, checkNow: existing == null || changedTarget);
}
