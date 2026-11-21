// Prozesse (Workflows): Bausteine, die nacheinander ausgeführt werden – wie bei n8n.
// Hier liegt die reine Logik: Datenmodell, Reihenfolge, Platzhalter, Erzeugen
// aus einer Beschreibung. Ausgeführt wird in der App (Agent, Werkzeuge, Push).

import 'dart:convert';
import 'dart:math' as math;

enum FlowNodeType {
  trigger('Auslöser'),
  agent('Agent'),
  tool('Werkzeug'),
  condition('Bedingung'),
  notify('Benachrichtigung'),
  save('Speichern');

  const FlowNodeType(this.label);
  final String label;

  static FlowNodeType? parse(String? s) {
    final v = (s ?? '').toLowerCase().trim();
    for (final t in values) {
      if (t.name == v || t.label.toLowerCase() == v) return t;
    }
    return switch (v) {
      'start' || 'schedule' || 'zeitplan' || 'manual' || 'manuell' => trigger,
      'llm' || 'prompt' || 'ai' || 'ki' || 'aufgabe' || 'task' => agent,
      'if' || 'filter' || 'wenn' || 'check' => condition,
      'push' || 'notification' || 'nachricht' || 'message' || 'benachrichtigen' => notify,
      'memory' || 'note' || 'notiz' || 'document' || 'dokument' => save,
      'action' || 'werkzeuge' || 'tools' => tool,
      _ => null,
    };
  }
}

class FlowNode {
  FlowNode({required this.id, required this.type, required this.title, Map<String, dynamic>? config, this.x = 0, this.y = 0})
      : config = config ?? {};
  final String id;
  FlowNodeType type;
  String title;
  final Map<String, dynamic> config;
  double x;
  double y;

  String str(String key, [String fallback = '']) => (config[key] ?? fallback).toString();

  /// Kurzbeschreibung für die Karte.
  String get summary => switch (type) {
        FlowNodeType.trigger => switch (str('mode', 'manual')) {
            'schedule' => '${str('days', 'daily') == 'weekdays' ? 'Mo–Fr' : (str('days') == 'weekly' ? 'wöchentlich' : 'täglich')} '
                '${(config['hour'] ?? 8).toString().padLeft(2, '0')}:${(config['minute'] ?? 0).toString().padLeft(2, '0')}',
            'watch' => 'bei Watchlist-Änderung',
            _ => 'manuell starten',
          },
        FlowNodeType.agent => str('prompt'),
        FlowNodeType.tool => '${str('tool')} ${(config['args'] is Map && (config['args'] as Map).isNotEmpty) ? jsonEncode(config['args']) : ''}'.trim(),
        FlowNodeType.condition => '${config['negate'] == true ? 'enthält nicht' : 'enthält'} „${str('contains')}“',
        FlowNodeType.notify => str('title', 'Junels'),
        FlowNodeType.save => str('mode', 'memory') == 'document' ? 'als Dokument' : 'ins Gedächtnis',
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'title': title,
        'config': config,
        'x': x.roundToDouble(),
        'y': y.roundToDouble(),
      };

  factory FlowNode.fromJson(Map<String, dynamic> j) => FlowNode(
        id: j['id'].toString(),
        type: FlowNodeType.parse(j['type'] as String?) ?? FlowNodeType.agent,
        title: (j['title'] ?? '').toString(),
        config: (j['config'] as Map?)?.cast<String, dynamic>() ?? {},
        x: (j['x'] as num?)?.toDouble() ?? 0,
        y: (j['y'] as num?)?.toDouble() ?? 0,
      );
}

class FlowEdge {
  const FlowEdge(this.from, this.to);
  final String from;
  final String to;
  List<String> toJson() => [from, to];
}

class Workflow {
  Workflow({
    required this.id,
    required this.name,
    this.description = '',
    List<FlowNode>? nodes,
    List<FlowEdge>? edges,
    this.enabled = true,
    this.allowInternet = true,
    this.lastRun,
    this.lastStatus,
  })  : nodes = nodes ?? [],
        edges = edges ?? [];

  final String id;
  String name;
  String description;
  final List<FlowNode> nodes;
  final List<FlowEdge> edges;
  bool enabled;

