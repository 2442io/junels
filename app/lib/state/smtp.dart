// Minimaler SMTP-Versand (für „Senden“ auf der E-Mail-Karte).
// Port 465: TLS sofort; 587: STARTTLS. Anmeldung mit AUTH PLAIN bzw. LOGIN.
// Bei Gmail braucht es ein App-Passwort (Google-Konto → Sicherheit → App-Passwörter).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class SmtpException implements Exception {
  SmtpException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Nur für Tests: selbst signierte Zertifikate annehmen.
bool Function(X509Certificate)? smtpBadCertificate;

class SmtpAccount {
  SmtpAccount({required this.host, required this.port, required this.user, required this.password, String? from, bool? implicitTls})
      : from = (from == null || from.isEmpty) ? user : from,
        implicitTls = implicitTls ?? port == 465;
  final String host;
  final int port;
  final bool implicitTls; // 465: TLS sofort, sonst STARTTLS
  final String user;
  final String password;
  final String from;

  /// Bekannte Anbieter: Server aus der Adresse ableiten.
  static (String, int)? guessServer(String email) {
    final d = email.split('@').last.toLowerCase();
    return switch (d) {
      'gmail.com' || 'googlemail.com' => ('smtp.gmail.com', 465),
      'outlook.com' || 'hotmail.com' || 'live.com' || 'outlook.at' || 'outlook.de' => ('smtp-mail.outlook.com', 587),
      'icloud.com' || 'me.com' || 'mac.com' => ('smtp.mail.me.com', 587),
      'gmx.at' || 'gmx.net' || 'gmx.de' => ('mail.gmx.net', 465),
      'web.de' => ('smtp.web.de', 587),
      'yahoo.com' || 'yahoo.de' => ('smtp.mail.yahoo.com', 465),
      'a1.net' || 'aon.at' => ('securemail.a1.net', 465),
      _ => null,
    };
  }
}

class _Conn {
  _Conn(this.socket) {
    _sub = socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(_lines.add);
  }
  Socket socket;
  final _lines = StreamController<String>();
  late StreamSubscription<String> _sub;
  late final StreamIterator<String> _it = StreamIterator(_lines.stream);

  Future<(int, String)> read() async {
    final buf = StringBuffer();
    while (true) {
      if (!await _it.moveNext().timeout(const Duration(seconds: 30))) throw SmtpException('Verbindung getrennt');
      final l = _it.current;
      buf.writeln(l);
      if (l.length < 4 || l[3] != '-') return (int.tryParse(l.substring(0, l.length < 3 ? l.length : 3)) ?? 0, buf.toString().trim());
    }
  }

  Future<(int, String)> cmd(String c, {List<int> ok = const [250], String? shown}) async {
    socket.write('$c\r\n');
    final r = await read();
    if (!ok.contains(r.$1)) throw SmtpException('Server lehnt „${shown ?? c.split(' ').first}“ ab: ${r.$2}');
    return r;
  }

  Future<void> close() async {
    await _it.cancel();
    await _sub.cancel();
    unawaited(_lines.close());
    socket.destroy();
  }
}

/// Schickt eine Mail; wirft [SmtpException] mit verständlicher Meldung.
Future<void> sendMail(SmtpAccount a,
    {required String to, required String subject, required String body, bool allowInsecure = false}) async {
  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(to)) throw SmtpException('Keine gültige Empfänger-Adresse: „$to“');
  Socket s;
  try {
    s = a.implicitTls
        ? await SecureSocket.connect(a.host, a.port, timeout: const Duration(seconds: 20), onBadCertificate: smtpBadCertificate)
        : await Socket.connect(a.host, a.port, timeout: const Duration(seconds: 20));
  } catch (e) {
    throw SmtpException('Mailserver ${a.host}:${a.port} nicht erreichbar ($e)');
  }
  var c = _Conn(s);
  try {
    final hello = await c.read();
    if (hello.$1 != 220) throw SmtpException('Mailserver antwortet nicht richtig: ${hello.$2}');
    var ehlo = await c.cmd('EHLO junels.local');
    if (!a.implicitTls && !allowInsecure) {
      if (!ehlo.$2.toUpperCase().contains('STARTTLS')) throw SmtpException('Server bietet keine Verschlüsselung (STARTTLS) an');
      await c.cmd('STARTTLS', ok: const [220]);
      // Lesestrom nicht abbrechen (das würde die Verbindung schließen) – TLS übernimmt den Socket
      final secured = await SecureSocket.secure(c.socket, host: a.host, onBadCertificate: smtpBadCertificate);
      c = _Conn(secured);
      ehlo = await c.cmd('EHLO junels.local');
    }
    final caps = ehlo.$2.toUpperCase();
    if (caps.contains('AUTH') && caps.contains('PLAIN')) {
      await c.cmd('AUTH PLAIN ${base64.encode(utf8.encode('\u0000${a.user}\u0000${a.password}'))}',
          ok: const [235], shown: 'Anmeldung');
    } else {
      await c.cmd('AUTH LOGIN', ok: const [334]);
      await c.cmd(base64.encode(utf8.encode(a.user)), ok: const [334], shown: 'Benutzername');
      await c.cmd(base64.encode(utf8.encode(a.password)), ok: const [235], shown: 'Passwort');
    }
    await c.cmd('MAIL FROM:<${a.from}>');
    await c.cmd('RCPT TO:<$to>', ok: const [250, 251]);
    await c.cmd('DATA', ok: const [354]);
    String enc(String h) => '=?UTF-8?B?${base64.encode(utf8.encode(h))}?=';
    final date = HttpDate.format(DateTime.now()).replaceFirst('GMT', '+0000');
    final msg = StringBuffer()
      ..write('From: ${a.from}\r\n')
      ..write('To: $to\r\n')
      ..write('Subject: ${enc(subject)}\r\n')
      ..write('Date: $date\r\n')
      ..write('MIME-Version: 1.0\r\n')
      ..write('Content-Type: text/plain; charset=utf-8\r\n')
      ..write('Content-Transfer-Encoding: base64\r\n\r\n');
    final b64 = base64.encode(utf8.encode(body.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n')));
    for (var i = 0; i < b64.length; i += 76) {
      msg.write('${b64.substring(i, i + 76 > b64.length ? b64.length : i + 76)}\r\n');
    }
    await c.cmd('$msg.', shown: 'Nachricht');
    try {
      c.socket.write('QUIT\r\n');
    } catch (_) {}
  } on SmtpException {
    rethrow;
  } catch (e) {
    throw SmtpException('Senden fehlgeschlagen: $e');
  } finally {
    try {
      await c.close();
    } catch (_) {}
  }
}
