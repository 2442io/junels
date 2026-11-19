// Einfacher Markdown-Leser für erzeugte Dokumente und Folien.
// Unterstützt: Überschriften, Absätze, Listen (auch verschachtelt/nummeriert),
// Tabellen, Bilder ![Titel](datei.png), Zitate, Code, Trennlinien.

sealed class MdBlock {}

class MdHeading extends MdBlock {
  MdHeading(this.level, this.text);
  final int level;
  final String text;
}

class MdParagraph extends MdBlock {
  MdParagraph(this.text);
  final String text;
}

class MdListItem extends MdBlock {
  MdListItem(this.text, {this.depth = 0, this.number});
  final String text;
  final int depth;
  final int? number; // null = Aufzählungspunkt
}

class MdTable extends MdBlock {
  MdTable(this.rows);
  final List<List<String>> rows; // erste Zeile = Kopf
}

class MdImage extends MdBlock {
  MdImage(this.src, this.caption);
  final String src;
  final String caption;
}

class MdQuote extends MdBlock {
  MdQuote(this.text);
  final String text;
}

class MdCode extends MdBlock {
  MdCode(this.text);
  final String text;
}

class MdRule extends MdBlock {}

/// Textstück mit Formatierung (fett/kursiv).
class MdRun {
  const MdRun(this.text, {this.bold = false, this.italic = false});
  final String text;
  final bool bold;
  final bool italic;
}

final _image = RegExp(r'^!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)\s*$');
final _heading = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$');
final _bullet = RegExp(r'^(\s*)[-*+•]\s+(.*)$');
final _ordered = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$');
final _rule = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');
final _tableSep = RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$');

List<MdBlock> parseMarkdown(String source) {
  final lines = source.replaceAll('\r\n', '\n').replaceAll('\t', '    ').split('\n');
  final out = <MdBlock>[];
  final para = <String>[];

  void flush() {
    if (para.isNotEmpty) {
      out.add(MdParagraph(para.join(' ').trim()));
      para.clear();
    }
  }

  List<String> cells(String line) {
    var l = line.trim();
    if (l.startsWith('|')) l = l.substring(1);
    if (l.endsWith('|')) l = l.substring(0, l.length - 1);
    return l.split('|').map((c) => c.trim()).toList();
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final t = line.trim();
    if (t.isEmpty) {
      flush();
      i++;
      continue;
    }
    if (t.startsWith('```')) {
      flush();
      final code = <String>[];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        code.add(lines[i]);
        i++;
      }
      i++;
      out.add(MdCode(code.join('\n')));
      continue;
    }
    final h = _heading.firstMatch(t);
    if (h != null) {
      flush();
      out.add(MdHeading(h.group(1)!.length, h.group(2)!));
      i++;
      continue;
    }
    if (_rule.hasMatch(t)) {
      flush();
      out.add(MdRule());
      i++;
      continue;
    }
    final img = _image.firstMatch(t);
    if (img != null) {
      flush();
      out.add(MdImage(img.group(2)!, img.group(1)!));
      i++;
      continue;
    }
    if (t.startsWith('|') && i + 1 < lines.length && _tableSep.hasMatch(lines[i + 1])) {
      flush();
      final rows = <List<String>>[cells(t)];
      i += 2;
      while (i < lines.length && lines[i].trim().startsWith('|')) {
        rows.add(cells(lines[i]));
        i++;
      }
      final width = rows.map((r) => r.length).fold(0, (a, b) => a > b ? a : b);
      out.add(MdTable([for (final r in rows) [...r, for (var k = r.length; k < width; k++) '']]));
      continue;
    }
    if (t.startsWith('>')) {
      flush();
      final q = <String>[];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        q.add(lines[i].trim().substring(1).trim());
        i++;
      }
      out.add(MdQuote(q.join(' ')));
      continue;
    }
    final b = _bullet.firstMatch(line);
    if (b != null) {
      flush();
      out.add(MdListItem(b.group(2)!.trim(), depth: (b.group(1)!.length ~/ 2).clamp(0, 3)));
      i++;
      continue;
    }
    final o = _ordered.firstMatch(line);
    if (o != null) {
      flush();
      out.add(MdListItem(o.group(3)!.trim(),
          depth: (o.group(1)!.length ~/ 2).clamp(0, 3), number: int.tryParse(o.group(2)!)));
      i++;
      continue;
    }
    para.add(t);
    i++;
  }
  flush();
  return out;
}

/// Zerlegt **fett**, __fett__, *kursiv*, _kursiv_ und `code` in Textstücke.
List<MdRun> parseInline(String text) {
  final runs = <MdRun>[];
  final re = RegExp(r'(\*\*|__)(.+?)\1|(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?!\*)|`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)');
  var pos = 0;
  for (final m in re.allMatches(text)) {
    if (m.start > pos) runs.add(MdRun(text.substring(pos, m.start)));
    if (m.group(2) != null) {
      runs.add(MdRun(m.group(2)!, bold: true));
    } else if (m.group(3) != null) {
      runs.add(MdRun(m.group(3)!, italic: true));
    } else if (m.group(4) != null) {
      runs.add(MdRun(m.group(4)!));
    } else {
      runs.add(MdRun('${m.group(5)} (${m.group(6)})'));
    }
    pos = m.end;
  }
  if (pos < text.length) runs.add(MdRun(text.substring(pos)));
  return runs;
}

/// Reiner Text ohne Markdown-Zeichen.
String plainInline(String text) => parseInline(text).map((r) => r.text).join();

/// Eine Folie: Titel + Inhalt.
class SlideSpec {
  SlideSpec(this.title, this.blocks);
  final String title;
  final List<MdBlock> blocks;
}

/// Teilt Markdown in Folien: jede Überschrift (#/##) beginnt eine neue Folie,
/// "---" ebenfalls. Text vor der ersten Überschrift landet auf der Titelfolie.
({String? subtitle, List<SlideSpec> slides}) splitSlides(String markdown) {
  final blocks = parseMarkdown(markdown);
  final slides = <SlideSpec>[];
  String? title;
  var body = <MdBlock>[];
  final intro = <MdBlock>[];
  var started = false;

  void push() {
    if (title != null || body.isNotEmpty) slides.add(SlideSpec(title ?? '', body));
    body = [];
    title = null;
  }

  for (final b in blocks) {
    if (b is MdHeading && b.level <= 2) {
      if (started) push();
      started = true;
      title = b.text;
    } else if (b is MdRule) {
      if (started) push();
      started = true;
    } else if (!started) {
      intro.add(b);
    } else {
      body.add(b is MdHeading ? MdParagraph('**${b.text}**') : b);
    }
  }
  if (started) push();
  final subtitle = intro.whereType<MdParagraph>().map((p) => plainInline(p.text)).join(' ').trim();
  if (!started && intro.isNotEmpty) slides.add(SlideSpec('', intro));
  return (subtitle: subtitle.isEmpty ? null : subtitle, slides: slides);
}
