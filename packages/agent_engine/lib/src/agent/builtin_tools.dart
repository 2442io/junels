// Eingebaute lokale Tools (SRS Abschnitt 5). Keines greift aufs Netzwerk zu.

import 'dart:convert';
import 'dart:math' as math;

import 'tool.dart';

List<AgentTool> builtinTools() => [
      TextSearchTool(),
      ReadFileTool(),
      JsonQueryTool(),
      CalculatorTool(),
      WriteArtifactTool(),
      DateTimeTool(),
    ];

// ---------------------------------------------------------------------------

class TextSearchTool extends AgentTool {
  @override
  String get name => 'text_search';
  @override
  String get title => 'Textsuche';
  @override
  String get description =>
      'Durchsucht angehängte Dateien und die lokale Wissensbasis nach Begriffen.';
  @override
  List<ToolParam> get params =>
      const [ToolParam('query', ParamType.string, 'Suchbegriffe')];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final query = (args['query'] ?? '').toString().trim();
    if (query.isEmpty) throw ToolException('query ist leer');
    final docs = ctx.allDocuments;
    if (docs.isEmpty) return 'Keine Dateien vorhanden, in denen gesucht werden kann.';

    final terms = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.length > 1)
        .toList();
    if (terms.isEmpty) terms.add(query.toLowerCase());

    final hits = <({String file, int line, String text, int score})>[];
    for (final d in docs) {
      final lines = const LineSplitter().convert(d.content);
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].toLowerCase();
        var score = 0;
        for (final t in terms) {
          if (l.contains(t)) score += 2;
        }
        if (l.contains(query.toLowerCase())) score += 3;
        if (score > 0) {
          final text = lines[i].trim();
          hits.add((
            file: d.name,
            line: i + 1,
            text: text.length > 200 ? '${text.substring(0, 200)}…' : text,
            score: score
          ));
        }
      }
    }
    if (hits.isEmpty) return 'Keine Treffer für "$query".';
    hits.sort((a, b) => b.score.compareTo(a.score));
    final top = hits.take(8);
    return '${hits.length} Treffer, die besten:\n${top.map((h) => '${h.file}:${h.line}: ${h.text}').join('\n')}';
  }
}

// ---------------------------------------------------------------------------

class ReadFileTool extends AgentTool {
  static const chunk = 3000;

