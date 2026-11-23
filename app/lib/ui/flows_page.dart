// Prozesse: Liste, Beobachtungen, Erzeugen per Prompt und Canvas-Editor (Bausteine verbinden wie bei n8n).
//
// Canvas: Bausteine per Tipp verbinden (Handy) oder ziehen (Mac), logisches Auto-Verbinden,
// Vorab-Check vor dem Start, animierter Ablauf mit Stopp, Fehler mit Hinweis und Reparatur durch den Agenten.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_controller.dart';
import '../state/app_scope.dart';
import '../state/automation.dart';
import 'connections_page.dart';
import 'mcp_page.dart';
import 'theme.dart';
import 'watchlist_page.dart';

String _two(int v) => v.toString().padLeft(2, '0');

IconData flowIcon(FlowNodeType t) => switch (t) {
      FlowNodeType.trigger => Icons.play_circle_outline,
      FlowNodeType.agent => Icons.smart_toy_outlined,
      FlowNodeType.tool => Icons.build_outlined,
      FlowNodeType.http => Icons.http,
      FlowNodeType.mcp => Icons.hub_outlined,
      FlowNodeType.condition => Icons.call_split,
      FlowNodeType.notify => Icons.notifications_active_outlined,
      FlowNodeType.save => Icons.bookmark_add_outlined,
    };

Color flowColor(BuildContext context, FlowNodeType t) {
  final c = AppColors.of(context);
  return switch (t) {
    FlowNodeType.trigger => c.mint,
    FlowNodeType.agent => c.blue,
    FlowNodeType.tool => c.violet,
    FlowNodeType.http => c.violet,
    FlowNodeType.mcp => c.blue,
    FlowNodeType.condition => c.amber,
    FlowNodeType.notify => c.red,
    FlowNodeType.save => c.muted,
  };
}

String _nodeHint(FlowNodeType t) => switch (t) {
      FlowNodeType.trigger => 'Wann der Prozess startet',
      FlowNodeType.agent => 'Auftrag an den KI-Agenten',
      FlowNodeType.tool => 'Websuche, Wetter, Nachrichten …',
      FlowNodeType.http => 'REST-API aufrufen, mit Anmeldung',
      FlowNodeType.mcp => 'Tool eines MCP-Servers',
      FlowNodeType.condition => 'Nur weiter, wenn …',
      FlowNodeType.notify => 'Push aufs Gerät',
      FlowNodeType.save => 'Notiz oder Dokument',
    };

const _examples = [
  'Jeden Morgen um 7 die wichtigsten Tech-News suchen, in 5 Punkten zusammenfassen und mir als Push schicken',
  'Werktags um 17 Uhr das Wetter für morgen in Wien prüfen und nur bei Regen eine Erinnerung an den Schirm schicken',
  'Wenn sich auf meiner Watchlist etwas ändert, die Änderung zusammenfassen und als Notiz speichern',
];

/// Startet einen Prozess – vorher Vorab-Check (zeigt, was fehlt, und bietet Behebung an).
Future<void> startFlow(BuildContext context, Workflow wf, {String? startAt, ValueChanged<String>? onSelectNode}) async {
  final app = AppScope.read(context);
  if (app.flows.isRunning(wf.id)) return;
  if (startAt == null) {
    final r = await showDialog<String>(context: context, builder: (_) => _PreflightDialog(wf: wf));
    if (r == null) return;
    if (r.startsWith('node:')) {
      onSelectNode?.call(r.substring(5));
      return;
    }
  }
  unawaited(app.flows.run(wf, startAt: startAt));
}

class FlowsPage extends StatefulWidget {
  const FlowsPage({super.key});
  @override
  State<FlowsPage> createState() => _FlowsPageState();
}

class _FlowsPageState extends State<FlowsPage> {
  final _prompt = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final text = _prompt.text.trim();
    if (text.isEmpty) return;
    final app = AppScope.read(context);
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      final wf = await app.flows.generate(text);
      await app.flows.upsert(wf);
      _prompt.clear();
      nav.push(MaterialPageRoute(builder: (_) => FlowEditor(id: wf.id)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _empty() async {
    final app = AppScope.read(context);
    final nav = Navigator.of(context);
    final wf = Workflow(id: newId(), name: 'Neuer Prozess');
    wf.nodes.add(FlowNode(id: 'n1', type: FlowNodeType.trigger, title: 'Start', config: {'mode': 'manual'}, x: 60, y: 120));
    await app.flows.upsert(wf);
    nav.push(MaterialPageRoute(builder: (_) => FlowEditor(id: wf.id)));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final watchFlows = {for (final w in app.watchlist.items) if (w.flowId != null) w.flowId!};
    final flows = app.flows.flows.where((f) => !watchFlows.contains(f.id)).toList();
    final narrow = MediaQuery.sizeOf(context).width < 560;
    return Scaffold(
      appBar: AppBar(title: const Text('Prozesse'), actions: [
        if (narrow)
          IconButton(tooltip: 'Beobachten', icon: const Icon(Icons.radar), onPressed: () => showWatchDialog(context))
        else
          OutlinedButton.icon(onPressed: () => showWatchDialog(context), icon: const Icon(Icons.radar, size: 18), label: const Text('Beobachten')),
        const SizedBox(width: 8),
        if (narrow)
          IconButton(tooltip: 'Leerer Prozess', icon: const Icon(Icons.add), onPressed: _empty)
        else
          OutlinedButton.icon(onPressed: _empty, icon: const Icon(Icons.add, size: 18), label: const Text('Leerer Prozess')),
        const SizedBox(width: 12),
      ]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 48),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const PageHeader(
                  icon: Icons.account_tree_outlined,
                  title: 'Prozesse',
                  subtitle: 'Abläufe aus Bausteinen, die der Agent selbständig ausführt – nach Zeitplan, beim Beobachten einer Seite '
                      'oder eines Themas (auch minütlich) oder per Klick.',
                ),
                // ---- Erzeugen per Prompt
                Panel(
                  padding: const EdgeInsets.all(16),
                  borderColor: c.mint.withValues(alpha: 0.35),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Icon(Icons.auto_awesome, color: c.mint, size: 20),
                      const SizedBox(width: 8),
                      Text('Per Prompt erzeugen', style: t.titleSmall),
                    ]),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _prompt,
                      minLines: 2,
                      maxLines: 5,
                      enabled: !_busy,
                      decoration: const InputDecoration(hintText: 'Beschreibe den Ablauf in einem Satz …'),
                      onSubmitted: (_) => _generate(),
                    ),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final e in _examples)
                        ActionChip(
                          label: Text(e.length > 60 ? '${e.substring(0, 60)}…' : e),
                          onPressed: _busy ? null : () => setState(() => _prompt.text = e),
                        ),
                    ]),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: _busy || !app.canChat ? null : _generate,
                        icon: _busy
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.auto_awesome, size: 18),
                        label: Text(_busy ? 'Baue Prozess …' : 'Prozess bauen'),
                      ),
                    ),
                  ]),
                ),
                const WatchSection(),
                SectionLabel('Meine Prozesse', padding: const EdgeInsets.fromLTRB(4, 24, 4, 8), trailing: MonoText('${flows.length}', color: c.faint)),
                if (flows.isEmpty)
                  Panel(
                    child: EmptyHint(
                      icon: Icons.account_tree_outlined,
                      title: 'Noch keine Prozesse',
                      text: 'Beschreibe oben einen Ablauf oder starte mit einem leeren Prozess.',
                    ),
                  ),
                for (final wf in flows) Padding(padding: const EdgeInsets.only(bottom: 8), child: _FlowCard(app: app, wf: wf)),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _FlowCard extends StatelessWidget {
  const _FlowCard({required this.app, required this.wf});
  final AppController app;
  final Workflow wf;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final running = app.flows.isRunning(wf.id);
    final trig = wf.trigger;
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FlowEditor(id: wf.id))),
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(12)),
          child: Wrap(
            alignment: WrapAlignment.center,
            runAlignment: WrapAlignment.center,
            spacing: 3,
            runSpacing: 3,
            children: [
              for (final n in wf.order().take(6))
                Container(width: 9, height: 9, decoration: BoxDecoration(color: flowColor(context, n.type), borderRadius: BorderRadius.circular(3))),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(wf.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall)),
              const SizedBox(width: 8),
              if (running)
                StatusChip('Läuft', color: c.amber, soft: c.amberSoft, dense: true)
              else if (wf.lastStatus == 'Fehler')
                StatusChip('Fehler', color: c.red, soft: c.redSoft, dense: true)
              else if (!wf.enabled)
                StatusChip('Pausiert', color: c.muted, soft: c.raised, dense: true)
              else
                StatusChip('Aktiv', color: c.mint, soft: c.mintSoft, dense: true),
            ]),
            const SizedBox(height: 3),
            MonoText([
              trig?.summary ?? 'ohne Auslöser',
              '${wf.nodes.length} Bausteine',
              if (wf.lastRun != null) 'zuletzt ${wf.lastRun!.day}.${wf.lastRun!.month}. ${_two(wf.lastRun!.hour)}:${_two(wf.lastRun!.minute)}',
            ].join(' · ')),
          ]),
        ),
        IconButton(
          tooltip: running ? 'Stoppen' : 'Jetzt ausführen',
          icon: Icon(running ? Icons.stop_circle_outlined : Icons.play_arrow_rounded, color: running ? c.red : null),
          onPressed: () => running ? app.flows.stop(wf) : startFlow(context, wf),
        ),
        Switch(
          value: wf.enabled,
          onChanged: (v) {
            wf.enabled = v;
            app.flows.upsert(wf);
          },
        ),
        PopupMenuButton<String>(
          tooltip: 'Mehr',
          onSelected: (v) async {
            if (v == 'copy') await duplicateFlow(context, wf);
            if (v == 'edit' && context.mounted) {
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => FlowEditor(id: wf.id)));
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Bearbeiten'))),
            PopupMenuItem(value: 'copy', child: ListTile(leading: Icon(Icons.copy_all_outlined), title: Text('Duplizieren'))),
          ],
        ),
      ]),
    );
  }
}

