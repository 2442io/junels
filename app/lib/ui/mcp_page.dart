// MCP-Server verwalten: hinzufügen, verbinden, Tools auswählen.

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/app_scope.dart';

Future<void> openMcp(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const McpPage()));

class McpPage extends StatelessWidget {
  const McpPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('MCP-Server')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editServer(context, app, null),
        icon: const Icon(Icons.add),
        label: const Text('Server hinzufügen'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              Text(
                'Über MCP (Model Context Protocol) bekommt der Agent zusätzliche Werkzeuge von anderen '
                'Programmen und Diensten – z. B. Kalender, Notizen, GitHub, Datenbanken oder eigene Server. '
                'Unterstützt werden Server mit HTTP-Adresse (Streamable HTTP oder SSE), auch im eigenen Netz.',
                style: t.bodySmall,
              ),
              const SizedBox(height: 12),
              if (app.mcpServers.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('Noch keine Server.', style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
              for (final s in app.mcpServers) _ServerCard(server: s),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServerCard extends StatefulWidget {
  const _ServerCard({required this.server});
  final McpServerConfig server;

  @override
  State<_ServerCard> createState() => _ServerCardState();
}

class _ServerCardState extends State<_ServerCard> {
  bool _busy = false;
  String? _error;
  bool _expanded = false;

  Future<void> _sync() async {
    final app = AppScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await app.syncMcpServer(widget.server);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
      if (err == null) _expanded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = widget.server;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final active = s.tools.where((x) => x.enabled).length;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.hub_outlined, color: s.enabled ? scheme.primary : scheme.outline),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.name, style: t.titleMedium),
                Text(s.url, style: t.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  s.tools.isEmpty
                      ? 'Noch nicht verbunden'
                      : '$active von ${s.tools.length} Tools aktiv${s.trusted ? ' · ohne Rückfrage' : ' · fragt vor Zugriff'}',
                  style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ]),
            ),
            Switch(
              value: s.enabled,
              onChanged: (v) {
                s.enabled = v;
                app.saveMcpServer(s);
              },
            ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'edit') await _editServer(context, app, s);
                if (v == 'delete') await app.removeMcpServer(s);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
                PopupMenuItem(value: 'delete', child: Text('Entfernen')),
              ],
            ),
          ]),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_error!, style: t.bodySmall?.copyWith(color: scheme.error)),
            ),
          Row(children: [
            TextButton.icon(
              onPressed: _busy ? null : _sync,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync, size: 18),
              label: Text(s.tools.isEmpty ? 'Verbinden & Tools laden' : 'Tools aktualisieren'),
            ),
            const Spacer(),
            if (s.tools.isNotEmpty)
              TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(_expanded ? 'Tools ausblenden' : 'Tools auswählen'),
              ),
          ]),
          if (_expanded && s.tools.isNotEmpty) ...[
            if (s.tools.length > 10)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                child: Text(
                  'Tipp: Nur die Tools aktivieren, die du brauchst – jedes Tool belegt Platz im Context des Modells.',
                  style: t.bodySmall,
                ),
              ),
            for (final tool in s.tools)
              CheckboxListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(left: 4),
                value: tool.enabled,
                onChanged: (v) {
                  tool.enabled = v ?? false;
                  app.saveMcpServer(s);
                },
                title: Text(tool.name),
                subtitle: tool.description.isEmpty
                    ? null
                    : Text(tool.description, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
          ],
        ]),
      ),
    );
  }
}

Future<void> _editServer(BuildContext context, AppController app, McpServerConfig? server) async {
  final s = server ??
      McpServerConfig(id: DateTime.now().microsecondsSinceEpoch.toString(), name: '', url: 'https://');
  final name = TextEditingController(text: s.name);
  final url = TextEditingController(text: s.url);
  final auth = s.headers['Authorization'] ?? '';
  final token = TextEditingController(text: auth.startsWith('Bearer ') ? auth.substring(7) : auth);
  final extra = TextEditingController(
      text: s.headers.entries.where((e) => e.key != 'Authorization').map((e) => '${e.key}: ${e.value}').join('\n'));
  var trusted = s.trusted;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text(server == null ? 'MCP-Server hinzufügen' : 'MCP-Server bearbeiten'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name', hintText: 'z. B. GitHub')),
              const SizedBox(height: 8),
              TextField(
                controller: url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'Adresse', hintText: 'https://server.example.com/mcp'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: token,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Token (optional)', hintText: 'wird als „Bearer …“ gesendet'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: extra,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Weitere Header (optional)', hintText: 'X-Api-Key: abc'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: trusted,
                onChanged: (v) => setD(() => trusted = v),
                title: const Text('Ohne Rückfrage nutzen'),
                subtitle: const Text('Sonst fragt die App vor jedem Chat, ob der Agent den Server nutzen darf.'),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Speichern')),
        ],
      ),
    ),
  );
  if (ok != true) return;
  final headers = <String, String>{};
  for (final line in extra.text.split('\n')) {
    final i = line.indexOf(':');
    if (i > 0) headers[line.substring(0, i).trim()] = line.substring(i + 1).trim();
  }
  if (token.text.trim().isNotEmpty) headers['Authorization'] = 'Bearer ${token.text.trim()}';
  s
    ..name = name.text.trim().isEmpty ? (Uri.tryParse(url.text.trim())?.host ?? 'MCP') : name.text.trim()
    ..url = url.text.trim()
    ..headers = headers
    ..trusted = trusted;
  await app.saveMcpServer(s);
  if (server == null && context.mounted) {
    final messenger = ScaffoldMessenger.of(context);
    final err = await app.syncMcpServer(s);
    messenger.showSnackBar(SnackBar(
      content: Text(err == null ? '${s.name}: ${s.tools.length} Tools geladen' : 'Verbindung fehlgeschlagen: $err'),
      duration: const Duration(seconds: 6),
    ));
  }
}
