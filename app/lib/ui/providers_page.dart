// Einstellungen → KI-Anbieter: eigene Server (On-Prem) und Cloud-APIs anbinden
// und festlegen, wer antwortet.

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_controller.dart';
import '../state/app_scope.dart';
import 'theme.dart';

class ProvidersSettings extends StatelessWidget {
  const ProvidersSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final list = app.providers;
    final onPrem = [for (final p in list) if (p.onPrem) p];
    final cloud = [for (final p in list) if (!p.onPrem) p];
    final r = app.settings.routing;

    Widget mode(String id, IconData icon, String title, String text, {Color? color}) {
      final sel = r == id;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Panel(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          color: sel ? c.mintSoft : null,
          borderColor: sel ? c.mint.withValues(alpha: 0.6) : null,
          onTap: () => app.setRouting(routing: id),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: sel ? c.mint : (color ?? c.muted)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: t.titleSmall),
                const SizedBox(height: 2),
                Text(text, style: t.bodySmall),
              ]),
            ),
            Icon(sel ? Icons.radio_button_checked : Icons.radio_button_off, color: sel ? c.mint : c.faint, size: 20),
          ]),
        ),
      );
    }

    Widget picker(String label, List<ProviderConfig> options, ProviderConfig? value, ValueChanged<String> onChanged) => Row(children: [
          Expanded(child: Text(label, style: t.bodyMedium)),
          if (options.isEmpty)
            Text('noch keiner', style: t.bodySmall)
          else
            DropdownButton<String>(
              value: value?.id,
              underline: const SizedBox(),
              borderRadius: BorderRadius.circular(12),
              items: [for (final p in options) DropdownMenuItem(value: p.id, child: Text(p.label, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => v == null ? null : onChanged(v),
            ),
        ]);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionLabel('Wer antwortet? (Standard – im Chat oben änderbar)', padding: EdgeInsets.fromLTRB(4, 0, 4, 8)),
      mode('local', Icons.phone_android, 'Nur lokal', 'Alles bleibt auf diesem Gerät. Standard.'),
      mode('onprem', Icons.dns_outlined, 'Nur On-Prem', 'Dein eigener Server antwortet (Ollama, LM Studio, vLLM …). Nichts geht in die Cloud.'),
      mode('cloud', Icons.cloud_outlined, 'Nur Cloud', 'Der gewählte Cloud-Anbieter beantwortet jede Frage.', color: c.blue),
      mode('hybrid', Icons.alt_route, 'Hybrid: zuerst am Gerät',
          'Zuerst antwortet das Gerät (oder dein Server). Klappt es nicht oder tippst du „Mit … beantworten“, übernimmt dein On-Prem-Server – oder die Cloud nach Freigabe (Nein / Einmal / Ganzer Chat).'),
      if (r == 'hybrid')
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Panel(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Row(children: [
              Expanded(child: Text('Zuerst fragen', style: t.bodyMedium)),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'local', label: Text('Gerät'), icon: Icon(Icons.phone_android, size: 16)),
                  ButtonSegment(value: 'onprem', label: Text('On-Prem'), icon: Icon(Icons.dns_outlined, size: 16)),
                ],
                selected: {app.settings.hybridFirst},
                showSelectedIcon: false,
                onSelectionChanged: (v) => app.setRouting(hybridFirst: v.first),
              ),
            ]),
          ),
        ),
      if (r == 'hybrid' && app.settings.hybridFirst == 'local')
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Panel(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Row(children: [
              Expanded(child: Text('Danach', style: t.bodyMedium)),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'onprem', label: Text('On-Prem'), icon: Icon(Icons.dns_outlined, size: 16)),
                  ButtonSegment(value: 'cloud', label: Text('Cloud'), icon: Icon(Icons.cloud_outlined, size: 16)),
                ],
                selected: {app.settings.hybridTarget},
                showSelectedIcon: false,
                onSelectionChanged: (v) => app.setRouting(hybridTarget: v.first),
              ),
            ]),
          ),
        ),
      if (r != 'local')
        Panel(
          padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
          child: Column(children: [
            if (r == 'onprem' || (r == 'hybrid' && app.settings.hybridFirst == 'onprem'))
              picker('On-Prem-Server', onPrem, app.onPremProvider, (id) => app.setRouting(onPremId: id)),
            if (r == 'hybrid' && app.settings.hybridFirst == 'local' && app.settings.hybridTarget == 'onprem')
              picker('On-Prem-Server', onPrem, app.onPremProvider, (id) => app.setRouting(onPremId: id)),
            if (r == 'cloud' || (r == 'hybrid' && (app.settings.hybridTarget == 'cloud' || app.settings.hybridFirst == 'onprem')))
              picker('Cloud-Anbieter', cloud, app.cloudProvider, (id) => app.setRouting(cloudId: id)),
          ]),
        ),
      if (!app.canChat && r != 'local')
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('Für diese Einstellung fehlt noch ein Anbieter – unten hinzufügen.', style: t.bodySmall?.copyWith(color: c.amber)),
        ),
      SectionLabel('Anbieter',
          padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
          trailing: TextButton.icon(
            onPressed: () => editProvider(context),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Hinzufügen'),
          )),
      if (list.isEmpty)
        Panel(
          child: EmptyHint(
            icon: Icons.cloud_queue,
            title: 'Noch kein Anbieter',
            text: 'Binde einen eigenen Server (z. B. Ollama im Netzwerk) oder einen Cloud-Anbieter wie OpenAI, Anthropic oder Gemini an.',
            action: FilledButton.icon(
              onPressed: () => editProvider(context),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Anbieter hinzufügen'),
            ),
          ),
        ),
      for (final p in list)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _ProviderTile(app: app, p: p),
        ),
      const SizedBox(height: 8),
      Text(
          'API-Schlüssel liegen im Tresor des Betriebssystems und werden nicht abgeglichen. '
          'Bei Cloud-Anbietern gehen Frage, Chatverlauf und gefundene Inhalte an den Anbieter – lokal gespeicherte Dateien nur, wenn du sie anhängst.',
          style: t.bodySmall),
    ]);
  }
}

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({required this.app, required this.p});
  final AppController app;
  final ProviderConfig p;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final active = (p.onPrem ? app.onPremProvider?.id : app.cloudProvider?.id) == p.id;
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      onTap: () => editProvider(context, existing: p),
      child: Row(children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(color: p.onPrem ? c.violetSoft : c.blueSoft, borderRadius: BorderRadius.circular(10)),
          child: Icon(p.onPrem ? Icons.dns_outlined : Icons.cloud_outlined, color: p.onPrem ? c.violet : c.blue, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              StatusChip(p.onPrem ? 'On-Prem' : 'Cloud', color: p.onPrem ? c.violet : c.blue, dense: true),
              if (active) ...[const SizedBox(width: 6), StatusChip('Aktiv', color: c.mint, soft: c.mintSoft, dense: true)],
            ]),
            const SizedBox(height: 3),
            MonoText('${p.model} · ${Uri.tryParse(p.baseUrl)?.host ?? p.baseUrl}'),
          ]),
        ),
        const Icon(Icons.chevron_right),
      ]),
    );
  }
}

