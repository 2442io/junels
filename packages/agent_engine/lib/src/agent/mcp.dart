// MCP-Client (Model Context Protocol) für entfernte Server über HTTP:
// "Streamable HTTP" (aktueller Standard) und das ältere "HTTP + SSE".
// Tools der Server werden als normale Agent-Tools angeboten.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mcp_oauth.dart';
import 'tool.dart';

const mcpProtocolVersion = '2025-06-18';

/// Gespeicherte Beschreibung eines MCP-Tools (für den Offline-Betrieb zwischengespeichert).
class McpToolSpec {
  McpToolSpec({required this.name, required this.description, required this.inputSchema, this.enabled = true});
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  bool enabled;

  Map<String, Object?> toJson() => {'name': name, 'description': description, 'inputSchema': inputSchema, 'enabled': enabled};
  factory McpToolSpec.fromJson(Map<String, dynamic> j) => McpToolSpec(
        name: j['name'] as String? ?? '',
        description: j['description'] as String? ?? '',
        inputSchema: (j['inputSchema'] as Map?)?.cast<String, dynamic>() ?? const {},
        enabled: j['enabled'] as bool? ?? true,
      );
}

class McpServerConfig {
  McpServerConfig({
    required this.id,
    required this.name,
    required this.url,
    Map<String, String>? headers,
    this.enabled = true,
    this.trusted = false,
    List<McpToolSpec>? tools,
    this.lastSync,
    Map<String, String>? oauth,
  })  : headers = headers ?? {},
        tools = tools ?? [],
        oauth = oauth ?? {};

  final String id;
  String name;
  String url;

  /// z. B. {"Authorization": "Bearer …"}
  Map<String, String> headers;
  bool enabled;

  /// true = ohne Rückfrage verbinden (sonst Internet-Freigabe wie bei der Websuche)
  bool trusted;
  List<McpToolSpec> tools;
  DateTime? lastSync;

  /// OAuth-Anmeldung (access_token, refresh_token, expires_at, client_id, token_endpoint …)
  Map<String, String> oauth;
  bool get loggedIn => (oauth['access_token'] ?? '').isNotEmpty;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'headers': headers,
        'enabled': enabled,
        'trusted': trusted,
        'tools': tools.map((t) => t.toJson()).toList(),
        'lastSync': lastSync?.toIso8601String(),
        if (oauth.isNotEmpty) 'oauth': oauth,
      };

  factory McpServerConfig.fromJson(Map<String, dynamic> j) => McpServerConfig(
        id: j['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
        name: j['name'] as String? ?? 'MCP',
        url: j['url'] as String? ?? '',
        headers: (j['headers'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())),
        enabled: j['enabled'] as bool? ?? true,
        trusted: j['trusted'] as bool? ?? false,
        tools: [for (final t in (j['tools'] as List? ?? const [])) McpToolSpec.fromJson((t as Map).cast())],
        lastSync: DateTime.tryParse(j['lastSync'] as String? ?? ''),
        oauth: (j['oauth'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())),
      );

  /// Kurzname für Tool-Präfixe, z. B. "github".
  String get slug {
    final s = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return s.isEmpty ? 'mcp' : (s.length > 16 ? s.substring(0, 16) : s);
  }
}

class McpException implements Exception {
  McpException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Server verlangt eine Anmeldung (HTTP 401) – ggf. per OAuth im Browser.
class McpAuthException extends McpException {
  McpAuthException(super.message, {this.wwwAuthenticate});
  final String? wwwAuthenticate;
}

/// Eine Server-Ereignis-Nachricht aus einem SSE-Strom.
class _SseEvent {
  _SseEvent(this.event, this.data);
  final String event;
  final String data;
}

Stream<_SseEvent> _sse(Stream<List<int>> bytes) async* {
  var event = 'message';
  final data = StringBuffer();
  await for (final line in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        yield _SseEvent(event, data.toString());
      }
      event = 'message';
      data.clear();
    } else if (line.startsWith('event:')) {
      event = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      if (data.isNotEmpty) data.write('\n');
      data.write(line.substring(5).startsWith(' ') ? line.substring(6) : line.substring(5));
    }
  }
  if (data.isNotEmpty) yield _SseEvent(event, data.toString());
}

/// Verbindung zu einem MCP-Server.
class McpClient {
  McpClient(this.config, {this.timeout = const Duration(seconds: 60)});
  final McpServerConfig config;
  final Duration timeout;

  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  String? _session;
  bool _initialized = false;
  int _nextId = 1;
  Map<String, dynamic>? serverInfo;

