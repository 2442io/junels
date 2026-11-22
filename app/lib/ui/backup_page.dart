// Sicherung exportieren und wiederherstellen.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/backup.dart';
import '../state/native_files.dart';
import 'theme.dart';

Future<void> openBackup(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BackupPage()));

class BackupPage extends StatefulWidget {
  const BackupPage({super.key});
  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool _withFiles = true;
  bool _busy = false;
  String? _status;

  Backup _backup() {
    final app = AppScope.read(context);
    return Backup(root: app.storage.root, outputs: app.outputsDir, attachments: app.attachmentsDir);
  }

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final (bytes, name) = await _backup().create(withFiles: _withFiles);
      final tmp = File('${Directory.systemTemp.path}/$name');
      await tmp.writeAsBytes(bytes);
      final saved = await NativeFiles.saveAs(tmp.path);
      setState(() => _status = saved == null
          ? 'Abgebrochen.'
          : 'Gespeichert: ${saved.split(Platform.pathSeparator).last} (${(bytes.length / 1e6).toStringAsFixed(1)} MB)');
    } catch (e) {
      setState(() => _status = 'Fehler: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final pick = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['zip'], withData: true);
    final file = pick?.files.single;
    if (file == null || !mounted) return;
    final bytes = file.bytes ?? (file.path != null ? await File(file.path!).readAsBytes() : null);
    if (bytes == null) return;
    final info = Backup.inspect(bytes);
    if (info == null) {
      setState(() => _status = 'Fehler: Das ist keine Junels-Sicherung.');
      return;
    }
    final created = DateTime.tryParse(info['created'] as String? ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sicherung wiederherstellen?'),
        content: Text(
          'Sicherung vom ${created == null ? '?' : '${created.day}.${created.month}.${created.year} ${created.hour}:${created.minute.toString().padLeft(2, '0')}'}'
          ' (Junels ${info['version']}, ${info['chats']} Chats).\n\n'
          'Deine aktuellen Chats, Prozesse, Beobachtungen, Einstellungen und das Gedächtnis werden dadurch ersetzt. '
          'Der jetzige Stand wird vorher als Sicherung in „Ausgaben“ abgelegt. Modelle bleiben erhalten.\n\n'
          'Danach beendet sich Junels – bitte neu öffnen.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Wiederherstellen')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final msg = await _backup().restore(bytes);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Fertig'),
          content: Text('$msg\n\nJunels beendet sich jetzt. Bitte danach neu öffnen.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Beenden'))],
        ),
      );
      // sofort beenden, damit nichts den wiederhergestellten Stand überschreibt
      Process.killPid(pid, ProcessSignal.sigkill);
      exit(0);
    } catch (e) {
      setState(() {
        _busy = false;
        _status = 'Fehler: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Sicherung')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(
                  'Eine ZIP-Datei mit allen Chats, Prozessen, Beobachtungen, Prompt-Vorlagen, Einstellungen, Gedächtnis, Wissensbasis '
                  'und eigenen Designs. Nicht enthalten: Modelle (lassen sich neu laden) und Passwörter/API-Schlüssel aus dem Tresor.',
                  style: t.bodySmall,
                ),
                const SizedBox(height: 16),
                Panel(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Exportieren', style: t.titleSmall),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('Erstellte Dateien und Anhänge mitsichern'),
                      subtitle: const Text('PDFs, PowerPoints, Bilder (je bis 50 MB, insgesamt bis 400 MB)'),
                      value: _withFiles,
                      onChanged: _busy ? null : (v) => setState(() => _withFiles = v ?? true),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _export,
                        icon: const Icon(Icons.archive_outlined),
                        label: const Text('Sicherung speichern …'),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 12),
                Panel(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Wiederherstellen', style: t.titleSmall),
                    const SizedBox(height: 6),
                    Text('Auch zum Umziehen auf ein anderes Gerät (z. B. vom Mac aufs Handy).', style: t.bodySmall),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _import,
                        icon: const Icon(Icons.unarchive_outlined),
                        label: const Text('Sicherung öffnen …'),
                      ),
                    ),
                  ]),
                ),
                if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
                if (_status != null) ...[
                  const SizedBox(height: 12),
                  Text(_status!, style: t.bodySmall?.copyWith(color: _status!.startsWith('Fehler') ? c.red : c.mint)),
                ],
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
