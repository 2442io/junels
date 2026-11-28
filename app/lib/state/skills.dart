// Skills im offenen Agent-Skills-Standard (agentskills.io): Ordner mit SKILL.md (+ references/, scripts/, assets/).
// Junels-Eigenes steht unter metadata (junels.*), andere Agents ignorieren das.
// Ein Skill sagt dem Agenten, wann und wie er Werkzeuge für eine Aufgabe kombiniert, und lädt NUR diese
// Werkzeuge – das macht kleine Modelle am Gerät deutlich zuverlässiger.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart' show OutputView, MacroStep;
import 'package:flutter/foundation.dart';

class Skill {
  Skill({
    required this.id,
    required this.name,
    this.slug = '',
    this.when = '',
    this.instructions = '',
    List<String>? tools,
    this.requiredTool = '',
    this.inputs = '',
    this.knowledge = '',
    this.icon = 'auto_awesome',
    this.auto = true,
    this.enabled = true,
    this.builtin = false,
    this.edited = false,
    this.notifyKind = 'auto',
    this.internet = 'ask',
    this.model = '',
    this.output = '',
    this.job = false,
    List<MacroStep>? macro,
    Map<String, String>? macroParams,
    this.flowId,
    this.promptId,
    Map<String, String>? files,
    this.license = '',
    this.compatibility = '',
    Map<String, String>? meta,
    List<String>? unmapped,
  })  : tools = tools ?? [],
        files = files ?? {},
        meta = meta ?? {},
        unmapped = unmapped ?? [],
        macro = macro ?? [],
        macroParams = macroParams ?? {};

  final String id;
  String name;
  String slug; // Aufruf im Chat: /slug
  String when; // Wann nutzen (Beschreibung, auch fürs automatische Erkennen)
  String instructions; // Anleitung in Schritten
  final List<String> tools; // erlaubte Werkzeuge (Namen)
  String requiredTool; // Ergebnis muss mit diesem Werkzeug entstehen (z. B. create_presentation), '' = frei
  String inputs; // Angaben, nach denen gefragt wird (kommagetrennt)
  String knowledge; // Wissen/Beispiele (Text)
  String icon;
  bool auto; // automatisch erkennen, wenn die Nachricht passt
  bool enabled;
  final bool builtin; // Basis-Skill aus Junels
  bool edited; // Basis-Skill vom Nutzer angepasst
  String notifyKind;

  /// Internet für diesen Skill: ask = wie im Chat (fragen), allow = ohne Rückfrage erlaubt, block = nie
  String internet;

  /// Modell für diesen Skill: '' = wie eingestellt, local, onprem, cloud, hybrid-onprem, hybrid-cloud
  String model;

  /// Ausgabeformat (OutputView): '' = automatisch, cards, table, list, steps, chart, pdf, word, excel, pptx
  String output;

  /// Als Web-Job ausführen: planen → im Browser ausführen → prüfen; Fortschritt in „Ergebnisse“
  bool job;

  /// Vorgemachter Ablauf (Aufnahme) – wird abgespielt statt geplant; das Modell springt nur bei Abweichungen ein
  List<MacroStep> macro;

  /// Platzhalter des Ablaufs mit Beispiel-/Standardwert (z. B. suchbegriff → „rtx 4070“)
  Map<String, String> macroParams;

  /// Ablauf (Prozess) dieses Skills: Auslöser (Zeitplan, Beobachtung, Ereignis) und/oder mehrere Schritte.
  /// Ohne eigene Anleitung ist der Skill der Ablauf selbst (/befehl startet ihn).
  String? flowId;

  /// Zeitplan dieses Skills (geplante Aufgabe = Skill mit Zeitplan); gespeichert als Zeitplan-Eintrag mit dieser Id
  String? promptId;

  /// Nur Export/Import: Rolle des mitgelieferten Ablaufs (ablauf | ausloeser), steht als metadata junels.flow
  String flowExport = '';

  /// Skill = Ablauf (keine eigene Anleitung)
  bool get runsFlow => flowId != null && instructions.trim().isEmpty;

  /// Weitere Dateien des Skill-Ordners (relativer Pfad → Text), z. B. references/REFERENCE.md, scripts/x.py.
  /// Werden erst bei Bedarf gelesen (skill-Werkzeug). Skripte werden NIE ausgeführt.
  final Map<String, String> files;
  String license;
  String compatibility;

  /// Fremde metadata-Einträge (author, version …) – bleiben beim Export erhalten
  final Map<String, String> meta;

  /// Werkzeuge aus allowed-tools, die Junels nicht hat (z. B. Bash) – nur zur Anzeige
  final List<String> unmapped;

  static const maxFileBytes = 200000;
  static const _offlineCompat = 'Works offline, no network access needed';
  static const maxFilesTotal = 1000000;

  /// Name nach Standard: a-z, 0-9, Bindestrich, max. 64, kein -- und nicht am Rand
  String get specName {
    final n = slugify(slug.isEmpty ? name : slug);
    return n.isEmpty ? 'skill' : n;
  }

  /// Beschreibung nach Standard: 1–1024 Zeichen, eine Zeile
  String get specDescription {
    var d = when.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (d.isEmpty) d = name;
    return d.length > 1024 ? d.substring(0, 1024) : d;
  }

  /// Datei hinzufügen (mit Größengrenzen); false = zu groß/ungültig
  bool addFile(String path, String text) {
    final p = path.replaceAll('\\', '/').replaceAll(RegExp(r'^(\./|/)+'), '');
    if (p.isEmpty || p.split('/').contains('..') || p.toUpperCase() == 'SKILL.MD') return false;
    if (text.length > maxFileBytes) return false;
    final total = files.entries.where((e) => e.key != p).fold<int>(0, (n, e) => n + e.value.length);
    if (total + text.length > maxFilesTotal) return false;
    files[p] = text;
    return true;
  }

  static const internetLabels = {'ask': 'Nachfragen (wie im Chat)', 'allow': 'Erlaubt, ohne Rückfrage', 'block': 'Gesperrt – nur offline'};
  static const modelLabels = {
    '': 'Wie eingestellt',
    'local': 'Lokal auf dem Gerät',
    'onprem': 'Eigener Server (On-Prem)',
    'cloud': 'Cloud',
    'hybrid-onprem': 'Hybrid: lokal → eigener Server',
    'hybrid-cloud': 'Hybrid: lokal → Cloud',
  };