  @override
  String get name => 'read_file';
  @override
  String get title => 'Datei lesen';
  @override
  String get description =>
      'Liest eine angehängte Datei abschnittsweise ($chunk Zeichen pro Aufruf).';
  @override
  List<ToolParam> get params => const [
        ToolParam('name', ParamType.string, 'Dateiname'),
        ToolParam('start', ParamType.integer, 'Startposition in Zeichen, 0 = Anfang'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final name = (args['name'] ?? '').toString();
    final doc = ctx.find(name);
    if (doc == null) {
      final names = ctx.allDocuments.map((d) => d.name).join(', ');
      throw ToolException(
          'Datei "$name" nicht gefunden. Vorhanden: ${names.isEmpty ? 'keine' : names}');
    }
    final start = math.max(0, (args['start'] as num?)?.toInt() ?? 0);
    if (start >= doc.content.length) {
      return 'Ende der Datei erreicht (${doc.content.length} Zeichen).';
    }
    final end = math.min(doc.content.length, start + chunk);
    final more = end < doc.content.length
        ? '\n[… weiter mit start=$end, gesamt ${doc.content.length} Zeichen]'
        : '\n[Dateiende]';
    return '${doc.name} (Zeichen $start–$end):\n${doc.content.substring(start, end)}$more';
  }
}

// ---------------------------------------------------------------------------

class JsonQueryTool extends AgentTool {
  @override
  String get name => 'json_query';
  @override
  String get title => 'JSON-Abfrage';
  @override
  String get description =>
      'Liest Werte aus JSON (Dateiname oder JSON-Text) per Pfad wie "items[0].name" oder "items[*].price".';
  @override
  List<ToolParam> get params => const [
        ToolParam('source', ParamType.string, 'Dateiname oder JSON-Text'),
        ToolParam('path', ParamType.string, 'Pfad, leer = ganzes Dokument'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final source = (args['source'] ?? '').toString();
    final path = (args['path'] ?? '').toString().trim();
    final doc = ctx.find(source);
    final text = doc?.content ?? source;
    Object? data;
    try {
      data = jsonDecode(text);
    } on FormatException catch (e) {
      throw ToolException('Kein gültiges JSON: ${e.message}');
    }
    final result = query(data, path);
    final out = const JsonEncoder.withIndent('  ').convert(result);
    return out.length > 2500 ? '${out.substring(0, 2500)}\n[… gekürzt]' : out;
  }

  /// Unterstützt: a.b, a[0], a[*].b, ["key mit leerzeichen"]
  static Object? query(Object? data, String path) {
    if (path.isEmpty || path == r'$' || path == '.') return data;
    var p = path.startsWith(r'$') ? path.substring(1) : path;
    final tokens = <Object>[];
    final re = RegExp(r'''\.?([A-Za-z_][\w-]*)|\[(\d+|\*)\]|\["([^"]+)"\]''');
    var pos = 0;
    while (pos < p.length) {
      final m = re.matchAsPrefix(p, pos);
      if (m == null) throw ToolException('Ungültiger Pfad bei "${p.substring(pos)}"');
      if (m.group(1) != null) {
        tokens.add(m.group(1)!);
      } else if (m.group(2) != null) {
        tokens.add(m.group(2) == '*' ? '*' : int.parse(m.group(2)!));
      } else {
        tokens.add(m.group(3)!);
      }
      pos = m.end;
    }

    List<Object?> current = [data];
    var fanned = false;
    for (final t in tokens) {
      final next = <Object?>[];
      for (final c in current) {
        if (t == '*') {
          if (c is List) next.addAll(c);
          if (c is Map) next.addAll(c.values);
          fanned = true;
        } else if (t is int) {
          if (c is List && t < c.length) next.add(c[t]);
        } else if (c is Map && c.containsKey(t)) {
          next.add(c[t]);
        }
      }
      current = next;
    }
    if (current.isEmpty) throw ToolException('Pfad "$path" nicht gefunden');
    return fanned ? current : current.first;
  }
}

// ---------------------------------------------------------------------------

class CalculatorTool extends AgentTool {
  @override
  String get name => 'calculator';
  @override
  String get title => 'Rechner';
  @override
  String get description =>
      'Berechnet mathematische Ausdrücke (+ - * / ^ %, Klammern, sqrt, sin, cos, tan, log, ln, abs, round, min, max, pi, e).';
  @override
  List<ToolParam> get params =>
      const [ToolParam('expression', ParamType.string, 'Ausdruck, z. B. "(3+4)*2"')];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final expr = (args['expression'] ?? '').toString();
    final v = evaluate(expr);
    return '$expr = ${format(v)}';
  }

  static String format(double v) {
    if (v.isNaN) return 'nicht definiert';
    if (v.isInfinite) return v > 0 ? '∞' : '-∞';
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
    final s = v.toStringAsPrecision(12);
    return s.contains('e') ? s : s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  static double evaluate(String expression) {
    var e = expression.replaceAll('×', '*').replaceAll('÷', '/').replaceAll(';', ',');
    // Dezimalkomma ("1,5") nur, wenn keine Funktion mit Argumentliste vorkommt
    if (!RegExp(r'[a-zA-Z]\s*\(').hasMatch(e)) {
      e = e.replaceAllMapped(RegExp(r'(\d),(\d)'), (m) => '${m[1]}.${m[2]}');
    }
    return _Parser(e).parse();
  }
}

class _Parser {
  _Parser(this.s);
  final String s;
  int i = 0;

  double parse() {
    final v = _expr();
    _ws();
    if (i < s.length) throw ToolException('Unerwartetes Zeichen "${s[i]}" an Position $i');
    return v;
  }

  void _ws() {
    while (i < s.length && s[i].trim().isEmpty) {
      i++;
    }
  }

  bool _eat(String c) {
    _ws();
    if (i < s.length && s[i] == c) {
      i++;
      return true;
    }
    return false;
  }

  double _expr() {
    var v = _term();
    while (true) {
      if (_eat('+')) {
        v += _term();
      } else if (_eat('-')) {
        v -= _term();
      } else {
        return v;
      }
    }
  }

  double _term() {
    var v = _unary();
    while (true) {
      if (_eat('*')) {
        v *= _unary();
      } else if (_eat('/')) {
        v /= _unary();
      } else if (_eat('%')) {
        v %= _unary();
      } else {
        return v;
      }
    }
  }

  // Vorzeichen bindet schwächer als ^ : -2^2 = -4
  double _unary() {
    if (_eat('-')) return -_unary();
    if (_eat('+')) return _unary();
    return _power();
  }

