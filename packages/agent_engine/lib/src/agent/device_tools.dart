// Werkzeuge fürs Gerät: E-Mail, WhatsApp, Anrufen, Kalender, Kontakte und (Mac)
// Dateien. Junels bereitet nur vor – senden, anrufen und speichern bestätigt der
// Nutzer in der jeweiligen App bzw. per Rückfrage.

import 'notify_tool.dart' show parseWhen;
import 'tool.dart';

class ContactInfo {
  ContactInfo(this.name, this.phones, this.emails);
  final String name;
  final List<String> phones;
  final List<String> emails;
}

class CalendarEvent {
  CalendarEvent(this.title, this.begin, this.end, {this.allDay = false, this.location = '', this.notes = '', this.calendar = ''});
  final String title;
  final DateTime begin;
  final DateTime end;
  final bool allDay;
  final String location;
  final String notes;
  final String calendar;
}

class FileHit {
  FileHit(this.path, this.name, {this.isDir = false, this.size = 0, this.modified});
  final String path;
  final String name;
  final bool isDir;
  final int size;
  final DateTime? modified;
}

/// Plattform-Funktionen (Android/macOS über MethodChannel, in Tests ein Fake).
abstract class DeviceActions {
  Future<List<ContactInfo>> contacts(String query);
  Future<void> composeEmail(String to, String subject, String body);
  Future<void> whatsapp(String phone, String text);
  Future<void> dial(String number);
  Future<void> calendarInsert(CalendarEvent e);
  Future<List<CalendarEvent>> calendarList(DateTime from, DateTime to);

  /// Welche Kalender sind lesbar (Name, Konto, Termine) – für die Fehlersuche, wenn nichts kommt.
  Future<String> calendarInfo() async => '';
  Future<List<FileHit>> fileSearch(String query, String ext);
  Future<String> fileRename(String path, String newName);
  Future<String> fileMove(String path, String folder);

  /// Rückfrage an den Nutzer (Dialog); true = bestätigt.
  Future<bool> confirm(String title, String detail);
  String get countryCode; // z. B. "43"
}

const _wd = ['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', 'Sonntag'];
String _two(int v) => v.toString().padLeft(2, '0');
String formatEvent(CalendarEvent e) {
  final d = '${_wd[e.begin.weekday - 1].substring(0, 2)} ${e.begin.day}.${e.begin.month}.';
  final t = e.allDay ? 'ganztägig' : '${_two(e.begin.hour)}:${_two(e.begin.minute)}–${_two(e.end.hour)}:${_two(e.end.minute)}';
  return '$d $t ${e.title}${e.location.isEmpty ? '' : ' (${e.location})'}';
}

/// Telefonnummer international (ohne +), z. B. "0664 123" → "43664123".
String normalizePhone(String raw, String countryCode) {
  var s = raw.replaceAll(RegExp(r'[^\d+]'), '');
  if (s.startsWith('+')) return s.substring(1);
  if (s.startsWith('00')) return s.substring(2);
  if (s.startsWith('0')) return '$countryCode${s.substring(1)}';
  return s;
}

