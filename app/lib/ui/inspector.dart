// Rechts: Artefakte (Code, Tabellen, Berichte) und Performance-Metriken.

import 'dart:convert';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_controller.dart';
import '../state/app_scope.dart';
import 'markdown_lite.dart';

class InspectorPanel extends StatelessWidget {
  const InspectorPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            tabs: [
              Tab(text: 'Artefakte (${app.artifacts.length})'),
              const Tab(text: 'Metriken'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _ArtifactList(app: app),
                _Metrics(app: app),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------- Artefakte

class _ArtifactList extends StatelessWidget {
  const _ArtifactList({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final items = app.artifacts.reversed.toList();
    final scheme = Theme.of(context).colorScheme;
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Hier erscheinen Code, Tabellen und Berichte, die der Agent mit „write_artifact“ anlegt.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _ArtifactCard(artifact: items[i]),
    );
  }
}

class _ArtifactCard extends StatelessWidget {
  const _ArtifactCard({required this.artifact});
  final Artifact artifact;

  static const _ext = {'code': 'txt', 'markdown': 'md', 'table': 'md', 'json': 'json', 'text': 'txt'};

  IconData get _icon => switch (artifact.kind) {
        'code' => Icons.code,
        'table' => Icons.table_chart_outlined,
        'json' => Icons.data_object,
        'markdown' => Icons.article_outlined,
        _ => Icons.notes,
      };

  Future<void> _export(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final safe = artifact.title.replaceAll(RegExp(r'[^\w\-äöüÄÖÜß ]'), '').trim();
    final name = '${safe.isEmpty ? 'artefakt' : safe}.${_ext[artifact.kind] ?? 'txt'}';
    try {
      final bytes = utf8.encode(artifact.content);
      // Mobile Plattformen schreiben die Bytes selbst, Desktop liefert nur einen Pfad
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Artefakt speichern',
        fileName: name,
        bytes: bytes,
      );
      if (path == null) return;
      if (Platform.isMacOS) await File(path).writeAsBytes(bytes);
      messenger.showSnackBar(SnackBar(content: Text('Gespeichert: $name')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Speichern fehlgeschlagen: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final preview = artifact.content.length > 4000
        ? '${artifact.content.substring(0, 4000)}\n…'
        : artifact.content;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(_icon, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(artifact.title,
                      style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  tooltip: 'Kopieren',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: artifact.content));
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Kopiert'), duration: Duration(seconds: 1)));
                  },
                ),
                IconButton(
                  tooltip: 'Als Datei speichern',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.save_alt, size: 18),
                  onPressed: () => _export(context),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: switch (artifact.kind) {
                'markdown' || 'table' => MarkdownLite(preview),
                'code' || 'json' => CodeBlock(code: preview, language: artifact.kind),
                _ => SelectableText(preview),
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------- Metriken

class _Metrics extends StatelessWidget {
  const _Metrics({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final s = app.lastStats;
    final info = app.engine?.info;
    final scheme = Theme.of(context).colorScheme;
    String mb(int b) => b <= 0 ? '–' : '${(b / (1024 * 1024)).round()} MB';
    String gb(int b) => b <= 0 ? '–' : '${(b / (1 << 30)).toStringAsFixed(1)} GB';
    final ctxUsed = s?.contextUsed ?? 0;
    final ctxSize = info?.contextSize ?? s?.contextSize ?? 0;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Expanded(
                child: _Tile(
                    label: 'Generierung',
                    value: app.lastTokensPerSecond == null ? '–' : app.lastTokensPerSecond!.toStringAsFixed(1),
                    unit: 'Tokens/s')),
            const SizedBox(width: 10),
            Expanded(
                child: _Tile(
                    label: 'Prompt',
                    value: s == null || s.promptTokens == 0 ? '–' : s.promptTokensPerSecond.toStringAsFixed(0),
                    unit: 'Tokens/s')),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
                child: _Tile(
                    label: 'Erstes Token',
                    value: s == null || s.timeToFirstTokenMs < 0 ? '–' : (s.timeToFirstTokenMs / 1000).toStringAsFixed(2),
                    unit: 's')),
            const SizedBox(width: 10),
            Expanded(
                child: _Tile(
                    label: 'Wiederverwendet',
                    value: s == null ? '–' : '${s.reusedTokens}',
                    unit: 'Tokens aus Cache')),
          ],
        ),
        const SizedBox(height: 16),
        _BarRow(
          label: 'Context',
          detail: ctxSize == 0 ? '–' : '$ctxUsed / $ctxSize Tokens',
          value: ctxSize == 0 ? 0 : ctxUsed / ctxSize,
        ),
        const SizedBox(height: 12),
        _BarRow(
          label: 'RAM der App',
          detail: '${mb(app.processMemory)} (Spitze ${mb(app.peakProcessMemory)})',
          value: app.device.totalMemory <= 0 ? 0 : app.processMemory / app.device.totalMemory,
          warn: app.availableMemory > 0 && app.availableMemory < 300 * 1024 * 1024,
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Noch verfügbar: ${gb(app.availableMemory)} von ${gb(app.device.totalMemory)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ),
        const SizedBox(height: 20),
        Text('Modell', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (info == null)
          Text('Kein Modell geladen.', style: TextStyle(color: scheme.onSurfaceVariant))
        else ...[
          _kv(context, 'Beschreibung', info.description),
          _kv(context, 'Parameter', '${(info.parameters / 1e9).toStringAsFixed(2)} Mrd.'),
          _kv(context, 'Größe', gb(info.sizeBytes)),
          _kv(context, 'Context', '${info.contextSize} (trainiert ${info.trainedContext})'),
          _kv(context, 'Backend', app.device.gpuLayers != 0 ? 'Metal (GPU)' : 'CPU, ${app.device.threads} Threads'),
          _kv(context, 'KV-Cache', app.device.quantizeKv ? 'q8_0 (sparsam)' : 'f16'),
        ],
      ],
    );
  }

  Widget _kv(BuildContext context, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(k, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
            Expanded(child: Text(v)),
          ],
        ),
      );
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, required this.unit});
  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: t.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text(value, style: t.headlineSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            Text(unit, style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _BarRow extends StatelessWidget {
  const _BarRow({required this.label, required this.detail, required this.value, this.warn = false});
  final String label;
  final String detail;
  final double value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Text(label, style: t.bodyMedium),
          const Spacer(),
          Text(detail, style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: value.clamp(0.0, 1.0),
            minHeight: 8,
            color: warn || value > 0.85 ? scheme.error : scheme.primary,
            backgroundColor: scheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }
}
