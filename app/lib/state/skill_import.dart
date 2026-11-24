import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_engine/agent_engine.dart';
import 'package:archive/archive.dart';

import 'skills.dart';

/// Skills importieren und exportieren nach dem offenen Agent-Skills-Standard (agentskills.io):
/// SKILL.md, ZIP/.skill mit einem oder mehreren Skill-Ordnern, Link (GitHub-Seite, Rohdatei, ZIP) oder Text.
/// Es wird nichts ausgeführt – Skripte werden nur als lesbare Dateien übernommen.
class SkillImport {
  SkillImport._();

  /// Werkzeug-Namen aus Claude-Skills („allowed-tools“) auf Junels übertragen
  /// (Claude Code, Codex, Gemini CLI, OpenCode, Cursor – der Standard legt keine Werkzeugnamen fest)
  static const toolMap = {
    'webfetch': 'web_fetch',
    'web_fetch': 'web_fetch',
    'fetch': 'web_fetch',
    'websearch': 'web_search',
    'web_search': 'web_search',
    'google_web_search': 'web_search',
    'read': 'read_file',
    'read_file': 'read_file',
    'view': 'read_file',
    'grep': 'text_search',
    'search_file_content': 'text_search',
    'glob': 'file_search',
    'list_directory': 'file_search',
    'ls': 'file_search',
    'write': 'create_document',
    'write_file': 'create_document',
    'edit': 'edit_file',
    'multiedit': 'edit_file',
    'replace': 'edit_file',
    'todowrite': 'send_notification',
  };

  /// Textdateien, die in einen Skill-Ordner gehören (Rest, z. B. Bilder, wird übersprungen)
  static final _textFile = RegExp(r'\.(md|markdown|txt|csv|tsv|json|ya?ml|xml|html?|py|sh|bash|js|mjs|ts|rb|ps1|sql|toml|ini|cfg|tex|rst)$',
      caseSensitive: false);

  static int _n = 0;
  static String _id() => 'u-${DateTime.now().microsecondsSinceEpoch}-${_n++}';

  /// Text einer SKILL.md (oder einer Markdown-Datei mit Frontmatter) → Skill
  static Skill? fromText(String text, {required List<AgentTool> available, Map<String, String> files = const {}}) {
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
    for (final e in files.entries) {
      s.addFile(e.key, e.value);
    }
    _fixTools(s, available);
    return s;
  }

