// Kleiner Markdown-Renderer ohne Abhängigkeiten: Überschriften, Listen,
// fett/kursiv, Inline-Code, Codeblöcke und Tabellen (als Monospace-Block).

import 'dart:io';

import 'package:agent_engine/agent_engine.dart' show cleanLink;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/native_files.dart';

final _imageInLine = RegExp(r'!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)');

/// Externen Link öffnen – erst nach Hinweis, dass man Junels verlässt.
Future<void> openExternalLink(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.open_in_new),
      title: const Text('Externe Seite öffnen?'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Du verlässt Junels und öffnest im Browser:', style: Theme.of(ctx).textTheme.bodyMedium),
        const SizedBox(height: 8),
        Text(uri.host, style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(url, style: Theme.of(ctx).textTheme.bodySmall, maxLines: 4, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        Text('Die Seite liegt außerhalb der App; dort gelten deren Datenschutzregeln.',
            style: Theme.of(ctx).textTheme.bodySmall),
      ]),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: url));
            Navigator.pop(ctx, false);
          },
          child: const Text('Kopieren'),
        ),
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Öffnen')),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await NativeFiles.openUrl(url);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Link konnte nicht geöffnet werden: $e')));
    }
  }
}
final _bareImage = RegExp(r'^\s*(?:[-*]\s+)?(?:Bild:\s*)?(https?://\S+\.(?:png|jpe?g|gif|webp)(?:\?\S*)?)\s*$', caseSensitive: false);

class MarkdownLite extends StatelessWidget {
  const MarkdownLite(this.text, {super.key, this.selectable = true, this.networkImages = false});
  final String text;
  final bool selectable;

  /// Bilder aus dem Internet direkt laden (sonst erst nach Antippen).
  final bool networkImages;

