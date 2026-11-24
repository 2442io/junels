import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/foundation.dart';

/// Zählt während eines Laufs mit: Modellaufrufe, Tokens, Werkzeuge.
class RunMeter {
  int calls = 0;
  int tokensIn = 0;
  int tokensOut = 0;
  int tools = 0;
  int toolErrors = 0;
  final Set<String> models = {};

  void metrics(GenerationStats s) {
    calls++;
    if (s.promptTokens > 0) tokensIn += s.promptTokens;
    if (s.generatedTokens > 0) tokensOut += s.generatedTokens;
  }

  void tool(bool error) {
    tools++;
    if (error) toolErrors++;
  }
}

class NodeStat {
  NodeStat(this.title, this.type, this.ms, this.status);
  final String title;
  final String type;
  final int ms;
  final String status; // done | error | skipped | stopped

  Map<String, Object?> toJson() => {'t': title, 'y': type, 'ms': ms, 's': status};
  factory NodeStat.fromJson(Map<String, dynamic> j) =>
      NodeStat(j['t'] as String? ?? '', j['y'] as String? ?? '', (j['ms'] as num?)?.toInt() ?? 0, j['s'] as String? ?? '');
}

/// Ein abgeschlossener Lauf (Prozess oder externer Aufruf).
class RunRecord {
  RunRecord({
    required this.source,
    required this.refId,
    required this.name,
    required this.start,
    required this.ms,
    required this.status,
    this.error = '',
    this.trigger = '',
    this.calls = 0,
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.tools = 0,
    this.toolErrors = 0,
    this.models = const [],
    this.nodes = const [],
  });

  final String source; // flow | mcp
  final String refId;
  final String name;
  final DateTime start;
  final int ms;
  final String status; // ok | error | stopped
  final String error;
  final String trigger;
  final int calls, tokensIn, tokensOut, tools, toolErrors;
  final List<String> models;
  final List<NodeStat> nodes;

  bool get ok => status == 'ok';

  Map<String, Object?> toJson() => {
        'src': source,
        'ref': refId,
        'name': name,
        'at': start.millisecondsSinceEpoch,
        'ms': ms,
        'st': status,
        if (error.isNotEmpty) 'err': error,
        if (trigger.isNotEmpty) 'tr': trigger,
        if (calls > 0) 'c': calls,
        if (tokensIn > 0) 'ti': tokensIn,
        if (tokensOut > 0) 'to': tokensOut,
        if (tools > 0) 'tl': tools,
        if (toolErrors > 0) 'te': toolErrors,
        if (models.isNotEmpty) 'm': models,
        if (nodes.isNotEmpty) 'n': [for (final n in nodes) n.toJson()],
      };

  factory RunRecord.fromJson(Map<String, dynamic> j) => RunRecord(
        source: j['src'] as String? ?? 'flow',
        refId: j['ref'] as String? ?? '',
        name: j['name'] as String? ?? '',
        start: DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0),
        ms: (j['ms'] as num?)?.toInt() ?? 0,
        status: j['st'] as String? ?? 'ok',
        error: j['err'] as String? ?? '',
        trigger: j['tr'] as String? ?? '',
        calls: (j['c'] as num?)?.toInt() ?? 0,
        tokensIn: (j['ti'] as num?)?.toInt() ?? 0,
        tokensOut: (j['to'] as num?)?.toInt() ?? 0,
        tools: (j['tl'] as num?)?.toInt() ?? 0,
        toolErrors: (j['te'] as num?)?.toInt() ?? 0,
        models: [for (final m in (j['m'] as List?) ?? const []) '$m'],
        nodes: [for (final n in (j['n'] as List?) ?? const []) NodeStat.fromJson((n as Map).cast())],
      );
}

/// Zusammenfassung für einen Prozess / eine Quelle im gewählten Zeitraum.
class RunSummary {
  RunSummary(this.refId, this.name, this.source);
  final String refId;
  final String name;
  final String source;
  final List<RunRecord> runs = [];

  int get count => runs.length;
  int get ok => runs.where((r) => r.ok).length;
  int get failed => runs.where((r) => r.status == 'error').length;
  double get rate => count == 0 ? 0 : ok / count;
  int get avgMs => count == 0 ? 0 : runs.fold<int>(0, (a, r) => a + r.ms) ~/ count;
  int get maxMs => runs.fold<int>(0, (a, r) => r.ms > a ? r.ms : a);
  int get tokens => runs.fold<int>(0, (a, r) => a + r.tokensIn + r.tokensOut);
  int get calls => runs.fold<int>(0, (a, r) => a + r.calls);
  RunRecord? get lastError => runs.where((r) => r.status == 'error').lastOrNull;
  RunRecord? get last => runs.lastOrNull;

  /// Bausteine: Ø Dauer und Fehler, langsamste zuerst.
  List<({String title, String type, int avgMs, int errors, int count})> get nodeStats {
    final m = <String, List<NodeStat>>{};
    for (final r in runs) {
      for (final n in r.nodes) {
        (m['${n.type}|${n.title}'] ??= []).add(n);
      }
    }
    final out = [
      for (final e in m.entries)
        (
          title: e.value.first.title,
          type: e.value.first.type,
          avgMs: e.value.fold<int>(0, (a, n) => a + n.ms) ~/ e.value.length,
          errors: e.value.where((n) => n.status == 'error').length,
          count: e.value.length,
        )
    ]..sort((a, b) => b.avgMs.compareTo(a.avgMs));
    return out;
  }
}

/// Laufprotokoll für die Überwachung (lokal, max. 90 Tage / 3000 Läufe).
class RunStats extends ChangeNotifier {
  RunStats(this._file);
  final File _file;
  final List<RunRecord> records = [];

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final cutoff = DateTime.now().subtract(const Duration(days: 90));
      records
        ..clear()
        ..addAll([
          for (final line in await _file.readAsLines())
            if (line.trim().isNotEmpty)
              if (_parse(line) case final r? when r.start.isAfter(cutoff)) r
        ]);
      notifyListeners();
    } catch (_) {}
  }

  RunRecord? _parse(String line) {
    try {
      return RunRecord.fromJson((jsonDecode(line) as Map).cast());
    } catch (_) {
      return null;
    }
  }

  Future<void> add(RunRecord r) async {
    records.add(r);
    var rewrite = false;
    if (records.length > 3000) {
      records.removeRange(0, records.length - 3000);
      rewrite = true;
    }
    notifyListeners();
    try {
      if (rewrite) {
        await _file.writeAsString('${records.map((x) => jsonEncode(x.toJson())).join('\n')}\n');
      } else {
        await _file.writeAsString('${jsonEncode(r.toJson())}\n', mode: FileMode.append);
      }
    } catch (_) {}
  }

  Future<void> clear({String? refId}) async {
    if (refId == null) {
      records.clear();
    } else {
      records.removeWhere((r) => r.refId == refId);
    }
    notifyListeners();
    try {
      await _file.writeAsString(records.isEmpty ? '' : '${records.map((x) => jsonEncode(x.toJson())).join('\n')}\n');
    } catch (_) {}
  }

  List<RunRecord> since(DateTime from) => [for (final r in records) if (r.start.isAfter(from)) r];

  List<RunSummary> summaries(DateTime from) {
    final m = <String, RunSummary>{};
    for (final r in since(from)) {
      (m['${r.source}:${r.refId}'] ??= RunSummary(r.refId, r.name, r.source)).runs.add(r);
    }
    return m.values.toList()..sort((a, b) => (b.last?.start ?? DateTime(0)).compareTo(a.last?.start ?? DateTime(0)));
  }
}
