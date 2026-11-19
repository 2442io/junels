// Anzeige von Dateien im Chat: Bild-Vorschauen und Dateikarten mit Öffnen/Teilen/Speichern.

import 'dart:io';

import 'package:flutter/material.dart';

import '../state/app_controller.dart' show isImageFile;
import '../state/native_files.dart';

String _size(int b) => b >= 1 << 20 ? '${(b / (1 << 20)).toStringAsFixed(1)} MB' : '${(b / 1024).ceil()} KB';

Future<void> _guard(BuildContext context, Future<void> Function() fn) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await fn();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Nicht möglich: $e')));
  }
}

/// Aktionen zu einer Datei (Menü).
class FileActions extends StatelessWidget {
  const FileActions(this.path, {super.key});
  final String path;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Datei-Aktionen',
      icon: const Icon(Icons.more_vert),
      onSelected: (v) => _guard(context, () async {
        switch (v) {
          case 'open':
            await NativeFiles.open(path);
          case 'share':
            await NativeFiles.share(path);
          case 'reveal':
            await NativeFiles.reveal(path);
          case 'save':
            final target = await NativeFiles.saveAs(path);
            if (target != null && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gespeichert: ${target.split('/').last}')));
            }
        }
      }),
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'open', child: ListTile(leading: Icon(Icons.open_in_new), title: Text('Öffnen'))),
        const PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.ios_share), title: Text('Teilen …'))),
        const PopupMenuItem(value: 'save', child: ListTile(leading: Icon(Icons.save_alt), title: Text('Speichern unter …'))),
        if (Platform.isMacOS)
          const PopupMenuItem(value: 'reveal', child: ListTile(leading: Icon(Icons.folder_open), title: Text('Im Finder zeigen'))),
      ],
    );
  }
}

/// Vom Agenten erzeugte Dateien unter einer Antwort.
class FileGallery extends StatelessWidget {
  const FileGallery(this.files, {super.key});
  final List<String> files;

  @override
  Widget build(BuildContext context) {
    final images = files.where(isImageFile).toList();
    final others = files.where((f) => !isImageFile(f)).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (images.isNotEmpty)
          Wrap(spacing: 8, runSpacing: 8, children: [for (final p in images) ImagePreview(p, size: 220)]),
        if (images.isNotEmpty && others.isNotEmpty) const SizedBox(height: 8),
        for (final p in others) FileCard(p),
      ]),
    );
  }
}

class FileCard extends StatelessWidget {
  const FileCard(this.path, {super.key});
  final String path;

  @override
  Widget build(BuildContext context) {
    final f = File(path);
    final exists = f.existsSync();
    final name = path.split(Platform.pathSeparator).last;
    final ext = name.split('.').last.toLowerCase();
    final (icon, label) = switch (ext) {
      'pdf' => (Icons.picture_as_pdf_outlined, 'PDF'),
      'pptx' => (Icons.slideshow_outlined, 'PowerPoint'),
      _ => (Icons.insert_drive_file_outlined, ext.toUpperCase()),
    };
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        leading: Icon(icon, color: ext == 'pdf' ? Colors.red.shade400 : (ext == 'pptx' ? Colors.orange.shade700 : null), size: 32),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(exists ? '$label · ${_size(f.lengthSync())}' : 'Datei nicht mehr vorhanden',
            style: TextStyle(color: exists ? null : scheme.error)),
        onTap: exists ? () => _guard(context, () => NativeFiles.open(path)) : null,
        trailing: exists ? FileActions(path) : null,
      ),
    );
  }
}

class ImagePreview extends StatelessWidget {
  const ImagePreview(this.path, {super.key, this.size = 160});
  final String path;
  final double size;

  @override
  Widget build(BuildContext context) {
    final f = File(path);
    if (!f.existsSync()) {
      return SizedBox(width: size, height: 40, child: const Center(child: Text('Bild fehlt')));
    }
    return Stack(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _ImageViewer(path))),
          child: Image.file(f, width: size, height: size, fit: BoxFit.cover, cacheWidth: (size * 2).round()),
        ),
      ),
      Positioned(
        right: 0,
        top: 0,
        child: Material(color: Colors.black26, shape: const CircleBorder(), child: Theme(
          data: Theme.of(context).copyWith(iconTheme: const IconThemeData(color: Colors.white)),
          child: FileActions(path),
        )),
      ),
    ]);
  }
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer(this.path);
  final String path;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(path.split(Platform.pathSeparator).last, style: const TextStyle(fontSize: 14)),
          actions: [FileActions(path)],
        ),
        body: InteractiveViewer(maxScale: 6, child: Center(child: Image.file(File(path)))),
      );
}
