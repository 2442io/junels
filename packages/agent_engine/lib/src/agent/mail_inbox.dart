// Posteingang lesen (IMAP, nur lesend): Absender, Betreff, Datum und Status der letzten Mails –
// für „Was ist liegengeblieben?“ und Fragen wie „Welche Mails sind unbeantwortet?“.
// Es werden nur Kopfzeilen geholt (BODY.PEEK), Flags bleiben unverändert (EXAMINE statt SELECT).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'tool.dart';

class ImapAccount {
  ImapAccount({required this.host, this.port = 993, required this.user, required this.password, this.secure = true});
  final String host;
  final int port;
  final String user;
  final String password;

  /// false nur für Tests (Klartext).
  final bool secure;

  /// Posteingang-Server aus der Adresse bzw. dem Postausgang ableiten.
  static String? guessHost(String email, {String smtpHost = ''}) {
    final d = email.split('@').last.toLowerCase();
    final known = switch (d) {
      'gmail.com' || 'googlemail.com' => 'imap.gmail.com',
      'outlook.com' || 'hotmail.com' || 'live.com' || 'outlook.at' || 'outlook.de' => 'outlook.office365.com',
      'icloud.com' || 'me.com' || 'mac.com' => 'imap.mail.me.com',
      'gmx.at' || 'gmx.net' || 'gmx.de' => 'imap.gmx.net',
      'web.de' => 'imap.web.de',
      'yahoo.com' || 'yahoo.de' => 'imap.mail.yahoo.com',
      'a1.net' || 'aon.at' => 'securemail.a1.net',
      _ => null,
    };
    if (known != null) return known;
    final s = smtpHost.trim();
    if (s.startsWith('smtp.')) return 'imap.${s.substring(5)}';
    if (s.startsWith('mail.') || s.startsWith('securemail.')) return s;
    return d.isEmpty ? null : 'imap.$d';
  }
}

class MailInfo {
  MailInfo({required this.from, required this.subject, required this.date, this.seen = false, this.answered = false, this.bulk = false});
  final String from;
  final String subject;
  final DateTime? date;
  final bool seen;
  final bool answered;

  /// Newsletter/automatische Mail (List-Unsubscribe, noreply …)
  final bool bulk;

  String get line {
    final d = date == null ? '' : '${date!.day}.${date!.month}. ';
    return '$d${from.isEmpty ? '?' : from} – „${subject.isEmpty ? '(ohne Betreff)' : subject}“${seen ? '' : ' [ungelesen]'}';
  }
}

