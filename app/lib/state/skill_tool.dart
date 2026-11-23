// Werkzeug „skill_erstellen“: Der Agent entwirft auf Zuruf einen eigenen Skill („Bau mir einen Skill, der …“).

import 'package:agent_engine/agent_engine.dart';

import 'skills.dart';

class SkillCreateTool extends AgentTool {
  SkillCreateTool({required this.available, required this.save});

  /// (Name, Titel) aller Werkzeuge, die ein Skill nutzen darf.
  final List<(String, String)> Function() available;
  final void Function(Skill s) save;

  @override
  String get name => 'skill_erstellen';
  @override
  String get title => 'Skill erstellen';
  @override
  String get keywords => 'skill fähigkeit ablauf vorlage wiederverwenden befehl';
  @override
  String get description {
    final list = available().map((t) => '${t.$1} (${t.$2})').join(', ');
    return 'Legt einen eigenen Skill an: eine wiederverwendbare Anleitung mit erlaubten Werkzeugen, aufrufbar mit /name. '
        'Nur wenn der Nutzer ausdrücklich einen Skill (oder eine wiederkehrende Fähigkeit) haben will. '
        'werkzeuge: kommagetrennt aus: $list. ergebnis: Werkzeug, mit dem das Ergebnis entstehen MUSS (z. B. create_presentation) oder leer. '
        'anleitung: nummerierte, konkrete Schritte.';
  }

  @override
  List<ToolParam> get params => const [
        ToolParam('name', ParamType.string, 'Kurzer Name, z. B. „Rechnungen sammeln“'),
        ToolParam('wann', ParamType.string, 'Wann der Skill passt (ein Satz)'),
        ToolParam('anleitung', ParamType.string, 'Schritte, je Zeile einer'),
        ToolParam('werkzeuge', ParamType.string, 'Erlaubte Werkzeuge, kommagetrennt'),
        ToolParam('angaben', ParamType.string, 'Angaben, nach denen gefragt wird, kommagetrennt (sonst "")'),
        ToolParam('ergebnis', ParamType.string, 'Pflicht-Werkzeug fürs Ergebnis oder ""'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final name = '${args['name'] ?? ''}'.trim();
    final steps = '${args['anleitung'] ?? ''}'.trim();
    if (name.isEmpty || steps.isEmpty) throw ToolException('name und anleitung sind nötig');
    final known = {for (final t in available()) t.$1};
    final tools = [
      for (final t in '${args['werkzeuge'] ?? ''}'.split(RegExp(r'[,;\s]+')))
        if (known.contains(t.trim())) t.trim(),
    ];
    final req = '${args['ergebnis'] ?? ''}'.trim();
    final s = Skill(
      id: 'u-${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      slug: Skill.slugify(name),
      when: '${args['wann'] ?? ''}'.trim(),
      instructions: steps,
      tools: {...tools, if (known.contains(req)) req}.toList(),
      requiredTool: known.contains(req) ? req : '',
      inputs: '${args['angaben'] ?? ''}'.trim(),
    );
    save(s);
    ctx.answerNow = true;
    return 'Skill „${s.name}“ gespeichert – aufrufen mit /${s.command}. Werkzeuge: ${s.tools.isEmpty ? 'keine' : s.tools.join(', ')}. '
        'Sag dem Nutzer kurz, wie er ihn nutzt und dass er ihn unter Skills anpassen kann.';
  }
}