/// Tag(e) aus "heute", "morgen", "übermorgen", "Freitag", "2026-11-21", "21.11." → [von, bis).
(DateTime, DateTime) parseDayRange(String raw, int days, DateTime now) {
  final s = raw.trim().toLowerCase();
  final today = DateTime(now.year, now.month, now.day);
  DateTime start = today;
  if (s.isEmpty || s == 'heute') {
    start = today;
  } else if (s == 'morgen') {
    start = today.add(const Duration(days: 1));
  } else if (s == 'übermorgen') {
    start = today.add(const Duration(days: 2));
  } else if (RegExp(r'^(diese |nächste )?woche$').hasMatch(s)) {
    start = s.startsWith('nächste') ? today.add(Duration(days: 8 - today.weekday)) : today;
    days = s.startsWith('nächste') ? 7 : 8 - today.weekday;
  } else {
    final i = _wd.indexWhere((w) => s.startsWith(w.toLowerCase().substring(0, 2)) && s.length >= 2 && w.toLowerCase().startsWith(s.split(' ').first));
    if (i >= 0) {
      var diff = (i + 1 - today.weekday) % 7;
      if (diff == 0) diff = 0;
      start = today.add(Duration(days: diff));
    } else {
      final iso = DateTime.tryParse(s);
      final de = RegExp(r'^(\d{1,2})\.(\d{1,2})\.?(\d{2,4})?$').firstMatch(s);
      if (iso != null) {
        start = DateTime(iso.year, iso.month, iso.day);
      } else if (de != null) {
        var y = de.group(3) == null ? now.year : int.parse(de.group(3)!);
        if (y < 100) y += 2000;
        start = DateTime(y, int.parse(de.group(2)!), int.parse(de.group(1)!));
      } else {
        throw ToolException('Tag nicht verstanden: "$raw" (z. B. heute, morgen, Freitag, 2026-11-21)');
      }
    }
  }
  return (start, start.add(Duration(days: days.clamp(1, 31))));
}

abstract class _DeviceTool extends AgentTool {
  _DeviceTool(this.device);
  final DeviceActions device;

  /// Empfänger auflösen: E-Mail/Nummer direkt, sonst im Adressbuch.
  Future<(String?, String)> resolve(String to, {required bool email}) async {
    final t = to.trim();
    if (t.isEmpty) return (null, '');
    if (email && t.contains('@')) return (t, t);
    if (!email && RegExp(r'^[\d\s+()/-]{5,}$').hasMatch(t)) return (t, t);
    final found = await device.contacts(t);
    final usable = [for (final c in found) if ((email ? c.emails : c.phones).isNotEmpty) c];
    if (usable.isEmpty) {
      throw ToolException(found.isEmpty
          ? 'Kein Kontakt „$t“ im Adressbuch gefunden. Frag nach der ${email ? 'E-Mail-Adresse' : 'Telefonnummer'}.'
          : '„$t“ hat keine ${email ? 'E-Mail-Adresse' : 'Telefonnummer'} im Adressbuch.');
    }
    final exact = usable.where((c) => c.name.toLowerCase() == t.toLowerCase()).toList();
    final pick = exact.length == 1 ? exact : usable;
    if (pick.length > 1) {
      throw ToolException('Mehrere Kontakte passen: ${pick.take(5).map((c) => c.name).join(', ')}. Frag, wer gemeint ist.');
    }
    final c = pick.single;
    final v = email ? c.emails.first : c.phones.firstWhere((p) => RegExp(r'^(\+|00)?4?3?\s*0?6').hasMatch(p), orElse: () => c.phones.first);
    return (v, c.name);
  }
}

class ContactsTool extends _DeviceTool {
  ContactsTool(super.device);
  @override
  String get name => 'contacts_search';
  @override
  String get title => 'Kontakte';
  @override
  String get description => 'Sucht im Adressbuch nach Namen und liefert Telefonnummern und E-Mail-Adressen.';
  @override
  List<ToolParam> get params => const [ToolParam('name', ParamType.string, 'Name oder Teil davon')];
  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final q = (args['name'] ?? '').toString().trim();
    if (q.isEmpty) throw ToolException('name ist leer');
    final list = await device.contacts(q);
    if (list.isEmpty) return 'Kein Kontakt „$q“ gefunden.';
    return [
      for (final c in list.take(8))
        '- ${c.name}${c.phones.isEmpty ? '' : ' · Tel: ${c.phones.join(', ')}'}${c.emails.isEmpty ? '' : ' · E-Mail: ${c.emails.join(', ')}'}',
    ].join('\n');
  }
}

