// iCal (ICS) lesen: Termine aus einer Kalender-Adresse (z. B. Google „Privatadresse im iCal-Format“),
// falls der Kalender nicht mit dem Gerät synchronisiert ist. Unterstützt Serien (RRULE: DAILY, WEEKLY mit BYDAY,
// MONTHLY, YEARLY; INTERVAL, COUNT, UNTIL), EXDATE, ganztägige Termine und Zeitzonen (Z, TZID, lokal).

import 'device_tools.dart';

/// Termine aus [ics] im Zeitraum [from]–[to] (lokale Zeit).
List<CalendarEvent> parseIcs(String ics, DateTime from, DateTime to, {String calendar = 'Kalender-Abo'}) {
  // Zeilen entfalten (Fortsetzungen beginnen mit Leerzeichen/Tab)
  final lines = <String>[];
  for (final raw in ics.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
    if ((raw.startsWith(' ') || raw.startsWith('\t')) && lines.isNotEmpty) {
      lines[lines.length - 1] += raw.substring(1);
    } else {
      lines.add(raw);
    }
  }
  final out = <CalendarEvent>[];
  Map<String, (String, Map<String, String>)>? ev;
  final exdates = <String>[];
  var calName = calendar;
  for (final line in lines) {
    if (line.startsWith('X-WR-CALNAME:') && calendar == 'Kalender-Abo') calName = _unescape(line.substring(13));
    if (line == 'BEGIN:VEVENT') {
      ev = {};
      exdates.clear();
      continue;
    }
    if (line == 'END:VEVENT') {
      if (ev != null) out.addAll(_expand(ev, List.of(exdates), from, to, calName));
      ev = null;
      continue;
    }
    if (ev == null) continue;
    final colon = _valueColon(line);
    if (colon < 0) continue;
    final head = line.substring(0, colon);
    final value = line.substring(colon + 1);
    final parts = head.split(';');
    final name = parts.first.toUpperCase();
    final params = <String, String>{
      for (final p in parts.skip(1))
        if (p.contains('=')) p.substring(0, p.indexOf('=')).toUpperCase(): p.substring(p.indexOf('=') + 1).replaceAll('"', ''),
    };
    if (name == 'EXDATE') {
      exdates.addAll(value.split(','));
    } else if (!ev.containsKey(name)) {
      ev[name] = (value, params);
    }
  }
  out.sort((a, b) => a.begin.compareTo(b.begin));
  return out;
}

/// Doppelpunkt, der Name/Parameter vom Wert trennt (nicht in Anführungszeichen).
int _valueColon(String line) {
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') quoted = !quoted;
    if (c == ':' && !quoted) return i;
  }
  return -1;
}