class ImapException implements Exception {
  ImapException(this.message);
  final String message;
  @override
  String toString() => message;
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Kurzer IMAP-Abruf: Anmelden, INBOX nur ansehen, suchen, Kopfzeilen holen, abmelden.
Future<List<MailInfo>> fetchInbox(ImapAccount acc,
    {int days = 14, bool unansweredOnly = false, bool unseenOnly = false, int max = 40, DateTime? now}) async {
  final Socket socket = acc.secure
      ? await SecureSocket.connect(acc.host, acc.port, timeout: const Duration(seconds: 15))
      : await Socket.connect(acc.host, acc.port, timeout: const Duration(seconds: 15));
  final buf = BytesBuilder(copy: false);
  final chunks = StreamController<void>.broadcast();
  final sub = socket.listen((d) {
    buf.add(d);
    chunks.add(null);
  }, onDone: () => chunks.close(), onError: (_) => chunks.close());
  var data = Uint8List(0);
  var tagN = 0;

  // Liest, bis die Antwort mit [tag] abgeschlossen ist (Literale {n} werden mitgelesen).
  Future<String> until(String? tag) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      if (buf.length > 0) {
        final add = buf.takeBytes();
        data = Uint8List.fromList([...data, ...add]);
      }
      final text = latin1.decode(data);
      final done = tag == null ? text.contains('\r\n') : RegExp('(^|\\r\\n)$tag (OK|NO|BAD)[^\\r\\n]*\\r\\n').hasMatch(text);
      if (done) {
        data = Uint8List(0);
        return utf8.decode(latin1.encode(text), allowMalformed: true);
      }
      if (DateTime.now().isAfter(deadline)) throw ImapException('Zeitüberschreitung beim Mail-Server');
      await chunks.stream.first.timeout(const Duration(seconds: 30), onTimeout: () {});
    }
  }

  Future<String> cmd(String c, {String? shown}) async {
    final tag = 'j${++tagN}';
    socket.write('$tag $c\r\n');
    final r = await until(tag);
    final status = RegExp('(^|\\r\\n)$tag (OK|NO|BAD)([^\\r\\n]*)').firstMatch(r);
    if (status?.group(2) != 'OK') {
      throw ImapException('Mail-Server lehnt „${shown ?? c.split(' ').first}“ ab:${status?.group(3) ?? ''}');
    }
    return r;
  }

  String q(String s) => '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';

  try {
    final hello = await until(null);
    if (!hello.startsWith('* OK') && !hello.startsWith('* PREAUTH')) throw ImapException('Unerwartete Begrüßung des Mail-Servers');
    await cmd('LOGIN ${q(acc.user)} ${q(acc.password)}', shown: 'Anmeldung (Passwort/App-Passwort prüfen)');
    await cmd('EXAMINE INBOX');
    final t = (now ?? DateTime.now()).subtract(Duration(days: days));
    final since = '${t.day}-${_months[t.month - 1]}-${t.year}';
    final crit = ['SINCE $since', 'NOT DELETED', if (unansweredOnly) 'UNANSWERED', if (unseenOnly) 'UNSEEN'].join(' ');
    final s = await cmd('UID SEARCH $crit');
    final ids = [
      for (final m in RegExp(r'\* SEARCH([ \d]*)').allMatches(s))
        for (final x in m.group(1)!.trim().split(RegExp(r'\s+')))
          if (x.isNotEmpty) x
    ];
    if (ids.isEmpty) {
      await cmd('LOGOUT').catchError((_) => '');
      return const [];
    }
    final pick = ids.length > max ? ids.sublist(ids.length - max) : ids;
    final f = await cmd('UID FETCH ${pick.join(',')} (FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE LIST-UNSUBSCRIBE AUTO-SUBMITTED PRECEDENCE)])');
    try {
      await cmd('LOGOUT');
    } catch (_) {}
    return parseFetch(f, self: acc.user).reversed.toList(); // neueste zuerst
  } finally {
    await sub.cancel();
    socket.destroy();
  }
}

/// FETCH-Antwort → Mails (öffentlich für Tests).
List<MailInfo> parseFetch(String r, {String self = ''}) {
  final out = <MailInfo>[];
  final parts = r.split(RegExp(r'(?=\* \d+ FETCH )'));
  for (final p in parts) {
    if (!p.startsWith('* ')) continue;
    final flags = RegExp(r'FLAGS \(([^)]*)\)').firstMatch(p)?.group(1) ?? '';
    final h = <String, String>{};
    String? key;
    for (final line in p.split(RegExp(r'\r?\n'))) {
      if (line.startsWith(' ') || line.startsWith('\t')) {
        if (key != null) h[key] = '${h[key]} ${line.trim()}';
        continue;
      }
      final m = RegExp(r'^([A-Za-z-]+):\s*(.*)$').firstMatch(line);
      if (m != null) {
        key = m.group(1)!.toLowerCase();
        h[key] = m.group(2)!;
      }
    }
    final from = decodeMimeWords(h['from'] ?? '');
    final addr = RegExp(r'<([^>]+)>').firstMatch(from)?.group(1) ?? from;
    if (self.isNotEmpty && addr.toLowerCase() == self.toLowerCase()) continue;
    final name = from.replaceAll(RegExp(r'\s*<[^>]+>'), '').replaceAll('"', '').trim();
    final bulk = h.containsKey('list-unsubscribe') ||
        (h['auto-submitted'] ?? 'no').toLowerCase() != 'no' ||
        RegExp(r'bulk|list|junk', caseSensitive: false).hasMatch(h['precedence'] ?? '') ||
        RegExp(r'no-?reply|newsletter|notification|mailer-daemon|donotreply', caseSensitive: false).hasMatch(addr);
    out.add(MailInfo(
      from: name.isEmpty ? addr : name,
      subject: decodeMimeWords(h['subject'] ?? ''),
      date: _parseDate(h['date'] ?? ''),
      seen: flags.contains(r'\Seen'),
      answered: flags.contains(r'\Answered'),
      bulk: bulk,
    ));
  }
  return out;
}