/// Prozess kopieren (pausiert) und die Kopie zum Anpassen öffnen.
Future<void> duplicateFlow(BuildContext context, Workflow wf, {bool replace = false}) async {
  final app = AppScope.read(context);
  final nav = Navigator.of(context);
  final m = ScaffoldMessenger.of(context);
  final copy = await app.flows.duplicate(wf);
  m.showSnackBar(SnackBar(content: Text('„${copy.name}“ angelegt – pausiert. Nach dem Anpassen einschalten.')));
  final route = MaterialPageRoute<void>(builder: (_) => FlowEditor(id: copy.id));
  if (replace) {
    nav.pushReplacement(route);
  } else {
    nav.push(route);
  }
}

// ============================================================ Vorab-Check

class _PreflightDialog extends StatefulWidget {
  const _PreflightDialog({required this.wf});
  final Workflow wf;
  @override
  State<_PreflightDialog> createState() => _PreflightDialogState();
}

class _PreflightDialogState extends State<_PreflightDialog> {
  final List<PreflightCheck> _checks = [];
  StreamSubscription<PreflightCheck>? _sub;
  bool _done = false;
  String? _fixing;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _sub?.cancel();
    setState(() {
      _checks.clear();
      _done = false;
    });
    final app = AppScope.read(context);
    _sub = app.flows.preflight(widget.wf).listen(
          (c) => mounted ? setState(() => _checks.add(c)) : null,
          onError: (Object e) => mounted ? setState(() => _checks.add(PreflightCheck('Prüfung', ok: false, detail: '$e'))) : null,
          onDone: () => mounted ? setState(() => _done = true) : null,
        );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _fix(PreflightCheck ch) async {
    final app = AppScope.read(context);
    final f = ch.fix!;
    if (f == 'node' && ch.nodeId != null) {
      Navigator.pop(context, 'node:${ch.nodeId}');
      return;
    }
    setState(() => _fixing = ch.label);
    try {
      if (f == 'internet' || f == 'autoconnect') {
        await app.flows.quickFix(widget.wf, f);
      } else if (f.startsWith('conn:')) {
        final conn = app.connections.byId(f.substring(5));
        if (conn != null) await editConnection(context, existing: conn);
      } else if (f.startsWith('login:')) {
        final srv = app.mcpServers.where((s) => s.id == f.substring(6)).firstOrNull;
        if (srv != null) await app.loginMcpServer(srv);
      } else if (f == 'mcp') {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const McpPage()));
      }
    } finally {
      if (mounted) setState(() => _fixing = null);
    }
    if (mounted) _start();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final blocking = _checks.where((x) => !x.ok && !x.warn).length;
    return AlertDialog(
      title: Row(children: [
        Icon(Icons.fact_check_outlined, color: c.mint),
        const SizedBox(width: 10),
        const Expanded(child: Text('Vor dem Start prüfen')),
      ]),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final (i, ch) in _checks.indexed)
                TweenAnimationBuilder<double>(
                  key: ValueKey('$i${ch.label}'),
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 280),
                  builder: (_, v, child) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, (1 - v) * 8), child: child)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(
                        ch.ok && !ch.warn ? Icons.check_circle : (ch.warn ? Icons.info_outline : Icons.error_outline),
                        size: 19,
                        color: ch.ok && !ch.warn ? c.mint : (ch.warn ? c.amber : c.red),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(ch.label, style: t.bodyMedium),
                          if (ch.detail.isNotEmpty) Text(ch.detail, style: t.bodySmall),
                        ]),
                      ),
                      if (ch.fix != null && (!ch.ok || ch.warn))
                        _fixing == ch.label
                            ? const Padding(padding: EdgeInsets.all(8), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                            : TextButton(
                                onPressed: _fixing != null ? null : () => _fix(ch),
                                child: Text(switch (ch.fix!) {
                                  'internet' => 'Erlauben',
                                  'autoconnect' => 'Verbinden',
                                  'node' => 'Öffnen',
                                  _ when ch.fix!.startsWith('login:') || ch.fix!.startsWith('conn:') => 'Anmelden',
                                  _ => 'Beheben',
                                }),
                              ),
                    ]),
                  ),
                ),
              if (!_done)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [
                    const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 12),
                    Text('Prüfe …', style: t.bodySmall),
                  ]),
                ),
            ]),
          ),
          if (_done) ...[
            const SizedBox(height: 10),
            Text(
              blocking == 0 ? 'Alles bereit.' : '$blocking ${blocking == 1 ? 'Punkt verhindert' : 'Punkte verhindern'} vermutlich einen erfolgreichen Lauf.',
              style: t.bodySmall?.copyWith(color: blocking == 0 ? c.mint : c.red),
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
        if (_done && blocking > 0) TextButton(onPressed: () => Navigator.pop(context, 'start'), child: const Text('Trotzdem starten')),
        FilledButton.icon(
          onPressed: _done && blocking == 0 ? () => Navigator.pop(context, 'start') : null,
          icon: const Icon(Icons.play_arrow_rounded, size: 20),
          label: const Text('Starten'),
        ),
      ],
    );
  }
}

// ============================================================== Canvas-Editor

const _nodeW = 236.0;
const _nodeH = 104.0;
const _padX = 26.0; // Platz links/rechts für die Anschlüsse (Tippfläche)
const _padY = 14.0; // Platz oben für den Status-Chip
const _canvas = Size(4000, 2600);

class FlowEditor extends StatefulWidget {
  const FlowEditor({super.key, required this.id});
  final String id;
  @override
  State<FlowEditor> createState() => _FlowEditorState();
}

class _FlowEditorState extends State<FlowEditor> with SingleTickerProviderStateMixin {
  final _tc = TransformationController();
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  String? _selected;
  String? _dragFrom; // Verbindung wird gezogen
  Offset? _dragPos;
  String? _connectFrom; // Verbinden per Tippen: Quelle gewählt, Ziel antippen
  String? _fixing; // Agent repariert diesen Baustein
  bool _fitted = false;
  Size _view = const Size(800, 600);
  final _viewKey = GlobalKey();

  Workflow? _wf(AppController app) => app.flows.flows.where((f) => f.id == widget.id).firstOrNull;

  void _save(AppController app, Workflow wf) {
    app.flows.upsert(wf);
  }

  @override
  void dispose() {
    _anim.dispose();
    _tc.dispose();
    super.dispose();
  }

  double get _scale => _tc.value.getMaxScaleOnAxis();

