import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_engine/agent_engine.dart';

import '../data/models.dart';
import '../version.dart';
import 'activity_log.dart';
import 'app_controller.dart';
import 'run_stats.dart';
import 'vault.dart';
import 'voice_service.dart' show appLog;

/// Junels als MCP-Server: andere Programme auf diesem Gerät (Claude Desktop, n8n, Dify,
/// LangGraph …) können deine Skills und Prozesse als Werkzeuge nutzen.
/// Sicherheit: nur 127.0.0.1, nur mit Schlüssel, Aktionen (Mail senden usw.) werden nur
/// vorgeschlagen und warten im Chat „Externe Aufrufe“ auf deine Freigabe.
class JunelsMcpServer {
  JunelsMcpServer(this.app);
  final AppController app;

  HttpServer? _http;
  String? error;
  int calls = 0;
  DateTime? lastCall;
  String lastTool = '';

  bool get running => _http != null;
  int get port => app.settings.mcpServePort;
  String get url => 'http://127.0.0.1:$port/mcp';

  static const _tokenKey = 'mcpserve:token';

  Future<String> token() async {
    final t = await Vault.read(_tokenKey);
    if (t != null && t.length >= 24) return t;
    return newToken();
  }

  Future<String> newToken() async {
    final r = Random.secure();
    final t = base64Url.encode([for (var i = 0; i < 32; i++) r.nextInt(256)]).replaceAll('=', '');
    await Vault.write(_tokenKey, t);
    return t;
  }

  late final McpServeCore core = McpServeCore(
    name: 'junels',
    version: appVersion,
    instructions: 'Junels ist ein lokaler KI-Agent. Die Werkzeuge führen Skills und Prozesse des Nutzers aus. '
        'Aktionen wie Senden oder Buchen werden nur vorgeschlagen und vom Nutzer in Junels freigegeben.',
    tools: _tools,
  );

  List<ServedTool> _tools() {
    final out = <ServedTool>[];
    final used = <String>{};
    String unique(String n) {
      var v = n;
      for (var i = 2; !used.add(v); i++) {
        v = '${n}_$i';
      }
      return v;
    }

    out.add(ServedTool(
      'junels_fragen',
      'Stellt Junels eine Frage oder einen Auftrag. Junels nutzt seine Werkzeuge, Gedächtnis und Wissensbasis.',
      {
        'type': 'object',
        'properties': {
          'frage': {'type': 'string', 'description': 'Frage oder Auftrag in natürlicher Sprache'}
        },
        'required': ['frage'],
      },
      (a) => _run('junels_fragen', 'Frage', '${a['frage'] ?? ''}'),
      title: 'Junels fragen',
    ));
    used.add('junels_fragen');
    for (final s in app.skills.enabled) {
      final name = unique('skill_${McpServeCore.safeName(s.command)}');
      out.add(ServedTool(
        name,
        '${s.when.isEmpty ? s.name : s.when} (Junels-Skill „${s.name}“)',
        {
          'type': 'object',
          'properties': {
            'aufgabe': {'type': 'string', 'description': 'Was der Skill tun soll'}
          },
          'required': ['aufgabe'],
        },
        (a) => _run(name, s.name, '${a['aufgabe'] ?? ''}', skillId: s.id),
        title: s.name,
      ));
    }
    for (final wf in app.flows.flows) {
      if (!wf.enabled) continue;
      final name = unique('prozess_${McpServeCore.safeName(wf.name)}');
      out.add(ServedTool(
        name,
        'Startet den Junels-Prozess „${wf.name}“ (${wf.nodes.length} Bausteine) und liefert das Ergebnis.',
        {
          'type': 'object',
          'properties': {
            'eingabe': {'type': 'string', 'description': 'Optionaler Text, der als Eingabe in den Prozess geht'}
          },
        },
        (a) => _runFlow(name, wf.id, '${a['eingabe'] ?? ''}'),
        title: 'Prozess: ${wf.name}',
      ));
    }
    return out;
  }

  Future<String> _run(String tool, String label, String task, {String? skillId}) async {
    if (task.trim().isEmpty) throw Exception('Kein Auftrag übergeben.');
    final skill = skillId == null ? null : app.skills.byId(skillId);
    if (skillId != null && skill == null) throw Exception('Skill gibt es nicht mehr.');
    final conv = app.routineConversation('mcp-extern', '🔌 Externe Aufrufe');
    final now = DateTime.now();
    conv.entries.add(ChatEntry(role: 'user', text: task, via: 'Extern · $label'));
    final entry = ChatEntry(role: 'assistant', via: '${now.day}.${now.month}. ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} · extern');
    conv.entries.add(entry);
    if (conv.entries.length > 60) conv.entries.removeRange(0, conv.entries.length - 60);
    final meter = RunMeter();
    final sw = Stopwatch()..start();
    var status = 'ok';
    var err = '';
    try {
      final answer = await app
          .automationAgent(task, allowInternet: app.settings.mcpServeInternet, conv: conv, entry: entry, skill: skill, meter: meter, source: 'mcp')
          .timeout(const Duration(minutes: 10), onTimeout: () => throw Exception('Zeitüberschreitung nach 10 Minuten'));
      entry.text = answer;
      final pending = entry.actions.length;
      return pending == 0 ? answer : '$answer\n\n($pending Aktion(en) warten in Junels auf Freigabe durch den Nutzer.)';
    } catch (e) {
      status = 'error';
      err = '$e'.replaceFirst('Exception: ', '');
      entry.text = 'Fehler: $err';
      rethrow;
    } finally {
      entry.durationMs = sw.elapsedMilliseconds;
      conv.updated = DateTime.now();
      unawaited(app.storage.saveConversation(conv));
      _record(tool, label, sw.elapsedMilliseconds, status, err, meter);
    }
  }

