// „Was ist liegengeblieben?“ – sammelt offene Punkte aus Chats, Prozessen, Beobachtungen
// und Kalender; für Mails, Tickets & Co. verweist es auf verbundene MCP-Werkzeuge.

import 'package:agent_engine/agent_engine.dart';

import 'app_controller.dart';

/// MCP-Werkzeuge, die Mails, Aufgaben oder Tickets lesen können.
final looseEndsMcp = ToolRouter.looseEndsMcp;

class LooseEndsTool extends AgentTool {
  LooseEndsTool(this.app, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final AppController app;
  final DateTime Function() _clock;

  @override
  String get name => 'find_loose_ends';
  @override
  String get title => 'Liegengebliebenes aufspüren';
  @override
  String get keywords => 'liegengeblieben offen unerledigt vergessen nachfassen erinnern aufgaben';
  @override
  String get description =>
      'Sammelt offene Punkte: Chats, in denen eine Rückfrage auf den Nutzer wartet oder etwas abbrach, Vorhaben aus Chats '
      '(„muss noch …“), fehlgeschlagene Prozesse, Beobachtungen mit Fehler oder ungelesenen Meldungen, anstehende Termine. '
      'Nennt außerdem Werkzeuge für Mails/Tickets, die du danach zusätzlich nutzen sollst.';
  @override
  List<ToolParam> get params => const [
        ToolParam('tage', ParamType.integer, 'Wie weit zurück (Tage, Standard 14)'),
      ];

  static final _intent = RegExp(
      r'\b(ich muss|muss noch|ich sollte|sollte noch|nicht vergessen|vergiss nicht|erinnere mich|to-?do|später|bis (morgen|montag|dienstag|mittwoch|donnerstag|freitag|ende der woche|nächste woche)|kümmere mich|mach ich noch|melde mich)\b',
      caseSensitive: false);

  static String _short(String s, [int n = 110]) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > n ? '${t.substring(0, n)}…' : t;
  }

  static String _day(DateTime d) => '${d.day}.${d.month}.';

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final now = _clock();
    final days = (int.tryParse('${args['tage'] ?? 14}') ?? 14).clamp(1, 90);
    final since = now.subtract(Duration(days: days));
    final out = <String>[];

    // ---- Chats
    final waiting = <String>[], failed = <String>[], plans = <String>[];
    for (final c in app.conversations) {
      if (AppController.isRoutineChat(c) || c.entries.isEmpty || c.updated.isBefore(since)) continue;
      if (c.id == app.current?.id) continue; // der laufende Chat zählt nicht
      final last = c.entries.last;
      if (last.role == 'assistant' && last.error != null) {
        failed.add('„${c.title}“ (${_day(c.updated)}): ${_short(last.error!, 80)}');
      } else if (last.role == 'assistant' && now.difference(c.updated).inHours >= 2) {
        final text = last.text.trim();
        final tail = text.length > 300 ? text.substring(text.length - 300) : text;
        if (RegExp(r'\?\s*$').hasMatch(tail) || RegExp(r'(soll ich|möchtest du|willst du|magst du)[^.!]*\?', caseSensitive: false).hasMatch(tail)) {
          final q = RegExp(r'[^.!?\n]*\?').allMatches(tail).lastOrNull?.group(0) ?? tail;
          waiting.add('„${c.title}“ (${_day(c.updated)}): ${_short(q)}');
        }
      }
      for (final e in c.entries.where((e) => e.role == 'user' && e.time.isAfter(since))) {
        final m = _intent.firstMatch(e.text);
        if (m == null) continue;
        final start = (m.start - 40).clamp(0, e.text.length);
        plans.add('„${c.title}“ (${_day(e.time)}): …${_short(e.text.substring(start), 120)}');
      }
    }
    if (waiting.isNotEmpty) out.add('RÜCKFRAGEN, DIE AUF DICH WARTEN (${waiting.length}):\n${waiting.take(10).map((x) => '- $x').join('\n')}');
    if (plans.isNotEmpty) out.add('VORHABEN AUS CHATS (${plans.length}):\n${plans.take(10).map((x) => '- $x').join('\n')}');
    if (failed.isNotEmpty) out.add('ABGEBROCHENE ANTWORTEN (${failed.length}):\n${failed.take(6).map((x) => '- $x').join('\n')}');