  String get command => slug.isEmpty ? slugify(name) : slug;

  static String slugify(String s) {
    var t = s.toLowerCase().trim();
    const map = {'ä': 'ae', 'ö': 'oe', 'ü': 'ue', 'ß': 'ss'};
    map.forEach((k, v) => t = t.replaceAll(k, v));
    t = t.replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    return t.length > 64 ? t.substring(0, 64).replaceAll(RegExp(r'-+$'), '') : t;
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        if (slug.isNotEmpty) 'slug': slug,
        'when': when,
        'instructions': instructions,
        'tools': tools,
        if (requiredTool.isNotEmpty) 'requiredTool': requiredTool,
        if (inputs.isNotEmpty) 'inputs': inputs,
        if (knowledge.isNotEmpty) 'knowledge': knowledge,
        'icon': icon,
        'auto': auto,
        'enabled': enabled,
        if (builtin) 'builtin': true,
        if (edited) 'edited': true,
        if (notifyKind != 'auto') 'notifyKind': notifyKind,
        if (internet != 'ask') 'internet': internet,
        if (model.isNotEmpty) 'model': model,
        if (output.isNotEmpty) 'output': output,
        if (job) 'job': true,
        if (macro.isNotEmpty) 'macro': [for (final m in macro) m.toJson()],
        if (macroParams.isNotEmpty) 'macroParams': macroParams,
        if (flowId != null) 'flowId': flowId,
        if (promptId != null) 'promptId': promptId,
        if (files.isNotEmpty) 'files': files,
        if (license.isNotEmpty) 'license': license,
        if (compatibility.isNotEmpty) 'compatibility': compatibility,
        if (meta.isNotEmpty) 'meta': meta,
        if (unmapped.isNotEmpty) 'unmapped': unmapped,
      };

