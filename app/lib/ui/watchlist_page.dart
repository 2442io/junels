// Watchlist: Webseiten und Themen beobachten.
// Jede neue Beobachtung ist ein Prozess im Canvas (Auslöser „Beobachten“ → … → Push),
// die Liste erscheint auf der Seite „Prozesse“. Ältere Einträge ohne Prozess laufen weiter.

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_scope.dart';
import 'flows_page.dart';
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

// ================================================================ Entwurf + Felder

/// Was beobachtet werden soll (für Dialog und Canvas-Auslöser).
class WatchDraft {
  WatchDraft({
    this.kind = WatchKind.page,
    this.target = '',
    this.promptMode = false,
    this.recentOnly = false,
    this.interval = 60,
    this.query = '',
    this.name = '',
    this.summarize = true,
    this.notify = true,
  });
  WatchKind kind;
  String target;
  bool promptMode;
  bool recentOnly;
  int interval;
  String query;
  String name;
  bool summarize;
  bool notify;

  String get normalizedTarget {
    final t = target.trim();
    if (kind == WatchKind.page && t.isNotEmpty && !t.startsWith('http')) return 'https://$t';
    return t;
  }

  String get defaultName {
    if (name.trim().isNotEmpty) return name.trim();
    final t = normalizedTarget;
    if (kind == WatchKind.page) return Uri.tryParse(t)?.host.replaceFirst('www.', '') ?? t;
    return t.length > 40 ? '${t.substring(0, 40)}…' : t;
  }

  WatchItem toProbe() => WatchItem(
        id: 'probe',
        kind: kind,
        title: defaultName,
        target: normalizedTarget,
        promptMode: kind == WatchKind.topic && promptMode,
        query: query,
        recentOnly: recentOnly,
      );

  factory WatchDraft.fromNode(FlowNode n) => WatchDraft(
        kind: n.str('watchKind', 'page') == 'topic' ? WatchKind.topic : WatchKind.page,
        target: n.str('watchTarget'),
        promptMode: n.config['promptMode'] == true,
        recentOnly: n.config['recentOnly'] == true,
        interval: (n.config['interval'] as num?)?.toInt() ?? 60,
        query: n.str('watchQuery'),
      );

  void applyTo(FlowNode n) {
    n.config
      ..['mode'] = 'watch'
      ..['watchInline'] = true
      ..['watchKind'] = kind == WatchKind.topic ? 'topic' : 'page'
      ..['watchTarget'] = target.trim()
      ..['interval'] = interval
      ..['promptMode'] = kind == WatchKind.topic && promptMode
      ..['recentOnly'] = recentOnly
      ..['watchQuery'] = query.trim();
  }

  factory WatchDraft.fromItem(WatchItem i) => WatchDraft(
        kind: i.kind,
        target: i.target,
        promptMode: i.promptMode,
        recentOnly: i.recentOnly,
        interval: i.intervalMinutes,
        query: i.query,
        name: i.title,
        summarize: i.summarize,
        notify: i.notify,
      );
}

/// Eingabefelder für eine Beobachtung – im Dialog und im Canvas-Auslöser.
class WatchFields extends StatefulWidget {
  const WatchFields({super.key, required this.draft, required this.onChanged});
  final WatchDraft draft;
  final VoidCallback onChanged;
  @override
  State<WatchFields> createState() => _WatchFieldsState();
}

class _WatchFieldsState extends State<WatchFields> {
  late final _target = TextEditingController(text: widget.draft.target);
  late final _query = TextEditingController(text: widget.draft.query);
  WatchPreview? _preview;
  bool _testing = false;
  bool _deriving = false;

  WatchDraft get d => widget.draft;

  @override
  void dispose() {
    _target.dispose();
    _query.dispose();
    super.dispose();
  }

  void _changed() {
    setState(() => _preview = null);
    widget.onChanged();
  }

  void _insert(String s) {
    final t = _target.text;
    final sel = _target.selection;
    final at = sel.isValid ? sel.baseOffset : t.length;
    final pre = t.substring(0, at);
    final add = (pre.isEmpty || pre.endsWith(' ') ? '' : ' ') + s;
    _target.text = '$pre$add${t.substring(at)}';
    // Cursor in die Anführungszeichen bzw. ans Ende
    final cursor = s == '""' ? pre.length + add.length - 1 : pre.length + add.length;
    _target.selection = TextSelection.collapsed(offset: cursor);
    d.target = _target.text;
    _changed();
  }

  Future<void> _derive() async {
    final app = AppScope.read(context);
    setState(() => _deriving = true);
    try {
      final q = await app.watchlist.deriveQuery(d.target);
      _query.text = q;
      d.query = q;
      _changed();
    } finally {
      if (mounted) setState(() => _deriving = false);
    }
  }