Future<void> editProvider(BuildContext context, {ProviderConfig? existing}) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => _ProviderEditor(existing: existing)));

class _ProviderEditor extends StatefulWidget {
  const _ProviderEditor({this.existing});
  final ProviderConfig? existing;

  @override
  State<_ProviderEditor> createState() => _ProviderEditorState();
}

class _ProviderEditorState extends State<_ProviderEditor> {
  late ProviderKind _kind = widget.existing?.kind ?? ProviderKind.anthropic;
  late final _name = TextEditingController(text: widget.existing?.name ?? _kind.label.replaceAll(RegExp(r' \(.*\)'), ''));
  late final _url = TextEditingController(text: widget.existing?.baseUrl ?? _kind.defaultUrl);
  late final _model = TextEditingController(text: widget.existing?.model ?? _kind.defaultModel);
  late final _ctx = TextEditingController(text: (widget.existing?.contextSize ?? 0) == 0 ? '' : '${widget.existing!.contextSize}');
  final _key = TextEditingController();
  late bool _onPrem = widget.existing?.onPrem ?? _kind.onPrem;
  bool _hasKey = false;
  bool _showKey = false;
  List<String> _models = const [];
  String? _status;
  bool _busy = false;
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      AppScope.read(context).providerHasKey(e.id).then((v) {
        if (mounted) setState(() => _hasKey = v);
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _url, _model, _ctx, _key]) {
      c.dispose();
    }
    super.dispose();
  }

  void _pickKind(ProviderKind k) {
    setState(() {
      // Standardwerte nur übernehmen, wenn der Nutzer nichts Eigenes eingetragen hat
      if (_url.text == _kind.defaultUrl || _url.text.isEmpty) _url.text = k.defaultUrl;
      if (_model.text == _kind.defaultModel || _model.text.isEmpty) _model.text = k.defaultModel;
      if (_name.text == _kind.label.replaceAll(RegExp(r' \(.*\)'), '') || _name.text.isEmpty) {
        _name.text = k.label.replaceAll(RegExp(r' \(.*\)'), '');
      }
      _kind = k;
      _onPrem = k.onPrem;
      _models = const [];
      _status = null;
    });
  }

  ProviderConfig _config() => ProviderConfig(
        id: widget.existing?.id ?? newId(),
        kind: _kind,
        name: _name.text.trim().isEmpty ? _kind.label : _name.text.trim(),
        baseUrl: _url.text.trim(),
        model: _model.text.trim(),
        onPrem: _onPrem,
        contextSize: int.tryParse(_ctx.text.trim()) ?? 0,
        enabled: widget.existing?.enabled ?? true,
      );

  Future<RemoteBackend> _backend() async {
    final app = AppScope.read(context);
    final cfg = _config();
    final key = _key.text.trim().isNotEmpty ? _key.text.trim() : (widget.existing == null ? null : await app.remoteBackend(widget.existing!).then((b) => b.apiKey));
    return RemoteBackend(cfg, apiKey: key);
  }

  Future<void> _loadModels() async {
    setState(() {
      _busy = true;
      _status = 'Lade Modelle …';
    });
    try {
      final b = await _backend();
      final list = await b.listModels();
      b.close();
      setState(() {
        _models = list;
        _status = list.isEmpty ? 'Keine Modelle gefunden.' : '${list.length} Modelle gefunden.';
      });
    } catch (e) {
      setState(() => _status = 'Fehler: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _ok = false;
      _status = 'Teste Verbindung …';
    });
    final sw = Stopwatch()..start();
    try {
      final b = await _backend();
      final r = await b.ping();
      b.close();
      setState(() {
        _ok = true;
        _status = 'Verbunden in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s – Antwort: „${r.isEmpty ? '(leer)' : r}“';
      });
    } catch (e) {
      setState(() => _status = 'Fehler: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final app = AppScope.read(context);
    final nav = Navigator.of(context);
    if (_url.text.trim().isEmpty || _model.text.trim().isEmpty) {
      setState(() => _status = 'Adresse und Modell angeben.');
      return;
    }
    await app.saveProvider(_config(), apiKey: _key.text.trim().isEmpty ? null : _key.text.trim());
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final app = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Anbieter hinzufügen' : widget.existing!.name),
        actions: [
          if (widget.existing != null)
            IconButton(
              tooltip: 'Entfernen',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final nav = Navigator.of(context);
                await app.removeProvider(widget.existing!.id);
                nav.pop();
              },
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(onPressed: _busy ? null : _save, child: const Text('Speichern')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionLabel('Anbieter', padding: EdgeInsets.fromLTRB(4, 0, 4, 8)),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final k in ProviderKind.values)
                    ChoiceChip(
                      label: Text(k.label),
                      avatar: Icon(k.onPrem ? Icons.dns_outlined : Icons.cloud_outlined, size: 16),
                      selected: _kind == k,
                      onSelected: (_) => _pickKind(k),
                    ),
                ]),
                const SizedBox(height: 18),
                TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
                const SizedBox(height: 12),
                TextField(
                  controller: _url,
                  decoration: InputDecoration(
                    labelText: 'API-Adresse',
                    helperText: _kind.onPrem ? 'z. B. http://192.168.1.10:11434/v1 (Ollama) oder http://server:1234/v1 (LM Studio)' : null,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _key,
                  obscureText: !_showKey,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: _kind.needsKey ? 'API-Schlüssel' : 'API-Schlüssel (falls nötig)',
                    hintText: _hasKey ? '•••••••• im Tresor – leer lassen, um ihn zu behalten' : null,
                    prefixIcon: const Icon(Icons.key_outlined, size: 20),
                    suffixIcon: IconButton(
                      icon: Icon(_showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
                      onPressed: () => setState(() => _showKey = !_showKey),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: _models.isEmpty
                        ? TextField(controller: _model, decoration: const InputDecoration(labelText: 'Modell'))
                        : DropdownButtonFormField<String>(
                            initialValue: _models.contains(_model.text) ? _model.text : null,
                            isExpanded: true,
                            decoration: const InputDecoration(labelText: 'Modell'),
                            items: [for (final m in _models) DropdownMenuItem(value: m, child: Text(m, overflow: TextOverflow.ellipsis))],
                            onChanged: (v) => setState(() => _model.text = v ?? _model.text),
                          ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _loadModels,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Modelle laden'),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                TextField(
                  controller: _ctx,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Context in Tokens (optional)',
                    hintText: 'leer = ${_onPrem ? '32768' : '128000'}',
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  title: const Text('Läuft im eigenen Netz (On-Prem)'),
                  subtitle: const Text('On-Prem-Server zählen nicht als Cloud und brauchen keine Freigabe pro Frage.'),
                  value: _onPrem,
                  onChanged: (v) => setState(() => _onPrem = v),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _test,
                    icon: _busy
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.bolt, size: 18),
                    label: const Text('Verbindung testen'),
                  ),
                ]),
                if (_status != null) ...[
                  const SizedBox(height: 10),
                  Panel(
                    padding: const EdgeInsets.all(12),
                    color: _ok ? c.mintSoft : (_status!.startsWith('Fehler') ? c.redSoft : null),
                    child: Text(_status!, style: t.bodySmall?.copyWith(color: _ok ? c.mint : (_status!.startsWith('Fehler') ? c.red : null))),
                  ),
                ],
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