  factory Skill.fromJson(Map<String, dynamic> j) => Skill(
        id: '${j['id']}',
        name: '${j['name'] ?? 'Skill'}',
        slug: '${j['slug'] ?? ''}',
        when: '${j['when'] ?? ''}',
        instructions: '${j['instructions'] ?? ''}',
        tools: [for (final t in (j['tools'] as List? ?? const [])) '$t'],
        requiredTool: '${j['requiredTool'] ?? ''}',
        inputs: '${j['inputs'] ?? ''}',
        knowledge: '${j['knowledge'] ?? ''}',
        icon: '${j['icon'] ?? 'auto_awesome'}',
        auto: j['auto'] != false,
        enabled: j['enabled'] != false,
        builtin: j['builtin'] == true,
        edited: j['edited'] == true,
        notifyKind: '${j['notifyKind'] ?? 'auto'}',
        internet: internetLabels.containsKey(j['internet']) ? '${j['internet']}' : 'ask',
        model: modelLabels.containsKey(j['model']) ? '${j['model']}' : '',
        output: OutputView.valid('${j['output'] ?? ''}') ? '${j['output'] ?? ''}' : '',
        job: j['job'] == true,
        macro: [for (final m in (j['macro'] as List? ?? const [])) MacroStep.fromJson((m as Map).cast<String, dynamic>())],
        macroParams: {for (final e in ((j['macroParams'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
        flowId: j['flowId'] as String?,
        promptId: j['promptId'] as String?,
        files: {for (final e in ((j['files'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
        license: '${j['license'] ?? ''}',
        compatibility: '${j['compatibility'] ?? ''}',
        meta: {for (final e in ((j['meta'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
        unmapped: [for (final t in (j['unmapped'] as List? ?? const [])) '$t'],
      );

  Skill copy({String? id, bool? builtin}) =>
      Skill.fromJson({...toJson(), if (id != null) 'id': id, if (builtin != null) 'builtin': builtin});

  /// Werkzeug-Namen, die andere Agents (Claude, Codex …) kennen – für allowed-tools beim Export
  static const portableTools = {
    'web_fetch': 'WebFetch',
    'web_search': 'WebSearch',
    'read_file': 'Read',
    'text_search': 'Grep',
    'file_search': 'Glob',
    'edit_file': 'Edit',
    'create_document': 'Write',
    'create_word': 'Write',
    'create_excel': 'Write',
  };

  /// YAML-Wert sicher schreiben (Anführungszeichen, wenn nötig)
  static String yamlStr(String v) {
    final t = v.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
    const special = '-?:,[]{}#&*!|>\'"%@`';
    final plain = t.isNotEmpty &&
        !special.contains(t[0]) &&
        !t.contains(': ') &&
        !t.contains(' #') &&
        !t.endsWith(':') &&
        !RegExp(r'^(true|false|yes|no|null|~|[0-9.+-]+)$', caseSensitive: false).hasMatch(t);
    return plain ? t : '"${t.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }

  /// Junels-Angaben unter metadata (Standard: Map String → String)
  Map<String, String> get junelsMeta => {
        ...meta,
        if (name != _titleFrom(specName)) 'junels.title': name,
        if (tools.isNotEmpty) 'junels.tools': tools.join(' '),
        if (requiredTool.isNotEmpty) 'junels.result': requiredTool,
        if (inputs.isNotEmpty) 'junels.inputs': inputs,
        if (internet != 'ask') 'junels.internet': internet,
        if (model.isNotEmpty) 'junels.model': model,
        if (output.isNotEmpty) 'junels.output': output,
        if (flowExport.isNotEmpty) 'junels.flow': flowExport,
        if (icon != 'auto_awesome') 'junels.icon': icon,
        if (!auto) 'junels.auto': 'false',
        if (slug.isNotEmpty && slug != specName) 'junels.command': slug,
      };

  /// Als SKILL.md nach dem Agent-Skills-Standard – läuft auch in Claude, Codex, Cursor & Co.
  String toMarkdown() {
    final b = StringBuffer()
      ..writeln('---')
      ..writeln('name: $specName')
      ..writeln('description: ${yamlStr(specDescription)}');
    if (license.isNotEmpty) b.writeln('license: ${yamlStr(license)}');
    final compat = compatibility.isNotEmpty
        ? compatibility
        : (internet == 'block' ? _offlineCompat : '');
    if (compat.isNotEmpty) b.writeln('compatibility: ${yamlStr(compat.length > 500 ? compat.substring(0, 500) : compat)}');
    final portable = [for (final t in tools) if (portableTools[t] case final p?) p];
    if (portable.isNotEmpty) b.writeln('allowed-tools: ${portable.toSet().join(' ')}');
    final m = junelsMeta;
    if (m.isNotEmpty) {
      b.writeln('metadata:');
      m.forEach((k, v) => b.writeln('  ${yamlStr(k)}: ${yamlStr(v)}'));
    }
    b
      ..writeln('---')
      ..writeln()
      ..writeln('# $name')
      ..writeln()
      ..writeln(instructions.trim());
    if (knowledge.trim().isNotEmpty) {
      b
        ..writeln()
        ..writeln('## Wissen & Beispiele')
        ..writeln()
        ..writeln(knowledge.trim());
    }
    if (files.isNotEmpty) {
      b
        ..writeln()
        ..writeln('## Dateien')
        ..writeln();
      for (final f in files.keys.toList()..sort()) {
        b.writeln('- [$f]($f)');
      }
    }
    return b.toString();
  }

  /// SKILL.md einlesen (eigene oder Claude-Skills). Nur Text – nichts wird ausgeführt.
  static Skill? fromMarkdown(String md, {required String id}) {
    final m = RegExp(r'^---\s*\r?\n([\s\S]*?)\r?\n---\s*\r?\n?([\s\S]*)$').firstMatch(md.replaceFirst('﻿', '').trimLeft());
    if (m == null) return null;
    final meta = parseFrontmatter(m.group(1)!);
    var body = m.group(2)!.trim();
    var knowledge = '';
    final k = body.indexOf('## Wissen & Beispiele');
    if (k >= 0) {
      knowledge = body.substring(k + '## Wissen & Beispiele'.length).trim();
      body = body.substring(0, k).trim();
    }
    // Dateiliste aus dem Export nicht als Anleitung übernehmen
    body = body.replaceFirst(RegExp(r'\n+## Dateien\n+(- \[[^\n]*\n?)+\s*$'), '').trim();
    final k2 = knowledge.indexOf('\n## Dateien\n');
    if (k2 >= 0) knowledge = knowledge.substring(0, k2).trim();
    final h1 = RegExp(r'^# (.+)\n+').firstMatch(body);
    body = body.replaceFirst(RegExp(r'^# .*\n+'), '');
    if (body.trim().isEmpty && (meta['description'] ?? '').isEmpty) return null;
    final rawName = meta['name'] ?? '';
    // Junels-Angaben: metadata.junels.* (Standard) oder junels-* (ältere Exporte)
    String? j(String key) => meta['metadata.junels.$key'] ?? meta['junels-$key'];
    final name = j('title') ?? h1?.group(1)?.trim() ?? (rawName.isEmpty ? 'Skill' : _titleFrom(rawName));
    String pick(String key, Map<String, String> labels, String dflt) => labels.containsKey(j(key)) ? j(key)! : dflt;
    final toolText = j('tools') ?? meta['allowed-tools'] ?? '';
    final skill = Skill(
      id: id,
      name: name,
      slug: slugify(j('command') ?? (rawName.isEmpty ? name : rawName)),
      when: meta['description'] ?? '',
      instructions: body.trim().isEmpty ? (meta['description'] ?? '') : body,
      tools: [for (final t in splitTools(toolText)) t],
      requiredTool: j('result') ?? '',
      inputs: j('inputs') ?? '',
      knowledge: knowledge,
      internet: pick('internet', internetLabels, 'ask'),
      model: pick('model', modelLabels, ''),
      output: OutputView.valid(j('output') ?? '') ? (j('output') ?? '') : '',
      icon: j('icon') ?? 'auto_awesome',
      auto: j('auto') != 'false',
      license: meta['license'] ?? '',
      compatibility: meta['compatibility'] == _offlineCompat ? '' : (meta['compatibility'] ?? ''),
      meta: {
        for (final e in meta.entries)
          if (e.key.startsWith('metadata.') && !e.key.startsWith('metadata.junels.')) e.key.substring(9): e.value,
      },
    );
    skill.flowExport = j('flow') ?? '';
    return skill;
  }

  /// allowed-tools: Leerzeichen-getrennt (Standard), auch mit Komma; Klammern bleiben zusammen: Bash(git:*)
  static List<String> splitTools(String text) => [
        for (final m in RegExp(r'[^\s,(]+(\([^)]*\))?').allMatches(text)) m.group(0)!,
      ];

  static String _titleFrom(String slug) {
    final w = slug.replaceAll(RegExp(r'[-_]+'), ' ').trim();
    return w.isEmpty ? 'Skill' : '${w[0].toUpperCase()}${w.substring(1)}';
  }

  /// Einfaches YAML-Frontmatter: key: wert, "Anführungszeichen", Block-Text (| oder >) über mehrere Zeilen.
  static Map<String, String> parseFrontmatter(String yaml) {
    final out = <String, String>{};
    final lines = yaml.split(RegExp(r'\r?\n'));
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final mm = RegExp(r'^([A-Za-z0-9_-]+)\s*:\s*(.*)$').firstMatch(line);
      if (mm == null) continue;
      final key = mm.group(1)!;
      var v = mm.group(2)!.trim();
      if (v == '|' || v == '>' || v == '|-' || v == '>-' || (v.isEmpty && i + 1 < lines.length && lines[i + 1].startsWith(RegExp(r'\s')))) {
        final buf = <String>[];
        while (i + 1 < lines.length && (lines[i + 1].startsWith(RegExp(r'\s')) || lines[i + 1].trim().isEmpty)) {
          i++;
          buf.add(lines[i].trim());
        }
        final nonEmpty = buf.where((x) => x.isNotEmpty).toList();
        // verschachtelte Map (metadata:) → key.unterkey
        if (!v.startsWith('|') && !v.startsWith('>') && nonEmpty.isNotEmpty &&
            nonEmpty.every((x) => RegExp(r'^("[^"]+"|' "'[^']+'" r'|[^\s:\-][^:]*?)\s*:(\s|$)').hasMatch(x))) {
          for (final x in nonEmpty) {
            final kv = RegExp(r'^("[^"]+"|' "'[^']+'" r'|[^:]+?)\s*:\s*(.*)$').firstMatch(x)!;
            out['$key.${_unquote(kv.group(1)!.trim())}'] = _unquote(kv.group(2)!.trim());
          }
          continue;
        }
        v = v.startsWith('|') ? buf.join('\n').trim() : nonEmpty.join(' ').trim();
        // Liste (- a / - b) → Komma-getrennt
        if (buf.isNotEmpty && buf.where((x) => x.isNotEmpty).every((x) => x.startsWith('- '))) {
          v = buf.where((x) => x.isNotEmpty).map((x) => x.substring(2).trim()).join(', ');
        }
      } else if (v.startsWith('[') && v.endsWith(']')) {
        v = v.substring(1, v.length - 1).split(',').map((x) => x.trim().replaceAll(RegExp('^["\']|["\']\$'), '')).join(', ');
      } else {
        v = _unquote(v);
      }
      out[key] = v;
    }
    return out;
  }

  static String _unquote(String v) {
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      return v.substring(1, v.length - 1).replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
    }
    if (v.length >= 2 && v.startsWith("'") && v.endsWith("'")) return v.substring(1, v.length - 1).replaceAll("''", "'");
    return v;
  }

  /// Text für das Modell in dieser Runde.
  String brief() {
    final b = StringBuffer('[SKILL „$name“ – folge dieser Anleitung]\n');
    if (when.isNotEmpty) b.writeln('Zweck: $when');
    if (inputs.trim().isNotEmpty) {
      b.writeln('Benötigte Angaben: $inputs – fehlt etwas Wichtiges, frag kurz danach (alles in einer Frage), sonst leg los.');
    }
    b.writeln('Anleitung:\n${instructions.trim()}');
    if (knowledge.trim().isNotEmpty) b.writeln('Wissen & Beispiele:\n${knowledge.trim()}');
    if (files.isNotEmpty) {
      b.writeln('Weitere Dateien dieses Skills – nur bei Bedarf lesen mit dem Werkzeug skill (aktion datei, name $command, pfad):');
      for (final f in files.keys.toList()..sort()) {
        b.writeln('- $f (${(files[f]!.length / 1000).ceil()} KB${f.startsWith('scripts/') ? ', Skript – wird nicht ausgeführt, nur lesbar' : ''})');
      }
    }
    return b.toString();
  }
}

/// Eingebaute Basis-Skills – aus den Werkzeugen von Junels. Anpassbar, jederzeit zurücksetzbar.
final builtinSkills = <Skill>[
  Skill(
    id: 'b-praesentation',
    name: 'Präsentation',
    slug: 'praesentation',
    icon: 'slideshow',
    when: 'Wenn ich eine Präsentation, Folien oder ein PowerPoint möchte.',
    instructions: '1. Thema, Zielgruppe und Folienzahl aus der Nachricht nehmen (sonst 6–8 Folien).\n'
        '2. Bei aktuellen Themen erst kurz im Web recherchieren.\n'
        '3. Die Präsentation mit create_presentation erstellen – nicht nur Folientexte im Chat auflisten.\n'
        '4. Passendes Design wählen (Reise, Business …) oder das genannte.',
    tools: ['create_presentation', 'web_search', 'web_fetch', 'create_chart'],
    requiredTool: 'create_presentation',
    inputs: 'Thema, Zielgruppe, Folienzahl',
    builtin: true,
  ),
  Skill(
    id: 'b-dokument',
    name: 'Dokument',
    slug: 'dokument',
    icon: 'description',
    when: 'Wenn ich einen Bericht, ein Handout, ein PDF oder ein Word-Dokument möchte.',
    instructions: '1. Gliederung aus der Aufgabe ableiten.\n2. Bei Bedarf recherchieren.\n'
        '3. Das Dokument mit create_document erstellen, mit klaren Überschriften und kurzen Absätzen.',
    tools: ['create_document', 'web_search', 'web_fetch', 'create_chart'],
    requiredTool: 'create_document',
    inputs: 'Thema, Umfang',
    builtin: true,
  ),
  Skill(
    id: 'b-erinnerung',
    name: 'Erinnerung',
    slug: 'erinnerung',
    icon: 'alarm',
    when: 'Wenn ich an etwas erinnert werden will oder einen Termin eintragen möchte.',
    instructions: '1. Zeitpunkt genau bestimmen (heute/morgen/Uhrzeit).\n'
        '2. send_notification mit art „erinnerung“; wenn ich Termin oder Kalender sage, kalender „ja“.\n'
        '3. In einem Satz bestätigen, wann erinnert wird.',
    tools: ['send_notification', 'calendar_add', 'datetime'],
    inputs: 'Was, Wann',
    builtin: true,
  ),
  Skill(
    id: 'b-tagesueberblick',
    name: 'Tagesüberblick',
    slug: 'heute',
    icon: 'wb_sunny',
    when: 'Wenn ich wissen will, was heute oder morgen ansteht.',
    instructions: '1. Termine mit calendar_list für den gefragten Tag holen.\n'
        '2. Wetter für meinen Ort holen.\n'
        '3. Kurz zusammenfassen: Termine mit Uhrzeit, dann Wetter in einem Satz, dann einen Tipp. '
        'Gibt das Kalender-Werkzeug einen HINWEIS aus, diesen kurz weitergeben.',
    tools: ['calendar_list', 'weather', 'news', 'datetime'],
    builtin: true,
  ),
  Skill(
    id: 'b-recherche',
    name: 'Recherche',
    slug: 'recherche',
    icon: 'travel_explore',
    when: 'Wenn ich etwas Aktuelles wissen oder verglichen haben will.',
    instructions: '1. Mit web_search suchen, die 2–3 besten Quellen mit web_fetch lesen.\n'
        '2. Antwort mit konkreten Zahlen und Quellen-Links, Widersprüche nennen.',
    tools: ['web_search', 'web_fetch', 'site_search'],
    builtin: true,
  ),
  Skill(
    id: 'b-begleiten',
    name: 'Begleiten',
    slug: 'begleiten',
    icon: 'explore',
    when: 'Wenn ich einen Amtsweg erledigen muss (Umzug, Reisepass, Antrag, Lebenslage) oder etwas auf einer Webseite gemeinsam '
        'mit dir ausfüllen will: Formular, Antrag, Tickets, Buchung.',
    instructions: 'OHNE LINK (Amtsweg, Lebenslage):\n'
        '1. Klären, worum es geht und wo ich wohne (Wien oder anderes Bundesland), falls nicht klar.\n'
        '2. Nur offizielle Quellen: site_search auf oesterreich.gv.at, bei Wien auch wien.gv.at (Amtshelfer unter wien.gv.at/amtswege); '
        'die passende Seite mit web_fetch lesen.\n'
        '3. Antworte so: ein Satz Überblick, dann „## Das brauchst du“ als Checkliste (- [ ] Unterlage), dann „## So geht es“ als '
        'nummerierte Schritte, dann Kosten, Fristen, zuständige Stelle und ob es online geht (ID Austria) – mit Link zur Quelle und zum Online-Formular.\n'
        '4. Am Ende anbieten: „Soll ich dich durch das Online-Formular begleiten?“ – bei Ja weiter wie MIT LINK.\n'
        '5. Keine Rechtsberatung, nichts erfinden: steht etwas nicht in der Quelle, das sagen und auf die Behörde verweisen.\n'
        'MIT LINK (Webseite, Formular):\n'
        '1. begleiten mit aktion start (url, ziel), dann aktion plan mit den Schritten dieser Seite.\n'
        '2. Ist ein Formular da: begleiten aktion formular. Jedes Feld in einfachen Worten erklären (was gemeint ist, wo ich die Angabe finde), '
        'höchstens 3 Angaben auf einmal fragen und mit browser type/select/check (F-Nummer) eintragen.\n'
        '3. 🔒-Felder (SV-Nummer, Passnummer, IBAN, Passwort) trage ich selbst ein – mit begleiten aktion zeigen hervorheben.\n'
        '4. Anmeldung (ID Austria), Captcha, Unterschrift und Zahlung an mich übergeben (aktion uebergabe).\n'
        '5. Vor dem Absenden begleiten aktion pruefen, kurz zusammenfassen und mein Ja abwarten.',
    tools: ['begleiten', 'browser', 'site_search', 'web_fetch', 'web_search'],
    inputs: 'Anliegen oder Link, Wohnort',
    builtin: true,
  ),
  Skill(
    id: 'b-liegengeblieben',
    name: 'Liegengebliebenes',
    slug: 'offen',
    icon: 'checklist',
    when: 'Wenn ich wissen will, was noch offen oder liegengeblieben ist.',
    instructions: '1. find_loose_ends nutzen, bei verbundenem Postfach auch mail_inbox.\n'
        '2. Nach Dringlichkeit sortiert auflisten, je Punkt ein Vorschlag für den nächsten Schritt.',
    tools: ['find_loose_ends', 'mail_inbox', 'calendar_list'],
    builtin: true,
  ),
  // ---------------------------------------------------------------- Im Web erledigen
  Skill(
    id: 'b-preis-scout',
    name: 'Preis-Scout',
    slug: 'preis',
    icon: 'sell',
    when: 'Wenn ich den besten Preis für ein Produkt suche oder Preise vergleichen will.',
    instructions: '1. Auf geizhals.at nach dem Produkt suchen (browser search) und mit browser collect (target 2) die Angebote sammeln.\n'
        '2. Zum Gegencheck auf willhaben.at suchen (gebraucht) und ggf. einen großen Shop (z. B. amazon.de) – je browser collect.\n'
        '3. Ergebnis als Tabelle: Produkt, Preis, Versand (wenn ersichtlich), Händler/Quelle, Link – günstigstes zuerst. '
        'Gebraucht-Angebote kennzeichnen.\n'
        '4. Nennt der Nutzer einen Zielpreis („unter 500 €“) und das günstigste Angebot liegt darunter: send_notification mit Preis und Link. '
        'Tipp an den Nutzer: unter „Wann“ täglich einplanen, dann meldet sich Junels, sobald der Preis fällt.\n'
        'Nie bestellen oder bezahlen.',
    tools: ['browser', 'site_search', 'web_search', 'web_fetch', 'send_notification', 'create_excel'],
    inputs: 'Produkt, optional Zielpreis',
    output: 'table',
    job: true,
    auto: false, // nur per /befehl – startet sonst ungefragt einen Web-Job
    builtin: true,
  ),
  Skill(
    id: 'b-inserate',
    name: 'Inserate-Wächter',
    slug: 'inserate',
    icon: 'radar',
    when: 'Wenn ich auf willhaben nach Wohnung, Auto, Fahrrad oder anderen Inseraten suche und nur neue Treffer sehen will.',
    instructions: '1. willhaben.at öffnen und die Suche mit den Filtern des Nutzers einstellen (Kategorie, Ort/Bezirk, Preis bis, '
        'Zimmer/Fläche, Marke …) – über Suchfeld und Filter-Links.\n'
        '2. browser collect mit text „neu“ (target 2): liefert nur Inserate, die noch nicht gemeldet wurden.\n'
        '3. Neue Treffer als Karten: Titel, Preis, Ort, Link. Keine neuen → kurz sagen „keine neuen Inserate“.\n'
        '4. Tipp an den Nutzer: unter „Wann“ einplanen (z. B. täglich 7:30) – dann kommen neue Inserate automatisch in „Ergebnisse“.\n'
        'Nie Kontakt aufnehmen oder etwas absenden.',
    tools: ['browser', 'site_search', 'web_search'],
    inputs: 'Was (Wohnung, Auto, Rad …), Ort, Preis bis, weitere Filter',
    output: 'cards',
    job: true,
    auto: false, // nur per /befehl – startet sonst ungefragt einen Web-Job
    builtin: true,
  ),
  Skill(
    id: 'b-reise',
    name: 'Reise-Vergleich',
    slug: 'reise',
    icon: 'flight',
    when: 'Wenn ich eine Reise plane und Zug, Flug und Hotel für einen Zeitraum vergleichen will.',
    instructions: '1. Zug: oebb.at (Ticketshop) – Verbindung für Hin- und Rückfahrt eintragen und die Angebote mit Zeit, Dauer, Umstiegen und Preis lesen.\n'
        '2. Flug (wenn sinnvoll): eine Flugsuche (z. B. austrian.com oder kayak.at) mit Datum – Abflug, Ankunft, Dauer, Preis.\n'
        '3. Hotel: booking.com mit Ort und Zeitraum, browser collect (target 1) – Name, Preis gesamt, Bewertung, Lage.\n'
        '4. Ergebnis als Tabelle je Bereich (Zug, Flug, Hotel) und ein kurzer Vorschlag (günstigste / schnellste Kombination).\n'
        'NICHT buchen: höchstens bis zur Übergabe vorbereiten, Buchen und Zahlen macht der Nutzer.',
    tools: ['browser', 'site_search', 'web_search', 'web_fetch', 'datetime', 'create_excel'],
    inputs: 'Von, Nach, Hinreise, Rückreise, Personen',
    output: 'table',
    job: true,
    auto: false, // nur per /befehl – startet sonst ungefragt einen Web-Job
    builtin: true,
  ),
  Skill(
    id: 'b-firmen-dossier',
    name: 'Firmen-Dossier',
    slug: 'dossier',
    icon: 'business',
    when: 'Wenn ich mich auf ein Treffen mit einer Firma vorbereite oder wissen will, wer eine Firma ist.',
    instructions: '1. web_search nach der Firma; Webseite mit web_fetch lesen (Über uns, Leistungen, Team, Kontakt).\n'
        '2. Firmenbuch-Daten über öffentliche Seiten (z. B. firmen.wko.at, firmenabc.at): Rechtsform, Sitz, Gründung, Geschäftsführung.\n'
        '3. Aktuelle News (news, web_search) der letzten 12 Monate.\n'
        '4. Ansprechpartner nur, wenn öffentlich auf der Firmenseite genannt (Name, Funktion) – keine privaten Daten.\n'
        '5. create_word: Dossier mit Abschnitten Überblick, Zahlen & Fakten, Leistungen, Personen, News, '
        'Fragen fürs Gespräch, Quellen.',
    tools: ['web_search', 'web_fetch', 'news', 'site_search', 'create_word'],
    inputs: 'Firma (Name oder Webseite)',
    output: 'word',
    builtin: true,
  ),
  Skill(
    id: 'b-formular',
    name: 'Formular-Ausfüller',
    slug: 'ausfuellen',
    icon: 'edit_note',
    when: 'Wenn ich ein Online-Formular mit meinen Daten ausfüllen lassen will.',
    instructions: '1. Seite öffnen (Link vom Nutzer) und browser form lesen.\n'
        '2. browser autofill: trägt Name, Adresse, E-Mail, Telefon, Kundennummern aus „Meine Daten“ ein (die Werte siehst du nicht).\n'
        '3. Was noch offen ist, kurz nachfragen (höchstens 3 Angaben auf einmal) und mit browser type/select/check eintragen.\n'
        '4. 🔒-Felder (SV-Nummer, IBAN, Pass, Passwort) mit browser mark hervorheben – die trägt der Nutzer selbst ein.\n'
        '5. NICHT absenden: am Ende zusammenfassen und sagen, dass der Nutzer prüft und selbst absendet.\n'
        'Sind „Meine Daten“ leer: auf Einstellungen → Meine Daten hinweisen.',
    tools: ['browser', 'begleiten', 'site_search'],
    inputs: 'Link zum Formular',
    auto: false, // nur per /befehl – startet sonst ungefragt einen Web-Job
    builtin: true,
  ),
  Skill(
    id: 'b-belege',
    name: 'Belege-Sammler',
    slug: 'belege',
    icon: 'receipt_long',
    when: 'Wenn ich Rechnungen aus Online-Portalen (Strom, Handy, Amazon …) herunterladen und für die Steuer auflisten will.',
    instructions: '1. Portal öffnen (z. B. Kundenkonto Rechnungen). Ist eine Anmeldung nötig: an den Nutzer übergeben – er meldet sich selbst an.\n'
        '2. Zur Rechnungsübersicht navigieren; den gewünschten Zeitraum (Standard: letzter Monat) suchen.\n'
        '3. Jede passende Rechnung mit browser download speichern (target = Link-Nummer, text = „<Anbieter> <Datum>“).\n'
        '4. create_excel: Liste mit Datum, Anbieter, Rechnungsnummer, Betrag (brutto), Datei – Summe am Ende.\n'
        'Nie bezahlen oder Einstellungen ändern. Tipp: unter „Wann“ monatlich einplanen.',
    tools: ['browser', 'site_search', 'create_excel', 'calculator'],
    inputs: 'Portal(e), Zeitraum',
    output: 'excel',
    job: true,
    auto: false, // nur per /befehl – startet sonst ungefragt einen Web-Job
    builtin: true,
  ),
  Skill(
    id: 'b-kuendigung',
    name: 'Kündigung & Verträge',
    slug: 'kuendigen',
    icon: 'gavel',
    when: 'Wenn ich einen Vertrag kündigen will oder wissen will, bis wann ich kündigen muss.',
    instructions: '1. Vertrag klären: Anbieter, Vertragsart, Kundennummer (falls in „Meine Daten“ – sonst nachfragen), Beginn, Mindestlaufzeit, Kündigungsfrist.\n'
        '2. Kündigungsfrist und letzten Kündigungstag berechnen (datetime, calculator); bei Unklarheit die AGB des Anbieters mit web_search suchen.\n'
        '3. create_word: Kündigungsschreiben (Absender, Empfänger mit Adresse des Anbieters, Betreff mit Kundennummer, '
        'Kündigung zum nächstmöglichen Termin, Bitte um schriftliche Bestätigung, Datum, Unterschriftszeile).\n'
        '4. calendar_add: Erinnerung 7 Tage vor dem letzten Kündigungstag und eine zum Vertragsende.\n'
        'Hinweis: kein Rechtsrat; Einschreiben oder Bestätigung aufheben.',
    tools: ['web_search', 'web_fetch', 'datetime', 'calculator', 'create_word', 'calendar_add'],
    inputs: 'Anbieter, Vertrag, Vertragsbeginn',
    output: 'word',
    builtin: true,
  ),
  Skill(
    id: 'b-termin-suche',
    name: 'Termin-Sucher',
    slug: 'termin-suche',
    icon: 'event_available',
    when: 'Wenn ich einen freien Termin bei Arzt, Amt oder Werkstatt online finden will.',
    instructions: '1. Buchungsseite öffnen (Link des Nutzers oder über site_search/web_search finden, z. B. Ordination, Magistrat, Werkstatt).\n'
        '2. Freie Termine im gewünschten Zeitraum suchen und auflisten (Datum, Uhrzeit, Ort/Person).\n'
        '3. Den passendsten Termin wählen (Wunsch des Nutzers) und das Formular mit browser autofill und den Angaben ausfüllen.\n'
        '4. VOR dem Bestätigen anhalten: zusammenfassen und an den Nutzer übergeben – er bestätigt selbst.\n'
        'Anmeldung, CAPTCHA und Zahlung macht der Nutzer.',
    tools: ['browser', 'begleiten', 'site_search', 'web_search', 'datetime'],
    inputs: 'Wo (Arzt/Amt/Link), Zeitraum, Anliegen',
    job: true,
    auto: false, // nur per /befehl – startet sonst ungefragt einen Web-Job
    builtin: true,
  ),
  Skill(
    id: 'b-mitschrift',
    name: 'Mitschrift',
    slug: 'mitschrift',
    icon: 'mail',
    when: 'Wenn ich ein Gespräch, Meeting oder Telefonat mitschreiben (transkribieren) lassen will.',
    instructions: 'Ohne weiteren Auftrag öffnet /mitschrift die Aufnahme (alles bleibt auf dem Gerät). Danach liegt die Mitschrift im Chat.\n'
        '1. Auswerten: kurze Zusammenfassung – Thema, Teilnehmende (wenn erkennbar), wichtigste Punkte, Entscheidungen, '
        'Aufgaben mit Zuständigen und Fristen.\n'
        '2. Bis zu 3 Rückfragen zu Unklarem (Namen, wer übernimmt was, Termine) – die Antworten in die Auswertung übernehmen.\n'
        '3. Auf Wunsch create_word: Protokoll mit Überschrift, Datum, Teilnehmende, Zusammenfassung, Entscheidungen, '
        'Aufgaben (Tabelle: Was, Wer, Bis wann), danach die vollständige Mitschrift mit Zeitmarken.',
    tools: ['create_word', 'calendar_add', 'remember'],
    inputs: 'Titel (optional) – oder Auftrag zur vorhandenen Mitschrift',
    auto: false,
    builtin: true,
  ),
  Skill(
    id: 'b-musik',
    name: 'Musik & Apps',
    slug: 'musik',
    icon: 'music_note',
    when: 'Wenn ich Musik hören, etwas in einer App suchen oder eine App öffnen will.',
    instructions: '1. control_app nutzen – zum Abspielen von Gesuchtem aktion „abspielen“ mit suche.\n'
        '2. Nie etwas kaufen, bestellen oder bezahlen.',
    tools: ['control_app'],
    builtin: true,
  ),
];

/// Alle Skills: Basis-Skills (ggf. angepasst) + eigene.
class SkillLibrary extends ChangeNotifier {
  SkillLibrary(this._file);
  final File _file;
  final List<Skill> _own = [];
  final Map<String, Skill> _overrides = {}; // angepasste Basis-Skills

  List<Skill> get all => [for (final b in builtinSkills) _overrides[b.id] ?? b, ..._own];
  List<Skill> get own => List.unmodifiable(_own);
  List<Skill> get basis => [for (final b in builtinSkills) _overrides[b.id] ?? b];
  List<Skill> get enabled => [for (final s in all) if (s.enabled) s];

  Skill? byId(String id) => all.where((s) => s.id == id).firstOrNull;

  /// Skill, dessen Zeitplan dieser Eintrag ist
  Skill? forPrompt(String promptId) => all.where((s) => s.promptId == promptId).firstOrNull;

  /// Freier Befehl (/name, /name-2 …)
  String uniqueSlug(String name, {String? exceptId}) {
    final base = Skill.slugify(name.isEmpty ? 'aufgabe' : name);
    var slug = base;
    for (var i = 2; all.any((o) => o.id != exceptId && o.command == slug); i++) {
      slug = '$base-$i';
    }
    return slug;
  }
  /// Frühere bzw. zweite Namen von Basis-Skills
  static const commandAliases = {'amtsweg': 'begleiten', 'amtswege': 'begleiten', 'amtsweg-lotse': 'begleiten'};

  Skill? byCommand(String cmd) {
    final c = commandAliases[cmd.toLowerCase()] ?? cmd.toLowerCase();
    return enabled.where((s) => s.command == c).firstOrNull ??
        enabled.where((s) => s.command.startsWith(c) || Skill.slugify(s.name) == c).firstOrNull;
  }

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      _own
        ..clear()
        ..addAll([for (final s in (j['own'] as List? ?? const [])) Skill.fromJson((s as Map).cast())]);
      _overrides
        ..clear()
        ..addAll({
          for (final s in (j['overrides'] as List? ?? const []))
            '${(s as Map)['id']}': Skill.fromJson({...s.cast<String, dynamic>(), 'builtin': true}),
        });
      notifyListeners();
    } catch (_) {}
  }

  Timer? _t;
  void _save() {
    _t?.cancel();
    _t = Timer(const Duration(milliseconds: 300), () async {
      try {
        final tmp = File('${_file.path}.tmp');
        await tmp.writeAsString(jsonEncode({
          'own': [for (final s in _own) s.toJson()],
          'overrides': [for (final s in _overrides.values) s.toJson()],
        }));
        await tmp.rename(_file.path);
      } catch (_) {}
    });
    notifyListeners();
  }

  void upsert(Skill s) {
    if (s.slug.isEmpty) s.slug = Skill.slugify(s.name);
    if (s.builtin) {
      s.edited = true;
      _overrides[s.id] = s;
    } else {
      final i = _own.indexWhere((x) => x.id == s.id);
      if (i >= 0) {
        _own[i] = s;
      } else {
        _own.insert(0, s);
      }
    }
    _save();
  }

  void remove(Skill s) {
    if (s.builtin) {
      _overrides.remove(s.id);
    } else {
      _own.removeWhere((x) => x.id == s.id);
    }
    _save();
  }

  /// Basis-Skill auf den Auslieferungszustand zurücksetzen.
  void reset(Skill s) {
    _overrides.remove(s.id);
    _save();
  }

  /// Jeder Ablauf ist auch ein Skill (/befehl, eine Liste für alles). Fehlt er, wird er angelegt; der Name folgt dem Ablauf.
  void syncFlow(String flowId, String name, String description, {bool enabled = true}) {
    final linked = _own.where((s) => s.flowId == flowId).toList();
    if (linked.isEmpty) {
      var slug = Skill.slugify(name);
      if (slug.isEmpty) slug = 'ablauf';
      final base = slug;
      for (var i = 2; all.any((s) => s.command == slug); i++) {
        slug = '$base-$i';
      }
      _own.add(Skill(
          id: 'flow-$flowId',
          name: name,
          slug: slug,
          when: description,
          instructions: '',
          flowId: flowId,
          auto: false,
          icon: 'flow',
          enabled: enabled));
      _save();
      return;
    }
    var changed = false;
    for (final s in linked.where((s) => s.runsFlow)) {
      if (s.name != name || s.when != description || s.enabled != enabled) {
        s
          ..name = name
          ..when = description
          ..enabled = enabled;
        changed = true;
      }
    }
    if (changed) _save();
  }

  /// Ablauf gelöscht: reine Ablauf-Skills verschwinden mit, Anleitungs-Skills verlieren nur den Auslöser.
  void flowRemoved(String flowId) {
    _own.removeWhere((s) => s.flowId == flowId && s.runsFlow);
    for (final s in _own.where((s) => s.flowId == flowId)) {
      s.flowId = null;
    }
    for (final s in _overrides.values.where((s) => s.flowId == flowId)) {
      s.flowId = null;
    }
    _save();
  }

  /// Skill zu einem Ablauf
  Skill? forFlow(String flowId) =>
      all.where((s) => s.flowId == flowId && !s.runsFlow).firstOrNull ?? all.where((s) => s.flowId == flowId).firstOrNull;

  void setEnabled(Skill s, bool v) {
    final copy = s.copy()..enabled = v;
    upsert(copy);
  }

  /// Welcher Skill passt zur Nachricht? 1. /befehl am Anfang, 2. eigene Skills mit „automatisch erkennen“
  /// über Wörter aus Name und Beschreibung. Basis-Skills nur per /befehl (ihre Werkzeuge findet Junels ohnehin).
  /// Gesprochen: „Skill Preis-Scout, RTX 4070“, „mit dem Skill Firmen-Dossier …“, „Slash dossier …“, „use skill …“
  (Skill, String)? matchSpoken(String input) {
    final t = input.trim();
    final m = RegExp(
            r'^(?:bitte\s+|please\s+)?(?:mit\s+(?:dem\s+)?|nutze\s+(?:den\s+)?|starte\s+(?:den\s+)?|use\s+(?:the\s+)?|run\s+(?:the\s+)?|start\s+(?:the\s+)?)?'
            r'(?:skill|slash|schrägstrich)\b[\s,:]*',
            caseSensitive: false)
        .firstMatch(t);
    if (m == null) return null;
    final words = t.substring(m.end).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    String norm(String x) => x.toLowerCase().replaceAll(RegExp(r'[^a-z0-9äöüß]'), '');
    for (var n = words.length < 4 ? words.length : 4; n >= 1; n--) {
      final cand = norm(words.take(n).join(' '));
      if (cand.isEmpty) continue;
      for (final s in enabled) {
        if (norm(s.name) == cand || norm(s.command) == cand || norm(commandAliases[cand] ?? '') == norm(s.command)) {
          final task = words.skip(n).join(' ').replaceFirst(RegExp(r'^[,:;.\-–]+\s*'), '').trim();
          return (s, task);
        }
      }
    }
    // ungefähr: Name beginnt mit dem ersten Wort (z. B. „Skill Preis …“)
    if (words.isNotEmpty) {
      final w = norm(words.first);
      if (w.length >= 4) {
        final hit = enabled.where((s) => norm(s.name).startsWith(w) || norm(s.command).startsWith(w)).toList();
        if (hit.length == 1) return (hit.first, words.skip(1).join(' ').replaceFirst(RegExp(r'^[,:;.\-–]+\s*'), '').trim());
      }
    }
    return null;
  }

  (Skill, String)? match(String input) {
    final t = input.trimLeft();
    final cmd = RegExp(r'^/([a-z0-9äöüß-]+)\s*', caseSensitive: false).firstMatch(t);
    if (cmd != null) {
      final s = byCommand(cmd.group(1)!);
      if (s != null) return (s, t.substring(cmd.end).trim());
    }
    // /befehl mitten im Satz („Wichtig wäre im /dossier unter Personas …“): nur genau passende Befehle,
    // nur nach Leerzeichen/Klammer (keine Pfade oder Links); der Befehl wird im Text durch den Skill-Namen ersetzt
    for (final m in RegExp(r'(?<=^|[\s(„"])/([a-z0-9äöüß-]{2,})(?=$|[\s.,;:!?)“"])', caseSensitive: false).allMatches(t)) {
      final c = m.group(1)!.toLowerCase();
      final s = enabled.where((x) => x.command == (commandAliases[c] ?? c)).firstOrNull;
      if (s == null) continue;
      final task = (t.substring(0, m.start) + s.name + t.substring(m.end)).replaceAll(RegExp(r'\s{2,}'), ' ').trim();
      return (s, task);
    }
    final low = t.toLowerCase();
    Skill? best;
    var bestScore = 0;
    for (final s in _own.where((s) => s.enabled && s.auto && !s.runsFlow)) {
      final words = {
        for (final w in RegExp(r'[a-zäöüß]{5,}').allMatches('${s.name} ${s.when}'.toLowerCase()).map((m) => m.group(0)!))
          if (!_stop.contains(w)) w,
      };
      var score = 0;
      for (final w in words) {
        if (low.contains(w.substring(0, w.length > 7 ? w.length - 2 : w.length))) score++;
      }
      if (low.contains(s.name.toLowerCase())) score += 2;
      if (score > bestScore) {
        bestScore = score;
        best = s;
      }
    }
    return best != null && bestScore >= 2 ? (best, t) : null;
  }

  static const _stop = {'wenn', 'dass', 'diese', 'einen', 'einer', 'eines', 'meine', 'meinen', 'meiner', 'möchte', 'will', 'immer',
    'etwas', 'damit', 'werden', 'wollen', 'haben', 'soll', 'sollen', 'bitte', 'oder', 'und', 'nicht', 'jeden', 'alles'};
}