  Future<void> _test() async {
    final app = AppScope.read(context);
    if (d.target.trim().isEmpty) return;
    setState(() {
      _testing = true;
      _preview = null;
    });
    if (d.kind == WatchKind.topic && d.promptMode && d.query.trim().isEmpty) await _derive();
    final p = await app.watchlist.preview(d.toProbe());
    if (mounted) {
      setState(() {
        _testing = false;
        _preview = p;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final topic = d.kind == WatchKind.topic;
    final sq = topic && !d.promptMode ? SearchQuery.parse(d.target) : null;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedButton<WatchKind>(
        segments: const [
          ButtonSegment(value: WatchKind.page, label: Text('Webseite'), icon: Icon(Icons.language, size: 18)),
          ButtonSegment(value: WatchKind.topic, label: Text('Thema'), icon: Icon(Icons.travel_explore, size: 18)),
        ],
        selected: {d.kind},
        showSelectedIcon: false,
        onSelectionChanged: (v) {
          d.kind = v.first;
          _changed();
        },
      ),
      if (topic) ...[
        const SizedBox(height: 10),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Suchanfrage'), icon: Icon(Icons.search, size: 18)),
            ButtonSegment(value: true, label: Text('Beschreibung'), icon: Icon(Icons.edit_note, size: 18)),
          ],
          selected: {d.promptMode},
          showSelectedIcon: false,
          onSelectionChanged: (v) {
            d.promptMode = v.first;
            _changed();
          },
        ),
      ],
      const SizedBox(height: 12),
      TextField(
        controller: _target,
        keyboardType: topic ? (d.promptMode ? TextInputType.multiline : TextInputType.text) : TextInputType.url,
        minLines: topic && d.promptMode ? 2 : 1,
        maxLines: topic && d.promptMode ? 5 : 1,
        decoration: InputDecoration(
          labelText: !topic ? 'Adresse' : (d.promptMode ? 'Was soll Junels für dich beobachten?' : 'Suchanfrage (wie bei Google)'),
          hintText: !topic
              ? 'https://beispiel.at/jobs'
              : (d.promptMode
                  ? 'z. B. Neue Förderungen für E-Autos in Österreich – keine Werbung, nur offizielle Stellen'
                  : 'z. B. "Wiener Linien" Störung -Wartung site:orf.at'),
          helperText: !topic
              ? 'Junels meldet neue Einträge und Textänderungen auf dieser Seite.'
              : (d.promptMode
                  ? 'Junels macht daraus eine Suche und der Agent prüft jeden neuen Treffer, ob er wirklich passt.'
                  : '"genaue Phrase" · -ausschließen · site:domain.at · OR für Alternativen'),
          helperMaxLines: 3,
        ),
        onChanged: (v) {
          d.target = v;
          _changed();
        },
      ),
      if (topic && !d.promptMode) ...[
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final (label, ins) in const [('"Phrase"', '""'), ('– ohne', '-'), ('site:', 'site:'), ('OR', 'OR ')])
            ActionChip(label: Text(label, style: const TextStyle(fontFamily: Ui.mono, fontSize: 12)), onPressed: () => _insert(ins)),
        ]),
        if (sq != null && sq.describe().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('Verstanden: ${sq.describe()}', style: t.bodySmall?.copyWith(color: c.mint)),
        ],
      ],
      if (topic && d.promptMode) ...[
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              controller: _query,
              decoration: const InputDecoration(
                labelText: 'Daraus gesucht wird (optional anpassen)',
                hintText: 'wird automatisch erzeugt',
                isDense: true,
              ),
              onChanged: (v) {
                d.query = v;
                _changed();
              },
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Suchanfrage aus der Beschreibung erzeugen',
            onPressed: _deriving || d.target.trim().isEmpty ? null : _derive,
            icon: _deriving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_awesome),
          ),
        ]),
      ],
      if (topic)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Nur Aktuelles (letzte 24 Stunden)'),
          value: d.recentOnly,
          onChanged: (v) {
            d.recentOnly = v ?? false;
            _changed();
          },
        ),
      const SizedBox(height: 8),
      DropdownButtonFormField<int>(
        initialValue: WatchItem.intervalOptions.any((o) => o.$1 == d.interval) ? d.interval : 60,
        decoration: const InputDecoration(labelText: 'Prüfen'),
        items: [for (final (m, l) in WatchItem.intervalOptions) DropdownMenuItem(value: m, child: Text(l))],
        onChanged: (v) {
          d.interval = v ?? d.interval;
          _changed();
        },
      ),
      if (d.interval < 15)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Minütlich prüft Junels, solange die App läuft. Im Hintergrund lässt Android oft nur alle paar Minuten zu.',
            style: t.bodySmall,
          ),
        ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _testing || d.target.trim().isEmpty ? null : _test,
          icon: _testing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.science_outlined, size: 18),
          label: Text(_testing ? 'Teste …' : 'Jetzt testen'),
        ),
      ),
      if (_preview != null) ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _preview!.ok ? c.mintSoft : c.amberSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(_preview!.ok ? Icons.check_circle_outline : Icons.info_outline, size: 16, color: _preview!.ok ? c.mint : c.amber),
              const SizedBox(width: 6),
              Expanded(child: Text(_preview!.message, style: t.bodySmall?.copyWith(color: _preview!.ok ? c.mint : c.amber))),
            ]),
            for (final h in _preview!.hits.take(5))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('• ${h['title'] ?? h['link']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: t.bodySmall),
              ),
          ]),
        ),
      ],
    ]);
  }
}