  void _snack(String text, {SnackBarAction? action}) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action, duration: const Duration(seconds: 4)));
  }

  void _fit(Workflow wf, Size view) {
    if (wf.nodes.isEmpty) return;
    final minX = wf.nodes.map((n) => n.x).reduce(math.min) - 40;
    final minY = wf.nodes.map((n) => n.y).reduce(math.min) - 60;
    final maxX = wf.nodes.map((n) => n.x + _nodeW).reduce(math.max) + 40;
    final maxY = wf.nodes.map((n) => n.y + _nodeH).reduce(math.max) + 110; // Platz für die Leiste unten
    final s = math.min(1.1, math.min(view.width / (maxX - minX), view.height / (maxY - minY))).clamp(0.3, 1.1);
    final dx = (view.width - (maxX - minX) * s) / 2 - minX * s;
    final dy = (view.height - (maxY - minY) * s) / 2 - minY * s;
    _tc.value = Matrix4.identity()
      ..translate(dx, dy)
      ..scale(s);
  }

  void _zoom(double f, Size view) {
    final center = Offset(view.width / 2, view.height / 2);
    final s = (_scale * f).clamp(0.25, 2.0) / _scale;
    _tc.value = Matrix4.identity()
      ..translate(center.dx, center.dy)
      ..scale(s)
      ..translate(-center.dx, -center.dy)
      ..multiply(_tc.value);
    setState(() {});
  }

  /// Bildschirmpunkt → Canvas-Koordinaten.
  Offset _toCanvas(Offset global) {
    final box = _viewKey.currentContext?.findRenderObject() as RenderBox?;
    final local = box == null ? global : box.globalToLocal(global);
    return _tc.toScene(local);
  }

  /// Baustein in der Nähe eines Canvas-Punkts (großzügig für Finger).
  FlowNode? _nodeAt(Workflow wf, Offset p, {String? except}) =>
      wf.nodes.where((m) => m.id != except && Rect.fromLTWH(m.x - 24, m.y - 24, _nodeW + 48, _nodeH + 48).contains(p)).firstOrNull;

  void _connect(AppController app, Workflow wf, String from, String to) {
    final before = wf.edges.length;
    wf.connect(from, to);
    if (wf.edges.length > before) {
      _save(app, wf);
      _snack('Verbunden: ${wf.node(from)?.title} → ${wf.node(to)?.title}');
    } else if (from != to) {
      _snack(wf.edges.any((e) => e.from == from && e.to == to) ? 'Schon verbunden.' : 'Das würde einen Kreis ergeben – nicht möglich.');
    }
  }

  /// Nach dem Verschieben: liegt ein loser Baustein direkt rechts neben einem anderen, logisch verbinden.
  void _snapConnect(AppController app, Workflow wf, FlowNode n) {
    if (n.type == FlowNodeType.trigger || wf.prev(n.id).isNotEmpty) return;
    FlowNode? best;
    var bestD = double.infinity;
    for (final m in wf.nodes) {
      if (m.id == n.id) continue;
      final gap = n.x - (m.x + _nodeW);
      final dy = (m.y - n.y).abs();
      if (gap < -40 || gap > 170 || dy > _nodeH * 0.9) continue;
      final d = gap.abs() + dy;
      if (d < bestD) {
        bestD = d;
        best = m;
      }
    }
    if (best != null) _connect(app, wf, best.id, n.id);
  }

  Future<void> _addNode(AppController app, Workflow wf, FlowNodeType type) async {
    final center = _tc.toScene(Offset(_view.width / 2, _view.height / 2));
    final n = FlowNode(
      id: wf.newNodeId(),
      type: type,
      title: switch (type) {
        FlowNodeType.trigger => 'Start',
        FlowNodeType.agent => 'Agent-Auftrag',
        FlowNodeType.tool => 'Werkzeug',
        FlowNodeType.http => 'Web-API',
        FlowNodeType.mcp => 'MCP-Tool',
        FlowNodeType.condition => 'Bedingung',
        FlowNodeType.notify => 'Push-Nachricht',
        FlowNodeType.save => 'Speichern',
      },
      config: switch (type) {
        FlowNodeType.trigger => {'mode': 'manual'},
        FlowNodeType.agent => {'prompt': ''},
        FlowNodeType.tool => {'tool': 'weather', 'args': <String, dynamic>{}},
        FlowNodeType.http => {'method': 'GET', 'url': '', 'headers': '', 'body': ''},
        FlowNodeType.mcp => {
            'server': app.mcpServers.where((s) => s.enabled).firstOrNull?.id ?? '',
            'serverName': app.mcpServers.where((s) => s.enabled).firstOrNull?.name ?? '',
            'tool': '',
            'args': <String, dynamic>{}
          },
        FlowNodeType.condition => {'contains': '', 'negate': false},
        FlowNodeType.notify => {'title': wf.name, 'text': '{{vorher}}'},
        FlowNodeType.save => {'mode': 'memory', 'title': wf.name},
      },
      x: center.dx - _nodeW / 2 + (wf.nodes.length % 3) * 16,
      y: center.dy - _nodeH / 2 + (wf.nodes.length % 3) * 16,
    );
    // logisch anhängen: an den gewählten Baustein, sonst ans Ende der Kette
    final selNode = _selected == null ? null : wf.node(_selected!);
    final anchor = type == FlowNodeType.trigger ? null : (selNode ?? wf.attachPoint());
    if (anchor != null) {
      final below = wf.next(anchor.id).length;
      n
        ..x = anchor.x + _nodeW + 80
        ..y = anchor.y + below * (_nodeH + 40);
    }
    wf.nodes.add(n);
    if (anchor != null) wf.connect(anchor.id, n.id);
    _selected = n.id;
    _save(app, wf);
    setState(() {});
    if (anchor != null) _snack('„${n.title}“ an „${anchor.title}“ angehängt');
  }

  Future<void> _repair(AppController app, Workflow wf, FlowNode n) async {
    setState(() => _fixing = n.id);
    try {
      final change = await app.flows.agentFix(wf, n);
      if (!mounted) return;
      _snack('Repariert: $change',
          action: SnackBarAction(label: 'Ab hier erneut', onPressed: () => startFlow(context, wf, startAt: n.id)));
    } catch (e) {
      if (mounted) _snack('Reparatur nicht möglich: ${'$e'.replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _fixing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final wf = _wf(app);
    if (wf == null) return const Scaffold();
    final running = app.flows.isRunning(wf.id);
    if (running != _anim.isAnimating) {
      // nicht während des Bauens starten/stoppen
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final r = AppScope.read(context).flows.isRunning(widget.id);
        if (r && !_anim.isAnimating) {
          _anim.repeat();
        } else if (!r && _anim.isAnimating) {
          _anim.stop();
        }
      });
    }
    final states = app.flows.state[wf.id] ?? const {};
    final errs = app.flows.errors[wf.id] ?? const <String, FlowError>{};
    final problems = wf.problems(app.flows.toolNames);
    final sel = _selected == null || _selected == '__flow__' ? null : wf.node(_selected!);

    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 980;
      final narrow = box.maxWidth < 600;
      final inspector = _selected == '__flow__'
          ? _FlowSettings(app: app, wf: wf, onClose: () => setState(() => _selected = null))
          : (sel == null
              ? null
              : _NodeInspector(
                  key: ValueKey(sel.id),
                  app: app,
                  wf: wf,
                  node: sel,
                  output: app.flows.outputs[wf.id]?[sel.id],
                  error: errs[sel.id],
                  repairing: _fixing == sel.id,
                  onRepair: () => _repair(app, wf, sel),
                  onRunFrom: () => startFlow(context, wf, startAt: sel.id),
                  onClose: () => setState(() => _selected = null),
                  onDelete: () {
                    wf.remove(sel.id);
                    _save(app, wf);
                    setState(() => _selected = null);
                  },
                  onConnectTap: () => setState(() {
                    _connectFrom = sel.id;
                    if (!wide) _selected = null;
                  }),
                  onConnectTo: (to) {
                    _connect(app, wf, sel.id, to);
                    setState(() {});
                  },
                  onChanged: () {
                    _save(app, wf);
                    setState(() {});
                  },
                ));
      return Scaffold(
        appBar: AppBar(
          title: _NameField(
            name: wf.name,
            onChanged: (v) {
              wf.name = v;
              _save(app, wf);
            },
          ),
          actions: [
            PillIconButton(
              icon: Icons.tune,
              tooltip: 'Prozess-Einstellungen',
              active: _selected == '__flow__',
              onPressed: () => setState(() => _selected = _selected == '__flow__' ? null : '__flow__'),
            ),
            const SizedBox(width: 8),
            if (running)
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: c.red, foregroundColor: Colors.white),
                onPressed: () => app.flows.stop(wf),
                icon: const Icon(Icons.stop_rounded, size: 20),
                label: Text(narrow ? 'Stopp' : 'Stoppen'),
              )
            else
              FilledButton.icon(
                onPressed: () => startFlow(context, wf, onSelectNode: (id) => setState(() => _selected = id)),
                icon: const Icon(Icons.play_arrow_rounded, size: 20),
                label: Text(narrow ? 'Start' : 'Ausführen'),
              ),
            const SizedBox(width: 12),
          ],
        ),
        body: Row(children: [
          Expanded(
            child: LayoutBuilder(builder: (context, view) {
              _view = view.biggest;
              if (!_fitted) {
                _fitted = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() => _fit(wf, view.biggest));
                });
              }
              final firstError = errs.entries.where((e) => wf.node(e.key) != null).firstOrNull;
              return Stack(children: [
                Positioned.fill(child: ColoredBox(color: c.canvas, child: CustomPaint(painter: _GridPainter(c.dots, _tc.value)))),
                Positioned.fill(
                  child: Container(
                    key: _viewKey,
                    child: InteractiveViewer(
                      transformationController: _tc,
                      constrained: false,
                      minScale: 0.25,
                      maxScale: 2.0,
                      boundaryMargin: const EdgeInsets.all(400),
                      onInteractionUpdate: (_) => setState(() {}),
                      child: SizedBox(
                        width: _canvas.width,
                        height: _canvas.height,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() {
                            _selected = null;
                            _connectFrom = null;
                          }),
                          child: Stack(clipBehavior: Clip.none, children: [
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _EdgePainter(
                                  wf: wf,
                                  states: states,
                                  color: c.borderStrong,
                                  active: c.mint,
                                  running: c.amber,
                                  error: c.red,
                                  anim: _anim,
                                  dragFrom: _dragFrom == null ? null : wf.node(_dragFrom!),
                                  dragPos: _dragPos,
                                ),
                              ),
                            ),
                            for (final n in wf.nodes)
                              Positioned(
                                left: n.x - _padX,
                                top: n.y - _padY,
                                width: _nodeW + 2 * _padX,
                                height: _nodeH + _padY + 4,
                                child: _NodeCard(
                                  node: n,
                                  state: states[n.id],
                                  selected: _selected == n.id,
                                  problem: problems.any((p) => p.contains('„${n.title}“')) || errs.containsKey(n.id),
                                  anim: _anim,
                                  connectSource: _connectFrom == n.id,
                                  connectTarget: (_connectFrom != null && _connectFrom != n.id) ||
                                      (_dragFrom != null && _dragPos != null && _nodeAt(wf, _dragPos!, except: _dragFrom)?.id == n.id),
                                  onTap: () {
                                    if (_connectFrom != null) {
                                      final from = _connectFrom!;
                                      setState(() => _connectFrom = null);
                                      if (from != n.id) _connect(app, wf, from, n.id);
                                      return;
                                    }
                                    setState(() => _selected = n.id);
                                  },
                                  onMove: (d) {
                                    setState(() {
                                      n
                                        ..x = (n.x + d.dx / _scale).clamp(0, _canvas.width - _nodeW)
                                        ..y = (n.y + d.dy / _scale).clamp(0, _canvas.height - _nodeH);
                                    });
                                  },
                                  onMoveEnd: () {
                                    _snapConnect(app, wf, n);
                                    _save(app, wf);
                                  },
                                  onPortTap: () => setState(() => _connectFrom = _connectFrom == n.id ? null : n.id),
                                  onConnectStart: () => setState(() {
                                    _dragFrom = n.id;
                                    _dragPos = Offset(n.x + _nodeW, n.y + _nodeH / 2);
                                  }),
                                  onConnectUpdate: (g) => setState(() => _dragPos = _toCanvas(g)),
                                  onConnectEnd: () {
                                    final p = _dragPos;
                                    final from = _dragFrom;
                                    setState(() {
                                      _dragFrom = null;
                                      _dragPos = null;
                                    });
                                    if (p == null || from == null) return;
                                    final target = _nodeAt(wf, p, except: from);
                                    if (target != null) {
                                      _connect(app, wf, from, target.id);
                                    } else if ((p - Offset(n.x + _nodeW, n.y + _nodeH / 2)).distance < 30) {
                                      // kaum bewegt = getippt → Verbinden per Tippen
                                      setState(() => _connectFrom = from);
                                    }
                                  },
                                ),
                              ),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
                // ---- oben: Lauf-Status, Verbinden-Modus oder Hinweise
                Positioned(
                  left: 12,
                  top: 12,
                  right: 12,
                  child: running
                      ? _RunBanner(app: app, wf: wf, anim: _anim)
                      : _connectFrom != null
                          ? _Banner(
                              icon: Icons.link,
                              color: c.mint,
                              soft: c.mintSoft,
                              text: 'Verbinden von „${wf.node(_connectFrom!)?.title ?? ''}“: Tippe auf den Ziel-Baustein.',
                              action: TextButton(onPressed: () => setState(() => _connectFrom = null), child: const Text('Abbrechen')),
                            )
                          : problems.isNotEmpty
                              ? _Banner(
                                  icon: Icons.warning_amber_rounded,
                                  color: c.amber,
                                  soft: c.amberSoft,
                                  text: problems.first + (problems.length > 1 ? '  (+${problems.length - 1})' : ''),
                                  action: problems.any((p) => p.contains('mit nichts verbunden'))
                                      ? TextButton(
                                          onPressed: () {
                                            final k = wf.autoConnect();
                                            _save(app, wf);
                                            _snack(k == 0 ? 'Nichts zu verbinden.' : '$k ${k == 1 ? 'Verbindung' : 'Verbindungen'} ergänzt.');
                                          },
                                          child: const Text('Auto-verbinden'),
                                        )
                                      : null,
                                )
                              : const SizedBox.shrink(),
                ),
                if (wide && wf.nodes.isNotEmpty)
                  Positioned(right: 14, top: running || problems.isNotEmpty || _connectFrom != null ? 66 : 14, child: _MiniMap(wf: wf, tc: _tc, view: view.biggest)),
                // ---- Fehler des letzten Laufs
                if (!running && firstError != null && (narrow ? _selected == null : true))
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 76,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: _ErrorCard(
                          node: wf.node(firstError.key)!,
                          error: firstError.value,
                          repairing: _fixing == firstError.key,
                          onOpen: () => setState(() => _selected = firstError.key),
                          onRepair: () => _repair(app, wf, wf.node(firstError.key)!),
                          onQuickFix: firstError.value.fix == null
                              ? null
                              : () async {
                                  await app.flows.quickFix(wf, firstError.value.fix!);
                                  if (context.mounted) startFlow(context, wf, startAt: firstError.key);
                                },
                          onRetry: () => startFlow(context, wf, startAt: firstError.key),
                        ),
                      ),
                    ),
                  ),
                // ---- Werkzeugleiste unten (eine Zeile, auf dem Handy scrollbar – nichts überlappt)
                if (!narrow || _selected == null)
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 12,
                    child: Center(
                      child: _Toolbar(
                        scale: _scale,
                        connectActive: _connectFrom != null,
                        onAdd: (t) => _addNode(app, wf, t),
                        onConnect: () {
                          final from = _selected != null && _selected != '__flow__' ? _selected : wf.attachPoint()?.id;
                          setState(() => _connectFrom = _connectFrom != null ? null : from);
                          if (from == null) _snack('Zuerst einen Baustein antippen.');
                        },
                        onAutoConnect: () {
                          final k = wf.autoConnect();
                          _save(app, wf);
                          _snack(k == 0 ? 'Alles ist schon verbunden.' : '$k ${k == 1 ? 'Verbindung' : 'Verbindungen'} ergänzt.');
                        },
                        onArrange: () {
                          wf.layout();
                          _save(app, wf);
                          setState(() => _fit(wf, view.biggest));
                        },
                        onZoomOut: () => _zoom(1 / 1.2, view.biggest),
                        onZoomIn: () => _zoom(1.2, view.biggest),
                        onFit: () => setState(() => _fit(wf, view.biggest)),
                      ),
                    ),
                  ),
              ]);
            }),
          ),
          if (wide && inspector != null) ...[
            VerticalDivider(width: 1, color: c.border),
            SizedBox(width: 380, child: inspector),
          ],
        ]),
        bottomSheet: !wide && inspector != null
            ? SizedBox(
                height: box.maxHeight * 0.6,
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  shape: RoundedRectangleBorder(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(Ui.rLg)), side: BorderSide(color: c.border)),
                  child: inspector,
                ),
              )
            : null,
      );
    });
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.soft, required this.text, this.action});
  final IconData icon;
  final Color color;
  final Color soft;
  final String text;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 640),
          padding: EdgeInsets.fromLTRB(12, action == null ? 9 : 2, action == null ? 12 : 2, action == null ? 9 : 2),
          decoration: BoxDecoration(color: soft, borderRadius: BorderRadius.circular(Ui.r), border: Border.all(color: color.withValues(alpha: 0.4))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Flexible(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 12.5))),
            if (action != null) action!,
          ]),
        ),
      );
}

