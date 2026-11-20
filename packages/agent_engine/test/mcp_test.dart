// MCP-Client gegen einen lokalen Testserver (Python).
import 'dart:convert';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:agent_engine/src/sync/sync_crypto.dart' show sha256;

var _passed = 0;
var _failed = 0;

void check(bool ok, String name) {
  ok ? _passed++ : _failed++;
  print('  ${ok ? 'ok  ' : 'FAIL'} $name');
}

Future<void> main() async {
  final proc = await Process.start('python3', ['test/fixtures/mcp_server.py']);
  final port = int.parse(await proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).first);
  final base = 'http://127.0.0.1:$port';
  try {
    for (final path in ['/mcp', '/mcp-sse', '/legacy/sse']) {
      print('MCP über $path');
      final cfg = McpServerConfig(id: path, name: 'Test Server', url: '$base$path', trusted: true);
      final c = McpClient(cfg, timeout: const Duration(seconds: 10));
      final info = await c.initialize();
      check(info['serverInfo']?['name'] == 'test', 'initialize');
      final tools = await c.listTools();
      check(tools.map((t) => t.name).join(',') == 'echo,add,fail', 'tools/list mit Seiten');
      check(await c.callTool('echo', {'text': 'hallo'}) == 'echo: hallo', 'tools/call echo');
      cfg.tools = tools;
      final clients = <String, McpClient>{cfg.id: c};
      final add = McpTool(cfg, tools[1], clients);
      check(add.name == 'test_server__add' && add.params.length == 3 && add.params[2].type == ParamType.string,
          'Tool-Abbildung (Pflicht a,b; optional note als Text)');
      final r = await add.run({'a': 2, 'b': '3.5', 'note': ''}, ToolContext());
      check(r == '5.5', 'Argumente umgewandelt, leeres Optionales weggelassen ($r)');
      var err = false;
      try {
        await McpTool(cfg, tools[2], clients).run({}, ToolContext());
      } on ToolException catch (e) {
        err = e.message == 'kaputt';
      }
      check(err, 'isError → ToolException');
      await c.close();
    }
    print('Absicherung');
    final bad = McpClient(McpServerConfig(id: 's', name: 's', url: '$base/secure'), timeout: const Duration(seconds: 5));
    var denied = false;
    try {
      await bad.initialize();
    } on McpException catch (e) {
      denied = e.message.contains('401');
    }
    check(denied, 'ohne Token → verweigert');
    final good = McpClient(
        McpServerConfig(id: 's', name: 's', url: '$base/secure', headers: {'Authorization': 'Bearer geheim'}),
        timeout: const Duration(seconds: 5));
    check((await good.listTools()).length == 3, 'mit Token → Tools');
    final untrusted = McpServerConfig(id: 'u', name: 'U', url: '$base/mcp', tools: [
      McpToolSpec(name: 'echo', description: '', inputSchema: const {}),
    ]);
    var asked = false;
    try {
      await McpTool(untrusted, untrusted.tools.first, {}).run({}, ToolContext(requestNetwork: (_) async {
        asked = true;
        return false;
      }));
    } on ToolException {
      // abgelehnt
    }
    check(asked, 'nicht vertrauenswürdig → Freigabe wird erfragt');
  } finally {
    proc.kill();
  }
  await _oauthTests();
  _registryTests();
  print('\n$_passed bestanden, $_failed fehlgeschlagen');
  exit(_failed == 0 ? 0 : 1);
}

// ---------------------------------------------------------------- OAuth

String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

