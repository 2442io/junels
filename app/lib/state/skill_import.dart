import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_engine/agent_engine.dart';
import 'package:archive/archive.dart';

import 'skills.dart';

/// Skills importieren: SKILL.md (Junels- oder Claude-Format), ZIP/.skill mit einem oder mehreren
/// Skill-Ordnern, Link (GitHub-Seite, Rohdatei, ZIP) oder eingefügter Text. Es wird nichts ausgeführt –
/// Skills sind reine Anleitungen; Skripte in einem Paket werden ignoriert.
class SkillImport {
  SkillImport._();

  /// Werkzeug-Namen aus Claude-Skills („allowed-tools“) auf Junels übertragen
  static const _toolMap = {
    'webfetch': 'web_fetch',
    'websearch': 'web_search',
    'read': 'read_file',
    'grep': 'text_search',
    'glob': 'file_search',
    'write': 'create_document',
  };

  static int _n = 0;
  static String _id() => 'u-${DateTime.now().microsecondsSinceEpoch}-${_n++}';

  /// Text einer SKILL.md (oder einer Markdown-Datei mit Frontmatter) → Skill
  static Skill? fromText(String text, {required List<AgentTool> available, String extraKnowledge = ''}) {
    var t = text.trim();
    if (!t.startsWith('---')) {
      // ohne Frontmatter: erste Überschrift = Name, erster Absatz = Beschreibung
      final h = RegExp(r'^#\s+(.+)$', multiLine: true).firstMatch(t);
      if (h == null) return null;
      final rest = t.substring(h.end).trim();
      final first = rest.split(RegExp(r'\n\s*\n')).first.trim();
      t = '---\nname: ${h.group(1)!.trim()}\ndescription: ${first.replaceAll('\n', ' ')}\n---\n$rest';
    }
    final s = Skill.fromMarkdown(t, id: _id());
    if (s == null) return null;
    if (extraKnowledge.trim().isNotEmpty) {
      final k = '${s.knowledge}\n\n$extraKnowledge'.trim();
      s.knowledge = k.length > 20000 ? '${k.substring(0, 20000)}\n[… gekürzt]' : k;
    }
    _fixTools(s, available);
    return s;
  }

  /// Werkzeuge prüfen: Claude-Namen übersetzen, unbekannte streichen, fehlende passend vorschlagen
  static void _fixTools(Skill s, List<AgentTool> available) {
    final names = {for (final t in available) t.name};
    final mapped = <String>{
      for (final x in s.tools)
        if (names.contains(x)) x else if (_toolMap[x.toLowerCase()] case final m? when names.contains(m)) m,
    };
    if (mapped.isEmpty) {
      // Aus Beschreibung und Anleitung ableiten (wie die Werkzeug-Auswahl im Chat)
      final text = '${s.name}. ${s.when}\n${s.instructions}';
      mapped.addAll(ToolRouter.select(available, (t) => (name: t.name, title: t.title, description: t.description), text)
          .map((t) => t.name)
          .where((n) => !n.contains('__'))
          .take(8));
    }
    s.tools
      ..clear()
      ..addAll(mapped);
    if (s.requiredTool.isNotEmpty && !s.tools.contains(s.requiredTool)) s.requiredTool = '';
  }