// ======================================================================== Dialog

/// Neue Beobachtung (als Prozess im Canvas) oder älteren Eintrag bearbeiten.
Future<void> showWatchDialog(BuildContext context, {WatchItem? existing, bool openCanvas = true}) async {
  final app = AppScope.read(context);
  final nav = Navigator.of(context);
  final draft = existing == null ? WatchDraft() : WatchDraft.fromItem(existing);
  final name = TextEditingController(text: existing?.title ?? '');
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text(existing == null ? 'Beobachten' : 'Beobachtung bearbeiten'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              WatchFields(draft: draft, onChanged: () => set(() {})),
              const SizedBox(height: 12),
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name (optional)'),
                onChanged: (v) => draft.name = v,
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Änderungen zusammenfassen'),
                subtitle: const Text('Der Agent beschreibt kurz, was neu ist.'),
                value: draft.summarize,
                onChanged: (v) => set(() => draft.summarize = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Push-Nachricht bei Neuem'),
                value: draft.notify,
                onChanged: (v) => set(() => draft.notify = v),
              ),
              if (existing == null)
                Text('Wird als Prozess angelegt – im Canvas kannst du weitere Schritte anhängen (z. B. Web-API, Notiz, Bedingung).',
                    style: Theme.of(ctx).textTheme.bodySmall),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: draft.target.trim().isEmpty ? null : () => Navigator.pop(ctx, true), child: const Text('Speichern')),
        ],
      ),
    ),
  );
  if (ok != true || draft.target.trim().isEmpty) return;
  if (draft.kind == WatchKind.topic && draft.promptMode && draft.query.trim().isEmpty) {
    draft.query = await app.watchlist.deriveQuery(draft.target);
  }
  if (existing == null) {
    final wf = app.flows.watchFlow(
      name: draft.defaultName,
      kind: draft.kind,
      target: draft.normalizedTarget,
      interval: draft.interval,
      promptMode: draft.kind == WatchKind.topic && draft.promptMode,
      recentOnly: draft.recentOnly,
      query: draft.query.trim(),
      summarize: draft.summarize,
      notify: draft.notify,
    );
    await app.flows.upsert(wf);
    if (openCanvas) nav.push(MaterialPageRoute(builder: (_) => FlowEditor(id: wf.id)));
    return;
  }
  final tgt = draft.normalizedTarget;
  final changedTarget = existing.target != tgt || existing.kind != draft.kind || existing.promptMode != draft.promptMode;
  existing
    ..kind = draft.kind
    ..title = draft.defaultName
    ..target = tgt
    ..promptMode = draft.kind == WatchKind.topic && draft.promptMode
    ..query = draft.query.trim()
    ..recentOnly = draft.recentOnly
    ..intervalMinutes = draft.interval
    ..summarize = draft.summarize
    ..notify = draft.notify;
  if (changedTarget) {
    existing
      ..fingerprint = null
      ..snapshot = ''
      ..seenLinks.clear();
  }
  await app.watchlist.upsert(existing, checkNow: changedTarget);
}

/// Alter Name (kompatibel).
Future<void> editWatch(BuildContext context, {WatchItem? existing}) => showWatchDialog(context, existing: existing);

// ======================================================================== Liste