class EmailTool extends _DeviceTool {
  EmailTool(super.device);
  @override
  String get name => 'compose_email';
  @override
  String get title => 'E-Mail vorbereiten';
  @override
  String get description => 'Öffnet die Mail-App mit fertigem Entwurf (Empfänger, Betreff, Text). '
      'Der Nutzer prüft und sendet selbst. to: E-Mail-Adresse oder Name aus dem Adressbuch (leer = ohne Empfänger).';
  @override
  List<ToolParam> get params => const [
        ToolParam('to', ParamType.string, 'Empfänger (Adresse oder Name)'),
        ToolParam('subject', ParamType.string, 'Betreff'),
        ToolParam('body', ParamType.string, 'Text der E-Mail'),
      ];
  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final (addr, who) = await resolve((args['to'] ?? '').toString(), email: true);
    final subject = (args['subject'] ?? '').toString();
    final body = (args['body'] ?? '').toString();
    final propose = ctx.propose;
    if (propose != null) {
      // Entwurf als Karte im Chat – gesendet wird erst nach dem Tipp auf „Senden“
      propose({'type': 'email', 'to': addr ?? '', 'name': who, 'subject': subject, 'body': body, 'status': 'pending'});
      ctx.answerNow = true;
      return 'Entwurf liegt als Karte im Chat${addr == null ? ' (Empfänger fehlt noch)' : ' an $who <$addr>'}, Betreff „$subject“. '
          'Der Nutzer sendet mit einem Tipp auf „Senden“. Sag nur kurz, an wen es geht, und frag „Soll ich das senden?“ – '
          'wiederhole den Text nicht.';
    }
    await device.composeEmail(addr ?? '', subject, body);
    return 'Mail-App geöffnet mit Entwurf${addr == null ? '' : ' an $who <$addr>'}, Betreff „$subject“. '
        'Der Nutzer muss nur noch auf Senden tippen. Sag ihm das kurz und zeig den Text.';
  }
}

class WhatsAppTool extends _DeviceTool {
  WhatsAppTool(super.device);
  @override
  String get name => 'compose_whatsapp';
  @override
  String get title => 'WhatsApp vorbereiten';
  @override
  String get description => 'Öffnet WhatsApp mit fertigem Text an eine Person (Nummer oder Name aus dem Adressbuch). '
      'Der Nutzer sendet selbst.';
  @override
  List<ToolParam> get params => const [
        ToolParam('to', ParamType.string, 'Empfänger (Nummer oder Name; leer = Kontakt in WhatsApp wählen)'),
        ToolParam('text', ParamType.string, 'Nachricht'),
      ];
  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final (nr, who) = await resolve((args['to'] ?? '').toString(), email: false);
    final text = (args['text'] ?? '').toString();
    final propose = ctx.propose;
    if (propose != null) {
      propose({
        'type': 'whatsapp',
        'to': nr == null ? '' : normalizePhone(nr, device.countryCode),
        'name': who,
        'body': text,
        'status': 'pending',
      });
      ctx.answerNow = true;
      return 'Entwurf liegt als Karte im Chat${nr == null ? '' : ' an $who'}. Mit „Senden“ öffnet sich WhatsApp mit dem Text. '
          'Sag kurz, an wen es geht, und frag „Soll ich das senden?“ – wiederhole den Text nicht.';
    }
    await device.whatsapp(nr == null ? '' : normalizePhone(nr, device.countryCode), text);
    return 'WhatsApp geöffnet${nr == null ? ' (Kontakt dort wählen)' : ' mit $who ($nr)'} und der Nachricht. '
        'Der Nutzer muss nur noch auf Senden tippen.';
  }
}

