// Prozesse: Liste, Erzeugen per Prompt und Canvas-Editor (Bausteine verbinden wie bei n8n).

import 'dart:math' as math;

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_controller.dart';
import '../state/app_scope.dart';
import 'theme.dart';

String _two(int v) => v.toString().padLeft(2, '0');

IconData flowIcon(FlowNodeType t) => switch (t) {
      FlowNodeType.trigger => Icons.play_circle_outline,
      FlowNodeType.agent => Icons.smart_toy_outlined,
      FlowNodeType.tool => Icons.build_outlined,
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
    FlowNodeType.condition => c.amber,
    FlowNodeType.notify => c.red,
    FlowNodeType.save => c.muted,
  };
}

const _examples = [
  'Jeden Morgen um 7 die wichtigsten Tech-News suchen, in 5 Punkten zusammenfassen und mir als Push schicken',
  'Werktags um 17 Uhr das Wetter für morgen in Wien prüfen und nur bei Regen eine Erinnerung an den Schirm schicken',
  'Wenn sich auf meiner Watchlist etwas ändert, die Änderung zusammenfassen und als Notiz speichern',
];

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
    final flows = app.flows.flows;
    return Scaffold(
      appBar: AppBar(title: const Text('Prozesse'), actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: OutlinedButton.icon(onPressed: _empty, icon: const Icon(Icons.add, size: 18), label: const Text('Leerer Prozess')),
        ),
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
                  subtitle: 'Abläufe aus Bausteinen, die der Agent selbständig ausführt – nach Zeitplan, bei Watchlist-Änderungen oder per Klick.',
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
        // Mini-Vorschau der Bausteine
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
          tooltip: 'Jetzt ausführen',
          icon: running
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.play_arrow_rounded),
          onPressed: running ? null : () => app.flows.run(wf),
        ),
        Switch(
          value: wf.enabled,
          onChanged: (v) {
            wf.enabled = v;
            app.flows.upsert(wf);
          },
        ),
      ]),
    );
  }
}

// ============================================================== Canvas-Editor

const _nodeW = 236.0;
const _nodeH = 104.0;
const _canvas = Size(4000, 2600);

class FlowEditor extends StatefulWidget {
  const FlowEditor({super.key, required this.id});
  final String id;
  @override
  State<FlowEditor> createState() => _FlowEditorState();
}

class _FlowEditorState extends State<FlowEditor> {
  final _tc = TransformationController();
  String? _selected;
  String? _dragFrom; // Verbindung wird gezogen
  Offset? _dragPos;
  bool _fitted = false;
  final _viewKey = GlobalKey();

  Workflow? _wf(AppController app) => app.flows.flows.where((f) => f.id == widget.id).firstOrNull;

  void _save(AppController app, Workflow wf) {
    app.flows.upsert(wf);
  }

  double get _scale => _tc.value.getMaxScaleOnAxis();

