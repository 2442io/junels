// Anzeige von Dateien im Chat: Bild-Vorschauen und Dateikarten mit Öffnen/Teilen/Speichern.

import 'transcript_view.dart' show TranscriptCard;
import 'dart:io';

import 'package:agent_engine/agent_engine.dart' show XlsxBook, officeText, colName;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

import '../state/app_controller.dart' show isImageFile;
import '../state/native_files.dart';
import 'quick_nav.dart';

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
          Wrap(spacing: 8, runSpacing: 8, children: [for (final p in images) _aiAware(p)]),
        if (images.isNotEmpty && others.isNotEmpty) const SizedBox(height: 8),
        for (final p in others) ...[
          if (p.endsWith('.mitschrift.json')) TranscriptCard(p) else FileCard(p),
          if (RegExp(r'\.(docx|xlsx)$', caseSensitive: false).hasMatch(p)) OfficePreview(p, key: ValueKey(p)),
        ],
      ]),
    );
  }
}

/// KI-Bilder: Screenreader-Hinweis; ältere Bilder ohne eingestempeltes Symbol bekommen es als Plakette.
Widget _aiAware(String p) {
  final name = p.split(Platform.pathSeparator).last;
  final stamped = name.startsWith('KI-Bild');
  final legacy = !stamped && name.startsWith('Bild ');
  final preview = ImagePreview(p, size: 220);
  if (!stamped && !legacy) return preview;
  return Semantics(
    label: 'KI-generiertes Bild',
    image: true,
    child: Stack(children: [
      preview,
      if (legacy) const Positioned(right: 8, bottom: 8, child: AiGeneratedBadge(height: 16)),
    ]),
  );
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
      'docx' => (Icons.description_outlined, 'Word'),
      'xlsx' => (Icons.table_chart_outlined, 'Excel'),
      _ => (Icons.insert_drive_file_outlined, ext.toUpperCase()),
    };
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        leading: Icon(icon,
            color: switch (ext) {
              'pdf' => Colors.red.shade400,
              'pptx' => Colors.orange.shade700,
              'docx' => Colors.blue.shade600,
              'xlsx' => Colors.green.shade700,
              _ => null,
            },
            size: 32),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(exists ? '$label · ${_size(f.lengthSync())}' : 'Datei nicht mehr vorhanden',
            style: TextStyle(color: exists ? null : scheme.error)),
        onTap: exists ? () => _guard(context, () => NativeFiles.open(path)) : null,
        trailing: exists ? FileActions(path) : null,
      ),
    );
  }
}

/// Folien bzw. Seiten zum Durchblättern (PowerPoint über das mit erzeugte PDF).
class SlidePreview extends StatefulWidget {
  const SlidePreview(this.path, {super.key});
  final String path;
  @override
  State<SlidePreview> createState() => _SlidePreviewState();
}

class _SlidePreviewState extends State<SlidePreview> {
  Future<List<String>>? _pages;
  int _stamp = 0;

  String get _pdf => widget.path.replaceFirst(RegExp(r'\.pptx$'), '.pdf');

  void _load() {
    final f = File(_pdf);
    final stamp = f.existsSync() ? f.lastModifiedSync().millisecondsSinceEpoch : 0;
    if (_pages != null && stamp == _stamp) return;
    _stamp = stamp;
    _pages = stamp == 0 ? Future.value(const <String>[]) : NativeFiles.pdfPages(_pdf, width: 960).catchError((_) => const <String>[]);
  }

  @override
  Widget build(BuildContext context) {
    _load(); // nach einer Änderung (edit_file) neu rendern
    return FutureBuilder<List<String>>(
      future: _pages,
      builder: (context, snap) {
        final pages = snap.data ?? const <String>[];
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(height: 96, child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))));
        }
        if (pages.isEmpty) return const SizedBox.shrink();
        final isDeck = widget.path.endsWith('.pptx');
        return SizedBox(
          height: isDeck ? 96 : 140,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: pages.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) => InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  fullscreenDialog: true,
                  builder: (_) => _PageViewer(pages: pages, start: i, title: widget.path.split(Platform.pathSeparator).last))),
              child: Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor)),
                    child: Image.file(File(pages[i]), fit: BoxFit.contain, cacheWidth: 360),
                  ),
                ),
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                    child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 10)),
                  ),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

