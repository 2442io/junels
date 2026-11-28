// Systemcheck: Hardware prüfen, passende Modelle empfehlen und herunterladen.

import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/app_scope.dart';
import 'model_import.dart';
import 'quick_nav.dart';
import '../l10n.dart';

Future<void> openSystemCheck(BuildContext context) async {
  final app = AppScope.read(context);
  app.refreshFreeDisk();
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SystemCheckPage()));
  await app.markSystemCheckSeen();
}

class SystemCheckPage extends StatelessWidget {
  const SystemCheckPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      appBar: JAppBar(title: Text(tr('Systemcheck & Modelle'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _DeviceCard(app: app),
              const SizedBox(height: 12),
              _SetCard(app: app),
              const SizedBox(height: 20),
              _KindSection(
                app: app,
                kind: ModelKind.llm,
                title: tr('Sprachmodell (Pflicht)'),
                subtitle: tr('Das Gehirn des Agenten. Läuft komplett auf diesem Gerät.'),
                icon: Icons.memory,
              ),
              const SizedBox(height: 4),
              const _CustomUrlField(),
              const SizedBox(height: 20),
              _KindSection(
                app: app,
                kind: ModelKind.image,
                title: tr('Bilder erzeugen – Stable Diffusion (optional)'),
                subtitle: (tr('Damit der Agent Bilder malen kann (Fotos, Illustrationen für Präsentationen). ') + tr('Diagramme und Dokumente gehen auch ohne.')),
                icon: Icons.brush_outlined,
              ),
              const SizedBox(height: 20),
              _KindSection(
                app: app,
                kind: ModelKind.stt,
                title: tr('Spracherkennung (optional)'),
                subtitle: tr('Für Mikrofon und Gespräch. Canary bzw. Parakeet sind ein Vielfaches schneller als Whisper.'),
                icon: Icons.mic_none,
              ),
              const SizedBox(height: 20),
              _KindSection(
                app: app,
                kind: ModelKind.tts,
                title: tr('Stimme – Kokoro / Piper (optional)'),
                subtitle: tr('Zum Vorlesen der Antworten.'),
                icon: Icons.record_voice_over_outlined,
              ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: () => pickAndImportModel(context),
                icon: const Icon(Icons.file_open_outlined),
                label: Text(tr('Eigene .gguf-Datei vom Gerät importieren')),
              ),
              const SizedBox(height: 8),
              Text(
                tr('Downloads kommen direkt von Hugging Face bzw. GitHub. Danach arbeitet die App ohne Internet.'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CustomUrlField extends StatefulWidget {
  const _CustomUrlField();

  @override
  State<_CustomUrlField> createState() => _CustomUrlFieldState();
}

class _CustomUrlFieldState extends State<_CustomUrlField> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('Anderes Modell per Link laden'), style: t.titleSmall),
            const SizedBox(height: 2),
            Text(tr('Link zu einer .gguf-Datei, z. B. von Hugging Face (Seite „Files“ → Datei → Link kopieren).'),
                style: t.bodySmall),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  decoration: InputDecoration(
                    hintText: 'https://huggingface.co/…/resolve/main/modell-Q4_K_M.gguf',
                    errorText: _error,
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: () {
                  final err = app.downloadCustomUrl(_ctrl.text);
                  setState(() => _error = err);
                  if (err == null) _ctrl.clear();
                },
                child: Text(tr('Laden')),
              ),
            ]),
            for (final d in app.customDownloads)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(d.entry.fileName, style: t.bodySmall),
                      if (d.error != null)
                        Text(d.error!, style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error))
                      else
                        LinearProgressIndicator(value: d.progress?.fraction),
                    ]),
                  ),
                  IconButton(
                    icon: Icon(d.error != null ? Icons.refresh : Icons.close),
                    onPressed: () => d.error != null ? app.startDownload(d.entry) : app.cancelDownload(d.entry),
                  ),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final d = app.device;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    String gb(int b) => b < 0 ? 'unbekannt' : '${(b / (1 << 30)).toStringAsFixed(1)} GB';
    final platform = Platform.isMacOS
        ? 'macOS'
        : Platform.isIOS
            ? 'iPadOS'
            : Platform.isAndroid
                ? 'Android'
                : Platform.operatingSystem;
    final rows = <(IconData, String, String)>[
      (Icons.devices_other, 'System', platform),
      (Icons.memory, tr('Arbeitsspeicher'), gb(d.totalMemory)),
      (Icons.sd_storage_outlined, tr('Freier Speicherplatz'), gb(app.freeDisk)),
      (Icons.developer_board, tr('Prozessor'), '${Platform.numberOfProcessors} Kerne, ${d.threads} für KI'),
      (Icons.bolt, tr('Beschleunigung'), d.gpuLayers != 0 ? 'Metal-GPU' : 'CPU (arm64)'),
      (Icons.unfold_more, tr('Max. Context'), '${d.maxContext} Tokens'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: scheme.primaryContainer,
                  child: Text(d.deviceClass.name.toUpperCase(),
                      style: t.titleMedium?.copyWith(color: scheme.onPrimaryContainer)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Geräteklasse ${d.deviceClass.label}', style: t.titleMedium),
                      Text(
                        switch (d.deviceClass) {
                          DeviceClass.s => tr('Kleine Modelle (bis 1,5B). Spracheingabe mit Whisper base.'),
                          DeviceClass.m => tr('Modelle bis 4B. Whisper large-v3-turbo (komprimiert) möglich.'),
                          DeviceClass.l => tr('Modelle bis 12B und Whisper large-v3-turbo.'),
                          DeviceClass.xl => tr('Auch große Modelle wie Gemma 4 26B und 16K Context.'),
                        },
                        style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Wrap(
              spacing: 24,
              runSpacing: 10,
              children: [
                for (final (icon, k, v) in rows)
                  SizedBox(
                    width: 240,
                    child: Row(
                      children: [
                        Icon(icon, size: 18, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text.rich(TextSpan(children: [
                            TextSpan(text: '$k: ', style: TextStyle(color: scheme.onSurfaceVariant)),
                            TextSpan(text: v),
                          ])),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _KindSection extends StatelessWidget {
  const _KindSection({
    required this.app,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.icon,
  });
  final AppController app;
  final ModelKind kind;
  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final recs = app.recommendations(kind);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: t.titleMedium)),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 2, 0, 8),
          child: Text(subtitle, style: t.bodySmall),
        ),
        for (final r in recs) _EntryTile(app: app, rec: r),
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.app, required this.rec});
  final AppController app;
  final Recommendation rec;

  @override
  Widget build(BuildContext context) {
    final e = rec.entry;
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final installed = app.installedPath(e) != null;
    final dl = app.downloads[e.id];
    final disabled = rec.suitability == Suitability.tooBig || rec.suitability == Suitability.noSpace;

    final (badgeColor, badgeText) = switch (rec.suitability) {
      Suitability.recommended => (Colors.green, tr('Empfohlen')),
      Suitability.suitable => (scheme.primary, tr('Passt')),
      Suitability.tooBig => (scheme.outline, tr('Zu groß')),
      Suitability.noSpace => (scheme.error, tr('Kein Platz')),
    };

    Widget action;
    if (dl != null && dl.active) {
      final p = dl.progress;
      action = Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 120,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              LinearProgressIndicator(value: dl.extracting ? null : p?.fraction),
              const SizedBox(height: 4),
              Text(
                dl.extracting
                    ? tr('Entpacke …')
                    : p == null
                        ? tr('Verbinde …')
                        : '${((p.fraction ?? 0) * 100).round()} % · ${_speed(p.bytesPerSecond)}${_eta(p.eta)}',
                style: t.labelSmall,
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: tr('Abbrechen'),
          icon: const Icon(Icons.close),
          onPressed: dl.extracting ? null : () => app.cancelDownload(e),
        ),
      ]);
    } else if (installed) {
      action = _installedActions(context, e);
    } else {
      action = FilledButton.tonalIcon(
        onPressed: disabled ? null : () => app.startDownload(e),
        icon: Icon(dl?.error != null ? Icons.refresh : Icons.download, size: 18),
        label: Text(dl?.error != null ? tr('Fortsetzen') : e.sizeLabel),
      );
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(e.name, style: t.titleSmall?.copyWith(color: disabled ? scheme.outline : null)),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: badgeColor.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(badgeText, style: t.labelSmall?.copyWith(color: badgeColor)),
                          ),
                          if (installed)
                            const Icon(Icons.check_circle, size: 16, color: Colors.green),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text('${e.description} ${disabled ? '· ${rec.reason}' : ''}',
                          style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                action,
              ],
            ),
            if (e.kind == ModelKind.llm && e.vision && installed) _VisionRow(app: app, model: e),
            if (dl?.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(dl!.error!, style: t.bodySmall?.copyWith(color: scheme.error)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _installedActions(BuildContext context, CatalogEntry e) {
    switch (e.kind) {
      case ModelKind.llm:
        final m = app.storedModelFor(e);
        final loaded = m != null && app.loadedModel?.id == m.id;
        return FilledButton.icon(
          onPressed: m == null || loaded || app.status == EngineStatus.loading
              ? null
              : () async {
                  await app.loadModel(m);
                  if (context.mounted && app.status == EngineStatus.ready) Navigator.of(context).maybePop();
                },
          icon: Icon(loaded ? Icons.check : Icons.play_arrow, size: 18),
          label: Text(loaded ? tr('Geladen') : tr('Laden')),
        );
      case ModelKind.image:
        return Chip(label: Text(tr('Bereit')), visualDensity: VisualDensity.compact);
      case ModelKind.stt:
      case ModelKind.tts:
        final active = e.kind == ModelKind.stt ? app.settings.sttModelId == e.id : app.settings.ttsVoiceId == e.id;
        return Row(mainAxisSize: MainAxisSize.min, children: [
          active
              ? Chip(label: Text(tr('Aktiv')), visualDensity: VisualDensity.compact)
              : TextButton(
                  onPressed: () => e.kind == ModelKind.stt
                      ? app.setVoiceSettings(sttModelId: e.id)
                      : app.setVoiceSettings(ttsVoiceId: e.id),
                  child: Text(tr('Verwenden')),
                ),
          if (e.kind == ModelKind.tts)
            IconButton(
              tooltip: tr('Probe hören'),
              icon: const Icon(Icons.play_circle_outline),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                messenger.showSnackBar(SnackBar(content: Text(tr('Teste Stimme …')), duration: Duration(seconds: 2)));
                final (ok, report) = await app.voice.output.diagnose(app.installedPath(e)!);
                messenger.hideCurrentSnackBar();
                if (!context.mounted) return;
                await showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(ok ? tr('Piper funktioniert') : tr('Piper-Test fehlgeschlagen')),
                    content: SingleChildScrollView(
                      child: SelectableText(
                        ok ? report : ('$report\nDie App nutzt bis dahin die Systemstimme. ' + tr('Bitte schick mir einen Screenshot dieser Meldung.')),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
                  ),
                );
              },
            ),
          IconButton(
            tooltip: tr('Löschen'),
            icon: const Icon(Icons.delete_outline),
            onPressed: () => app.removeVoiceModel(e),
          ),
        ]);
    }
  }

  static String _speed(double bps) =>
      bps <= 0 ? '' : bps > 1 << 20 ? '${(bps / (1 << 20)).toStringAsFixed(1)} MB/s' : '${(bps / 1024).round()} KB/s';

  static String _eta(Duration? d) {
    if (d == null) return '';
    if (d.inMinutes >= 1) return ' · ${d.inMinutes} min';
    return ' · ${d.inSeconds} s';
  }
}

/// Zusatzdatei für Bildverständnis (mmproj) zu einem Sprachmodell.
class _VisionRow extends StatelessWidget {
  const _VisionRow({required this.app, required this.model});
  final AppController app;
  final CatalogEntry model;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final id = 'mmproj:${model.id}';
    final path = app.settings.installed[id];
    final has = path != null && File(path).existsSync();
    final dl = app.downloads[id];
    Widget trailing;
    if (dl != null && dl.active) {
      final p = dl.progress;
      trailing = Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 90, child: LinearProgressIndicator(value: p?.fraction)),
        IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => dl.cancel.cancel()),
      ]);
    } else if (has) {
      trailing = TextButton(onPressed: () => app.removeVision(model), child: Text(tr('Entfernen')));
    } else {
      trailing = TextButton.icon(
        onPressed: () => app.downloadVision(model),
        icon: const Icon(Icons.download, size: 16),
        label: Text(dl?.error != null ? tr('Erneut versuchen') : tr('Laden')),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(has ? Icons.visibility : Icons.visibility_outlined, size: 18, color: has ? Colors.green : scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              has ? tr('Bilder verstehen: bereit') : tr('Bilder verstehen (Fotos, Screenshots, Scans) – Zusatzdatei'),
              style: t.bodySmall,
            ),
          ),
          trailing,
        ]),
        if (dl?.error != null) Text(dl!.error!, style: t.bodySmall?.copyWith(color: scheme.error)),
      ]),
    );
  }
}