  void _fit(Workflow wf, Size view) {
    if (wf.nodes.isEmpty) return;
    final minX = wf.nodes.map((n) => n.x).reduce(math.min) - 40;
    final minY = wf.nodes.map((n) => n.y).reduce(math.min) - 40;
    final maxX = wf.nodes.map((n) => n.x + _nodeW).reduce(math.max) + 40;
    final maxY = wf.nodes.map((n) => n.y + _nodeH).reduce(math.max) + 40;
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

  Future<void> _addNode(AppController app, Workflow wf, FlowNodeType type, Size view) async {
    final center = _tc.toScene(Offset(view.width / 2, view.height / 2));
    final n = FlowNode(
      id: wf.newNodeId(),
      type: type,
      title: switch (type) {
        FlowNodeType.trigger => 'Start',
        FlowNodeType.agent => 'Agent-Auftrag',
        FlowNodeType.tool => 'Werkzeug',
        FlowNodeType.condition => 'Bedingung',
        FlowNodeType.notify => 'Push-Nachricht',
        FlowNodeType.save => 'Speichern',
      },
      config: switch (type) {
        FlowNodeType.trigger => {'mode': 'manual'},
        FlowNodeType.agent => {'prompt': ''},
        FlowNodeType.tool => {'tool': 'weather', 'args': <String, dynamic>{}},
        FlowNodeType.condition => {'contains': '', 'negate': false},
        FlowNodeType.notify => {'title': wf.name, 'text': '{{vorher}}'},
        FlowNodeType.save => {'mode': 'memory', 'title': wf.name},
      },
      x: center.dx - _nodeW / 2 + (wf.nodes.length % 3) * 16,
      y: center.dy - _nodeH / 2 + (wf.nodes.length % 3) * 16,
    );
    // an den gewählten Baustein anhängen
    final sel = _selected == null ? null : wf.node(_selected!);
    if (sel != null) {
      n
        ..x = sel.x + _nodeW + 70
        ..y = sel.y;
    }
    wf.nodes.add(n);
    if (sel != null) wf.connect(sel.id, n.id);
    _selected = n.id;
    _save(app, wf);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final wf = _wf(app);
    if (wf == null) return const Scaffold();
    final running = app.flows.isRunning(wf.id);
    final states = app.flows.state[wf.id] ?? const {};
    final problems = wf.problems(app.flows.toolNames);
    final sel = _selected == null ? null : wf.node(_selected!);

    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 980;
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
            PopupMenuButton<FlowNodeType>(
              tooltip: 'Baustein hinzufügen',
              onSelected: (t) => _addNode(app, wf, t, Size(box.maxWidth - (wide && sel != null ? 360 : 0), box.maxHeight - 62)),
              itemBuilder: (_) => [
                for (final t in FlowNodeType.values)
                  PopupMenuItem(
                    value: t,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(flowIcon(t), color: flowColor(context, t)),
                      title: Text(t.label),
                    ),
                  ),
              ],
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(99), border: Border.all(color: c.borderStrong)),
                child: Row(children: [
                  const Icon(Icons.add, size: 18),
                  const SizedBox(width: 6),
                  Text('Baustein', style: Theme.of(context).textTheme.labelLarge),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            PillIconButton(
              icon: Icons.auto_fix_high,
              tooltip: 'Automatisch anordnen',
              onPressed: () {
                wf.layout();
                _save(app, wf);
                _fit(wf, Size(box.maxWidth - (wide && sel != null ? 360 : 0), box.maxHeight - 62));
                setState(() {});
              },
            ),
            const SizedBox(width: 6),
            PillIconButton(
              icon: Icons.tune,
              tooltip: 'Prozess-Einstellungen',
              active: _selected == '__flow__',
              onPressed: () => setState(() => _selected = _selected == '__flow__' ? null : '__flow__'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: running || problems.any((p) => p.contains('Auslöser')) ? null : () => app.flows.run(wf),
              icon: running
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow_rounded, size: 20),
              label: Text(running ? 'Läuft …' : 'Ausführen'),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: Row(children: [
          Expanded(
            child: LayoutBuilder(builder: (context, view) {
              if (!_fitted) {
                _fitted = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() => _fit(wf, view.biggest));
                });
              }
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
                          onTap: () => setState(() => _selected = null),
                          child: Stack(clipBehavior: Clip.none, children: [
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _EdgePainter(
                                  wf: wf,
                                  states: states,
                                  color: c.borderStrong,
                                  active: c.mint,
                                  dragFrom: _dragFrom == null ? null : wf.node(_dragFrom!),
                                  dragPos: _dragPos,
                                ),
                              ),
                            ),
                            for (final n in wf.nodes)
                              Positioned(
                                left: n.x,
                                top: n.y,
                                width: _nodeW,
                                height: _nodeH,
                                child: _NodeCard(
                                  node: n,
                                  state: states[n.id],
                                  selected: _selected == n.id,
                                  problem: problems.any((p) => p.contains('„${n.title}“')),
                                  onTap: () => setState(() => _selected = n.id),
                                  onMove: (d) {
                                    setState(() {
                                      n
                                        ..x = (n.x + d.dx / _scale).clamp(0, _canvas.width - _nodeW)
                                        ..y = (n.y + d.dy / _scale).clamp(0, _canvas.height - _nodeH);
                                    });
                                  },
                                  onMoveEnd: () => _save(app, wf),
                                  onConnectStart: () => setState(() {
                                    _dragFrom = n.id;
                                    _dragPos = Offset(n.x + _nodeW, n.y + _nodeH / 2);
                                  }),
                                  onConnectUpdate: (g) => setState(() => _dragPos = _toCanvas(g)),
                                  onConnectEnd: () {
                                    final p = _dragPos;
                                    if (p != null) {
                                      final target = wf.nodes
                                          .where((m) => m.id != n.id && Rect.fromLTWH(m.x - 20, m.y - 20, _nodeW + 40, _nodeH + 40).contains(p))
                                          .firstOrNull;
                                      if (target != null) {
                                        wf.connect(n.id, target.id);
                                        _save(app, wf);
                                      }
                                    }
                                    setState(() {
                                      _dragFrom = null;
                                      _dragPos = null;
                                    });
                                  },
                                ),
                              ),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
                // ---- Hinweise
                if (problems.isNotEmpty)
                  Positioned(
                    left: 14,
                    top: 14,
                    right: 14,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: c.amberSoft,
                          borderRadius: BorderRadius.circular(Ui.r),
                          border: Border.all(color: c.amber.withValues(alpha: 0.4)),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.warning_amber_rounded, size: 16, color: c.amber),
                          const SizedBox(width: 8),
                          Flexible(child: Text(problems.first, style: TextStyle(color: c.amber, fontSize: 12.5))),
                          if (problems.length > 1) Text('  +${problems.length - 1}', style: TextStyle(color: c.amber, fontSize: 12.5)),
                        ]),
                      ),
                    ),
                  ),
                // ---- Legende
                Positioned(
                  left: 14,
                  bottom: 14,
                  child: _Legend(),
                ),
                // ---- Zoom
                Positioned(
                  right: 14,
                  bottom: 14,
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    _MiniMap(wf: wf, tc: _tc, view: view.biggest),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(color: c.border),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(icon: const Icon(Icons.remove, size: 18), onPressed: () => _zoom(1 / 1.2, view.biggest)),
                        SizedBox(width: 44, child: Center(child: MonoText('${(_scale * 100).round()}%'))),
                        IconButton(icon: const Icon(Icons.add, size: 18), onPressed: () => _zoom(1.2, view.biggest)),
                        IconButton(
                          tooltip: 'Alles zeigen',
                          icon: const Icon(Icons.fit_screen_outlined, size: 18),
                          onPressed: () => setState(() => _fit(wf, view.biggest)),
                        ),
                      ]),
                    ),
                  ]),
                ),
              ]);
            }),
          ),
          if (wide && _selected != null) ...[
            VerticalDivider(width: 1, color: c.border),
            SizedBox(
              width: 360,
              child: _selected == '__flow__'
                  ? _FlowSettings(app: app, wf: wf, onClose: () => setState(() => _selected = null))
                  : (sel == null
                      ? const SizedBox()
                      : _NodeInspector(
                          key: ValueKey(sel.id),
                          app: app,
                          wf: wf,
                          node: sel,
                          output: app.flows.outputs[wf.id]?[sel.id],
                          onClose: () => setState(() => _selected = null),
                          onDelete: () {
                            wf.remove(sel.id);
                            _save(app, wf);
                            setState(() => _selected = null);
                          },
                          onChanged: () {
                            _save(app, wf);
                            setState(() {});
                          },
                        )),
            ),
          ],
        ]),
        bottomSheet: !wide && _selected != null
            ? SizedBox(
                height: box.maxHeight * 0.55,
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  shape: RoundedRectangleBorder(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(Ui.rLg)), side: BorderSide(color: c.border)),
                  child: _selected == '__flow__'
                      ? _FlowSettings(app: app, wf: wf, onClose: () => setState(() => _selected = null))
                      : (sel == null
                          ? const SizedBox()
                          : _NodeInspector(
                              key: ValueKey(sel.id),
                              app: app,
                              wf: wf,
                              node: sel,
                              output: app.flows.outputs[wf.id]?[sel.id],
                              onClose: () => setState(() => _selected = null),
                              onDelete: () {
                                wf.remove(sel.id);
                                _save(app, wf);
                                setState(() => _selected = null);
                              },
                              onChanged: () {
                                _save(app, wf);
                                setState(() {});
                              },
                            )),
                ),
              )
            : null,
      );
    });
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
    required this.onTap,
    required this.onMove,
    required this.onMoveEnd,
    required this.onConnectStart,
    required this.onConnectUpdate,
    required this.onConnectEnd,
  });
  final FlowNode node;
  final String? state;
  final bool selected;
  final bool problem;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMove;
  final VoidCallback onMoveEnd;
  final VoidCallback onConnectStart;
  final ValueChanged<Offset> onConnectUpdate;
  final VoidCallback onConnectEnd;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final color = flowColor(context, node.type);
    final (chipLabel, chipColor) = switch (state) {
      'running' => ('Läuft', c.amber),
      'done' => ('Fertig', c.mint),
      'skipped' => ('Übersprungen', c.muted),
      'error' => ('Fehler', c.red),
      'pending' => ('Wartet', c.faint),
      _ => (null, c.faint),
    };
    final border = selected ? c.mint : (state == 'error' || problem ? c.red.withValues(alpha: 0.7) : (state == 'running' ? c.amber : c.borderStrong));
    return Stack(clipBehavior: Clip.none, children: [
      Positioned.fill(
        child: GestureDetector(
          onTap: onTap,
          onPanUpdate: (d) => onMove(d.delta),
          onPanEnd: (_) => onMoveEnd(),
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: border, width: selected ? 1.8 : 1),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.22), blurRadius: 14, offset: const Offset(0, 6)),
                if (state == 'running') BoxShadow(color: c.amber.withValues(alpha: 0.25), blurRadius: 18),
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
                    Text(node.type.label.toUpperCase(),
                        style: TextStyle(fontSize: 9.5, letterSpacing: 1.1, color: c.faint, fontWeight: FontWeight.w600)),
                    Text(node.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface)),
                  ]),
                ),
              ]),
              const Spacer(),
              MonoText(node.summary.isEmpty ? '—' : node.summary.replaceAll('\n', ' '), size: 10.5),
            ]),
          ),
        ),
      ),
      if (chipLabel != null) Positioned(right: 10, top: -10, child: StatusChip(chipLabel, color: chipColor, dense: true, soft: Color.alphaBlend(chipColor.withValues(alpha: 0.22), scheme.surface))),
      // Eingang
      if (node.type != FlowNodeType.trigger)
        Positioned(left: -7, top: _nodeH / 2 - 7, child: _Port(color: c.borderStrong, fill: scheme.surface)),
      // Ausgang: ziehen, um zu verbinden
      Positioned(
        right: -11,
        top: _nodeH / 2 - 11,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => onConnectStart(),
          onPanUpdate: (d) => onConnectUpdate(d.globalPosition),
          onPanEnd: (_) => onConnectEnd(),
          child: Padding(padding: const EdgeInsets.all(4), child: _Port(color: color, fill: scheme.surface, big: true)),
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
        width: 14,
        height: 14,
        decoration: BoxDecoration(color: fill, shape: BoxShape.circle, border: Border.all(color: color, width: big ? 2.2 : 1.6)),
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
  _EdgePainter({required this.wf, required this.states, required this.color, required this.active, this.dragFrom, this.dragPos});
  final Workflow wf;
  final Map<String, String> states;
  final Color color;
  final Color active;
  final FlowNode? dragFrom;
  final Offset? dragPos;

  void _curve(Canvas canvas, Offset a, Offset b, Paint p, {bool arrow = true, bool dashed = false}) {
    final dx = math.max(60.0, (b.dx - a.dx).abs() / 2);
    final path = Path()
      ..moveTo(a.dx, a.dy)
      ..cubicTo(a.dx + dx, a.dy, b.dx - dx, b.dy, b.dx, b.dy);
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
      final done = states[a.id] == 'done' && (states[b.id] == 'done' || states[b.id] == 'running');
      final skipped = states[b.id] == 'skipped';
      final p = Paint()
        ..color = done ? active : (skipped ? color.withValues(alpha: 0.4) : color)
        ..strokeWidth = done ? 2.2 : 1.6
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      _curve(canvas, Offset(a.x + _nodeW + 2, a.y + _nodeH / 2), Offset(b.x - 6, b.y + _nodeH / 2), p, dashed: skipped);
    }
    if (dragFrom != null && dragPos != null) {
      final p = Paint()
        ..color = active
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      _curve(canvas, Offset(dragFrom!.x + _nodeW + 2, dragFrom!.y + _nodeH / 2), dragPos!, p, dashed: true);
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) => true;
}

