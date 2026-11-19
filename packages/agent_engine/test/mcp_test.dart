// MCP-Client gegen einen lokalen Testserver (Python).
import 'dart:convert';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';

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
  print('\n$_passed bestanden, $_failed fehlgeschlagen');
  exit(_failed == 0 ? 0 : 1);
}