  @override
  Widget build(BuildContext context) {
    // Bild-Zeilen herauslösen, der Rest wird normal gesetzt
    final parts = <Widget>[];
    final buf = <String>[];
    var inCode = false;
    void flush() {
      if (buf.isEmpty) return;
      for (final b in _parse(buf.join('\n'))) {
        parts.add(_buildBlock(context, b));
      }
      buf.clear();
    }

    for (final line in text.split('\n')) {
      if (line.trimLeft().startsWith('```')) inCode = !inCode;
      if (!inCode && _imageInLine.hasMatch(line)) {
        // Bild irgendwo in der Zeile (z. B. "Bild: ![](url)") → Text davor, Bild, Text danach
        var rest = line;
        for (var m = _imageInLine.firstMatch(rest); m != null; m = _imageInLine.firstMatch(rest)) {
          final pre = rest.substring(0, m.start).replaceFirst(RegExp(r'(Bild|Image|Foto)\s*:\s*$', caseSensitive: false), '');
          if (pre.trim().isNotEmpty && !RegExp(r'^\s*[-*]?\s*$').hasMatch(pre)) buf.add(pre);
          flush();
          parts.add(_MdImage(src: m.group(2)!, alt: m.group(1) ?? '', autoLoad: networkImages));
          rest = rest.substring(m.end);
        }
        if (rest.trim().isNotEmpty) buf.add(rest);
        continue;
      }
      final bare = inCode ? null : _bareImage.firstMatch(line);
      if (bare != null) {
        flush();
        parts.add(_MdImage(src: bare.group(1)!, alt: '', autoLoad: networkImages));
      } else {
        buf.add(line);
      }
    }
    flush();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          parts[i],
        ],
      ],
    );
  }

  Widget _buildBlock(BuildContext context, _Block b) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final scheme = theme.colorScheme;
    switch (b.kind) {
      case _Kind.code:
        return CodeBlock(code: b.text, language: b.lang);
      case _Kind.heading:
        final style = switch (b.level) {
          1 => t.titleLarge,
          2 => t.titleMedium,
          _ => t.titleSmall,
        };
        return _text(context, b.text, style?.copyWith(fontWeight: FontWeight.w600));
      case _Kind.bullet:
        return Padding(
          padding: EdgeInsets.only(left: 4.0 + b.level * 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 18, child: Text(b.lang ?? '•', style: t.bodyMedium)),
              Expanded(child: _text(context, b.text, t.bodyMedium)),
            ],
          ),
        );
      case _Kind.quote:
        return Container(
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: scheme.outline, width: 3))),
          child: _text(context, b.text, t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
        );
      case _Kind.table:
        return CodeBlock(code: b.text, language: 'Tabelle', compact: true);
      case _Kind.paragraph:
        return _text(context, b.text, t.bodyMedium?.copyWith(height: 1.45));
    }
  }

  Widget _text(BuildContext context, String s, TextStyle? style) {
    final span = TextSpan(style: style, children: inlineSpans(context, s));
    return selectable ? SelectableText.rich(span) : Text.rich(span);
  }

  static List<InlineSpan> inlineSpans(BuildContext context, String s) {
    final scheme = Theme.of(context).colorScheme;
    final spans = <InlineSpan>[];
    final re = RegExp(r'(\[[^\]]+\]\(https?://[^)\s]+\)|https?://[^\s<>()\[\]]*[^\s<>()\[\].,;:!?\x27"]|\*\*[^*]+\*\*|`[^`]+`|\*[^*\s][^*]*\*|(?<![\w/])_[^_\s][^_]*_(?!\w))');
    final linkStyle = TextStyle(color: scheme.primary, decoration: TextDecoration.underline, decorationColor: scheme.primary);
    var pos = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > pos) spans.add(TextSpan(text: s.substring(pos, m.start)));
      final tok = m.group(0)!;
      if (tok.startsWith('[') || tok.startsWith('http')) {
        final md = RegExp(r'^\[([^\]]+)\]\((\S+)\)$').firstMatch(tok);
        final url = md?.group(2) ?? tok;
        spans.add(TextSpan(
          text: md?.group(1) ?? shortLinkLabel(tok),
          style: linkStyle,
          recognizer: TapGestureRecognizer()..onTap = () => openExternalLink(context, url),
        ));
        spans.add(TextSpan(text: ' ↗', style: TextStyle(color: scheme.primary, fontSize: 11)));
      } else if (tok.startsWith('**')) {
        spans.add(TextSpan(text: tok.substring(2, tok.length - 2), style: const TextStyle(fontWeight: FontWeight.w700)));
      } else if (tok.startsWith('`')) {
        spans.add(TextSpan(
          text: tok.substring(1, tok.length - 1),
          style: TextStyle(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['Menlo', 'Courier'],
            backgroundColor: scheme.surfaceContainerHighest,
          ),
        ));
      } else {
        spans.add(TextSpan(text: tok.substring(1, tok.length - 1), style: const TextStyle(fontStyle: FontStyle.italic)));
      }
      pos = m.end;
    }
    if (pos < s.length) spans.add(TextSpan(text: s.substring(pos)));
    return spans;
  }

  static List<_Block> _parse(String src) {
    final lines = src.replaceAll('\r\n', '\n').split('\n');
    final out = <_Block>[];
    final para = <String>[];
    void flush() {
      if (para.isNotEmpty) {
        out.add(_Block(_Kind.paragraph, para.join('\n')));
        para.clear();
      }
    }

    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('```')) {
        flush();
        final lang = trimmed.substring(3).trim();
        final code = <String>[];
        i++;
        while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
          code.add(lines[i]);
          i++;
        }
        i++; // schließende ```
        out.add(_Block(_Kind.code, code.join('\n'), lang: lang.isEmpty ? null : lang));
        continue;
      }
      if (trimmed.startsWith('|')) {
        flush();
        final rows = <String>[];
        while (i < lines.length && lines[i].trimLeft().startsWith('|')) {
          rows.add(lines[i].trim());
          i++;
        }
        out.add(_Block(_Kind.table, _alignTable(rows)));
        continue;
      }
      final h = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
      if (h != null) {
        flush();
        out.add(_Block(_Kind.heading, h.group(2)!, level: h.group(1)!.length));
        i++;
        continue;
      }
      final indent = line.length - trimmed.length;
      final bullet = RegExp(r'^([-*+])\s+(.*)$').firstMatch(trimmed);
      final numbered = RegExp(r'^(\d+)[.)]\s+(.*)$').firstMatch(trimmed);
      if (bullet != null || numbered != null) {
        flush();
        out.add(_Block(_Kind.bullet, (bullet ?? numbered)!.group(2)!,
            level: indent ~/ 2, lang: numbered != null ? '${numbered.group(1)}.' : null));
        i++;
        continue;
      }
      if (trimmed.startsWith('>')) {
        flush();
        out.add(_Block(_Kind.quote, trimmed.substring(1).trim()));
        i++;
        continue;
      }
      if (trimmed.isEmpty) {
        flush();
      } else {
        para.add(line);
      }
      i++;
    }
    flush();
    return out;
  }

  /// Richtet Markdown-Tabellen spaltenweise aus.
  static String _alignTable(List<String> rows) {
    final cells = [
      for (final r in rows)
        if (!RegExp(r'^\|?\s*:?-{2,}').hasMatch(r))
          r.replaceAll(RegExp(r'^\||\|$'), '').split('|').map((c) => c.trim()).toList()
    ];
    if (cells.isEmpty) return rows.join('\n');
    final cols = cells.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    final widths = List.filled(cols, 0);
    for (final r in cells) {
      for (var c = 0; c < r.length; c++) {
        if (r[c].length > widths[c]) widths[c] = r[c].length;
      }
    }
    final b = StringBuffer();
    for (var ri = 0; ri < cells.length; ri++) {
      final r = cells[ri];
      b.writeln([for (var c = 0; c < cols; c++) (c < r.length ? r[c] : '').padRight(widths[c])].join('  '));
      if (ri == 0 && cells.length > 1) {
        b.writeln([for (var c = 0; c < cols; c++) '─' * widths[c]].join('  '));
      }
    }
    return b.toString().trimRight();
  }
}

