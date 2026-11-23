// Skills: Pakete aus Anleitung + erlaubten Werkzeugen (angelehnt an SKILL.md).
// Ein Skill sagt dem Agenten, wann und wie er Werkzeuge für eine Aufgabe kombiniert, und lädt NUR diese
// Werkzeuge – das macht kleine Modelle am Gerät deutlich zuverlässiger.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  }) : tools = tools ?? [];

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

  String get command => slug.isEmpty ? slugify(name) : slug;

  static String slugify(String s) {
    var t = s.toLowerCase().trim();
    const map = {'ä': 'ae', 'ö': 'oe', 'ü': 'ue', 'ß': 'ss'};
    map.forEach((k, v) => t = t.replaceAll(k, v));
    t = t.replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    return t.length > 24 ? t.substring(0, 24).replaceAll(RegExp(r'-+$'), '') : t;
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
      );

  Skill copy({String? id, bool? builtin}) =>
      Skill.fromJson({...toJson(), if (id != null) 'id': id, if (builtin != null) 'builtin': builtin});

  /// Als SKILL.md (Frontmatter + Anleitung) – zum Teilen und für Claude-kompatible Skills.
  String toMarkdown() {
    final b = StringBuffer()
      ..writeln('---')
      ..writeln('name: $command')
      ..writeln('description: ${when.replaceAll('\n', ' ')}')
      ..writeln('junels-title: $name')
      ..writeln('junels-tools: ${tools.join(', ')}');
    if (requiredTool.isNotEmpty) b.writeln('junels-result: $requiredTool');
    if (inputs.isNotEmpty) b.writeln('junels-inputs: $inputs');
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
    return b.toString();
  }

  /// SKILL.md einlesen (eigene oder Claude-Skills). Nur Text – nichts wird ausgeführt.
  static Skill? fromMarkdown(String md, {required String id}) {
    final m = RegExp(r'^---\s*\n([\s\S]*?)\n---\s*\n?([\s\S]*)$').firstMatch(md.trimLeft());
    if (m == null) return null;
    final meta = <String, String>{};
    for (final line in m.group(1)!.split('\n')) {
      final i = line.indexOf(':');
      if (i > 0) meta[line.substring(0, i).trim()] = line.substring(i + 1).trim();
    }
    var body = m.group(2)!.trim();
    var knowledge = '';
    final k = body.indexOf('## Wissen & Beispiele');
    if (k >= 0) {
      knowledge = body.substring(k + '## Wissen & Beispiele'.length).trim();
      body = body.substring(0, k).trim();
    }
    body = body.replaceFirst(RegExp(r'^# .*\n+'), '');
    final name = meta['junels-title'] ?? meta['name'] ?? 'Skill';
    return Skill(
      id: id,
      name: name,
      slug: slugify(meta['name'] ?? name),
      when: meta['description'] ?? '',
      instructions: body,
      tools: [for (final t in (meta['junels-tools'] ?? '').split(',')) if (t.trim().isNotEmpty) t.trim()],
      requiredTool: meta['junels-result'] ?? '',
      inputs: meta['junels-inputs'] ?? '',
      knowledge: knowledge,
    );
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
    when: 'Wenn ich etwas auf einer Webseite gemeinsam mit dir erledigen will (Amtsweg, Tickets, Buchung).',
    instructions: '1. begleiten mit aktion start (url, ziel).\n2. Plan anlegen, Schritt für Schritt im Browser arbeiten.\n'
        '3. Anmeldung, Captcha und Zahlung an mich übergeben.',
    tools: ['begleiten', 'browser'],
    inputs: 'Link, Ziel',
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
  Skill? byCommand(String cmd) {
    final c = cmd.toLowerCase();
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

  void setEnabled(Skill s, bool v) {
    final copy = s.copy()..enabled = v;
    upsert(copy);
  }

  /// Welcher Skill passt zur Nachricht? 1. /befehl am Anfang, 2. eigene Skills mit „automatisch erkennen“
  /// über Wörter aus Name und Beschreibung. Basis-Skills nur per /befehl (ihre Werkzeuge findet Junels ohnehin).
  (Skill, String)? match(String input) {
    final t = input.trimLeft();
    final cmd = RegExp(r'^/([a-z0-9äöüß-]+)\s*', caseSensitive: false).firstMatch(t);
    if (cmd != null) {
      final s = byCommand(cmd.group(1)!);
      if (s != null) return (s, t.substring(cmd.end).trim());
    }
    final low = t.toLowerCase();
    Skill? best;
    var bestScore = 0;
    for (final s in _own.where((s) => s.enabled && s.auto)) {
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