class CallTool extends _DeviceTool {
  CallTool(super.device);
  @override
  String get name => 'call_phone';
  @override
  String get title => 'Anrufen';
  @override
  String get description => 'Öffnet die Telefon-App mit der Nummer (Name aus dem Adressbuch oder Nummer). '
      'Der Nutzer startet den Anruf selbst.';
  @override
  List<ToolParam> get params => const [ToolParam('to', ParamType.string, 'Name oder Telefonnummer')];
  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final (nr, who) = await resolve((args['to'] ?? '').toString(), email: false);
    if (nr == null) throw ToolException('Wen soll ich anrufen? to ist leer.');
    await device.dial(nr);
    return 'Telefon-App geöffnet mit $who ($nr). Der Nutzer tippt auf Anrufen.';
  }
}

class CalendarAddTool extends _DeviceTool {
  CalendarAddTool(super.device, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  @override
  String get name => 'calendar_add';
  @override
  String get title => 'Termin eintragen';
  @override
  String get description => 'Legt einen Termin im Kalender an (der Nutzer bestätigt im Kalender). '
      'start z. B. "2026-11-21 14:00", "morgen 9:30", "21.11. 18:00"; nur Datum = ganztägig.';
  @override
  List<ToolParam> get params => const [
        ToolParam('title', ParamType.string, 'Titel'),
        ToolParam('start', ParamType.string, 'Beginn'),
        ToolParam('duration_minutes', ParamType.integer, 'Dauer in Minuten (Standard 60)'),
        ToolParam('location', ParamType.string, 'Ort (optional)'),
        ToolParam('notes', ParamType.string, 'Notizen (optional)'),
      ];
  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final title = (args['title'] ?? '').toString().trim();
    if (title.isEmpty) throw ToolException('title ist leer');
    final raw = (args['start'] ?? '').toString().trim();
    final now = _clock();
    DateTime begin;
    var allDay = false;
    try {
      // nur ein Datum ohne Uhrzeit → ganztägig
      if (!RegExp(r'\d[:.]\d{2}(?!\.)|\buhr\b|^in ', caseSensitive: false).hasMatch(raw) ||
          RegExp(r'^\d{1,2}\.\d{1,2}\.(\d{2,4})?$').hasMatch(raw)) {
        throw const FormatException('Datum');
      }
      begin = parseWhen(raw, now) ?? (throw const FormatException('leer'));
    } on FormatException {
      try {
        begin = parseDayRange(raw, 1, now).$1;
        allDay = true;
      } on ToolException {
        throw ToolException('Beginn nicht verstanden: "$raw". Format z. B. "2026-11-21 14:00".');
      }
    }
    final mins = (int.tryParse('${args['duration_minutes'] ?? 60}') ?? 60).clamp(5, 24 * 60);
    final end = allDay ? begin.add(const Duration(days: 1)) : begin.add(Duration(minutes: mins));
    final e = CalendarEvent(title, begin, end,
        allDay: allDay, location: (args['location'] ?? '').toString(), notes: (args['notes'] ?? '').toString());
    await device.calendarInsert(e);
    return 'Kalender geöffnet mit dem Termin: ${formatEvent(e)}. Der Nutzer bestätigt dort mit Speichern.';
  }
}

class CalendarListTool extends _DeviceTool {
  CalendarListTool(super.device, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  @override
  String get name => 'calendar_list';
  @override
  String get title => 'Termine abrufen';
  @override
  String get description => 'Liest die Termine aus dem Kalender des Geräts. day: "heute", "morgen", "Freitag", '
      '"2026-11-21", "diese Woche".';
  @override
  List<ToolParam> get params => const [
        ToolParam('day', ParamType.string, 'Tag (Standard heute)'),
        ToolParam('days', ParamType.integer, 'Anzahl Tage ab day (Standard 1)'),
      ];
  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final days = int.tryParse('${args['days'] ?? 1}') ?? 1;
    final (from, to) = parseDayRange((args['day'] ?? '').toString(), days, _clock());
    final list = await device.calendarList(from, to);
    final span = to.difference(from).inDays <= 1
        ? '${_wd[from.weekday - 1]}, ${from.day}.${from.month}.'
        : '${from.day}.${from.month}. bis ${to.subtract(const Duration(days: 1)).day}.${to.subtract(const Duration(days: 1)).month}.';
    // Wenige Treffer: prüfen, ob Kalender fehlen/nicht synchronisiert sind (Hinweis nur bei Problemen)
    var info = '';
    if (list.length < 5) {
      try {
        info = await device.calendarInfo();
      } catch (_) {}
    }
    if (list.isEmpty) return 'Keine Termine ($span).${info.isEmpty ? '' : '\n$info'}';
    return 'Termine $span (Quelle: Kalender des Geräts):\n${list.map((e) => '- ${formatEvent(e)}').join('\n')}'
        '${info.isEmpty ? '' : '\n$info'}';
  }
}

