// "Modell laden": Datei wählen → GGUF-Kopf prüfen → Speicher prüfen → ins
// App-Verzeichnis übernehmen → optional sofort laden (SRS Abschnitt 4).

import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../state/app_scope.dart';

Future<void> pickAndImportModel(BuildContext context) async {
  final app = AppScope.read(context);
  final messenger = ScaffoldMessenger.of(context);

  FilePickerResult? res;
  try {
    res = await FilePicker.platform.pickFiles(
      dialogTitle: 'GGUF-Modell wählen',
      // FileType.custom mit "gguf" scheitert auf Android/iOS am unbekannten MIME-Typ
      type: FileType.any,
      allowMultiple: false,
      withData: false,
      lockParentWindow: true,
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Dateiauswahl fehlgeschlagen: $e')));
    return;
  }
  if (res == null || res.files.isEmpty) return;
  final picked = res.files.single;
  final path = picked.path;
  if (path == null) {
    messenger.showSnackBar(const SnackBar(content: Text('Die Datei ist nicht lokal verfügbar.')));
    return;
  }
  if (!context.mounted) return;

  if (!picked.name.toLowerCase().endsWith('.gguf')) {
    await _info(context, 'Kein GGUF-Modell',
        '„${picked.name}“ ist keine .gguf-Datei. Unterstützt werden nur GGUF-Modelle, '
        'z. B. Qwen 2.5 3B oder Llama 3.2 3B in Q4_K_M.');
    return;
  }

  GgufInfo info;
  try {
    info = await app.inspectModel(path);
  } on GgufFormatException catch (e) {
    if (context.mounted) await _info(context, 'Ungültige Datei', e.message);
    return;
  }
  if (!context.mounted) return;

  final fit = app.checkFit(info);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => _ImportDialog(info: info, fit: fit),
  );
  if (ok != true || !context.mounted) return;

  // Datei-Wähler auf Android/iOS legt eine Kopie im Cache an → verschieben statt doppelt kopieren
  final fromCache = Platform.isAndroid || Platform.isIOS;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => const _ProgressDialog(),
  );
  try {
    final stored = await app.importModel(info, picked.name, fromPickerCache: fromCache);
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (!context.mounted) return;
    final load = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Modell importiert'),
        content: Text('${stored.displayName} liegt jetzt lokal in der App. Jetzt laden?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Später')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Laden')),
        ],
      ),
    );
    if (load == true) await app.loadModel(stored);
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      await _info(context, 'Import fehlgeschlagen', '$e\n\nIst genug Speicherplatz frei?');
    }
  }
}

Future<void> _info(BuildContext context, String title, String text) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );

class _ImportDialog extends StatelessWidget {
  const _ImportDialog({required this.info, required this.fit});
  final GgufInfo info;
  final FitResult fit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (fit.level) {
      FitLevel.ok => (Icons.check_circle_outline, Colors.green),
      FitLevel.warn => (Icons.warning_amber_rounded, Colors.orange),
      FitLevel.refuse => (Icons.block, scheme.error),
    };
    String gb(int b) => '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    final rows = <(String, String)>[
      ('Name', info.name),
      ('Architektur', info.architecture),
      ('Quantisierung', info.quantization),
      ('Dateigröße', gb(info.fileSize)),
      if (info.contextLength != null) ('Trainings-Context', '${info.contextLength} Tokens'),
      ('Chat-Template', info.hasChatTemplate ? 'vorhanden' : 'fehlt (ChatML wird verwendet)'),
    ];
    return AlertDialog(
      title: const Text('Modell prüfen'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (k, v) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 130, child: Text(k, style: TextStyle(color: scheme.onSurfaceVariant))),
                    Expanded(child: Text(v)),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(icon, color: color),
                  const SizedBox(width: 10),
                  Expanded(child: Text(fit.message)),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Abbrechen')),
        if (fit.level != FitLevel.refuse)
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(fit.level == FitLevel.warn ? 'Trotzdem importieren' : 'Importieren'),
          ),
      ],
    );
  }
}

class _ProgressDialog extends StatelessWidget {
  const _ProgressDialog();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = app.importProgress;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Modell wird übernommen'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: p),
            const SizedBox(height: 12),
            Text(p == null ? 'Bitte warten …' : '${(p * 100).round()} %'),
          ],
        ),
      ),
    );
  }
}