  /// ZIP/.skill: jede SKILL.md wird ein Skill; weitere .md-Dateien im selben Ordner kommen als Wissen dazu.
  static List<Skill> fromZip(Uint8List bytes, {required List<AgentTool> available}) {
    final arc = ZipDecoder().decodeBytes(bytes);
    final files = <String, String>{};
    for (final f in arc.files) {
      if (!f.isFile) continue;
      final name = f.name.replaceAll('\\', '/');
      if (name.contains('__MACOSX/') || !name.toLowerCase().endsWith('.md')) continue;
      if (f.size > 400000) continue;
      files[name] = utf8.decode(f.content as List<int>, allowMalformed: true);
    }
    final out = <Skill>[];
    final skillFiles = files.keys.where((k) => k.split('/').last.toUpperCase() == 'SKILL.MD').toList();
    for (final k in skillFiles) {
      final dir = k.contains('/') ? k.substring(0, k.lastIndexOf('/') + 1) : '';
      final refs = [
        for (final e in files.entries)
          if (e.key != k && e.key.startsWith(dir) && !skillFiles.any((o) => o != k && e.key.startsWith(o.substring(0, o.lastIndexOf('/') + 1)) && o.length > k.length))
            '### ${e.key.substring(dir.length)}\n${e.value.trim()}'
      ];
      final s = fromText(files[k]!, available: available, extraKnowledge: refs.join('\n\n'));
      if (s != null) out.add(s);
    }
    // ZIP ohne SKILL.md, aber mit genau einer Markdown-Datei
    if (out.isEmpty && files.length == 1) {
      final s = fromText(files.values.first, available: available);
      if (s != null) out.add(s);
    }
    return out;
  }

  /// Link → Adresse der Rohdatei. GitHub-Seiten (blob/tree) werden auf raw.githubusercontent.com umgestellt.
  static List<Uri> candidates(String link) {
    var l = link.trim();
    if (!l.startsWith('http')) l = 'https://$l';
    final u = Uri.tryParse(l);
    if (u == null || u.host.isEmpty) return const [];
    if (u.host == 'github.com') {
      final p = u.pathSegments.where((x) => x.isNotEmpty).toList();
      if (p.length >= 4 && (p[2] == 'blob' || p[2] == 'tree')) {
        final raw = 'https://raw.githubusercontent.com/${p[0]}/${p[1]}/${p.sublist(3).join('/')}';
        if (p[2] == 'blob') return [Uri.parse(raw)];
        return [Uri.parse('$raw/SKILL.md'), Uri.parse('$raw/skill.md'), Uri.parse('$raw/README.md')];
      }
      if (p.length == 2) {
        return [
          Uri.parse('https://raw.githubusercontent.com/${p[0]}/${p[1]}/HEAD/SKILL.md'),
          Uri.parse('https://github.com/${p[0]}/${p[1]}/archive/HEAD.zip'),
        ];
      }
    }
    if (l.endsWith('/')) return [Uri.parse('${l}SKILL.md')];
    return [u];
  }

  /// Von einem Link laden (der Nutzer hat ihn selbst eingegeben – das ist die Freigabe).
  static Future<List<Skill>> fromLink(String link, {required List<AgentTool> available}) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    Object? lastErr;
    try {
      for (final u in candidates(link)) {
        try {
          final req = await c.getUrl(u);
          req.followRedirects = true;
          final res = await req.close().timeout(const Duration(seconds: 30));
          final bytes = Uint8List.fromList([for (final chunk in await res.toList()) ...chunk]);
          if (res.statusCode != 200) {
            lastErr = 'HTTP ${res.statusCode}';
            continue;
          }
          if (bytes.length > 20 * 1024 * 1024) throw Exception('Datei zu groß (über 20 MB)');
          final isZip = bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B;
          final list = isZip
              ? fromZip(bytes, available: available)
              : [if (fromText(utf8.decode(bytes, allowMalformed: true), available: available) case final s?) s];
          if (list.isNotEmpty) return list;
          lastErr = 'keine SKILL.md gefunden';
        } catch (e) {
          lastErr = e;
        }
      }
    } finally {
      c.close(force: true);
    }
    throw Exception('Kein Skill unter diesem Link gefunden${lastErr == null ? '' : ' ($lastErr)'}');
  }

  /// Datei(en): .md, .zip oder .skill
  static List<Skill> fromFile(String name, Uint8List bytes, {required List<AgentTool> available}) {
    final low = name.toLowerCase();
    if (low.endsWith('.zip') || low.endsWith('.skill') || (bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B)) {
      return fromZip(bytes, available: available);
    }
    final s = fromText(utf8.decode(bytes, allowMalformed: true), available: available);
    return s == null ? const [] : [s];
  }
}
