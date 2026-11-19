// Push-Nachricht an den Nutzer – sofort oder zu einem Zeitpunkt (Erinnerung).

import 'tool.dart';

/// Liest Zeitangaben wie "", "jetzt", "in 30 Minuten", "in 2 h", "15:00",
/// "morgen 8:30", "2026-12-24 18:00". Liefert null für "sofort".
/// Wirft [FormatException], wenn nichts erkannt wird.
DateTime? parseWhen(String raw, DateTime now) {
  final s = raw.trim().toLowerCase().replaceAll('uhr', '').trim();
  if (s.isEmpty || s == 'jetzt' || s == 'sofort' || s == 'now') return null;
  final rel = RegExp(r'^in\s+(\d+(?:[.,]\d+)?)\s*(s|sek\w*|sec\w*|m|min\w*|h|std\w*|stunde\w*|hour\w*|t|tag\w*|d|day\w*)$').firstMatch(s);
  if (rel != null) {
    final v = double.parse(rel.group(1)!.replaceAll(',', '.'));
    final u = rel.group(2)!;
    final secs = u.startsWith('s')
        ? v
        : (u.startsWith('h') || u.startsWith('std') || u.startsWith('stunde'))
            ? v * 3600
            : (u.startsWith('t') || u.startsWith('d'))
                ? v * 86400
                : v * 60;
    return now.add(Duration(seconds: secs.round()));
  }
  final iso = DateTime.tryParse(s.replaceFirst(' ', 'T'));
  if (iso != null) return iso;
  final de = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{2,4})?\s*(\d{1,2})[:.](\d{2})$').firstMatch(s);
  if (de != null) {
    var y = de.group(3) == null ? now.year : int.parse(de.group(3)!);
    if (y < 100) y += 2000;
    return DateTime(y, int.parse(de.group(2)!), int.parse(de.group(1)!), int.parse(de.group(4)!), int.parse(de.group(5)!));
  }
  final t = RegExp(r'^(heute|morgen|übermorgen)?\s*(?:um\s*)?(\d{1,2})(?:[:.](\d{2}))?$').firstMatch(s);
  if (t != null) {
    final day = switch (t.group(1)) { 'morgen' => 1, 'übermorgen' => 2, _ => 0 };
    var d = DateTime(now.year, now.month, now.day + day, int.parse(t.group(2)!), int.parse(t.group(3) ?? '0'));
    if (t.group(1) == null && !d.isAfter(now)) d = d.add(const Duration(days: 1));
    return d;
  }
  throw FormatException('Zeitangabe nicht verstanden: "$raw"');
}

typedef Notifier = Future<void> Function(String title, String text, DateTime? at);

class NotifyTool extends AgentTool {
  NotifyTool(this.send, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final Notifier send;
  final DateTime Function() _clock;

  @override
  String get name => 'send_notification';
  @override
  String get keywords => 'erinnere erinnerung erinnern benachrichtigung push mitteilung später wecker uhr';
  @override
  String get title => 'Push-Nachricht senden';
  @override
  String get description =>
      'Schickt dem Nutzer eine Push-Benachrichtigung aufs Gerät – sofort oder als Erinnerung zu einer Zeit. '
      'when: leer = sofort, sonst z. B. "in 30 Minuten", "15:00", "morgen 8:30".';
  @override
  List<ToolParam> get params => const [
        ToolParam('title', ParamType.string, 'Kurzer Titel'),
        ToolParam('text', ParamType.string, 'Nachrichtentext'),
        ToolParam('when', ParamType.string, 'Zeitpunkt (leer = sofort)'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final title = (args['title'] ?? '').toString().trim();
    final text = (args['text'] ?? '').toString().trim();
    if (title.isEmpty && text.isEmpty) throw ToolException('title und text sind leer');
    final now = _clock();
    DateTime? at;
    try {
      at = parseWhen((args['when'] ?? '').toString(), now);
    } on FormatException catch (e) {
      throw ToolException('${e.message}. Beispiele: "in 30 Minuten", "15:00", "morgen 8:30".');
    }
    if (at != null && !at.isAfter(now)) at = null;
    await send(title.isEmpty ? 'Junels' : title, text, at);
    if (at == null) return 'Push-Nachricht gesendet.';
    final hh = at.hour.toString().padLeft(2, '0'), mm = at.minute.toString().padLeft(2, '0');
    final sameDay = at.year == now.year && at.month == now.month && at.day == now.day;
    return 'Erinnerung geplant für ${sameDay ? 'heute' : '${at.day}.${at.month}.${at.year}'} um $hh:$mm Uhr.';
  }
}