class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: c.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.trip_origin, size: 14, color: c.mint),
        const SizedBox(width: 6),
        Text('Vom rechten Punkt auf einen Baustein ziehen = verbinden', style: TextStyle(fontSize: 12, color: c.muted)),
      ]),
    );
  }
}

class _MiniMap extends StatelessWidget {
  const _MiniMap({required this.wf, required this.tc, required this.view});
  final Workflow wf;
  final TransformationController tc;
  final Size view;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    if (wf.nodes.isEmpty || view.width < 600) return const SizedBox.shrink();
    return Container(
      width: 180,
      height: 110,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(Ui.r),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.all(8),
      child: CustomPaint(painter: _MiniPainter(wf, tc, view, c, (t) => flowColor(context, t))),
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
    // sichtbarer Ausschnitt
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
  const _Head({required this.icon, required this.color, required this.title, required this.onClose, this.trailing});
  final IconData icon;
  final Color color;
  final String title;
  final VoidCallback onClose;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Row(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
          if (trailing != null) trailing!,
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
            subtitle: const Text('Zeitplan und Watchlist lösen den Prozess aus'),
            value: wf.enabled,
            onChanged: (v) {
              wf.enabled = v;
              app.flows.upsert(wf);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Darf ins Internet'),
            subtitle: const Text('Websuche, Webseiten, Nachrichten, Wetter ohne Rückfrage'),
            value: wf.allowInternet,
            onChanged: (v) {
              wf.allowInternet = v;
              app.flows.upsert(wf);
            },
          ),
          const SizedBox(height: 12),
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
    required this.onClose,
    required this.onDelete,
    required this.onChanged,
  });
  final AppController app;
  final Workflow wf;
  final FlowNode node;
  final String? output;
  final VoidCallback onClose;
  final VoidCallback onDelete;
  final VoidCallback onChanged;