String _unescape(String s) => s.replaceAll(r'\n', '\n').replaceAll(r'\N', '\n').replaceAll(r'\,', ',').replaceAll(r'\;', ';').replaceAll(r'\\', r'\');

/// Datum/Zeit aus ICS → lokale Zeit. (Ganztägig, UTC mit Z, sonst als Ortszeit gelesen.)
(DateTime, bool)? _date(String v, Map<String, String> params) {
  v = v.trim();
  final allDay = params['VALUE'] == 'DATE' || RegExp(r'^\d{8}$').hasMatch(v);
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$').firstMatch(v);
  if (m == null) return null;
  final y = int.parse(m.group(1)!), mo = int.parse(m.group(2)!), d = int.parse(m.group(3)!);
  if (allDay || m.group(4) == null) return (DateTime(y, mo, d), true);
  final h = int.parse(m.group(4)!), mi = int.parse(m.group(5)!), s = int.tryParse(m.group(6) ?? '0') ?? 0;
  if (m.group(7) == 'Z') return (DateTime.utc(y, mo, d, h, mi, s).toLocal(), false);
  return (DateTime(y, mo, d, h, mi, s), false); // TZID: wie Gerätezeit (meist identisch)
}

List<CalendarEvent> _expand(
    Map<String, (String, Map<String, String>)> ev, List<String> exdates, DateTime from, DateTime to, String calName) {
  final start = ev['DTSTART'];
  if (start == null) return const [];
  final s = _date(start.$1, start.$2);
  if (s == null) return const [];
  final (begin, allDay) = s;
  Duration length;
  final end = ev['DTEND'];
  final e = end == null ? null : _date(end.$1, end.$2);
  if (e != null) {
    length = e.$1.difference(begin);
  } else {
    final dur = ev['DURATION']?.$1;
    length = dur != null ? _duration(dur) : (allDay ? const Duration(days: 1) : const Duration(hours: 1));
  }
  if (length.isNegative || length == Duration.zero) length = allDay ? const Duration(days: 1) : const Duration(minutes: 30);
  if ((ev['STATUS']?.$1 ?? '').toUpperCase() == 'CANCELLED') return const [];
  final title = _unescape(ev['SUMMARY']?.$1 ?? '(ohne Titel)');
  final location = _unescape(ev['LOCATION']?.$1 ?? '');
  final notes = _unescape(ev['DESCRIPTION']?.$1 ?? '');
  final ex = {for (final x in exdates) if (_date(x, const {}) case (final d, _)) _key(d, allDay)};

  CalendarEvent at(DateTime b) =>
      CalendarEvent(title, b, b.add(length), allDay: allDay, location: location, notes: notes, calendar: calName);
  bool hits(DateTime b) => b.isBefore(to) && b.add(length).isAfter(from) && !ex.contains(_key(b, allDay));

  final rule = ev['RRULE']?.$1;
  if (rule == null) return hits(begin) ? [at(begin)] : const [];

  final r = {for (final p in rule.split(';')) if (p.contains('=')) p.split('=')[0].toUpperCase(): p.split('=')[1]};
  final freq = r['FREQ'] ?? '';
  final interval = int.tryParse(r['INTERVAL'] ?? '1') ?? 1;
  final count = int.tryParse(r['COUNT'] ?? '');
  final until = r['UNTIL'] == null ? null : _date(r['UNTIL']!, const {})?.$1;
  const days = {'MO': 1, 'TU': 2, 'WE': 3, 'TH': 4, 'FR': 5, 'SA': 6, 'SU': 7};
  final byDay = [
    for (final d in (r['BYDAY'] ?? '').split(','))
      if (days[d.replaceAll(RegExp(r'[^A-Z]'), '')] case final n?) n,
  ];
  final out = <CalendarEvent>[];
  var n = 0;
  var cur = begin;
  // Schritte bis zum Zeitraum (max. ~ 50 Jahre täglich), dann Treffer sammeln
  for (var guard = 0; guard < 20000; guard++) {
    if (until != null && cur.isAfter(until.add(const Duration(days: 1)))) break;
    if (!cur.isBefore(to)) break;
    final candidates = freq == 'WEEKLY' && byDay.isNotEmpty
        ? [
            for (final wd in byDay..sort())
              DateTime(cur.year, cur.month, cur.day - (cur.weekday - 1) + (wd - 1), cur.hour, cur.minute, cur.second),
          ]
        : [cur];
    for (final c in candidates) {
      if (c.isBefore(begin)) continue;
      if (until != null && c.isAfter(until.add(const Duration(days: 1)))) break;
      n++;
      if (count != null && n > count) return out;
      if (hits(c)) out.add(at(c));
    }
    cur = switch (freq) {
      'DAILY' => DateTime(cur.year, cur.month, cur.day + interval, cur.hour, cur.minute, cur.second),
      'WEEKLY' => DateTime(cur.year, cur.month, cur.day + 7 * interval, cur.hour, cur.minute, cur.second),
      'MONTHLY' => DateTime(cur.year, cur.month + interval, cur.day, cur.hour, cur.minute, cur.second),
      'YEARLY' => DateTime(cur.year + interval, cur.month, cur.day, cur.hour, cur.minute, cur.second),
      _ => to, // unbekannt: nur der erste Termin
    };
    if (out.length > 200) break;
  }
  return out;
}

String _key(DateTime d, bool allDay) => allDay ? '${d.year}-${d.month}-${d.day}' : d.toIso8601String().substring(0, 16);

Duration _duration(String v) {
  final m = RegExp(r'P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?').firstMatch(v);
  if (m == null) return const Duration(hours: 1);
  int g(int i) => int.tryParse(m.group(i) ?? '') ?? 0;
  return Duration(days: g(1) * 7 + g(2), hours: g(3), minutes: g(4), seconds: g(5));
}