Future<void> _oauthTests() async {
  print('MCP-Anmeldung (OAuth)');
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://127.0.0.1:${srv.port}';
  var challenge = '';
  var refreshed = 0;
  srv.listen((req) async {
    final res = req.response;
    Future<void> json(Object o, [int code = 200]) async {
      res
        ..statusCode = code
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(o));
      await res.close();
    }

    final path = req.uri.path;
    if (path == '/mcp') {
      final auth = req.headers.value('authorization') ?? '';
      final body = await utf8.decodeStream(req);
      if (auth != 'Bearer tok-1' && auth != 'Bearer tok-2') {
        res.headers.set('WWW-Authenticate', 'Bearer resource_metadata="$base/.well-known/oauth-protected-resource/mcp"');
        return json({'error': 'unauthorized'}, 401);
      }
      final m = jsonDecode(body) as Map;
      if (m['id'] == null) {
        res.statusCode = 202;
        return res.close();
      }
      final result = m['method'] == 'initialize'
          ? {'serverInfo': {'name': 'oauth-test'}, 'protocolVersion': '2025-06-18', 'capabilities': {}}
          : {'tools': [{'name': 'whoami', 'description': 'wer bin ich', 'inputSchema': {'type': 'object'}}]};
      return json({'jsonrpc': '2.0', 'id': m['id'], 'result': result});
    }
    if (path == '/.well-known/oauth-protected-resource/mcp') {
      return json({'resource': '$base/mcp', 'authorization_servers': ['$base/auth'], 'scopes_supported': ['read']});
    }
    if (path == '/.well-known/oauth-authorization-server/auth') {
      return json({
        'issuer': '$base/auth',
        'authorization_endpoint': '$base/auth/authorize',
        'token_endpoint': '$base/auth/token',
        'registration_endpoint': '$base/auth/register',
      });
    }
    if (path == '/auth/register') {
      final b = jsonDecode(await utf8.decodeStream(req)) as Map;
      final ok = (b['redirect_uris'] as List).first.toString().startsWith('http://127.0.0.1:');
      return json(ok ? {'client_id': 'cid-1'} : {'error': 'invalid_redirect_uri'}, ok ? 201 : 400);
    }
    if (path == '/auth/authorize') {
      final q = req.uri.queryParameters;
      challenge = q['code_challenge'] ?? '';
      final ok = q['client_id'] == 'cid-1' && q['code_challenge_method'] == 'S256' && q['resource'] == '$base/mcp' && q['scope'] == 'read';
      final redirect = Uri.parse(q['redirect_uri']!).replace(queryParameters: ok
          ? {'code': 'code-123', 'state': q['state']!}
          : {'error': 'invalid_request', 'state': q['state']!});
      res
        ..statusCode = 302
        ..headers.set('Location', redirect.toString());
      return res.close();
    }
    if (path == '/auth/token') {
      final f = Uri.splitQueryString(await utf8.decodeStream(req));
      if (f['grant_type'] == 'authorization_code') {
        final ok = f['code'] == 'code-123' && _b64(sha256(ascii.encode(f['code_verifier'] ?? ''))) == challenge;
        return ok
            ? json({'access_token': 'tok-1', 'refresh_token': 'r1', 'expires_in': 1, 'token_type': 'Bearer'})
            : json({'error': 'invalid_grant'}, 400);
      }
      if (f['grant_type'] == 'refresh_token' && f['refresh_token'] == 'r1') {
        refreshed++;
        return json({'access_token': 'tok-2', 'refresh_token': 'r2', 'expires_in': 3600});
      }
      return json({'error': 'invalid_grant'}, 400);
    }
    res.statusCode = 404;
    await res.close();
  });
  try {
    final cfg = McpServerConfig(id: 'o', name: 'OAuth', url: '$base/mcp', trusted: true);
    String? www;
    try {
      await McpClient(cfg).initialize();
    } on McpAuthException catch (e) {
      www = e.wwwAuthenticate;
    }
    check(www != null && www.contains('resource_metadata'), 'ohne Anmeldung → 401 mit Hinweis');
    var saved = 0;
    McpOAuth.onTokens = (_) => saved++;
    await McpOAuth.login(cfg, wwwAuthenticate: www, openBrowser: (u) async {
      // „Browser“: Anmeldeseite aufrufen und der Weiterleitung folgen
      final c = HttpClient();
      final r = await (await c.getUrl(u)).close();
      await r.drain<void>();
      c.close();
    });
    check(cfg.oauth['access_token'] == 'tok-1' && cfg.oauth['client_id'] == 'cid-1' && saved == 1, 'Anmeldung mit PKCE → Token');
    final c2 = McpClient(cfg);
    final info = await c2.initialize();
    check(info['serverInfo']?['name'] == 'oauth-test', 'mit Token verbunden');
    check(refreshed == 1 && cfg.oauth['access_token'] == 'tok-2' && cfg.oauth['refresh_token'] == 'r2',
        'abgelaufenes Token automatisch erneuert');
    check((await c2.listTools()).single.name == 'whoami', 'Tools nach Anmeldung');
    await c2.close();
  } finally {
    McpOAuth.onTokens = null;
    await srv.close(force: true);
  }
}

void _registryTests() {
  print('MCP-Store');
  const body = '''{"servers":[
 {"server":{"name":"com.notion/mcp","title":"Notion","description":"Notion MCP","version":"1.0.0",
   "remotes":[{"type":"streamable-http","url":"https://mcp.notion.com/mcp"}]},
  "_meta":{"io.modelcontextprotocol.registry/official":{"status":"active","isLatest":true}}},
 {"server":{"name":"io.github.someone/notion-helper","description":"inoffiziell","version":"0.1",
   "remotes":[{"type":"sse","url":"https://notion-helper.example.dev/sse","headers":[{"name":"X-API-Key","description":"API key","isRequired":true,"isSecret":true}]}]}},
 {"server":{"name":"io.github.x/local","description":"nur lokal","packages":[{"registryType":"npm","identifier":"x"}]}},
 {"server":{"name":"com.acme/tenant","remotes":[{"type":"streamable-http","url":"https://{tenant}.acme.com/mcp"}]}}
],"metadata":{"count":4}}''';
  final r = parseRegistry(body);
  check(r.length == 2, 'nur Remote-Server ohne Platzhalter (${r.map((e) => e.id)})');
  check(r.first.id == 'com.notion/mcp' && r.first.official && r.first.vendor == 'notion.com' && r.first.auth == McpAuth.oauth,
      'Anbieter-Server erkannt und zuerst');
  check(!r[1].official && r[1].auth == McpAuth.token && r[1].headers.single.name == 'X-API-Key', 'Community-Server mit Header');
  check(featuredMcpServers.every((e) => e.url.startsWith('https://')) && featuredMcpServers.length >= 15, 'Empfehlungsliste');
}