  double _power() {
    final base = _atom();
    if (_eat('^')) return math.pow(base, _unary()).toDouble();
    return base;
  }

  double _atom() {
    _ws();
    if (_eat('(')) {
      final v = _expr();
      if (!_eat(')')) throw ToolException('")" fehlt');
      return v;
    }
    final start = i;
    if (i < s.length && RegExp(r'[0-9.]').hasMatch(s[i])) {
      while (i < s.length && RegExp(r'[0-9.]').hasMatch(s[i])) {
        i++;
      }
      if (i < s.length && (s[i] == 'e' || s[i] == 'E') &&
          i + 1 < s.length && RegExp(r'[0-9+-]').hasMatch(s[i + 1])) {
        i += 2;
        while (i < s.length && RegExp(r'[0-9]').hasMatch(s[i])) {
          i++;
        }
      }
      final v = double.tryParse(s.substring(start, i));
      if (v == null) throw ToolException('Ungültige Zahl "${s.substring(start, i)}"');
      return v;
    }
    while (i < s.length && RegExp(r'[a-zA-Z_]').hasMatch(s[i])) {
      i++;
    }
    final name = s.substring(start, i).toLowerCase();
    if (name.isEmpty) {
      throw ToolException(i < s.length ? 'Unerwartetes Zeichen "${s[i]}"' : 'Ausdruck unvollständig');
    }
    if (name == 'pi') return math.pi;
    if (name == 'e') return math.e;
    if (!_eat('(')) throw ToolException('Unbekannter Name "$name"');
    final args = <double>[_expr()];
    while (_eat(',')) {
      args.add(_expr());
    }
    if (!_eat(')')) throw ToolException('")" fehlt nach $name');
    double one() => args.first;
    return switch (name) {
      'sqrt' => math.sqrt(one()),
      'sin' => math.sin(one()),
      'cos' => math.cos(one()),
      'tan' => math.tan(one()),
      'log' => math.log(one()) / math.ln10,
      'ln' => math.log(one()),
      'abs' => one().abs(),
      'round' => args.length > 1
          ? (one() * math.pow(10, args[1])).roundToDouble() / math.pow(10, args[1])
          : one().roundToDouble(),
      'floor' => one().floorToDouble(),
      'ceil' => one().ceilToDouble(),
      'min' => args.reduce(math.min),
      'max' => args.reduce(math.max),
      _ => throw ToolException('Unbekannte Funktion "$name"'),
    };
  }
}

// ---------------------------------------------------------------------------

class WriteArtifactTool extends AgentTool {
  @override
  String get name => 'write_artifact';
  @override
  String get title => 'Artefakt anlegen';
  @override
  String get description =>
      'Legt Code, eine Tabelle (Markdown) oder einen Bericht im Artefakt-Panel ab.';
  @override
  List<ToolParam> get params => const [
        ToolParam('title', ParamType.string, 'kurzer Titel'),
        ToolParam('kind', ParamType.enumeration, 'Art',
            values: ['code', 'markdown', 'table', 'json', 'text']),
        ToolParam('content', ParamType.string, 'vollständiger Inhalt'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final title = (args['title'] ?? 'Artefakt').toString().trim();
    final content = (args['content'] ?? '').toString();
    if (content.trim().isEmpty) throw ToolException('content ist leer');
    ctx.onArtifact(Artifact(
        title: title.isEmpty ? 'Artefakt' : title,
        kind: (args['kind'] ?? 'text').toString(),
        content: content));
    return 'Artefakt "$title" angelegt (${content.length} Zeichen).';
  }
}

// ---------------------------------------------------------------------------

class DateTimeTool extends AgentTool {
  @override
  String get name => 'datetime';
  @override
  String get title => 'Datum & Uhrzeit';
  @override
  String get description => 'Liefert aktuelles Datum, Uhrzeit und Wochentag des Geräts.';
  @override
  List<ToolParam> get params => const [];

  static const _days = ['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', 'Sonntag'];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final n = ctx.clock();
    String two(int v) => v.toString().padLeft(2, '0');
    final offset = n.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    return '${_days[n.weekday - 1]}, ${two(n.day)}.${two(n.month)}.${n.year}, '
        '${two(n.hour)}:${two(n.minute)} Uhr (UTC$sign${two(offset.inHours.abs())}:${two(offset.inMinutes.abs() % 60)}, '
        'ISO ${n.toIso8601String()})';
  }
}
