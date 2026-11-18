// Kleiner Markdown-Renderer ohne Abhängigkeiten: Überschriften, Listen,
// fett/kursiv, Inline-Code, Codeblöcke und Tabellen (als Monospace-Block).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MarkdownLite extends StatelessWidget {
  const MarkdownLite(this.text, {super.key, this.selectable = true});
  final String text;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final blocks = _parse(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _buildBlock(context, blocks[i]),
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
    final re = RegExp(r'(\*\*[^*]+\*\*|`[^`]+`|\*[^*\s][^*]*\*|_[^_\s][^_]*_)');
    var pos = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > pos) spans.add(TextSpan(text: s.substring(pos, m.start)));
      final tok = m.group(0)!;
      if (tok.startsWith('**')) {
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
