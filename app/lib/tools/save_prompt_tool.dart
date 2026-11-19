import 'package:agent_engine/agent_engine.dart';

import '../data/models.dart';

/// Legt aus dem Chat heraus einen gespeicherten Prompt ("Meine Prompts") an.
class SavePromptTool extends AgentTool {
  SavePromptTool(this.save, this.existing);
  final Future<void> Function(SavedPrompt p) save;
  final List<SavedPrompt> Function() existing;

  @override
  String get name => 'save_prompt';
  @override
  String get keywords => 'prompt prompts vorlage speichern anlegen merken zeitplan täglich jeden morgen automatisch briefing';
  @override
  String get title => 'Prompt speichern';
  @override
  String get description =>
      'Speichert einen Prompt unter "Meine Prompts", optional mit Zeitplan (z. B. jeden Morgen 08:30). '
      'Nur verwenden, wenn der Nutzer ausdrücklich einen Prompt speichern/anlegen will. '
      'Gleicher Titel = bestehenden Prompt aktualisieren.';
  @override
  List<ToolParam> get params => const [
        ToolParam('title', ParamType.string, 'Kurzer Name'),
        ToolParam('text', ParamType.string, 'Vollständiger Prompt-Text, der später ausgeführt wird'),
        ToolParam('schedule', ParamType.enumeration, 'Zeitplan', values: ['off', 'daily', 'weekdays', 'weekly']),
        ToolParam('time', ParamType.string, 'Uhrzeit HH:MM (leer bei off)'),
        ToolParam('weekday', ParamType.string, 'Wochentag bei weekly, z. B. Montag'),
        ToolParam('allow_internet', ParamType.boolean, 'Internet ohne Nachfrage erlauben (nötig für Webseiten bei Zeitplan)'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final title = (args['title'] ?? '').toString().trim();
    final text = (args['text'] ?? '').toString().trim();
    if (text.isEmpty) throw ToolException('text ist leer');
    final schedule = ScheduleKind.values.firstWhere((k) => k.name == (args['schedule'] ?? 'off').toString(),
        orElse: () => ScheduleKind.off);
    var hour = 8, minute = 30;
    final t = RegExp(r'(\d{1,2})(?:[:.h](\d{2}))?').firstMatch((args['time'] ?? '').toString());
    if (t != null) {
      hour = int.parse(t.group(1)!).clamp(0, 23);
      minute = int.parse(t.group(2) ?? '0').clamp(0, 59);
    } else if (schedule != ScheduleKind.off) {
      throw ToolException('time fehlt (Format HH:MM)');
    }
    var weekday = DateTime.monday;
    final wd = (args['weekday'] ?? '').toString().toLowerCase().trim();
    if (wd.length >= 2) {
      final i = SavedPrompt.weekdayNames.indexWhere((n) => n.toLowerCase().startsWith(wd.substring(0, 2)));
      if (i >= 0) weekday = i + 1;
    }
    final name = title.isEmpty ? (text.length > 30 ? '${text.substring(0, 30)}…' : text) : title;
    final old = existing().where((p) => p.title.toLowerCase() == name.toLowerCase()).firstOrNull;
    final p = SavedPrompt(
      id: old?.id,
      title: name,
      text: text,
      profileId: old?.profileId,
      schedule: schedule,
      hour: hour,
      minute: minute,
      weekday: weekday,
      allowInternet: args['allow_internet'] == true || args['allow_internet'] == 'true',
      notify: old?.notify ?? true,
      lastRun: old?.lastRun,
    );
    await save(p);
    return '${old == null ? 'Gespeichert' : 'Aktualisiert'}: "${p.title}" unter Meine Prompts – ${p.scheduleLabel}'
        '${p.allowInternet ? ', Internet erlaubt' : ''}.';
  }
}
