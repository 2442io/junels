// MCP-Store: empfohlene Server der Anbieter und Suche im offiziellen MCP Registry.

import 'dart:async';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/app_scope.dart';
import '../state/native_files.dart';

Future<void> openMcpStore(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const McpStorePage()));

class McpStorePage extends StatefulWidget {
  const McpStorePage({super.key});

  @override
  State<McpStorePage> createState() => _McpStorePageState();
}

class _McpStorePageState extends State<McpStorePage> {
  final _search = TextEditingController();
  List<McpStoreEntry>? _results;
  String? _error;
  bool _loading = false;
  String _category = 'Alle';
  Timer? _debounce;

  @override
  void dispose() {
    _search.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _runSearch(String q) async {
    if (q.trim().length < 2) {
      setState(() {
        _results = null;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await searchMcpRegistry(q);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _error = 'Registry nicht erreichbar: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final t = Theme.of(context).textTheme;
    final cats = ['Alle', ...{for (final e in featuredMcpServers) e.category}];
    final featured = featuredMcpServers.where((e) => _category == 'Alle' || e.category == _category).toList();
    final searching = _search.text.trim().length >= 2;
    return Scaffold(
      appBar: AppBar(title: const Text('MCP-Store')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Text('Werkzeuge für den Agenten aus anderen Diensten. „Vom Anbieter“ = vom Unternehmen selbst betrieben. '
                  'Server mit „Anmeldung im Browser“ verbindest du mit deinem Konto beim Anbieter.',
                  style: t.bodySmall),
              const SizedBox(height: 12),
              TextField(
                controller: _search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Im offiziellen MCP Registry suchen (z. B. Kalender, Notion, Wetter)',
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _search.clear();
                            _runSearch('');
                          }),
                ),
                onChanged: (v) {
                  setState(() {});
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 500), () => _runSearch(v));
                },
                onSubmitted: _runSearch,
              ),
              const SizedBox(height: 12),
              if (searching) ...[
                if (_loading) const LinearProgressIndicator(),
                if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                if (_results != null && _results!.isEmpty && !_loading)
                  const Padding(padding: EdgeInsets.all(8), child: Text('Keine Remote-Server gefunden.')),
                for (final e in _results ?? const <McpStoreEntry>[]) _StoreTile(entry: e, app: app),
              ] else ...[
                Text('Empfohlen', style: t.titleMedium),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final c in cats)
                    ChoiceChip(label: Text(c), selected: _category == c, onSelected: (_) => setState(() => _category = c)),
                ]),
                const SizedBox(height: 8),
                for (final e in featured) _StoreTile(entry: e, app: app),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StoreTile extends StatefulWidget {
  const _StoreTile({required this.entry, required this.app});
  final McpStoreEntry entry;
  final AppController app;

  @override
  State<_StoreTile> createState() => _StoreTileState();
}

class _StoreTileState extends State<_StoreTile> {
  bool _busy = false;

  McpServerConfig? get _installed =>
      widget.app.mcpServers.where((s) => s.url.trim() == widget.entry.url.trim()).firstOrNull;

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 6)));

  Future<void> _add() async {
    final e = widget.entry;
    final app = widget.app;
    // Pflicht-Header (Token/API-Schlüssel) abfragen
    final headers = <String, String>{};
    if (e.headers.isNotEmpty) {
      final ctrls = {for (final h in e.headers) h.name: TextEditingController()};
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${e.title} verbinden'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Dieser Server braucht einen Zugangsschlüssel. Er bleibt nur auf diesem Gerät.'),
            const SizedBox(height: 8),
            for (final h in e.headers)
              TextField(
                controller: ctrls[h.name],
                obscureText: h.secret,
                decoration: InputDecoration(labelText: h.name, helperText: h.description, helperMaxLines: 3),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Verbinden')),
          ],
        ),
      );
      if (ok != true) return;
      for (final h in e.headers) {
        var v = ctrls[h.name]!.text.trim();
        if (v.isEmpty) continue;
        if (h.name.toLowerCase() == 'authorization' && !v.contains(' ')) v = 'Bearer $v';
        headers[h.name] = v;
      }
    }
    setState(() => _busy = true);
    final srv = McpServerConfig(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: e.title,
      url: e.url,
      headers: headers,
    );
    await app.saveMcpServer(srv);
    var err = await app.syncMcpServer(srv);
    if (err != null && app.mcpNeedsLogin.containsKey(srv.id)) {
      if (mounted) _snack('Anmeldung bei ${e.vendor} im Browser – danach kehrst du automatisch zurück.');
      err = await app.loginMcpServer(srv);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(err == null
        ? '${e.title} verbunden: ${srv.tools.length} Werkzeuge${srv.tools.length > 10 ? ' (unter MCP-Server auswählen)' : ''}.'
        : '${e.title}: $err');
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final inst = _installed;
    Widget badge(String text, Color bg, Color fg) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
          child: Text(text, style: t.labelSmall?.copyWith(color: fg)),
        );
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: scheme.secondaryContainer,
              child: Text(e.title.isEmpty ? '?' : e.title[0].toUpperCase(),
                  style: TextStyle(color: scheme.onSecondaryContainer, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.title, style: t.titleSmall),
                Text(e.vendor, style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ]),
            ),
            if (inst != null)
              const Chip(avatar: Icon(Icons.check, size: 16), label: Text('Installiert'), visualDensity: VisualDensity.compact)
            else
              FilledButton.tonal(
                onPressed: _busy ? null : _add,
                child: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Hinzufügen'),
              ),
          ]),
          if (e.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(e.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: t.bodySmall),
          ],
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            e.official
                ? badge('Vom Anbieter', Colors.green.withValues(alpha: 0.18), Colors.green.shade700)
                : badge('Community', scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
            badge(e.authLabel, scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
            if (e.website.isNotEmpty)
              InkWell(
                onTap: () => NativeFiles.openUrl(e.website),
                child: Text('Webseite ↗', style: t.labelSmall?.copyWith(color: scheme.primary)),
              ),
          ]),
        ]),
      ),
    );
  }
}