/// Laufender Prozess: welcher Schritt, wie lange, Fortschritt – mit Stopp.
class _RunBanner extends StatelessWidget {
  const _RunBanner({required this.app, required this.wf, required this.anim});
  final AppController app;
  final Workflow wf;
  final Animation<double> anim;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.topCenter,
      child: AnimatedBuilder(
        animation: anim,
        builder: (context, _) {
          final st = app.flows.state[wf.id] ?? const {};
          final total = st.length;
          final finished = st.values.where((s) => s == 'done' || s == 'skipped' || s == 'error').length;
          final cur = app.flows.current[wf.id];
          final node = cur == null ? null : wf.node(cur);
          final since = app.flows.startedAt[wf.id];
          final secs = since == null ? 0 : DateTime.now().difference(since).inSeconds;
          final idx = node == null ? finished : finished + 1;
          return Container(
            constraints: const BoxConstraints(maxWidth: 640),
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(Ui.r),
              border: Border.all(color: c.amber.withValues(alpha: 0.6)),
              boxShadow: [BoxShadow(color: c.amber.withValues(alpha: 0.12 + 0.1 * math.sin(anim.value * math.pi * 2).abs()), blurRadius: 16)],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: c.amber)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    node == null ? 'Läuft …' : 'Schritt $idx/$total · ${node.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onSurface, fontSize: 13),
                  ),
                ),
                MonoText('${secs ~/ 60}:${_two(secs % 60)}', color: c.muted),
                IconButton(
                  tooltip: 'Stoppen',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.stop_circle_outlined, color: c.red),
                  onPressed: () => app.flows.stop(wf),
                ),
              ]),
              if ((app.flows.live[wf.id] ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 26, top: 2, right: 8),
                  child: Text(app.flows.live[wf.id]!,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.muted, fontSize: 12)),
                ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  minHeight: 4,
                  value: total == 0 ? null : (finished + (node == null ? 0 : 0.5)) / total,
                  color: c.amber,
                  backgroundColor: c.raised,
                ),
              ),
            ]),
          );
        },
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.node,
    required this.error,
    required this.repairing,
    required this.onOpen,
    required this.onRepair,
    required this.onRetry,
    this.onQuickFix,
  });
  final FlowNode node;
  final FlowError error;
  final bool repairing;
  final VoidCallback onOpen;
  final VoidCallback onRepair;
  final VoidCallback onRetry;
  final VoidCallback? onQuickFix;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 6,
      shadowColor: Colors.black45,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Ui.r), side: BorderSide(color: c.red.withValues(alpha: 0.6))),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.error_outline, color: c.red, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text('Gestoppt bei „${node.title}“', style: t.titleSmall?.copyWith(color: c.red))),
          ]),
          const SizedBox(height: 4),
          Text(error.message, maxLines: 3, overflow: TextOverflow.ellipsis, style: t.bodySmall),
          const SizedBox(height: 4),
          Text('💡 ${error.hint}', style: t.bodySmall?.copyWith(color: c.muted)),
          const SizedBox(height: 4),
          Wrap(alignment: WrapAlignment.end, spacing: 4, children: [
            TextButton.icon(onPressed: onOpen, icon: const Icon(Icons.edit_outlined, size: 16), label: const Text('Selbst ändern')),
            if (onQuickFix != null)
              TextButton.icon(onPressed: onQuickFix, icon: const Icon(Icons.bolt, size: 16), label: Text(error.fix == 'internet' ? 'Internet erlauben' : 'Beheben')),
            TextButton.icon(onPressed: onRetry, icon: const Icon(Icons.replay, size: 16), label: const Text('Erneut')),
            FilledButton.tonalIcon(
              onPressed: repairing ? null : onRepair,
              icon: repairing ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_fix_high, size: 16),
              label: Text(repairing ? 'Agent repariert …' : 'Agent beheben lassen'),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// Untere Leiste: Bausteine, Verbinden, Auto-Verbinden, Anordnen, Zoom.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.scale,
    required this.connectActive,
    required this.onAdd,
    required this.onConnect,
    required this.onAutoConnect,
    required this.onArrange,
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onFit,
  });
  final double scale;
  final bool connectActive;
  final ValueChanged<FlowNodeType> onAdd;
  final VoidCallback onConnect;
  final VoidCallback onAutoConnect;
  final VoidCallback onArrange;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget btn(IconData i, String tip, VoidCallback f, {bool active = false}) => IconButton(
          tooltip: tip,
          isSelected: active,
          style: IconButton.styleFrom(backgroundColor: active ? c.mintSoft : null, foregroundColor: active ? c.mint : null),
          icon: Icon(i, size: 20),
          onPressed: f,
        );
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: c.border),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          PopupMenuButton<FlowNodeType>(
            tooltip: 'Baustein hinzufügen',
            onSelected: onAdd,
            itemBuilder: (_) => [
              for (final t in FlowNodeType.values)
                PopupMenuItem(
                  value: t,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(flowIcon(t), color: flowColor(context, t)),
                    title: Text(t.label),
                    subtitle: Text(_nodeHint(t)),
                  ),
                ),
            ],
            child: Container(
              height: 38,
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(color: c.mint, borderRadius: BorderRadius.circular(99)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.add, size: 18, color: scheme.surface),
                const SizedBox(width: 6),
                Text('Baustein', style: TextStyle(color: scheme.surface, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
          const SizedBox(width: 4),
          btn(Icons.link, 'Verbinden (Quelle, dann Ziel antippen)', onConnect, active: connectActive),
          btn(Icons.cable_outlined, 'Lose Bausteine automatisch verbinden', onAutoConnect),
          btn(Icons.auto_fix_high, 'Automatisch anordnen', onArrange),
          Container(width: 1, height: 24, color: c.border, margin: const EdgeInsets.symmetric(horizontal: 4)),
          btn(Icons.remove, 'Verkleinern', onZoomOut),
          SizedBox(width: 44, child: Center(child: MonoText('${(scale * 100).round()}%'))),
          btn(Icons.add, 'Vergrößern', onZoomIn),
          btn(Icons.fit_screen_outlined, 'Alles zeigen', onFit),
        ]),
      ),
    );
  }
}