// ------------------------------------------------------------ Dateien (Mac)

class FileSearchTool extends _DeviceTool {
  FileSearchTool(super.device);
  @override
  String get name => 'file_search';
  @override
  String get title => 'Dateien suchen';
  @override
  String get description => 'Sucht Dateien nach Namen in den freigegebenen Ordnern des Macs.';
  @override
  List<ToolParam> get params => const [
        ToolParam('query', ParamType.string, 'Wörter im Dateinamen (leer = alle)'),
        ToolParam('ext', ParamType.string, 'Dateityp, z. B. "pdf" (optional)'),
      ];
  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final hits = await device.fileSearch((args['query'] ?? '').toString(), (args['ext'] ?? '').toString());
    if (hits.isEmpty) return 'Nichts gefunden.';
    return [
      for (final h in hits.take(40))
        '- ${h.path}${h.isDir ? ' (Ordner)' : ' (${(h.size / 1024).ceil()} KB${h.modified == null ? '' : ', ${h.modified!.day}.${h.modified!.month}.${h.modified!.year}'})'}',
    ].join('\n');
  }
}

class FileRenameTool extends _DeviceTool {
  FileRenameTool(super.device);
  @override
  String get name => 'file_rename';
  @override
  String get title => 'Datei umbenennen';
  @override
  String get description => 'Benennt eine Datei um (nur nach Bestätigung durch den Nutzer). path: voller Pfad aus file_search.';
  @override
  List<ToolParam> get params => const [
        ToolParam('path', ParamType.string, 'Voller Pfad'),
        ToolParam('new_name', ParamType.string, 'Neuer Dateiname inkl. Endung'),
      ];
  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final path = (args['path'] ?? '').toString();
    final name = (args['new_name'] ?? '').toString().trim();
    if (path.isEmpty || name.isEmpty) throw ToolException('path und new_name nötig');
    final old = path.split('/').last;
    if (!await device.confirm('Datei umbenennen?', '„$old“\n→ „$name“')) return 'Der Nutzer hat das Umbenennen abgelehnt.';
    final p = await device.fileRename(path, name);
    return 'Umbenannt: $p';
  }
}

class FileMoveTool extends _DeviceTool {
  FileMoveTool(super.device);
  @override
  String get name => 'file_move';
  @override
  String get title => 'Datei verschieben';
  @override
  String get description => 'Verschiebt eine Datei in einen Ordner (wird angelegt, falls nötig) – nur nach Bestätigung. '
      'Zum Sortieren mehrerer Dateien: erst file_search, dann je Datei file_move.';
  @override
  List<ToolParam> get params => const [
        ToolParam('path', ParamType.string, 'Voller Pfad der Datei'),
        ToolParam('folder', ParamType.string, 'Voller Pfad des Zielordners'),
      ];
  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final path = (args['path'] ?? '').toString();
    final folder = (args['folder'] ?? '').toString();
    if (path.isEmpty || folder.isEmpty) throw ToolException('path und folder nötig');
    if (!await device.confirm('Datei verschieben?', '„${path.split('/').last}“\n→ $folder')) {
      return 'Der Nutzer hat das Verschieben abgelehnt.';
    }
    final p = await device.fileMove(path, folder);
    return 'Verschoben nach: $p';
  }
}