  // Altes Protokoll (HTTP + SSE)
  bool _legacy = false;
  Uri? _legacyEndpoint;
  StreamSubscription<_SseEvent>? _legacySub;
  final _legacyPending = <int, Completer<Map<String, dynamic>>>{};

  Future<void> close() async {
    await _legacySub?.cancel();
    _http.close(force: true);
  }

  Uri get _uri => Uri.parse(config.url.trim());

  /// Mit fester Länge senden (manche Server können kein "chunked").
  void _body(HttpClientRequest req, Object msg) {
    final bytes = utf8.encode(jsonEncode(msg));
    req.contentLength = bytes.length;
    req.add(bytes);
  }

  void _headers(HttpClientRequest req, {bool json = true}) {
    if (json) req.headers.contentType = ContentType.json;
    req.headers.set(HttpHeaders.acceptHeader, 'application/json, text/event-stream');
    if (_initialized) req.headers.set('MCP-Protocol-Version', mcpProtocolVersion);
    if (_session != null) req.headers.set('Mcp-Session-Id', _session!);
    config.headers.forEach((k, v) {
      if (k.trim().isNotEmpty) req.headers.set(k.trim(), v.trim());
    });
    final token = config.oauth['access_token'];
    if (token != null && token.isNotEmpty && !config.headers.keys.any((k) => k.toLowerCase() == 'authorization')) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
  }

  Future<Map<String, dynamic>> _request(String method, [Map<String, dynamic>? params]) async {
    if (method == 'initialize') await McpOAuth.ensureFresh(config);
    if (!_initialized && method != 'initialize') await initialize();
    final id = _nextId++;
    final msg = {'jsonrpc': '2.0', 'id': id, 'method': method, if (params != null) 'params': params};
    if (_legacy) return _legacyRequest(id, msg);

    final req = await _http.postUrl(_uri).timeout(timeout);
    _headers(req);
    _body(req, msg);
    final res = await req.close().timeout(timeout);
    final sid = res.headers.value('mcp-session-id');
    if (sid != null && sid.isNotEmpty) _session = sid;
    if (res.statusCode == 401) {
      await res.drain<void>();
      throw McpAuthException('Anmeldung nötig (401)', wwwAuthenticate: res.headers.value('www-authenticate'));
    }
    if (res.statusCode == 403) {
      await res.drain<void>();
      throw McpException('Zugriff verweigert (403) – Token/Anmeldedaten prüfen.');
    }
    if (res.statusCode >= 400) {
      final body = await res.transform(utf8.decoder).join().catchError((_) => '');
      throw McpException('Server antwortet mit ${res.statusCode}${body.isEmpty ? '' : ': ${body.length > 200 ? body.substring(0, 200) : body}'}',);
    }
    final type = res.headers.contentType?.mimeType ?? '';
    Map<String, dynamic>? reply;
    if (type == 'text/event-stream') {
      await for (final ev in _sse(res).timeout(timeout)) {
        try {
          final j = jsonDecode(ev.data);
          if (j is Map && j['id'] == id) {
            reply = j.cast<String, dynamic>();
            break;
          }
        } catch (_) {}
      }
    } else {
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      final j = jsonDecode(body);
      if (j is List) {
        reply = j.whereType<Map>().where((m) => m['id'] == id).firstOrNull?.cast<String, dynamic>();
      } else if (j is Map) {
        reply = j.cast<String, dynamic>();
      }
    }
    if (reply == null) throw McpException('Keine Antwort vom Server auf $method');
    return _unwrap(reply);
  }

  Map<String, dynamic> _unwrap(Map<String, dynamic> reply) {
    final err = reply['error'];
    if (err is Map) throw McpException('MCP-Fehler ${err['code'] ?? ''}: ${err['message'] ?? err}');
    return (reply['result'] as Map?)?.cast<String, dynamic>() ?? const {};
  }

  Future<void> _notify(String method) async {
    final msg = {'jsonrpc': '2.0', 'method': method};
    final target = _legacy ? _legacyEndpoint! : _uri;
    final req = await _http.postUrl(target).timeout(timeout);
    _headers(req);
    _body(req, msg);
    final res = await req.close().timeout(timeout);
    await res.drain<void>();
  }