class _NameField extends StatefulWidget {
  const _NameField({required this.name, required this.onChanged});
  final String name;
  final ValueChanged<String> onChanged;
  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  late final _c = TextEditingController(text: widget.name);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _c,
        style: Theme.of(context).textTheme.titleMedium,
        decoration: const InputDecoration(
          filled: false,
          isDense: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
        onChanged: (v) => widget.onChanged(v.trim().isEmpty ? 'Prozess' : v.trim()),
      );
}

class _NodeCard extends StatelessWidget {
  const _NodeCard({
    required this.node,
    required this.state,
    required this.selected,
    required this.problem,
    required this.anim,
    required this.connectSource,
    required this.connectTarget,
    required this.onTap,
    required this.onMove,
    required this.onMoveEnd,
    required this.onPortTap,
    required this.onConnectStart,
    required this.onConnectUpdate,
    required this.onConnectEnd,
  });
  final FlowNode node;
  final String? state;
  final bool selected;
  final bool problem;
  final Animation<double> anim;
  final bool connectSource;
  final bool connectTarget;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMove;
  final VoidCallback onMoveEnd;
  final VoidCallback onPortTap;
  final VoidCallback onConnectStart;
  final ValueChanged<Offset> onConnectUpdate;
  final VoidCallback onConnectEnd;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final color = flowColor(context, node.type);
    final (chipLabel, chipColor, chipIcon) = switch (state) {
      'running' => ('Läuft', c.amber, Icons.autorenew),
      'done' => ('Fertig', c.mint, Icons.check),
      'skipped' => ('Übersprungen', c.muted, Icons.redo),
      'error' => ('Fehler', c.red, Icons.close),
      'stopped' => ('Gestoppt', c.red, Icons.stop),
      'pending' => ('Wartet', c.faint, Icons.schedule),
      _ => (null, c.faint, null),
    };
    final border = connectSource || selected
        ? c.mint
        : connectTarget
            ? c.mint.withValues(alpha: 0.7)
            : (state == 'error' || problem ? c.red.withValues(alpha: 0.7) : (state == 'running' ? c.amber : c.borderStrong));
    final card = Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border, width: selected || connectSource ? 2 : (connectTarget ? 1.6 : 1)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.22), blurRadius: 14, offset: const Offset(0, 6)),
          if (connectTarget) BoxShadow(color: c.mint.withValues(alpha: 0.18), blurRadius: 14),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(8)),
            child: Icon(flowIcon(node.type), size: 17, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(node.type.label.toUpperCase(), style: TextStyle(fontSize: 9.5, letterSpacing: 1.1, color: c.faint, fontWeight: FontWeight.w600)),
              Text(node.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface)),
            ]),
          ),
        ]),
        const Spacer(),
        MonoText(node.summary.isEmpty ? '—' : node.summary.replaceAll('\n', ' '), size: 10.5),
      ]),
    );
    return Stack(clipBehavior: Clip.none, children: [
      Positioned(
        left: _padX,
        top: _padY,
        width: _nodeW,
        height: _nodeH,
        child: GestureDetector(
          onTap: onTap,
          onPanUpdate: (d) => onMove(d.delta),
          onPanEnd: (_) => onMoveEnd(),
          child: state == 'running'
              ? AnimatedBuilder(
                  animation: anim,
                  builder: (_, child) {
                    final v = 0.5 + 0.5 * math.sin(anim.value * math.pi * 2);
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [BoxShadow(color: c.amber.withValues(alpha: 0.15 + 0.35 * v), blurRadius: 10 + 16 * v, spreadRadius: 1 + 2 * v)],
                      ),
                      child: child,
                    );
                  },
                  child: card,
                )
              : card,
        ),
      ),
      if (chipLabel != null)
        Positioned(
          right: _padX + 10,
          top: 2,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(color: Color.alphaBlend(chipColor.withValues(alpha: 0.22), scheme.surface), borderRadius: BorderRadius.circular(99)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (state == 'running')
                RotationTransition(turns: anim, child: Icon(chipIcon, size: 11, color: chipColor))
              else if (chipIcon != null)
                Icon(chipIcon, size: 11, color: chipColor),
              const SizedBox(width: 3),
              Text(chipLabel, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: chipColor, height: 1.3)),
            ]),
          ),
        ),
      // Eingang
      if (node.type != FlowNodeType.trigger)
        Positioned(left: _padX - 7, top: _padY + _nodeH / 2 - 7, child: _Port(color: connectTarget ? c.mint : c.borderStrong, fill: scheme.surface)),
      // Ausgang: antippen (dann Ziel antippen) oder ziehen – große Tippfläche für Finger
      Positioned(
        right: 0,
        top: _padY + _nodeH / 2 - 24,
        width: 2 * _padX,
        height: 48,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPortTap,
          onPanStart: (_) => onConnectStart(),
          onPanUpdate: (d) => onConnectUpdate(d.globalPosition),
          onPanEnd: (_) => onConnectEnd(),
          child: Center(child: _Port(color: color, fill: connectSource ? color : scheme.surface, big: true)),
        ),
      ),
    ]);
  }
}

class _Port extends StatelessWidget {
  const _Port({required this.color, required this.fill, this.big = false});
  final Color color;
  final Color fill;
  final bool big;
  @override
  Widget build(BuildContext context) => Container(
        width: big ? 18 : 14,
        height: big ? 18 : 14,
        decoration: BoxDecoration(color: fill, shape: BoxShape.circle, border: Border.all(color: color, width: big ? 2.4 : 1.6)),
        child: big ? Icon(Icons.add, size: 11, color: fill == color ? Colors.white : color) : null,
      );
}

/// Punktraster im Bildschirmraum – folgt Verschieben und Zoom, reicht aber immer bis zum Rand.
class _GridPainter extends CustomPainter {
  _GridPainter(this.color, this.m);
  final Color color;
  final Matrix4 m;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    final s = m.getMaxScaleOnAxis();
    var step = 26.0 * s;
    while (step < 12) {
      step *= 2;
    }
    final ox = m.getTranslation().x % step;
    final oy = m.getTranslation().y % step;
    final r = (1.1 * s).clamp(0.7, 1.6);
    for (var x = ox; x < size.width; x += step) {
      for (var y = oy; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), r, p);
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => true;
}

class _EdgePainter extends CustomPainter {
  _EdgePainter({
    required this.wf,
    required this.states,
    required this.color,
    required this.active,
    required this.running,
    required this.error,
    required this.anim,
    this.dragFrom,
    this.dragPos,
  }) : super(repaint: anim);
  final Workflow wf;
  final Map<String, String> states;
  final Color color;
  final Color active;
  final Color running;
  final Color error;
  final Animation<double> anim;
  final FlowNode? dragFrom;
  final Offset? dragPos;

  Path _path(Offset a, Offset b) {
    final dx = math.max(60.0, (b.dx - a.dx).abs() / 2);
    return Path()
      ..moveTo(a.dx, a.dy)
      ..cubicTo(a.dx + dx, a.dy, b.dx - dx, b.dy, b.dx, b.dy);
  }

