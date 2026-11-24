import 'dart:async';

/// Ein Werkzeug, das Junels nach außen anbietet (MCP-Server).
class ServedTool {
  ServedTool(this.name, this.description, this.inputSchema, this.call, {this.title});
  final String name;
  final String? title;
  final String description;
  final Map<String, Object?> inputSchema;
  final Future<String> Function(Map<String, Object?> args) call;
}

/// MCP-Protokoll (JSON-RPC 2.0, „Streamable HTTP“ ohne Stream): nur die Teile, die ein
/// Werkzeug-Server braucht. Transport und Anmeldung macht der Aufrufer.
class McpServeCore {
  McpServeCore({required this.name, required this.version, required this.tools, this.instructions});
  final String name;
  final String version;
  final String? instructions;
  final List<ServedTool> Function() tools;

  static const versions = ['2025-06-18', '2025-03-26', '2024-11-05'];

  static String safeName(String s) {
    final v = s
        .toLowerCase()
        .replaceAll('ä', 'ae')
        .replaceAll('ö', 'oe')
        .replaceAll('ü', 'ue')
        .replaceAll('ß', 'ss')
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return v.length > 60 ? v.substring(0, 60) : v;
  }

  /// Bearbeitet eine Nachricht (oder einen Stapel). Ergebnis null = keine Antwort (Benachrichtigung).
  Future<Object?> handle(Object? msg) async {
    if (msg is List) {
      final out = [
        for (final m in msg)
          if (await handle(m) case final r?) r
      ];
      return out.isEmpty ? null : out;
    }
    if (msg is! Map) return _err(null, -32600, 'Ungültige Anfrage');
    final id = msg['id'];
    final method = msg['method'];
    final params = (msg['params'] as Map?)?.cast<String, Object?>() ?? const {};
    if (method is! String) return id == null ? null : _err(id, -32600, 'Methode fehlt');
    if (id == null) return null; // Benachrichtigung (z. B. notifications/initialized)
    try {
      switch (method) {
        case 'initialize':
          final want = params['protocolVersion'];
          return _ok(id, {
            'protocolVersion': versions.contains(want) ? want : versions.first,
            'capabilities': {
              'tools': {'listChanged': false}
            },
            'serverInfo': {'name': name, 'version': version},
            if (instructions != null) 'instructions': instructions,
          });
        case 'ping':
          return _ok(id, <String, Object?>{});
        case 'tools/list':
          return _ok(id, {
            'tools': [
              for (final t in tools())
                {
                  'name': t.name,
                  if (t.title != null) 'title': t.title,
                  'description': t.description,
                  'inputSchema': t.inputSchema,
                }
            ]
          });
        case 'tools/call':
          final name = params['name'];
          final t = tools().where((x) => x.name == name).firstOrNull;
          if (t == null) return _err(id, -32602, 'Unbekanntes Werkzeug: $name');
          final args = (params['arguments'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
          try {
            final text = await t.call(args);
            return _ok(id, {
              'content': [
                {'type': 'text', 'text': text}
              ],
              'isError': false,
            });
          } catch (e) {
            return _ok(id, {
              'content': [
                {'type': 'text', 'text': '$e'.replaceFirst('Exception: ', '')}
              ],
              'isError': true,
            });
          }
        case 'resources/list':
          return _ok(id, {'resources': <Object>[]});
        case 'prompts/list':
          return _ok(id, {'prompts': <Object>[]});
        default:
          return _err(id, -32601, 'Methode nicht unterstützt: $method');
      }
    } catch (e) {
      return _err(id, -32603, '$e');
    }
  }

  static Map<String, Object?> _ok(Object? id, Object? result) => {'jsonrpc': '2.0', 'id': id, 'result': result};
  static Map<String, Object?> _err(Object? id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message}
      };

  /// Nur Aufrufe vom eigenen Gerät zulassen (Schutz gegen DNS-Rebinding aus dem Browser).
  static bool originAllowed(String? origin) {
    if (origin == null || origin.isEmpty || origin == 'null') return true;
    final u = Uri.tryParse(origin);
    return u != null && const {'localhost', '127.0.0.1', '[::1]', '::1'}.contains(u.host);
  }
}