  /// Verbindung aufbauen (neues Protokoll, sonst Rückfall auf HTTP + SSE).
  Future<Map<String, dynamic>> initialize() async {
    final params = {
      'protocolVersion': mcpProtocolVersion,
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'Junels', 'version': '1.7'},
    };
    Map<String, dynamic> r;
    try {
      r = await _request('initialize', params);
    } on McpException catch (e) {
      if (!RegExp(r'\b(404|405)\b').hasMatch(e.message)) rethrow;
      await _connectLegacy();
      r = await _legacyRequest(_nextId++, {'jsonrpc': '2.0', 'id': _nextId - 1, 'method': 'initialize', 'params': params});
    }
    serverInfo = r;
    _initialized = true;
    await _notify('notifications/initialized');
    return r;
  }

  Future<void> _connectLegacy() async {
    _legacy = true;
    final req = await _http.getUrl(_uri).timeout(timeout);
    _headers(req, json: false);
    req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
    final res = await req.close().timeout(timeout);
    if (res.statusCode == 401) {
      await res.drain<void>();
      throw McpAuthException('Anmeldung nötig (401)', wwwAuthenticate: res.headers.value('www-authenticate'));
    }
    if (res.statusCode >= 400) {
      await res.drain<void>();
      throw McpException('Server antwortet mit ${res.statusCode} (weder Streamable HTTP noch SSE)');
    }
    final endpoint = Completer<Uri>();
    _legacySub = _sse(res).listen((ev) {
      if (ev.event == 'endpoint' && !endpoint.isCompleted) {
        endpoint.complete(_uri.resolve(ev.data.trim()));
        return;
      }
      try {
        final j = jsonDecode(ev.data);
        if (j is Map && j['id'] is int) _legacyPending.remove(j['id'])?.complete(j.cast<String, dynamic>());
      } catch (_) {}
    }, onError: (Object e) {
      for (final c in _legacyPending.values) {
        if (!c.isCompleted) c.completeError(McpException('Verbindung getrennt: $e'));
      }
    });
    _legacyEndpoint = await endpoint.future.timeout(timeout, onTimeout: () => throw McpException('SSE-Server nennt keinen Endpunkt'));
  }

  Future<Map<String, dynamic>> _legacyRequest(int id, Map<String, dynamic> msg) async {
    final c = Completer<Map<String, dynamic>>();
    _legacyPending[id] = c;
    final req = await _http.postUrl(_legacyEndpoint!).timeout(timeout);
    _headers(req);
    _body(req, msg);
    final res = await req.close().timeout(timeout);
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) {
      _legacyPending.remove(id);
      throw McpException('Server antwortet mit ${res.statusCode}: $body');
    }
    // manche Server antworten direkt statt über den Strom
    if (body.trim().startsWith('{')) {
      try {
        final j = jsonDecode(body);
        if (j is Map && j['id'] == id) {
          _legacyPending.remove(id);
          return _unwrap(j.cast<String, dynamic>());
        }
      } catch (_) {}
    }
    return _unwrap(await c.future.timeout(timeout));
  }

  /// Liste aller Tools des Servers.
  Future<List<McpToolSpec>> listTools() async {
    final out = <McpToolSpec>[];
    String? cursor;
    for (var page = 0; page < 20; page++) {
      final r = await _request('tools/list', {if (cursor != null) 'cursor': cursor});
      for (final t in (r['tools'] as List? ?? const [])) {
        if (t is Map) {
          out.add(McpToolSpec(
            name: t['name'] as String? ?? '',
            description: (t['description'] as String? ?? t['title'] as String? ?? '').trim(),
            inputSchema: (t['inputSchema'] as Map?)?.cast<String, dynamic>() ?? const {},
          ));
        }
      }
      cursor = r['nextCursor'] as String?;
      if (cursor == null || cursor.isEmpty) break;
    }
    return out;
  }

  /// Ruft ein Tool auf und liefert den Text der Antwort.
  Future<String> callTool(String name, Map<String, dynamic> args) async {
    final r = await _request('tools/call', {'name': name, 'arguments': args});
    final parts = <String>[];
    for (final c in (r['content'] as List? ?? const [])) {
      if (c is! Map) continue;
      switch (c['type']) {
        case 'text':
          parts.add(c['text']?.toString() ?? '');
        case 'image':
          parts.add('[Bild ${c['mimeType'] ?? ''}]');
        case 'resource':
          final res = c['resource'];
          if (res is Map) parts.add(res['text']?.toString() ?? '[Ressource ${res['uri'] ?? ''}]');
        case 'resource_link':
          parts.add('[Link: ${c['name'] ?? ''} ${c['uri'] ?? ''}]');
        default:
          parts.add(jsonEncode(c));
      }
    }
    if (parts.isEmpty && r['structuredContent'] != null) parts.add(jsonEncode(r['structuredContent']));
    final text = parts.join('\n').trim();
    if (r['isError'] == true) throw ToolException(text.isEmpty ? 'Das Tool meldet einen Fehler.' : text);
    return text.isEmpty ? '(keine Ausgabe)' : text;
  }
}