  void _draw(Canvas canvas, Path path, Offset b, Paint p, {bool arrow = true, bool dashed = false}) {
    if (dashed) {
      for (final m in path.computeMetrics()) {
        var d = 0.0;
        while (d < m.length) {
          canvas.drawPath(m.extractPath(d, math.min(d + 7, m.length)), p);
          d += 12;
        }
      }
    } else {
      canvas.drawPath(path, p);
    }
    if (arrow) {
      final ap = Path()
        ..moveTo(b.dx - 9, b.dy - 5)
        ..lineTo(b.dx - 1, b.dy)
        ..lineTo(b.dx - 9, b.dy + 5);
      canvas.drawPath(ap, p);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final e in wf.edges) {
      final a = wf.node(e.from), b = wf.node(e.to);
      if (a == null || b == null) continue;
      final sa = states[a.id], sb = states[b.id];
      final flowing = sa == 'done' && sb == 'running';
      final done = sa == 'done' && (sb == 'done' || sb == 'error');
      final skipped = sb == 'skipped' || sb == 'stopped';
      final failed = sb == 'error';
      final pa = Offset(a.x + _nodeW + 2, a.y + _nodeH / 2);
      final pb = Offset(b.x - 6, b.y + _nodeH / 2);
      final path = _path(pa, pb);
      final p = Paint()
        ..color = failed ? error : (flowing ? running : (done ? active : (skipped ? color.withValues(alpha: 0.4) : color)))
        ..strokeWidth = done || flowing ? 2.4 : 1.6
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      _draw(canvas, path, pb, p, dashed: skipped);
      // Datenfluss: wandernde Punkte zum gerade laufenden Baustein
      if (flowing) {
        final dot = Paint()..color = running;
        for (final m in path.computeMetrics()) {
          for (var k = 0; k < 3; k++) {
            final t = (anim.value + k / 3) % 1.0;
            final tan = m.getTangentForOffset(m.length * t);
            if (tan != null) canvas.drawCircle(tan.position, 4, dot);
          }
        }
      }
    }
    if (dragFrom != null && dragPos != null) {
      final p = Paint()
        ..color = active
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke;
      final a = Offset(dragFrom!.x + _nodeW + 2, dragFrom!.y + _nodeH / 2);
      _draw(canvas, _path(a, dragPos!), dragPos!, p, dashed: true);
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) => true;
}

class _MiniMap extends StatelessWidget {
  const _MiniMap({required this.wf, required this.tc, required this.view});
  final Workflow wf;
  final TransformationController tc;
  final Size view;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    if (wf.nodes.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: Container(
        width: 180,
        height: 110,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(Ui.r),
          border: Border.all(color: c.border),
        ),
        padding: const EdgeInsets.all(8),
        child: CustomPaint(painter: _MiniPainter(wf, tc, view, c, (t) => flowColor(context, t))),
      ),
    );
  }
}

class _MiniPainter extends CustomPainter {
  _MiniPainter(this.wf, this.tc, this.view, this.c, this.colorOf);
  final Workflow wf;
  final TransformationController tc;
  final Size view;
  final AppColors c;
  final Color Function(FlowNodeType) colorOf;

  @override
  void paint(Canvas canvas, Size size) {
    final minX = wf.nodes.map((n) => n.x).reduce(math.min) - 60;
    final minY = wf.nodes.map((n) => n.y).reduce(math.min) - 60;
    final maxX = wf.nodes.map((n) => n.x + _nodeW).reduce(math.max) + 60;
    final maxY = wf.nodes.map((n) => n.y + _nodeH).reduce(math.max) + 60;
    final s = math.min(size.width / (maxX - minX), size.height / (maxY - minY));
    Offset m(double x, double y) => Offset((x - minX) * s, (y - minY) * s);
    final edge = Paint()
      ..color = c.borderStrong
      ..strokeWidth = 1;
    for (final e in wf.edges) {
      final a = wf.node(e.from), b = wf.node(e.to);
      if (a == null || b == null) continue;
      canvas.drawLine(m(a.x + _nodeW, a.y + _nodeH / 2), m(b.x, b.y + _nodeH / 2), edge);
    }
    for (final n in wf.nodes) {
      final r = Rect.fromPoints(m(n.x, n.y), m(n.x + _nodeW, n.y + _nodeH));
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(2)), Paint()..color = colorOf(n.type).withValues(alpha: 0.75));
    }
    final tl = tc.toScene(Offset.zero), br = tc.toScene(Offset(view.width, view.height));
    final vr = Rect.fromPoints(m(tl.dx, tl.dy), m(br.dx, br.dy)).intersect(Offset.zero & size);
    if (!vr.isEmpty) {
      canvas.drawRect(
          vr,
          Paint()
            ..color = c.mint
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4);
    }
  }

  @override
  bool shouldRepaint(_MiniPainter old) => true;
}

// ---------------------------------------------------------------- Inspektor

class _Head extends StatelessWidget {
  const _Head({required this.icon, required this.color, required this.title, required this.onClose, this.trailing = const []});
  final IconData icon;
  final Color color;
  final String title;
  final VoidCallback onClose;
  final List<Widget> trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Row(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
          ...trailing,
          IconButton(icon: const Icon(Icons.close), onPressed: onClose),
        ]),
      );
}

class _FlowSettings extends StatelessWidget {
  const _FlowSettings({required this.app, required this.wf, required this.onClose});
  final AppController app;
  final Workflow wf;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(children: [
      _Head(icon: Icons.tune, color: c.mint, title: 'Prozess', onClose: onClose),
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          if (wf.description.isNotEmpty) ...[
            Text(wf.description, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Aktiv'),
            subtitle: const Text('Zeitplan und Beobachtung lösen den Prozess aus'),
            value: wf.enabled,
            onChanged: (v) {
              wf.enabled = v;
              app.flows.upsert(wf);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Darf ins Internet'),
            subtitle: const Text('Websuche, Webseiten, Web-APIs, MCP-Server ohne Rückfrage'),
            value: wf.allowInternet,
            onChanged: (v) {
              wf.allowInternet = v;
              app.flows.upsert(wf);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.key_outlined),
            title: const Text('Zugänge (API-Schlüssel, SSO)'),
            subtitle: Text('${app.connections.items.length} angelegt'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConnectionsPage())),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.hub_outlined),
            title: const Text('MCP-Server'),
            subtitle: Text('${app.mcpServers.length} eingerichtet'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const McpPage())),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Duplizieren'),
            onPressed: () => duplicateFlow(context, wf, replace: true),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: Icon(Icons.delete_outline, color: c.red),
            label: Text('Prozess löschen', style: TextStyle(color: c.red)),
            onPressed: () async {
              final nav = Navigator.of(context);
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Prozess löschen?'),
                  content: Text('„${wf.name}“ wird entfernt.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Löschen')),
                  ],
                ),
              );
              if (ok == true) {
                await app.flows.remove(wf);
                nav.pop();
              }
            },
          ),
        ]),
      ),
    ]);
  }
}

class _NodeInspector extends StatefulWidget {
  const _NodeInspector({
    super.key,
    required this.app,
    required this.wf,
    required this.node,
    required this.output,
    required this.error,
    required this.repairing,
    required this.onRepair,
    required this.onRunFrom,
    required this.onClose,
    required this.onDelete,
    required this.onChanged,
    required this.onConnectTap,
    required this.onConnectTo,
  });
  final AppController app;
  final Workflow wf;
  final FlowNode node;
  final String? output;
  final FlowError? error;
  final bool repairing;
  final VoidCallback onRepair;
  final VoidCallback onRunFrom;
  final VoidCallback onClose;
  final VoidCallback onDelete;
  final VoidCallback onChanged;
  final VoidCallback onConnectTap;
  final ValueChanged<String> onConnectTo;

  @override
  State<_NodeInspector> createState() => _NodeInspectorState();
}

class _NodeInspectorState extends State<_NodeInspector> {
  final Map<String, TextEditingController> _ctrls = {};
  String? _httpTest;
  bool _httpBusy = false;
  bool _mcpBusy = false;
  WatchDraft? _watch;

  @override
  void initState() {
    super.initState();
    // Header aus erzeugten Prozessen (JSON-Objekt) als Zeilen „Name: Wert“ bearbeitbar machen
    final h = widget.node.config['headers'];
    if (h is Map) widget.node.config['headers'] = h.entries.map((e) => '${e.key}: ${e.value}').join('\n');
  }

  TextEditingController _ctrl(String key, String value) => _ctrls.putIfAbsent(key, () => TextEditingController(text: value));

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  FlowNode get n => widget.node;

  void _set(String key, dynamic v) {
    n.config[key] = v;
    widget.onChanged();
  }