enum _Kind { paragraph, heading, bullet, quote, code, table }

class _Block {
  _Block(this.kind, this.text, {this.level = 0, this.lang});
  final _Kind kind;
  final String text;
  final int level;
  final String? lang;
}

class CodeBlock extends StatelessWidget {
  const CodeBlock({super.key, required this.code, this.language, this.compact = false});
  final String code;
  final String? language;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
            child: Row(
              children: [
                Text(language ?? 'Code',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                const Spacer(),
                IconButton(
                  tooltip: 'Kopieren',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Kopiert'), duration: Duration(seconds: 1)));
                  },
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.fromLTRB(12, 0, 12, compact ? 10 : 12),
            child: SelectableText(
              code,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: ['Menlo', 'Roboto Mono', 'Courier'],
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bild im Markdown: lokale Datei sofort, Internet-Bild nach Freigabe bzw. Antippen.
class _MdImage extends StatefulWidget {
  const _MdImage({required this.src, required this.alt, required this.autoLoad});
  final String src;
  final String alt;
  final bool autoLoad;

  @override
  State<_MdImage> createState() => _MdImageState();
}

class _MdImageState extends State<_MdImage> {
  late bool _load = widget.autoLoad;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final remote = widget.src.startsWith('http');
    Widget err(Object e, [Object? _]) => Container(
          padding: const EdgeInsets.all(10),
          color: scheme.surfaceContainerHighest,
          child: Text('Bild nicht verfügbar: ${widget.src}', style: t.bodySmall),
        );
    final Widget img;
    if (!remote) {
      final f = File(widget.src);
      img = f.existsSync() ? Image.file(f, fit: BoxFit.contain) : err('');
    } else if (_load) {
      img = Image.network(widget.src, fit: BoxFit.contain, errorBuilder: (c, e, s) => err(e),
          loadingBuilder: (c, child, p) => p == null
              ? child
              : const SizedBox(height: 120, child: Center(child: CircularProgressIndicator(strokeWidth: 2))));
    } else {
      img = InkWell(
        onTap: () => setState(() => _load = true),
        child: Container(
          height: 72,
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.image_outlined),
            const SizedBox(width: 8),
            Flexible(child: Text('Bild aus dem Internet laden (${Uri.tryParse(widget.src)?.host ?? ''})', style: t.bodySmall)),
          ]),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: ClipRRect(borderRadius: BorderRadius.circular(8), child: img),
      ),
      if (widget.alt.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 4), child: Text(widget.alt, style: t.bodySmall)),
    ]);
  }
}


/// Kurze Anzeige für nackte Links: „amazon.de › Brotkasten-XL“ statt der ganzen Adresse.
String shortLinkLabel(String url) {
  final u = Uri.tryParse(cleanLink(url));
  if (u == null || u.host.isEmpty) return url;
  final host = u.host.replaceFirst(RegExp(r'^www\.'), '');
  final seg = u.pathSegments.where((p) => p.isNotEmpty && p != 'dp' && !RegExp(r'^[A-Z0-9]{10}$').hasMatch(p)).firstOrNull;
  if (seg == null) return host;
  var name = Uri.decodeComponent(seg).replaceAll(RegExp(r'[-_+]+'), ' ').replaceAll(RegExp(r'\.(html?|php|aspx?)$'), '');
  if (name.length > 28) name = '${name.substring(0, 27)}…';
  return '$host › $name';
}