DateTime? _parseDate(String s) {
  final m = RegExp(r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{1,2}):(\d{2})').firstMatch(s);
  if (m == null) return null;
  final mon = _months.indexWhere((x) => x.toLowerCase() == m.group(2)!.toLowerCase()) + 1;
  if (mon == 0) return null;
  return DateTime(int.parse(m.group(3)!), mon, int.parse(m.group(1)!), int.parse(m.group(4)!), int.parse(m.group(5)!));
}

/// =?UTF-8?B?…?= und =?ISO-8859-1?Q?…?= dekodieren.
String decodeMimeWords(String s) {
  final joined = s.replaceAll(RegExp(r'\?=\s+=\?'), '?==?');
  return joined.replaceAllMapped(RegExp(r'=\?([^?]+)\?([bBqQ])\?([^?]*)\?=', caseSensitive: false), (m) {
    final cs = m.group(1)!.toLowerCase();
    List<int> bytes;
    try {
      if (m.group(2)!.toLowerCase() == 'b') {
        bytes = base64.decode(base64.normalize(m.group(3)!));
      } else {
        final q = m.group(3)!.replaceAll('_', ' ');
        bytes = [];
        for (var i = 0; i < q.length; i++) {
          if (q[i] == '=' && i + 2 < q.length) {
            final hex = int.tryParse(q.substring(i + 1, i + 3), radix: 16);
            if (hex != null) {
              bytes.add(hex);
              i += 2;
              continue;
            }
          }
          bytes.add(q.codeUnitAt(i));
        }
      }
      return cs.contains('utf') ? utf8.decode(bytes, allowMalformed: true) : latin1.decode(bytes);
    } catch (_) {
      return m.group(0)!;
    }
  });
}

/// Werkzeug: Posteingang ansehen (nur Kopfzeilen).
class MailInboxTool extends AgentTool {
  MailInboxTool(this.account);
  final Future<ImapAccount?> Function() account;

  @override
  bool get requiresNetwork => true;
  @override
  String get name => 'mail_inbox';
  @override
  String get title => 'Posteingang ansehen';
  @override
  String get keywords => 'mail mails e-mail posteingang inbox unbeantwortet ungelesen nachrichten';
  @override
  String get description =>
      'Liest Absender, Betreff und Datum der letzten Mails im Posteingang (nur lesen, ohne Inhalt). '
      'filter: "unbeantwortet" (ohne Newsletter), "ungelesen" oder "alle".';
  @override
  List<ToolParam> get params => const [
        ToolParam('filter', ParamType.enumeration, 'Welche Mails', values: ['unbeantwortet', 'ungelesen', 'alle']),
        ToolParam('tage', ParamType.integer, 'Wie viele Tage zurück (Standard 7)'),
      ];

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final acc = await account();
    if (acc == null) {
      return 'Kein Posteingang eingerichtet. Hinweis für den Nutzer: Einstellungen → Verbindungen → Tresor & Konten → Mail-Konto, '
          '„Posteingang lesen“ einschalten.';
    }
    await ctx.ensureNetwork('Posteingang lesen (${acc.host})');
    final filter = (args['filter'] ?? 'unbeantwortet').toString();
    final days = (int.tryParse('${args['tage'] ?? 7}') ?? 7).clamp(1, 60);
    final list = await fetchInbox(acc, days: days, unansweredOnly: filter == 'unbeantwortet', unseenOnly: filter == 'ungelesen');
    final shown = filter == 'alle' ? list : list.where((m) => !m.bulk).toList();
    final skipped = list.length - shown.length;
    if (shown.isEmpty) {
      return 'Keine ${filter == 'alle' ? '' : '$filter '}Mails der letzten $days Tage${skipped > 0 ? ' (außer $skipped Newslettern/automatischen Mails)' : ''}.';
    }
    return '${shown.length} ${filter == 'alle' ? '' : '$filter '}Mails der letzten $days Tage (Quelle: Posteingang ${acc.user}):\n'
        '${shown.take(25).map((m) => '- ${m.line}').join('\n')}'
        '${skipped > 0 ? '\n($skipped Newsletter/automatische Mails ausgeblendet)' : ''}';
  }
}