  Future<String> _runFlow(String tool, String flowId, String input) async {
    final wf = app.flows.flows.where((f) => f.id == flowId).firstOrNull;
    if (wf == null) throw Exception('Prozess gibt es nicht mehr.');
    if (app.flows.isRunning(wf.id)) throw Exception('Der Prozess läuft gerade schon.');
    final sw = Stopwatch()..start();
    await app.flows.run(wf, input: input, event: 'extern');
    _record(tool, 'Prozess ${wf.name}', sw.elapsedMilliseconds, wf.lastStatus == 'Erfolgreich' ? 'ok' : 'error', wf.lastStatus ?? '', RunMeter(),
        stats: false);
    if (wf.lastStatus != 'Erfolgreich') {
      final fe = app.flows.errors[wf.id]?.values.firstOrNull;
      throw Exception('Prozess „${wf.name}“: ${fe?.message ?? wf.lastStatus}');
    }
    final out = app.flows.outputs[wf.id] ?? const {};
    for (final n in wf.order().reversed) {
      final v = out[n.id];
      if (v != null && v.trim().isNotEmpty) return v;
    }
    return 'Prozess „${wf.name}“ abgeschlossen.';
  }

  void _record(String tool, String label, int ms, String status, String err, RunMeter m, {bool stats = true}) {
    calls++;
    lastCall = DateTime.now();
    lastTool = label;
    if (stats) {
      unawaited(app.runStats.add(RunRecord(
          source: 'mcp',
          refId: tool,
          name: label,
          start: DateTime.now().subtract(Duration(milliseconds: ms)),
          ms: ms,
          status: status,
          error: err,
          trigger: 'extern',
          calls: m.calls,
          tokensIn: m.tokensIn,
          tokensOut: m.tokensOut,
          tools: m.tools,
          toolErrors: m.toolErrors,
          models: m.models.toList())));
    }
    unawaited(app.logActivity(Activity(
        kind: 'mcp',
        title: 'Externer Aufruf: $label${status == 'ok' ? '' : ' (Fehler)'}',
        detail: '${(ms / 1000).toStringAsFixed(1)} s${err.isEmpty ? '' : ' · $err'}',
        approval: 'Junels-MCP-Server (von dir eingeschaltet)')));
    app.refreshUi();
  }

  Future<void> start() async {
    await stop();
    error = null;
    try {
      final tok = await token();
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _http = s;
      s.listen((req) => unawaited(_handle(req, tok)), onError: (Object e) => appLog('MCP-Server', '$e', error: true));
      appLog('MCP-Server', 'läuft auf $url');
    } catch (e) {
      error = e is SocketException ? 'Port $port ist belegt – anderen Port wählen.' : '$e';
      appLog('MCP-Server', 'Start fehlgeschlagen: $e', error: true);
    }
    app.refreshUi();
  }

  Future<void> stop() async {
    final s = _http;
    _http = null;
    if (s != null) await s.close(force: true);
    app.refreshUi();
  }

  Future<void> _handle(HttpRequest req, String tok) async {
    final res = req.response;
    Future<void> send(int status, [Object? body]) async {
      res.statusCode = status;
      if (body != null) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(body));
      }
      await res.close();
    }

    try {
      if (!McpServeCore.originAllowed(req.headers.value('origin'))) return await send(403, {'error': 'Herkunft nicht erlaubt'});
      if (req.uri.path != '/mcp' && req.uri.path != '/mcp/') return await send(404, {'error': 'Pfad /mcp verwenden'});
      final auth = req.headers.value('authorization') ?? '';
      final given = auth.toLowerCase().startsWith('bearer ') ? auth.substring(7).trim() : '';
      if (!_same(given, tok)) {
        res.headers.set('WWW-Authenticate', 'Bearer');
        return await send(401, {'error': 'Schlüssel fehlt oder falsch'});
      }
      if (req.method != 'POST') {
        res.headers.set('Allow', 'POST');
        return await send(405);
      }
      if ((req.contentLength) > 1024 * 1024) return await send(413);
      final raw = await utf8.decoder.bind(req).join();
      Object? msg;
      try {
        msg = jsonDecode(raw);
      } catch (_) {
        return await send(400, {
          'jsonrpc': '2.0',
          'id': null,
          'error': {'code': -32700, 'message': 'Kein gültiges JSON'}
        });
      }
      final out = await core.handle(msg);
      if (out == null) return await send(202);
      return await send(200, out);
    } catch (e) {
      try {
        await send(500, {'error': '$e'});
      } catch (_) {}
    }
  }

  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return d == 0;
  }

  /// Einrichtungs-Schnipsel für Clients (Claude Desktop, Cursor, n8n MCP Client …).
  Future<String> clientConfig() async => const JsonEncoder.withIndent('  ').convert({
        'mcpServers': {
          'junels': {
            'type': 'http',
            'url': url,
            'headers': {'Authorization': 'Bearer ${await token()}'}
          }
        }
      });
}