/// Abschnitt „Beobachtungen“ (auf der Prozesse-Seite und der Watchlist-Seite).
class WatchSection extends StatelessWidget {
  const WatchSection({super.key, this.showHeader = true});
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final items = app.watchlist.items;
    final next = app.watchlist.nextDue;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (showHeader)
        SectionLabel('Beobachtungen',
            padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (app.watchlist.unseen > 0) ...[
                StatusChip('${app.watchlist.unseen} neu', color: c.amber, soft: c.amberSoft, dense: true),
                const SizedBox(width: 8),
              ],
              if (next != null) MonoText('nächste ${next.isBefore(DateTime.now()) ? 'jetzt' : '${_two(next.hour)}:${_two(next.minute)}'}', color: c.faint),
            ])),
      if (items.isEmpty)
        Panel(
          child: EmptyHint(
            icon: Icons.radar,
            title: 'Noch nichts beobachtet',
            text: 'Beobachte eine Produktseite, eine Stellenbörse – oder ein Thema wie „Wiener Linien Störung“. '
                'Junels meldet sich, wenn es Neues gibt.',
            action: FilledButton.icon(
              onPressed: () => showWatchDialog(context),
              icon: const Icon(Icons.radar, size: 18),
              label: const Text('Beobachten'),
            ),
          ),
        ),
      for (final i in items) Padding(padding: const EdgeInsets.only(bottom: 8), child: _WatchCard(item: i)),
    ]);
  }
}

class WatchlistPage extends StatelessWidget {
  const WatchlistPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Watchlist'), actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: FilledButton.icon(
            onPressed: () => showWatchDialog(context),
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
                  subtitle: 'Junels prüft Webseiten und Themen regelmäßig – auch minütlich – und meldet sich, wenn es Neues gibt. '
                      'Jede Beobachtung ist ein Prozess im Canvas.',
                ),
                const WatchSection(),
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
    final flow = item.flowId == null ? null : app.flows.flows.where((f) => f.id == item.flowId).firstOrNull;
    final chip = item.lastError != null
        ? StatusChip('Fehler', color: c.red, soft: c.redSoft, dense: true)
        : item.unseen > 0
            ? StatusChip('${item.unseen} neu', color: c.amber, soft: c.amberSoft, dense: true)
            : (!item.enabled
                ? StatusChip('Pausiert', color: c.muted, soft: c.raised, dense: true)
                : StatusChip('Aktuell', color: c.mint, soft: c.mintSoft, dense: true));
    final what = page
        ? (Uri.tryParse(item.target)?.host.isNotEmpty == true ? Uri.parse(item.target).host : item.target)
        : (item.promptMode ? '„${item.searchQuery}“ (geprüft vom Agenten)' : '„${item.target}“');
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _WatchDetail(id: item.id))),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: page ? c.blueSoft : c.violetSoft, borderRadius: BorderRadius.circular(11)),
          child: Icon(page ? Icons.language : Icons.travel_explore, color: page ? c.blue : c.violet, size: 21),
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
            MonoText('$what · ${item.intervalLabel} · geprüft ${_ago(item.lastCheck)}'),
            if (item.events.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(item.events.first.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall),
            ],
          ]),
        ),
        if (flow != null)
          IconButton(
            tooltip: 'Im Canvas öffnen',
            icon: const Icon(Icons.account_tree_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FlowEditor(id: flow.id))),
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
          value: flow?.enabled ?? item.enabled,
          onChanged: (v) {
            if (flow != null) {
              flow.enabled = v;
              app.flows.upsert(flow);
            } else {
              item.enabled = v;
              app.watchlist.upsert(item, checkNow: false);
            }
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
    final flow = item.flowId == null ? null : app.flows.flows.where((f) => f.id == item.flowId).firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(item.title), actions: [
        if (flow != null)
          IconButton(
            tooltip: 'Im Canvas bearbeiten',
            icon: const Icon(Icons.account_tree_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FlowEditor(id: flow.id))),
          )
        else
          IconButton(tooltip: 'Bearbeiten', icon: const Icon(Icons.edit_outlined), onPressed: () => showWatchDialog(context, existing: item)),
        IconButton(
          tooltip: 'Entfernen',
          icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            final nav = Navigator.of(context);
            if (flow != null) {
              await app.flows.remove(flow);
            } else {
              await app.watchlist.remove(item);
            }
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
                    Wrap(spacing: 8, runSpacing: 6, children: [
                      StatusChip(item.kind == WatchKind.page ? 'Webseite' : (item.promptMode ? 'Thema (Beschreibung)' : 'Thema'),
                          color: item.kind == WatchKind.page ? c.blue : c.violet, dense: true),
                      StatusChip(item.intervalLabel, color: c.muted, soft: c.raised, dense: true),
                      if (item.recentOnly) StatusChip('nur Aktuelles', color: c.muted, soft: c.raised, dense: true),
                      if (flow != null) StatusChip('Prozess „${flow.name}“', color: c.mint, soft: c.mintSoft, dense: true),
                    ]),
                    const SizedBox(height: 10),
                    SelectableText(item.target, style: TextStyle(fontFamily: Ui.mono, fontSize: 13, color: c.muted)),
                    if (item.promptMode && item.query.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text('Gesucht wird: ${item.query}', style: t.bodySmall),
                    ],
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
