// Systemcheck: Hardware prüfen, passende Modelle empfehlen und herunterladen.

import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/app_scope.dart';
import 'model_import.dart';

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
      appBar: AppBar(title: const Text('Systemcheck & Modelle')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _DeviceCard(app: app),
              const SizedBox(height: 20),
              _KindSection(
                app: app,
                kind: ModelKind.llm,
                title: 'Sprachmodell (Pflicht)',
                subtitle: 'Das Gehirn des Agenten. Läuft komplett auf diesem Gerät.',
                icon: Icons.memory,
              ),
              const SizedBox(height: 4),
              const _CustomUrlField(),
              const SizedBox(height: 20),
              _KindSection(
                app: app,
                kind: ModelKind.stt,
                title: 'Spracherkennung – Whisper (optional)',
                subtitle: 'Für die Mikrofon-Eingabe. large-v3-turbo ist die beste Wahl, wenn das Gerät es schafft.',
                icon: Icons.mic_none,
              ),
              const SizedBox(height: 20),
              _KindSection(
                app: app,
                kind: ModelKind.tts,
                title: 'Stimme – Piper (optional)',
                subtitle: 'Zum Vorlesen der Antworten.',
                icon: Icons.record_voice_over_outlined,
              ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: () => pickAndImportModel(context),
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Eigene .gguf-Datei vom Gerät importieren'),
              ),
              const SizedBox(height: 8),
              Text(
                'Downloads kommen direkt von Hugging Face bzw. GitHub. Danach arbeitet die App ohne Internet.',
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
            Text('Anderes Modell per Link laden', style: t.titleSmall),
            const SizedBox(height: 2),
            Text('Link zu einer .gguf-Datei, z. B. von Hugging Face (Seite „Files“ → Datei → Link kopieren).',
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
                child: const Text('Laden'),
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
      (Icons.memory, 'Arbeitsspeicher', gb(d.totalMemory)),
      (Icons.sd_storage_outlined, 'Freier Speicherplatz', gb(app.freeDisk)),
      (Icons.developer_board, 'Prozessor', '${Platform.numberOfProcessors} Kerne, ${d.threads} für KI'),
      (Icons.bolt, 'Beschleunigung', d.gpuLayers != 0 ? 'Metal-GPU' : 'CPU (arm64)'),
      (Icons.unfold_more, 'Max. Context', '${d.maxContext} Tokens'),
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
                          DeviceClass.s => 'Kleine Modelle (bis 1,5B). Spracheingabe mit Whisper base.',
                          DeviceClass.m => 'Modelle bis 4B. Whisper large-v3-turbo (komprimiert) möglich.',
                          DeviceClass.l => 'Modelle bis 12B und Whisper large-v3-turbo.',
                          DeviceClass.xl => 'Auch große Modelle wie Gemma 4 26B und 16K Context.',
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
      Suitability.recommended => (Colors.green, 'Empfohlen'),
      Suitability.suitable => (scheme.primary, 'Passt'),
      Suitability.tooBig => (scheme.outline, 'Zu groß'),
      Suitability.noSpace => (scheme.error, 'Kein Platz'),
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
                    ? 'Entpacke …'
                    : p == null
                        ? 'Verbinde …'
                        : '${((p.fraction ?? 0) * 100).round()} % · ${_speed(p.bytesPerSecond)}${_eta(p.eta)}',
                style: t.labelSmall,
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Abbrechen',
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
        label: Text(dl?.error != null ? 'Fortsetzen' : e.sizeLabel),
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
          label: Text(loaded ? 'Geladen' : 'Laden'),
        );
      case ModelKind.stt:
      case ModelKind.tts:
        final active = e.kind == ModelKind.stt ? app.settings.sttModelId == e.id : app.settings.ttsVoiceId == e.id;
        return Row(mainAxisSize: MainAxisSize.min, children: [
          active
              ? const Chip(label: Text('Aktiv'), visualDensity: VisualDensity.compact)
              : TextButton(
                  onPressed: () => e.kind == ModelKind.stt
                      ? app.setVoiceSettings(sttModelId: e.id)
                      : app.setVoiceSettings(ttsVoiceId: e.id),
                  child: const Text('Verwenden'),
                ),
          if (e.kind == ModelKind.tts)
            IconButton(
              tooltip: 'Probe hören',
              icon: const Icon(Icons.play_circle_outline),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                messenger.showSnackBar(const SnackBar(content: Text('Teste Stimme …'), duration: Duration(seconds: 2)));
                try {
                  final r = await app.voice.output.diagnose(app.installedPath(e)!);
                  messenger.showSnackBar(SnackBar(content: Text(r), duration: const Duration(seconds: 8)));
                } catch (err) {
                  messenger.showSnackBar(SnackBar(
                      content: Text('Piper-Test fehlgeschlagen: $err\nDie App nutzt dann die Systemstimme.'),
                      duration: const Duration(seconds: 12)));
                }
              },
            ),
          IconButton(
            tooltip: 'Löschen',
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