/// Zwei Knöpfe: passendes Komplett-Set für Handy oder Desktop – nur Modelle, die hier laufen.
class _SetCard extends StatelessWidget {
  const _SetCard({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    String mb(int b) => b >= 1 << 30 ? '${(b / (1 << 30)).toStringAsFixed(1)} GB' : '${(b / (1 << 20)).round()} MB';
    Widget option(bool mobile) {
      final set = app.modelSet(mobile: mobile);
      final missing = set.where((e) => app.installedPath(e) == null).toList();
      final size = missing.fold<int>(0, (a, e) => a + e.sizeBytes);
      final busy = set.any((e) => app.downloads[e.id]?.active == true);
      final kindLabel = {ModelKind.llm: tr('Modell'), ModelKind.stt: tr('Hören'), ModelKind.tts: tr('Stimme')};
      return Expanded(
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(12), alignment: Alignment.centerLeft),
          onPressed: busy
              ? null
              : () async {
                  final messenger = ScaffoldMessenger.of(context);
                  messenger.showSnackBar(SnackBar(
                      content: Text(missing.isEmpty
                          ? '${mobile ? 'Handy' : 'Desktop'}-Set wird aktiviert'
                          : 'Lade ${missing.length} Modell(e), ${mb(size)} …')));
                  await app.installModelSet(mobile: mobile);
                },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(mobile ? Icons.smartphone : Icons.desktop_windows_outlined, size: 20),
                const SizedBox(width: 8),
                Text(mobile ? tr('Handy') : 'Desktop', style: t.titleSmall),
                if (busy) ...[
                  const SizedBox(width: 8),
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ]),
              const SizedBox(height: 6),
              for (final e in set)
                Text('${kindLabel[e.kind]}: ${e.name}${app.installedPath(e) != null ? ' ✓' : ''}',
                    style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Text(missing.isEmpty ? tr('Alles geladen – tippen zum Aktivieren') : 'Noch zu laden: ${mb(size)}',
                  style: t.labelSmall),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Schnell einrichten'), style: t.titleMedium),
            const SizedBox(height: 4),
            Text(tr('Ein Komplett-Set aus Sprachmodell, Spracherkennung und Stimme – nur was laut Systemcheck auf diesem Gerät läuft.'),
                style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            Row(children: [option(true), const SizedBox(width: 12), option(false)]),
          ],
        ),
      ),
    );
  }
}