  @override
  State<_NodeInspector> createState() => _NodeInspectorState();
}

class _NodeInspectorState extends State<_NodeInspector> {
  final Map<String, TextEditingController> _ctrls = {};

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

  Widget _field(String key, String label, {String? hint, int lines = 1, String? helper}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: _ctrl(key, n.str(key)),
          minLines: lines,
          maxLines: lines == 1 ? 1 : lines + 4,
          decoration: InputDecoration(labelText: label, hintText: hint, helperText: helper, helperMaxLines: 3),
          onChanged: (v) => _set(key, v),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final app = widget.app;
    final color = flowColor(context, n.type);
    final tools = [...app.tools, ...app.mcpTools];
    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: _ctrl('__title', n.title),
          decoration: const InputDecoration(labelText: 'Titel'),
          onChanged: (v) {
            n.title = v;
            widget.onChanged();
          },
        ),
      ),
    ];
    switch (n.type) {
      case FlowNodeType.trigger:
        final mode = n.str('mode', 'manual');
        children.addAll([
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'manual', label: Text('Manuell')),
              ButtonSegment(value: 'schedule', label: Text('Zeitplan')),
              ButtonSegment(value: 'watch', label: Text('Watchlist')),
            ],
            selected: {mode},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => _set('mode', v.first)),
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
          if (mode == 'watch')
            DropdownButtonFormField<String>(
              initialValue: app.watchlist.items.any((w) => w.id == n.str('watchId')) ? n.str('watchId') : '',
              decoration: const InputDecoration(labelText: 'Bei Änderung von'),
              items: [
                const DropdownMenuItem(value: '', child: Text('jedem Watchlist-Eintrag')),
                for (final w in app.watchlist.items) DropdownMenuItem(value: w.id, child: Text(w.title)),
              ],
              onChanged: (v) => setState(() => _set('watchId', v ?? '')),
            ),
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
          for (final p in tool.params) {
            children.add(Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                controller: _ctrl('arg:${p.name}', '${args[p.name] ?? ''}'),
                decoration: InputDecoration(labelText: p.name, helperText: p.description, helperMaxLines: 2),
                onChanged: (v) {
                  args[p.name] = v;
                  widget.onChanged();
                },
              ),
            ));
          }
        }
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
    children.addAll([
      const SectionLabel('Verbindungen', padding: EdgeInsets.fromLTRB(0, 12, 0, 6)),
      if (ins.isEmpty && outs.isEmpty) Text('Noch keine – vom rechten Punkt ziehen.', style: t.bodySmall),
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
        trailing: IconButton(tooltip: 'Baustein löschen', icon: Icon(Icons.delete_outline, color: c.red), onPressed: widget.onDelete),
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