  /// Beim Anlegen erteilte Freigabe: Werkzeuge dürfen ins Internet.
  bool allowInternet;
  DateTime? lastRun;
  String? lastStatus;

  FlowNode? node(String id) => nodes.where((n) => n.id == id).firstOrNull;
  FlowNode? get trigger => nodes.where((n) => n.type == FlowNodeType.trigger).firstOrNull;

  List<FlowNode> next(String id) => [for (final e in edges) if (e.from == id) node(e.to)].whereType<FlowNode>().toList();
  List<FlowNode> prev(String id) => [for (final e in edges) if (e.to == id) node(e.from)].whereType<FlowNode>().toList();

  String newNodeId() {
    var i = nodes.length + 1;
    while (node('n$i') != null) {
      i++;
    }
    return 'n$i';
  }

  void connect(String from, String to) {
    if (from == to || edges.any((e) => e.from == from && e.to == to)) return;
    // keine Kreise
    if (_reaches(to, from)) return;
    edges.add(FlowEdge(from, to));
  }

  bool _reaches(String start, String target) {
    final seen = <String>{};
    final stack = [start];
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      if (n == target) return true;
      if (!seen.add(n)) continue;
      stack.addAll(edges.where((e) => e.from == n).map((e) => e.to));
    }
    return false;
  }

  void remove(String id) {
    nodes.removeWhere((n) => n.id == id);
    edges.removeWhere((e) => e.from == id || e.to == id);
  }

  /// Ausführungsreihenfolge (topologisch, beginnend bei den Auslösern bzw. Knoten ohne Vorgänger).
  List<FlowNode> order() {
    final indeg = {for (final n in nodes) n.id: 0};
    for (final e in edges) {
      if (indeg.containsKey(e.to) && indeg.containsKey(e.from)) indeg[e.to] = indeg[e.to]! + 1;
    }
    final queue = [
      for (final n in nodes) if (indeg[n.id] == 0 && n.type == FlowNodeType.trigger) n,
      for (final n in nodes) if (indeg[n.id] == 0 && n.type != FlowNodeType.trigger) n,
    ];
    final out = <FlowNode>[];
    while (queue.isNotEmpty) {
      final n = queue.removeAt(0);
      out.add(n);
      for (final m in next(n.id)) {
        indeg[m.id] = indeg[m.id]! - 1;
        if (indeg[m.id] == 0) queue.add(m);
      }
    }
    return out;
  }

  /// Knoten in Spalten nach Tiefe anordnen (für erzeugte Prozesse).
  void layout({double dx = 300, double dy = 150}) {
    final depth = <String, int>{};
    for (final n in order()) {
      final p = prev(n.id);
      depth[n.id] = p.isEmpty ? 0 : p.map((x) => (depth[x.id] ?? 0) + 1).reduce(math.max);
    }
    final perCol = <int, int>{};
    for (final n in order()) {
      final d = depth[n.id] ?? 0;
      final row = perCol[d] ?? 0;
      perCol[d] = row + 1;
      n
        ..x = 40 + d * dx
        ..y = 60 + row * dy;
    }
  }

  /// Hinweise auf Lücken (fehlender Prompt, unverbundene Bausteine …).
  List<String> problems(Set<String> toolNames) {
    final p = <String>[];
    if (trigger == null) p.add('Es fehlt ein Auslöser.');
    for (final n in nodes) {
      if (n.type != FlowNodeType.trigger && prev(n.id).isEmpty) p.add('„${n.title}“ ist mit nichts verbunden.');
      if (n.type == FlowNodeType.agent && n.str('prompt').trim().isEmpty) p.add('„${n.title}“ hat keinen Auftrag.');
      if (n.type == FlowNodeType.tool && !toolNames.contains(n.str('tool'))) p.add('„${n.title}“: Werkzeug „${n.str('tool')}“ ist nicht aktiv.');
      if (n.type == FlowNodeType.condition && n.str('contains').trim().isEmpty) p.add('„${n.title}“: Bedingung ist leer.');
    }
    return p;
  }

  /// Ist der Zeitplan-Auslöser jetzt fällig (seit dem letzten Lauf erreicht)?
  bool dueAt(DateTime now) {
    final t = trigger;
    if (!enabled || t == null || t.str('mode') != 'schedule') return false;
    final hour = (t.config['hour'] as num?)?.toInt() ?? 8;
    final minute = (t.config['minute'] as num?)?.toInt() ?? 0;
    final days = t.str('days', 'daily');
    final today = DateTime(now.year, now.month, now.day, hour, minute);
    if (now.isBefore(today)) return false;
    if (days == 'weekdays' && now.weekday > 5) return false;
    if (days == 'weekly' && now.weekday != ((t.config['weekday'] as num?)?.toInt() ?? 1)) return false;
    final last = lastRun;
    // höchstens 2 h nachholen (z. B. nach dem Aufwachen des Geräts)
    if (now.difference(today).inMinutes > 120) return false;
    return last == null || last.isBefore(today);
  }

  /// Nächster geplanter Start (null = kein Zeitplan).
  DateTime? nextAfter(DateTime now) {
    final t = trigger;
    if (!enabled || t == null || t.str('mode') != 'schedule') return null;
    final hour = (t.config['hour'] as num?)?.toInt() ?? 8;
    final minute = (t.config['minute'] as num?)?.toInt() ?? 0;
    final days = t.str('days', 'daily');
    for (var i = 0; i < 8; i++) {
      final d = DateTime(now.year, now.month, now.day + i, hour, minute);
      if (!d.isAfter(now)) continue;
      if (days == 'weekdays' && d.weekday > 5) continue;
      if (days == 'weekly' && d.weekday != ((t.config['weekday'] as num?)?.toInt() ?? 1)) continue;
      return d;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (description.isNotEmpty) 'description': description,
        'nodes': [for (final n in nodes) n.toJson()],
        'edges': [for (final e in edges) e.toJson()],
        'enabled': enabled,
        'allowInternet': allowInternet,
        if (lastRun != null) 'lastRun': lastRun!.toIso8601String(),
        if (lastStatus != null) 'lastStatus': lastStatus,
      };

  factory Workflow.fromJson(Map<String, dynamic> j) => Workflow(
        id: j['id'].toString(),
        name: (j['name'] ?? 'Prozess').toString(),
        description: (j['description'] ?? '').toString(),
        nodes: [for (final n in (j['nodes'] as List? ?? const [])) if (n is Map) FlowNode.fromJson(n.cast())],
        edges: [
          for (final e in (j['edges'] as List? ?? const []))
            if (e is List && e.length == 2)
              FlowEdge(e[0].toString(), e[1].toString())
            else if (e is Map && e['from'] != null && e['to'] != null)
              FlowEdge(e['from'].toString(), e['to'].toString())
        ],
        enabled: j['enabled'] as bool? ?? true,
        allowInternet: j['allowInternet'] as bool? ?? true,
        lastRun: DateTime.tryParse(j['lastRun'] as String? ?? ''),
        lastStatus: j['lastStatus'] as String?,
      );

  // ------------------------------------------------------------ Platzhalter

  /// Ersetzt {{vorher}}, {{eingabe}}, {{datum}}, {{uhrzeit}} und {{<Knoten-ID>}}.
  static String fill(String template, Map<String, String> vars) =>
      template.replaceAllMapped(RegExp(r'\{\{\s*([\wäöüÄÖÜß-]+)\s*\}\}'), (m) => vars[m.group(1)!.toLowerCase()] ?? vars[m.group(1)!] ?? '');

  // ------------------------------------------------------ Erzeugen per Prompt

  /// Allgemeine JSON-Grammatik (GBNF) für das lokale Modell.
  static const jsonGrammar = r'''root ::= object
value ::= object | array | string | number | ("true" | "false" | "null") ws
object ::= "{" ws ( string ":" ws value ( "," ws string ":" ws value )* )? "}" ws
array ::= "[" ws ( value ( "," ws value )* )? "]" ws
string ::= "\"" ( [^"\\\x7F\x00-\x1F] | "\\" ( ["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] ) )* "\"" ws
number ::= "-"? [0-9] [0-9]{0,15} ( "." [0-9] [0-9]{0,9} )? ws
ws ::= ( " " | "\n" )?
''';

  /// Anweisung an das Modell: Prozess als JSON.
  static String generationPrompt(String description, List<(String, String)> tools) => '''
Baue aus dieser Beschreibung einen Prozess (Workflow) aus Bausteinen:
"$description"

Bausteintypen:
- trigger: Auslöser. config: {"mode": "manual" | "schedule" | "watch", "hour": 0-23, "minute": 0-59, "days": "daily" | "weekdays" | "weekly"}
- agent: Auftrag an den KI-Agenten (darf Werkzeuge benutzen). config: {"prompt": "…"} – mit {{vorher}} bekommt er das Ergebnis des vorigen Bausteins.
- tool: ein Werkzeug direkt aufrufen. config: {"tool": "<name>", "args": {…}}
- condition: weiter nur, wenn das vorige Ergebnis einen Text enthält. config: {"contains": "…", "negate": false}
- notify: Push-Nachricht. config: {"title": "…", "text": "{{vorher}}"}
- save: Ergebnis speichern. config: {"mode": "memory" | "document", "title": "…"}

Verfügbare Werkzeuge: ${tools.map((t) => '${t.$1} (${t.$2})').join(', ')}

Antworte nur mit JSON in dieser Form:
{"name": "Kurzer Name", "nodes": [{"id": "n1", "type": "trigger", "title": "…", "config": {…}}, …], "edges": [["n1", "n2"], …]}
Halte den Prozess einfach (3–6 Bausteine), beginne mit genau einem trigger und verbinde die Bausteine der Reihe nach. Titel und Texte auf Deutsch.''';

  /// Liest die Modellantwort tolerant (Codeblock, Text drumherum, Varianten der Felder).
  static Workflow? fromModelJson(String text, {required String id, Set<String> toolNames = const {}}) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    Map<String, dynamic> j;
    try {
      j = (jsonDecode(text.substring(start, end + 1)) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
    final rawNodes = (j['nodes'] ?? j['steps'] ?? j['bausteine']) as List?;
    if (rawNodes == null || rawNodes.isEmpty) return null;
    final wf = Workflow(id: id, name: (j['name'] ?? j['title'] ?? 'Neuer Prozess').toString());
    var i = 0;
    for (final r in rawNodes) {
      if (r is! Map) continue;
      i++;
      final type = FlowNodeType.parse(r['type']?.toString()) ?? FlowNodeType.agent;
      final cfg = <String, dynamic>{...?(r['config'] as Map?)?.cast<String, dynamic>()};
      // Felder, die manche Modelle direkt am Knoten statt in config schreiben
      for (final k in const ['prompt', 'tool', 'args', 'contains', 'negate', 'text', 'mode', 'hour', 'minute', 'days']) {
        if (!cfg.containsKey(k) && r.containsKey(k)) cfg[k] = r[k];
      }
      if (type == FlowNodeType.tool && toolNames.isNotEmpty && !toolNames.contains(cfg['tool'])) {
        // unbekanntes Werkzeug: als Agenten-Auftrag weiterführen
        final args = cfg['args'];
        wf.nodes.add(FlowNode(
            id: (r['id'] ?? 'n$i').toString(),
            type: FlowNodeType.agent,
            title: (r['title'] ?? 'Agent').toString(),
            config: {'prompt': 'Benutze ${cfg['tool']} ${args is Map ? jsonEncode(args) : ''} und gib das Ergebnis zurück. {{vorher}}'.trim()}));
        continue;
      }
      if (type == FlowNodeType.trigger) {
        cfg['mode'] = const {'manual', 'schedule', 'watch'}.contains(cfg['mode']) ? cfg['mode'] : (cfg['hour'] != null ? 'schedule' : 'manual');
        for (final k in const ['hour', 'minute']) {
          if (cfg[k] != null) cfg[k] = int.tryParse(cfg[k].toString()) ?? 0;
        }
      }
      wf.nodes.add(FlowNode(
          id: (r['id'] ?? 'n$i').toString(),
          type: type,
          title: (r['title'] ?? r['name'] ?? type.label).toString(),
          config: cfg));
    }
    for (final e in (j['edges'] ?? j['connections'] ?? const []) as List) {
      if (e is List && e.length >= 2) wf.connect(e[0].toString(), e[1].toString());
      if (e is Map && e['from'] != null && e['to'] != null) wf.connect(e['from'].toString(), e['to'].toString());
    }
    // ohne Kanten: der Reihe nach verbinden
    if (wf.edges.isEmpty) {
      for (var k = 0; k + 1 < wf.nodes.length; k++) {
        wf.connect(wf.nodes[k].id, wf.nodes[k + 1].id);
      }
    }
    if (wf.trigger == null) {
      final t = FlowNode(id: wf.newNodeId(), type: FlowNodeType.trigger, title: 'Start', config: {'mode': 'manual'});
      final first = wf.nodes.first.id;
      wf.nodes.insert(0, t);
      wf.connect(t.id, first);
    }
    wf.layout();
    return wf;
  }

  /// Ohne Modell: einfacher Ablauf Auslöser → Agent → Benachrichtigung.
  static Workflow fromDescription(String description, {required String id}) {
    final s = scheduleOf(description);
    final wf = Workflow(id: id, name: _nameOf(description), description: description);
    wf.nodes.addAll([
      FlowNode(
          id: 'n1',
          type: FlowNodeType.trigger,
          title: s == null ? 'Manuell starten' : 'Zeitplan',
          config: s == null ? {'mode': 'manual'} : {'mode': 'schedule', 'hour': s.$1, 'minute': s.$2, 'days': s.$3}),
      FlowNode(id: 'n2', type: FlowNodeType.agent, title: 'Auftrag', config: {'prompt': _strip(description)}),
      FlowNode(id: 'n3', type: FlowNodeType.notify, title: 'Push-Nachricht', config: {'title': _nameOf(description), 'text': '{{vorher}}'}),
    ]);
    wf.connect('n1', 'n2');
    wf.connect('n2', 'n3');
    wf.layout();
    return wf;
  }

  /// Uhrzeit und Rhythmus aus Text („jeden Morgen um 7“, „werktags 8:30“, „montags“).
  static (int, int, String)? scheduleOf(String text) {
    final t = text.toLowerCase();
    final time = RegExp(r'(?:um|ab|gegen)?\s*(\d{1,2})(?:[:.](\d{2}))?\s*(?:uhr|h\b)').firstMatch(t) ??
        RegExp(r'\bum\s+(\d{1,2})(?:[:.](\d{2}))?\b').firstMatch(t);
    var hour = time == null ? null : int.tryParse(time.group(1)!);
    final minute = time?.group(2) == null ? 0 : int.parse(time!.group(2)!);
    if (hour != null && hour > 23) hour = null;
    final days = RegExp(r'werktag|wochentag|mo\s*[–-]\s*fr|montag bis freitag').hasMatch(t)
        ? 'weekdays'
        : RegExp(r'wöchentlich|jede woche|montags|jeden montag|freitags|jeden freitag').hasMatch(t)
            ? 'weekly'
            : 'daily';
    final periodic = RegExp(r'jede[nr]? (tag|morgen|abend|früh)|täglich|morgens|abends|werktag|wöchentlich|jede woche|montags|freitags|jeden montag|jeden freitag')
        .hasMatch(t);
    if (!periodic && hour == null) return null;
    hour ??= t.contains('abend') ? 19 : 7;
    if (hour < 12 && t.contains('abend')) hour += 12;
    return (hour, minute, days);
  }

  static String _strip(String d) => d
      .replaceAll(RegExp(r'(jede[nr]? (tag|morgen|abend)|täglich|werktags|wöchentlich)(\s+um\s+\d{1,2}([:.]\d{2})?\s*(uhr)?)?[,:]?\s*', caseSensitive: false), '')
      .trim();

  static String _nameOf(String d) {
    final s = _strip(d).replaceAll(RegExp(r'\s+'), ' ');
    final cut = s.split(RegExp(r'[,.;:]')).first.trim();
    final words = cut.split(' ');
    final name = words.take(5).join(' ');
    return name.isEmpty ? 'Neuer Prozess' : '${name[0].toUpperCase()}${name.substring(1)}';
  }
}