    // ---- Prozesse & Beobachtungen
    final flows = [
      for (final f in app.flows.flows)
        if (f.enabled && f.lastStatus == 'Fehler') '„${f.name}“ – zuletzt ${f.lastRun == null ? '?' : _day(f.lastRun!)} fehlgeschlagen'
    ];
    if (flows.isNotEmpty) out.add('FEHLGESCHLAGENE PROZESSE:\n${flows.map((x) => '- $x').join('\n')}');
    final watch = <String>[
      for (final w in app.watchlist.items)
        if (w.enabled && w.lastError != null)
          '„${w.title}“: Fehler beim Prüfen (${_short(w.lastError!, 80)})'
        else if (w.unseen > 0)
          '„${w.title}“: ${w.unseen} ungelesene Meldung${w.unseen == 1 ? '' : 'en'}'
    ];
    if (watch.isNotEmpty) out.add('BEOBACHTUNGEN:\n${watch.map((x) => '- $x').join('\n')}');

    // ---- Kalender (nächste 7 Tage)
    if (app.settings.enabledTools.contains('calendar_list')) {
      try {
        final start = DateTime(now.year, now.month, now.day);
        final ev = await app.deviceBridge.calendarList(start, start.add(const Duration(days: 7)));
        if (ev.isNotEmpty) {
          out.add('TERMINE DER NÄCHSTEN 7 TAGE (prüfe, ob etwas vorzubereiten ist):\n${ev.take(15).map((e) => '- ${formatEvent(e)}').join('\n')}');
        }
      } catch (_) {}
    }

    // ---- Mails: eigener Posteingang (IMAP, nur Kopfzeilen) und/oder MCP-Werkzeuge
    var mailChecked = false;
    final acc = await app.imapAccount();
    if (acc != null) {
      try {
        await ctx.ensureNetwork('Posteingang lesen (${acc.host})');
        final mails = (await fetchInbox(acc, days: days.clamp(1, 30), unansweredOnly: true)).where((m) => !m.bulk).toList();
        mailChecked = true;
        // Nur, was älter als ein paar Stunden ist – frisch Eingetroffenes ist noch nicht „liegengeblieben“
        final old = mails.where((m) => m.date == null || now.difference(m.date!).inHours >= 4).toList();
        if (old.isNotEmpty) {
          out.add('UNBEANTWORTETE MAILS (${old.length}, ohne Newsletter):\n${old.take(12).map((m) => '- ${m.line}').join('\n')}');
        }
      } catch (e) {
        out.add('POSTEINGANG: konnte nicht gelesen werden ($e).');
      }
    }
    final mcp = [for (final t in app.mcpTools) if (looseEndsMcp.hasMatch('${t.name} ${t.title} ${t.description}')) t.name];
    final hint = mcp.isNotEmpty
        ? 'Prüfe JETZT zusätzlich mit ${mcp.take(6).join(', ')}: ${mailChecked ? '' : 'unbeantwortete Mails, '}offene Aufgaben/Tickets der letzten $days Tage.'
        : mailChecked
            ? ''
            : 'Mails konnte ich nicht prüfen: Kein Posteingang eingerichtet (Einstellungen → Tresor & Mail-Konto → „Posteingang lesen“) '
                'und kein Mail-Werkzeug verbunden.';

    if (out.isEmpty) return 'In Chats, Prozessen, Beobachtungen und Kalender ist nichts liegengeblieben (letzte $days Tage). $hint';
    return '${out.join('\n\n')}\n\n$hint\n\nFasse danach übersichtlich zusammen: was am dringendsten ist zuerst, je Punkt ein konkreter nächster Schritt.';
  }
}