  /// Werkzeuge prüfen: Claude-Namen übersetzen, unbekannte streichen, fehlende passend vorschlagen
  static void _fixTools(Skill s, List<AgentTool> available) {
    final names = {for (final t in available) t.name};
    final mapped = <String>{};
    final unmapped = <String>[];
    for (final x in s.tools) {
      final base = x.replaceFirst(RegExp(r'\(.*\)$'), '').trim(); // Bash(git:*) → Bash
      final m = names.contains(base) ? base : toolMap[base.toLowerCase()];
      if (m != null && names.contains(m)) {
        mapped.add(m);
      } else if (!unmapped.contains(base)) {
        unmapped.add(base);
      }
    }
    s.unmapped
      ..clear()
      ..addAll(unmapped);
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

  /// ZIP/.skill: jeder Ordner mit SKILL.md wird ein Skill; seine übrigen Textdateien (references/, scripts/,
  /// assets/ …) bleiben als Dateien erhalten und werden erst bei Bedarf gelesen.
  static List<Skill> fromZip(Uint8List bytes, {required List<AgentTool> available}) {
    final arc = ZipDecoder().decodeBytes(bytes);
    final files = <String, String>{};
    for (final f in arc.files) {
      if (!f.isFile) continue;
      final name = f.name.replaceAll('\\', '/');
      if (name.contains('__MACOSX/') || name.split('/').any((p) => p.startsWith('.') && p.length > 1)) continue;
      if (!_textFile.hasMatch(name) || f.size > Skill.maxFileBytes) continue;
      files[name] = utf8.decode(f.content as List<int>, allowMalformed: true);
    }
    String dirOf(String k) => k.contains('/') ? k.substring(0, k.lastIndexOf('/') + 1) : '';
    final skillFiles = files.keys.where((k) => k.split('/').last.toUpperCase() == 'SKILL.MD').toList()
      ..sort((a, b) => b.length.compareTo(a.length)); // tiefste Ordner zuerst
    final taken = <String>{};
    final out = <Skill>[];
    for (final k in skillFiles) {
      final dir = dirOf(k);
      final own = <String, String>{};
      for (final e in files.entries) {
        if (e.key == k || taken.contains(e.key) || !e.key.startsWith(dir)) continue;
        if (skillFiles.contains(e.key)) continue;
        own[e.key.substring(dir.length)] = e.value;
        taken.add(e.key);
      }
      final s = fromText(files[k]!, available: available, files: own);
      if (s != null) out.add(s);
    }
    // ZIP ohne SKILL.md, aber mit genau einer Markdown-Datei
    if (out.isEmpty) {
      final md = files.keys.where((k) => k.toLowerCase().endsWith('.md')).toList();
      final s = md.length == 1 ? fromText(files[md.first]!, available: available) : null;
      if (s != null) out.add(s);
    }
    return out.reversed.toList();
  }

  /// Export als Standard-Paket: <name>/SKILL.md + Dateien – importierbar in Claude, Codex, Cursor & Co.
  /// Ablauf eines Skills liegt als assets/junels-flow.json bei (Junels baut ihn beim Import wieder auf);
  /// reine Ablauf-Skills bekommen dazu eine lesbare Schrittliste als Anleitung – für andere Agents.
  static Uint8List toZip(List<Skill> skills, {List<Workflow> flows = const []}) {
    final arc = Archive();
    final used = <String>{};
    for (final s0 in skills) {
      final wf = s0.flowId == null ? null : flows.where((f) => f.id == s0.flowId).firstOrNull;
      var s = s0;
      if (wf != null) {
        s = s0.copy();
        s.flowExport = s0.runsFlow ? 'ablauf' : 'ausloeser';
        if (s0.runsFlow) s.instructions = flowSteps(wf);
        final j = wf.toJson();
        for (final n in (j['nodes'] as List)) {
          final cfg = (n as Map)['config'];
          if (cfg is Map && cfg['skill'] == s0.id) cfg['skill'] = '@self';
        }
        j.remove('lastRun');
        j.remove('lastStatus');
        s.files['assets/junels-flow.json'] = const JsonEncoder.withIndent('  ').convert(j);
      }
      var dir = s.specName;
      for (var i = 2; used.contains(dir); i++) {
        dir = Skill.slugify('${s.specName}-$i');
      }
      used.add(dir);
      // name muss dem Ordnernamen entsprechen
      final md = s.toMarkdown().replaceFirst(RegExp(r'^name: .*$', multiLine: true), 'name: $dir');
      arc.addFile(ArchiveFile.string('$dir/SKILL.md', md));
      for (final e in s.files.entries) {
        arc.addFile(ArchiveFile.string('$dir/${e.key}', e.value));
      }
    }
    return ZipEncoder().encodeBytes(arc);
  }

  /// Lesbare Schrittliste eines Ablaufs (für andere Agents und zum Nachlesen)
  static String flowSteps(Workflow wf) {
    final b = StringBuffer('Ablauf in Schritten:\n');
    var i = 1;
    for (final n in wf.order()) {
      final sum = n.summary.replaceAll(RegExp(r'\s+'), ' ').trim();
      b.writeln('${i++}. ${n.title} (${n.type.label})${sum.isEmpty ? '' : ': ${sum.length > 200 ? '${sum.substring(0, 200)}…' : sum}'}');
    }
    return b.toString().trim();
  }

  /// Beim Import mitgelieferten Ablauf (assets/junels-flow.json) wieder aufbauen → neuer Workflow oder null
  static Workflow? flowFromSkill(Skill s, String newFlowId) {
    final raw = s.files.remove('assets/junels-flow.json');
    if (raw == null) return null;
    try {
      final j = (jsonDecode(raw) as Map).cast<String, dynamic>();
      j['id'] = newFlowId;
      for (final n in (j['nodes'] as List? ?? const [])) {
        final cfg = (n as Map)['config'];
        if (cfg is Map && cfg['skill'] == '@self') {
          cfg
            ..['skill'] = s.id
            ..['skillName'] = s.name
            ..['skillCommand'] = s.command;
        }
      }
      final wf = Workflow.fromJson(j);
      wf.enabled = false; // erst nach dem Prüfen einschalten
      s.flowId = wf.id;
      if (s.flowExport == 'ablauf') s.instructions = '';
      return wf;
    } catch (_) {
      return null;
    }
  }

  /// Prüft eine SKILL.md gegen den Standard; leere Liste = gültig
  static List<String> validate(String md, {String? dirName}) {
    final m = RegExp(r'^---\s*\r?\n([\s\S]*?)\r?\n---').firstMatch(md.trimLeft());
    if (m == null) return ['Frontmatter (--- … ---) fehlt'];
    final f = Skill.parseFrontmatter(m.group(1)!);
    final out = <String>[];
    final name = f['name'] ?? '';
    if (name.isEmpty || name.length > 64) out.add('name fehlt oder ist länger als 64 Zeichen');
    if (!RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$').hasMatch(name)) out.add('name: nur a-z, 0-9 und einzelne Bindestriche');
    if (dirName != null && name != dirName) out.add('name passt nicht zum Ordnernamen');
    final d = f['description'] ?? '';
    if (d.isEmpty || d.length > 1024) out.add('description fehlt oder ist länger als 1024 Zeichen');
    if ((f['compatibility'] ?? '').length > 500) out.add('compatibility ist länger als 500 Zeichen');
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