/// Ein MCP-Tool als Agent-Tool. Hält pro Server eine Verbindung (wird bei Bedarf aufgebaut).
class McpTool extends AgentTool {
  McpTool(this.server, this.spec, this._clients);
  final McpServerConfig server;
  final McpToolSpec spec;
  final Map<String, McpClient> _clients;

  static const maxParams = 6;

  @override
  String get name {
    final base = '${server.slug}__${spec.name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}';
    return base.length > 60 ? base.substring(0, 60) : base;
  }

  @override
  String get title => '${spec.name} (${server.name})';

  @override
  String get description {
    final d = spec.description.replaceAll(RegExp(r'\s+'), ' ');
    final short = d.length > 220 ? '${d.substring(0, 217)}…' : d;
    return '[MCP ${server.name}] ${short.isEmpty ? spec.name : short}';
  }

  Map<String, dynamic> get _props => (spec.inputSchema['properties'] as Map?)?.cast<String, dynamic>() ?? const {};
  Set<String> get _required => {...(spec.inputSchema['required'] as List? ?? const []).map((e) => e.toString())};

  /// Pflichtfelder mit echtem Typ, optionale als Text ("" = weglassen); höchstens [maxParams].
  @override
  List<ToolParam> get params {
    final req = _required;
    final names = [..._props.keys.where(req.contains), ..._props.keys.where((k) => !req.contains(k))];
    final out = <ToolParam>[];
    for (final k in names.take(maxParams)) {
      final p = (_props[k] as Map?)?.cast<String, dynamic>() ?? const {};
      final desc = (p['description'] as String? ?? '').replaceAll(RegExp(r'\s+'), ' ');
      final short = desc.length > 100 ? '${desc.substring(0, 97)}…' : desc;
      final type = p['type'];
      final optional = !req.contains(k);
      final enumVals = (p['enum'] as List?)?.map((e) => e.toString()).toList();
      if (optional) {
        out.add(ToolParam(k, ParamType.string, '${short.isEmpty ? k : short} (optional, leer = weglassen${type is String && type != 'string' ? ', $type' : ''})'));
      } else if (enumVals != null && enumVals.isNotEmpty) {
        out.add(ToolParam(k, ParamType.enumeration, short.isEmpty ? k : short, values: enumVals));
      } else {
        final t = switch (type) {
          'integer' => ParamType.integer,
          'number' => ParamType.number,
          'boolean' => ParamType.boolean,
          _ => ParamType.string,
        };
        out.add(ToolParam(k, t, '${short.isEmpty ? k : short}${type == 'object' || type == 'array' ? ' (als JSON)' : ''}'));
      }
    }
    return out;
  }

  @override
  bool get requiresNetwork => !server.trusted;

  /// Argumente an das Schema anpassen (Text → Zahl/JSON, leere optionale weglassen).
  Map<String, dynamic> convertArgs(Map<String, dynamic> args) {
    final out = <String, dynamic>{};
    final req = _required;
    args.forEach((k, v) {
      final schema = (_props[k] as Map?)?.cast<String, dynamic>() ?? const {};
      final type = schema['type'];
      if (v is String) {
        final s = v.trim();
        if (s.isEmpty && !req.contains(k)) return;
        switch (type) {
          case 'integer':
            out[k] = int.tryParse(s) ?? double.tryParse(s)?.round() ?? s;
          case 'number':
            out[k] = double.tryParse(s.replaceAll(',', '.')) ?? s;
          case 'boolean':
            out[k] = const {'true', 'ja', 'yes', '1'}.contains(s.toLowerCase());
          case 'object' || 'array':
            try {
              out[k] = jsonDecode(s);
            } catch (_) {
              out[k] = type == 'array' ? s.split(',').map((e) => e.trim()).toList() : s;
            }
          default:
            out[k] = v;
        }
      } else {
        out[k] = v;
      }
    });
    return out;
  }

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    if (!server.trusted) await ctx.ensureNetwork('MCP-Server „${server.name}“: ${spec.name}');
    var client = _clients[server.id];
    try {
      client ??= _clients[server.id] = McpClient(server);
      return await client.callTool(spec.name, convertArgs(args));
    } on ToolException {
      rethrow;
    } catch (e) {
      // Verbindung neu aufbauen und einmal wiederholen (Sitzung abgelaufen o. Ä.)
      await _clients.remove(server.id)?.close();
      try {
        final c = _clients[server.id] = McpClient(server);
        return await c.callTool(spec.name, convertArgs(args));
      } on ToolException {
        rethrow;
      } catch (e2) {
        throw ToolException('MCP-Server „${server.name}“ nicht erreichbar: $e2');
      }
    }
  }
}
