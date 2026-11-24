import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_scope.dart';
import 'monitor_page.dart';
import 'quick_nav.dart';

/// Junels als MCP-Server für andere Programme auf diesem Gerät.
class McpServePage extends StatefulWidget {
  const McpServePage({super.key});

  @override
  State<McpServePage> createState() => _McpServePageState();
}

class _McpServePageState extends State<McpServePage> {
  bool _showToken = false;
  String _token = '';
  String _config = '';
  late final TextEditingController _port;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    _port = TextEditingController(text: '${app.settings.mcpServePort}');
    _load();
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    final t = await app.mcpServe.token();
    final c = await app.mcpServe.clientConfig();
    if (mounted) {
      setState(() {
        _token = t;
        _config = c;
      });
    }
  }

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  void _copy(String s, String what) {
    Clipboard.setData(ClipboardData(text: s));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what kopiert')));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final srv = app.mcpServe;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final tools = srv.core.tools();
    return Scaffold(
      appBar: JAppBar(title: const Text('Junels als MCP-Server')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
            Text(
                'Andere Programme auf diesem Gerät – z. B. Claude Desktop, Cursor, n8n, Dify oder LangGraph – können deine Skills '
                'und Prozesse als Werkzeuge nutzen. Erreichbar nur auf diesem Gerät (127.0.0.1) und nur mit dem Schlüssel. '
                'Aktionen wie Senden oder Buchen werden nie direkt ausgeführt: Sie warten im Chat „Externe Aufrufe“ auf deine Freigabe.',
                style: t.bodySmall),
            const SizedBox(height: 12),
            Card(
              child: Column(children: [
                SwitchListTile(
                  value: app.settings.mcpServe,
                  title: const Text('MCP-Server einschalten'),
                  subtitle: Text(srv.running
                      ? 'Läuft: ${srv.url}'
                      : srv.error ?? 'Aus'),
                  onChanged: (v) async {
                    app.settings.mcpServe = v;
                    await app.storage.saveSettings(app.settings);
                    v ? await srv.start() : await srv.stop();
                    await _load();
                  },
                ),
                SwitchListTile(
                  value: app.settings.mcpServeInternet,
                  title: const Text('Externe Aufrufe dürfen ins Internet'),
                  subtitle: const Text('Websuche, Nachrichten, Cloud-Modelle. Aus: nur lokale Werkzeuge'),
                  onChanged: (v) async {
                    app.settings.mcpServeInternet = v;
                    await app.storage.saveSettings(app.settings);
                    setState(() {});
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(children: [
                    SizedBox(
                      width: 120,
                      child: TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Port', isDense: true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () async {
                        final p = int.tryParse(_port.text.trim());
                        if (p == null || p < 1024 || p > 65535) return;
                        app.settings.mcpServePort = p;
                        await app.storage.saveSettings(app.settings);
                        if (app.settings.mcpServe) await srv.start();
                        await _load();
                      },
                      child: const Text('Übernehmen'),
                    ),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            Text('Verbinden', style: t.titleSmall),
            const SizedBox(height: 6),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SelectableText('Adresse: ${srv.url}', style: t.bodyMedium),
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(
                      child: SelectableText(
                          'Schlüssel: ${_showToken ? _token : '••••••••••••${_token.length > 4 ? _token.substring(_token.length - 4) : ''}'}',
                          style: t.bodyMedium),
                    ),
                    IconButton(
                        tooltip: _showToken ? 'Verbergen' : 'Anzeigen',
                        onPressed: () => setState(() => _showToken = !_showToken),
                        icon: Icon(_showToken ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18)),
                    IconButton(tooltip: 'Kopieren', onPressed: () => _copy(_token, 'Schlüssel'), icon: const Icon(Icons.copy, size: 18)),
                  ]),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    FilledButton.tonalIcon(
                      onPressed: () => _copy(_config, 'Einrichtung'),
                      icon: const Icon(Icons.copy_all, size: 18),
                      label: const Text('Einrichtung kopieren (JSON)'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('Neuen Schlüssel erzeugen?'),
                            content: const Text('Programme mit dem alten Schlüssel haben danach keinen Zugriff mehr.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
                              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Neu erzeugen')),
                            ],
                          ),
                        );
                        if (ok != true) return;
                        await srv.newToken();
                        if (app.settings.mcpServe) await srv.start();
                        await _load();
                      },
                      icon: const Icon(Icons.autorenew, size: 18),
                      label: const Text('Neuer Schlüssel'),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  Text(
                      'Claude Desktop / Cursor: JSON in die MCP-Einstellungen einfügen. n8n: Knoten „MCP Client Tool“, '
                      'Endpoint = Adresse, Authentifizierung „Bearer“ mit dem Schlüssel. LangGraph/Dify: MCP-Adapter mit Streamable HTTP.',
                      style: t.bodySmall),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Text('Angebotene Werkzeuge (${tools.length})', style: t.titleSmall),
            const SizedBox(height: 6),
            Card(
              child: Column(children: [
                for (final x in tools)
                  ListTile(
                    dense: true,
                    leading: Icon(
                        x.name.startsWith('skill_')
                            ? Icons.auto_awesome
                            : x.name.startsWith('prozess_')
                                ? Icons.account_tree_outlined
                                : Icons.chat_outlined,
                        size: 20),
                    title: Text(x.title ?? x.name),
                    subtitle: Text(x.name, style: TextStyle(color: scheme.onSurfaceVariant, fontFamily: 'monospace', fontSize: 12)),
                  ),
              ]),
            ),
            const SizedBox(height: 6),
            Text('Angeboten werden alle eingeschalteten Skills und aktiven Prozesse. Ausschalten = nicht mehr sichtbar.', style: t.bodySmall),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.insights_outlined),
              title: Text(srv.calls == 0 ? 'Noch keine externen Aufrufe seit dem Start' : '${srv.calls} Aufrufe seit dem Start · zuletzt ${srv.lastTool}'),
              subtitle: const Text('Alle Aufrufe in der Überwachung und im Aktivitätsprotokoll'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MonitorPage(source: 'mcp'))),
            ),
          ]),
        ),
      ),
    );
  }
}