class _PageViewer extends StatefulWidget {
  const _PageViewer({required this.pages, required this.start, required this.title});
  final List<String> pages;
  final int start;
  final String title;
  @override
  State<_PageViewer> createState() => _PageViewerState();
}

class _PageViewerState extends State<_PageViewer> {
  late final _ctrl = PageController(initialPage: widget.start);
  late int _i = widget.start;

  void _go(int d) {
    final n = (_i + d).clamp(0, widget.pages.length - 1);
    _ctrl.animateToPage(n, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.space): () => _go(1),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: JAppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text('${widget.title} · ${_i + 1}/${widget.pages.length}', style: const TextStyle(fontSize: 15)),
          ),
          body: Stack(children: [
            PageView.builder(
              controller: _ctrl,
              itemCount: widget.pages.length,
              onPageChanged: (i) => setState(() => _i = i),
              itemBuilder: (_, i) => InteractiveViewer(
                maxScale: 4,
                child: Center(child: Image.file(File(widget.pages[i]), fit: BoxFit.contain)),
              ),
            ),
            if (_i > 0)
              Positioned(
                left: 8,
                top: 0,
                bottom: 0,
                child: Center(
                    child: IconButton.filledTonal(onPressed: () => _go(-1), icon: const Icon(Icons.chevron_left), tooltip: 'Zurück')),
              ),
            if (_i < widget.pages.length - 1)
              Positioned(
                right: 8,
                top: 0,
                bottom: 0,
                child: Center(
                    child: IconButton.filledTonal(onPressed: () => _go(1), icon: const Icon(Icons.chevron_right), tooltip: 'Weiter')),
              ),
          ]),
        ),
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
        appBar: JAppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(path.split(Platform.pathSeparator).last, style: const TextStyle(fontSize: 14)),
          actions: [FileActions(path)],
        ),
        body: InteractiveViewer(maxScale: 6, child: Center(child: Image.file(File(path)))),
      );
}


/// Kurze Vorschau für Word (erste Absätze) und Excel (erste Zeilen des ersten Blatts).
class OfficePreview extends StatelessWidget {
  const OfficePreview(this.path, {super.key});
  final String path;

  @override
  Widget build(BuildContext context) {
    final f = File(path);
    if (!f.existsSync()) return const SizedBox.shrink();
    final t = Theme.of(context);
    final border = BoxDecoration(border: Border.all(color: t.dividerColor), borderRadius: BorderRadius.circular(8));
    try {
      final bytes = f.readAsBytesSync();
      if (path.toLowerCase().endsWith('.xlsx')) {
        final book = XlsxBook.open(bytes);
        final sheets = book.sheets;
        final (values, formulas) = book.cells(sheets.first.$2);
        final keys = {...values.keys, ...formulas.keys};
        if (keys.isEmpty) return const SizedBox.shrink();
        final rows = (keys.map((k) => k.$2).reduce((a, b) => a > b ? a : b) + 1).clamp(1, 8);
        final cols = (keys.map((k) => k.$1).reduce((a, b) => a > b ? a : b) + 1).clamp(1, 6);
        String show(int c, int r) {
          final v = values[(c, r)];
          if (v is double) return v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2).replaceAll('.', ',');
          if (v != null) return '$v';
          return formulas[(c, r)] != null ? '=${formulas[(c, r)]}' : '';
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: border,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Table(
                defaultColumnWidth: const IntrinsicColumnWidth(),
                children: [
                  for (var r = 0; r < rows; r++)
                    TableRow(
                      decoration: BoxDecoration(color: r == 0 ? t.colorScheme.primaryContainer : null),
                      children: [
                        for (var c = 0; c < cols; c++)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 180),
                              child: Text(show(c, r),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: t.textTheme.bodySmall?.copyWith(fontWeight: r == 0 ? FontWeight.w600 : null)),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
              child: Text(
                  '${sheets.length == 1 ? sheets.first.$1 : '${sheets.length} Blätter: ${sheets.map((s) => s.$1).join(', ')}'}'
                  ' · Spalten A–${colName(cols - 1)}',
                  style: t.textTheme.labelSmall?.copyWith(color: t.hintColor)),
            ),
          ]),
        );
      }
      final text = officeText(bytes, 'docx').replaceAll(RegExp(r'^#+\s*', multiLine: true), '').trim();
      if (text.isEmpty) return const SizedBox.shrink();
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: border,
        child: Text(text.length > 600 ? '${text.substring(0, 600)} …' : text, maxLines: 8, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall),
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
  }
}