  Widget _field(String key, String label, {String? hint, int lines = 1, String? helper, TextInputType? keyboard}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: _ctrl(key, n.str(key)),
          minLines: lines,
          maxLines: lines == 1 ? 1 : lines + 4,
          keyboardType: keyboard,
          autocorrect: keyboard != TextInputType.url,
          decoration: InputDecoration(labelText: label, hintText: hint, helperText: helper, helperMaxLines: 3),
          onChanged: (v) => _set(key, v),
        ),
      );

  List<Widget> _argFields(List<ToolParam> params, Map<String, dynamic> args) => [
        for (final p in params)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              controller: _ctrl('arg:${p.name}', '${args[p.name] ?? ''}'),
              decoration: InputDecoration(labelText: p.name, helperText: p.description, helperMaxLines: 2),
              onChanged: (v) {
                args[p.name] = v;
                widget.onChanged();
              },
            ),
          ),
      ];

  Future<void> _testHttp() async {
    final app = widget.app;
    final method = n.str('method', 'GET').toUpperCase();
    if (method != 'GET') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('$method wirklich senden?'),
          content: const Text('Ein Test mit dieser Methode kann beim Dienst etwas anlegen oder ändern.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Senden')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() {
      _httpBusy = true;
      _httpTest = null;
    });
    try {
      final conn = n.str('connection').isEmpty ? null : app.connections.byId(n.str('connection'));
      var url = n.str('url').trim();
      if (!url.startsWith('http') && conn != null && conn.baseUrl.isNotEmpty) {
        url = '${conn.baseUrl.replaceFirst(RegExp(r'/+$'), '')}/${url.replaceFirst(RegExp(r'^/+'), '')}';
      } else if (!url.startsWith('http')) {
        url = 'https://$url';
      }
      var uri = Uri.parse(url);
      final headers = <String, String>{};
      for (final line in n.str('headers').split('\n')) {
        final i = line.indexOf(':');
        if (i > 0) headers[line.substring(0, i).trim()] = line.substring(i + 1).trim();
      }
      if (conn != null) {
        final (h, q) = await app.connections.authFor(conn);
        headers.addAll(h);
        if (q.isNotEmpty) uri = uri.replace(queryParameters: {...uri.queryParameters, ...q});
      }
      final r = await httpCall(
          method: method, url: uri, headers: headers, body: method == 'GET' ? null : n.str('body'), throwOnError: false);
      final txt = r.pretty;
      setState(() => _httpTest = 'HTTP ${r.status} · ${r.took.inMilliseconds} ms${r.ok ? '' : ' – ${httpStatusHint(r.status)}'}\n\n'
          '${txt.length > 1200 ? '${txt.substring(0, 1200)} …' : txt}');
    } catch (e) {
      setState(() => _httpTest = 'Fehler: $e');
    } finally {
      if (mounted) setState(() => _httpBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final app = widget.app;
    final color = flowColor(context, n.type);
    final tools = [...app.tools, ...app.mcpTools];
    final children = <Widget>[];

    // ---- Fehler des letzten Laufs
    final err = widget.error;
    if (err != null) {
      children.add(Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: c.redSoft, borderRadius: BorderRadius.circular(Ui.r), border: Border.all(color: c.red.withValues(alpha: 0.4))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.error_outline, color: c.red, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text('Fehler beim letzten Lauf', style: t.titleSmall?.copyWith(color: c.red))),
          ]),
          const SizedBox(height: 6),
          SelectableText(err.message, style: t.bodySmall),
          const SizedBox(height: 6),
          Text('💡 ${err.hint}', style: t.bodySmall),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            FilledButton.tonalIcon(
              onPressed: widget.repairing ? null : widget.onRepair,
              icon: widget.repairing
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_fix_high, size: 16),
              label: Text(widget.repairing ? 'Agent repariert …' : 'Agent beheben lassen'),
            ),
            OutlinedButton.icon(onPressed: widget.onRunFrom, icon: const Icon(Icons.replay, size: 16), label: const Text('Ab hier erneut')),
          ]),
          const SizedBox(height: 4),
          Text('Oder unten selbst ändern.', style: t.bodySmall),
        ]),
      ));
    }

    children.add(Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _ctrl('__title', n.title),
        decoration: const InputDecoration(labelText: 'Titel'),
        onChanged: (v) {
          n.title = v;
          widget.onChanged();
        },
      ),
    ));

    switch (n.type) {
      case FlowNodeType.trigger:
        final mode = n.str('mode', 'manual');
        children.addAll([
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'manual', label: Text('Manuell')),
              ButtonSegment(value: 'schedule', label: Text('Zeitplan')),
              ButtonSegment(value: 'watch', label: Text('Beobachten')),
            ],
            selected: {mode},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() {
              n.config['mode'] = v.first;
              if (v.first == 'watch' && n.config['watchInline'] == null) n.config['watchInline'] = true;
              widget.onChanged();
            }),
          ),
          const SizedBox(height: 14),
          if (mode == 'schedule') ...[
            OutlinedButton.icon(
              icon: const Icon(Icons.schedule, size: 18),
              label: Text('${_two((n.config['hour'] as num?)?.toInt() ?? 8)}:${_two((n.config['minute'] as num?)?.toInt() ?? 0)} Uhr'),
              onPressed: () async {
                final r = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay(hour: (n.config['hour'] as num?)?.toInt() ?? 8, minute: (n.config['minute'] as num?)?.toInt() ?? 0),
                );
                if (r != null) {
                  n.config['hour'] = r.hour;
                  n.config['minute'] = r.minute;
                  setState(widget.onChanged);
                }
              },
            ),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'daily', label: Text('Täglich')),
                ButtonSegment(value: 'weekdays', label: Text('Mo–Fr')),
                ButtonSegment(value: 'weekly', label: Text('Wöchentl.')),
              ],
              selected: {n.str('days', 'daily')},
              showSelectedIcon: false,
              onSelectionChanged: (v) => setState(() => _set('days', v.first)),
            ),
            if (n.str('days') == 'weekly') ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                initialValue: (n.config['weekday'] as num?)?.toInt() ?? 1,
                decoration: const InputDecoration(labelText: 'Wochentag'),
                items: [
                  for (final (i, d) in const [(1, 'Montag'), (2, 'Dienstag'), (3, 'Mittwoch'), (4, 'Donnerstag'), (5, 'Freitag'), (6, 'Samstag'), (7, 'Sonntag')])
                    DropdownMenuItem(value: i, child: Text(d)),
                ],
                onChanged: (v) => setState(() => _set('weekday', v ?? 1)),
              ),
            ],
          ],
          if (mode == 'watch' && n.config['watchInline'] == true) ...[
            WatchFields(
              key: ValueKey('watch-${n.id}'),
              draft: _watch ??= WatchDraft.fromNode(n),
              onChanged: () {
                _watch!.applyTo(n);
                widget.onChanged();
              },
            ),
          ],
          if (mode == 'watch' && n.config['watchInline'] != true) ...[
            DropdownButtonFormField<String>(
              initialValue: app.watchlist.items.any((w) => w.id == n.str('watchId')) ? n.str('watchId') : '',
              decoration: const InputDecoration(labelText: 'Bei Änderung von'),
              items: [
                const DropdownMenuItem(value: '', child: Text('jedem Watchlist-Eintrag')),
                for (final w in app.watchlist.items.where((w) => w.flowId == null)) DropdownMenuItem(value: w.id, child: Text(w.title)),
              ],
              onChanged: (v) => setState(() => _set('watchId', v ?? '')),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => setState(() {
                n.config['watchInline'] = true;
                widget.onChanged();
              }),
              icon: const Icon(Icons.radar, size: 18),
              label: const Text('Stattdessen hier festlegen, was beobachtet wird'),
            ),
          ],
          if (mode == 'manual') Text('Startet nur über „Ausführen“.', style: t.bodySmall),
        ]);
      case FlowNodeType.agent:
        children.add(_field('prompt', 'Auftrag an den Agenten',
            lines: 5,
            hint: 'z. B. Fasse {{vorher}} in 5 Punkten zusammen.',
            helper: 'Der Agent darf alle aktiven Werkzeuge benutzen. {{vorher}} = Ergebnis des vorigen Bausteins, {{datum}}, {{uhrzeit}}.'));
      case FlowNodeType.tool:
        final tool = tools.where((x) => x.name == n.str('tool')).firstOrNull;
        children.add(DropdownButtonFormField<String>(
          initialValue: tool?.name,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Werkzeug'),
          items: [for (final x in tools) DropdownMenuItem(value: x.name, child: Text(x.title, overflow: TextOverflow.ellipsis))],
          onChanged: (v) => setState(() {
            n.config['tool'] = v;
            n.config['args'] = <String, dynamic>{};
            _ctrls.removeWhere((k, _) => k.startsWith('arg:'));
            widget.onChanged();
          }),
        ));
        children.add(const SizedBox(height: 12));
        if (tool != null) {
          children.add(Text(tool.description, style: t.bodySmall));
          children.add(const SizedBox(height: 12));
          final args = (n.config['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
          n.config['args'] = args;
          children.addAll(_argFields(tool.params, args));
        }
      case FlowNodeType.http:
        final conns = app.connections.items;
        final connId = conns.any((x) => x.id == n.str('connection')) ? n.str('connection') : '';
        children.addAll([
          Row(children: [
            SizedBox(
              width: 112,
              child: DropdownButtonFormField<String>(
                initialValue: const ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'].contains(n.str('method', 'GET')) ? n.str('method', 'GET') : 'GET',
                decoration: const InputDecoration(labelText: 'Methode'),
                items: [for (final m in const ['GET', 'POST', 'PUT', 'PATCH', 'DELETE']) DropdownMenuItem(value: m, child: Text(m))],
                onChanged: (v) => setState(() => _set('method', v ?? 'GET')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _ctrl('url', n.str('url')),
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Adresse', hintText: 'https://api.beispiel.at/v1/…'),
                onChanged: (v) => _set('url', v),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: connId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Anmeldung (Zugang)'),
            items: [
              const DropdownMenuItem(value: '', child: Text('ohne Anmeldung')),
              for (final x in conns) DropdownMenuItem(value: x.id, child: Text('${x.name} · ${x.kind.label}', overflow: TextOverflow.ellipsis)),
              const DropdownMenuItem(value: '__new__', child: Text('＋ Neuer Zugang (API-Schlüssel, Google, SSO …)')),
            ],
            onChanged: (v) async {
              if (v == '__new__') {
                final id = await editConnection(context);
                if (id != null) _set('connection', id);
                if (mounted) setState(() {});
                return;
              }
              setState(() => _set('connection', v ?? ''));
            },
          ),
          if (connId.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  await editConnection(context, existing: app.connections.byId(connId));
                  if (mounted) setState(() {});
                },
                icon: const Icon(Icons.key_outlined, size: 16),
                label: const Text('Zugang bearbeiten / anmelden'),
              ),
            ),
          const SizedBox(height: 8),
          _field('headers', 'Header (optional, je Zeile „Name: Wert“)', lines: 2, hint: 'Accept: application/json'),
          if (n.str('method', 'GET') != 'GET' && n.str('method', 'GET') != 'DELETE')
            _field('body', 'Inhalt (Body)', lines: 4, hint: '{"text": "{{vorher}}"}', helper: 'JSON wird automatisch erkannt. {{vorher}} = Ergebnis des vorigen Bausteins.'),
          _field('extract', 'Wert auslesen (optional)', hint: 'z. B. items.0.title', helper: 'Pfad im JSON der Antwort – sonst geht die ganze Antwort weiter.'),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _httpBusy || n.str('url').trim().isEmpty ? null : _testHttp,
              icon: _httpBusy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.science_outlined, size: 18),
              label: const Text('Jetzt testen'),
            ),
          ),
          if (_httpTest != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(10)),
              child: SelectableText(_httpTest!, style: TextStyle(fontFamily: Ui.mono, fontSize: 11.5, color: c.muted)),
            ),
          ],
        ]);
      case FlowNodeType.mcp:
        final servers = app.mcpServers;
        final srv = servers.where((s) => s.id == n.str('server')).firstOrNull;
        final spec = srv?.tools.where((x) => x.name == n.str('tool')).firstOrNull;
        children.addAll([
          if (servers.isEmpty) ...[
            Text('Noch kein MCP-Server eingerichtet.', style: t.bodySmall),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const McpPage())),
              icon: const Icon(Icons.hub_outlined, size: 18),
              label: const Text('MCP-Server hinzufügen'),
            ),
          ] else ...[
            DropdownButtonFormField<String>(
              initialValue: srv?.id,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Server'),
              items: [for (final s in servers) DropdownMenuItem(value: s.id, child: Text(s.name, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() {
                final s = servers.where((x) => x.id == v).firstOrNull;
                n.config
                  ..['server'] = v ?? ''
                  ..['serverName'] = s?.name ?? ''
                  ..['tool'] = ''
                  ..['args'] = <String, dynamic>{};
                _ctrls.removeWhere((k, _) => k.startsWith('arg:'));
                widget.onChanged();
              }),
            ),
            if (srv != null) ...[
              const SizedBox(height: 8),
              Row(children: [
                Icon(srv.loggedIn ? Icons.verified_user_outlined : (app.mcpNeedsLogin.containsKey(srv.id) ? Icons.lock_outline : Icons.link),
                    size: 16, color: srv.loggedIn ? c.mint : (app.mcpNeedsLogin.containsKey(srv.id) ? c.amber : c.faint)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                      srv.loggedIn
                          ? 'Angemeldet (OAuth/SSO)'
                          : (app.mcpNeedsLogin.containsKey(srv.id) ? 'Anmeldung nötig' : '${srv.tools.length} Tools bekannt'),
                      style: t.bodySmall),
                ),
                if (app.mcpNeedsLogin.containsKey(srv.id) || srv.loggedIn)
                  TextButton(
                    onPressed: _mcpBusy
                        ? null
                        : () async {
                            setState(() => _mcpBusy = true);
                            final e = await app.loginMcpServer(srv);
                            if (mounted) {
                              setState(() => _mcpBusy = false);
                              if (e != null) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(e)));
                            }
                          },
                    child: Text(srv.loggedIn ? 'Neu anmelden' : 'Anmelden'),
                  ),
                TextButton(
                  onPressed: _mcpBusy
                      ? null
                      : () async {
                          setState(() => _mcpBusy = true);
                          final e = await app.syncMcpServer(srv);
                          if (mounted) {
                            setState(() => _mcpBusy = false);
                            ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(e ?? 'Tools geladen.')));
                          }
                        },
                  child: _mcpBusy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Tools laden'),
                ),
              ]),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: spec?.name,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Tool'),
                items: [for (final x in srv.tools) DropdownMenuItem(value: x.name, child: Text(x.name, overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() {
                  n.config
                    ..['tool'] = v ?? ''
                    ..['args'] = <String, dynamic>{};
                  _ctrls.removeWhere((k, _) => k.startsWith('arg:'));
                  widget.onChanged();
                }),
              ),
              if (spec != null) ...[
                const SizedBox(height: 10),
                if (spec.description.isNotEmpty) Text(spec.description, maxLines: 5, overflow: TextOverflow.ellipsis, style: t.bodySmall),
                const SizedBox(height: 10),
                ...() {
                  final args = (n.config['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
                  n.config['args'] = args;
                  return _argFields(app.mcpToolFor(srv.id, spec.name)?.params ?? const [], args);
                }(),
              ],
            ],
          ],
        ]);
      case FlowNodeType.condition:
        children.addAll([
          _field('contains', 'Weiter nur, wenn das Ergebnis enthält', hint: 'z. B. Regen'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Umkehren („enthält nicht“)'),
            value: n.config['negate'] == true,
            onChanged: (v) => setState(() => _set('negate', v)),
          ),
        ]);
      case FlowNodeType.notify:
        children.addAll([
          _field('title', 'Titel der Push-Nachricht'),
          _field('text', 'Text', lines: 3, helper: '{{vorher}} = Ergebnis des vorigen Bausteins'),
        ]);
      case FlowNodeType.save:
        children.addAll([
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'memory', label: Text('Gedächtnis')),
              ButtonSegment(value: 'document', label: Text('Dokument (PDF)')),
            ],
            selected: {n.str('mode', 'memory')},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => _set('mode', v.first)),
          ),
          const SizedBox(height: 12),
          _field('title', 'Titel'),
        ]);
    }

    // Verbindungen
    final outs = widget.wf.next(n.id);
    final ins = widget.wf.prev(n.id);
    final candidates = [for (final m in widget.wf.nodes) if (m.id != n.id && m.type != FlowNodeType.trigger && !outs.any((o) => o.id == m.id)) m];
    children.addAll([
      SectionLabel('Verbindungen',
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 6),
          trailing: PopupMenuButton<String>(
            tooltip: 'Verbinden mit …',
            enabled: candidates.isNotEmpty,
            onSelected: widget.onConnectTo,
            itemBuilder: (_) => [
              for (final m in candidates)
                PopupMenuItem(
                  value: m.id,
                  child: Row(children: [
                    Icon(flowIcon(m.type), size: 18, color: flowColor(context, m.type)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(m.title, overflow: TextOverflow.ellipsis)),
                  ]),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.add_link, size: 18, color: candidates.isEmpty ? c.faint : c.mint),
                const SizedBox(width: 4),
                Text('Verbinden mit …', style: TextStyle(fontSize: 12.5, color: candidates.isEmpty ? c.faint : c.mint)),
              ]),
            ),
          )),
      if (ins.isEmpty && outs.isEmpty) Text('Noch keine – „Verbinden mit …“ wählen oder den Punkt rechts am Baustein antippen.', style: t.bodySmall),
      for (final x in ins)
        _ConnRow(
            label: 'von ${x.title}',
            icon: Icons.arrow_forward,
            onRemove: () {
              widget.wf.edges.removeWhere((e) => e.from == x.id && e.to == n.id);
              widget.onChanged();
            }),
      for (final x in outs)
        _ConnRow(
            label: 'nach ${x.title}',
            icon: Icons.arrow_forward,
            onRemove: () {
              widget.wf.edges.removeWhere((e) => e.from == n.id && e.to == x.id);
              widget.onChanged();
            }),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: widget.onConnectTap,
          icon: const Icon(Icons.touch_app_outlined, size: 18),
          label: const Text('Ziel im Canvas antippen'),
        ),
      ),
    ]);
    if (widget.output != null && widget.output!.trim().isNotEmpty) {
      children.addAll([
        const SectionLabel('Letztes Ergebnis', padding: EdgeInsets.fromLTRB(0, 16, 0, 6)),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(10)),
          child: SelectableText(
            widget.output!.length > 1500 ? '${widget.output!.substring(0, 1500)} …' : widget.output!,
            style: TextStyle(fontFamily: Ui.mono, fontSize: 11.5, color: c.muted),
          ),
        ),
      ]);
    }
    return Column(children: [
      _Head(
        icon: flowIcon(n.type),
        color: color,
        title: n.type.label,
        onClose: widget.onClose,
        trailing: [
          if (n.type != FlowNodeType.trigger)
            IconButton(tooltip: 'Ab hier ausführen', icon: const Icon(Icons.play_circle_outline), onPressed: widget.onRunFrom),
          IconButton(tooltip: 'Baustein löschen', icon: Icon(Icons.delete_outline, color: c.red), onPressed: widget.onDelete),
        ],
      ),
      Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: children)),
    ]);
  }
}

class _ConnRow extends StatelessWidget {
  const _ConnRow({required this.label, required this.icon, required this.onRemove});
  final String label;
  final IconData icon;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 16, color: AppColors.of(context).faint),
        const SizedBox(width: 8),
        Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
        IconButton(tooltip: 'Verbindung entfernen', icon: const Icon(Icons.link_off, size: 18), onPressed: onRemove),
      ]);
}

// Hilfsfunktion für Tests/Debug: Prozess als JSON (z. B. zum Teilen).
String flowToJson(Workflow wf) => const JsonEncoder.withIndent('  ').convert(wf.toJson());
