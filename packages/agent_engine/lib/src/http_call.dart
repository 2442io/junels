// Web-API-Aufrufe (REST) für Prozesse und OAuth 2.0 / OpenID Connect (z. B. Google, Microsoft,
// eigener SSO). Reines dart:io – Speichern der Zugangsdaten übernimmt die App (Tresor).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'sync/sync_crypto.dart' show sha256;

// =========================================================================== REST

class HttpCallResult {
  HttpCallResult(this.status, this.body, this.headers, this.took);
  final int status;
  final String body;
  final Map<String, String> headers;
  final Duration took;

  bool get ok => status >= 200 && status < 300;

  /// JSON hübsch eingerückt, sonst der Text (gekürzt).
  String get pretty {
    final t = body.trim();
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        final s = const JsonEncoder.withIndent('  ').convert(jsonDecode(t));
        return s.length > 20000 ? '${s.substring(0, 20000)}\n…' : s;
      } catch (_) {}
    }
    return t.length > 20000 ? '${t.substring(0, 20000)}\n…' : t;
  }
}

/// Fehler einer Web-API mit verständlichem Hinweis.
class HttpCallException implements Exception {
  HttpCallException(this.status, this.message, {this.hint = '', this.body = ''});
  final int status;
  final String message;
  final String hint;
  final String body;
  @override
  String toString() => hint.isEmpty ? message : '$message – $hint';
}

/// Was ein HTTP-Status bedeutet und was man tun kann.
String httpStatusHint(int status) => switch (status) {
      400 => 'Die Anfrage ist fehlerhaft: Parameter oder Inhalt (Body) prüfen.',
      401 => 'Anmeldung fehlt oder ist abgelaufen: Zugang (Verbindung) prüfen bzw. neu anmelden.',
      403 => 'Keine Berechtigung: Der Zugang darf das nicht (Rechte/Scopes prüfen).',
      404 => 'Adresse nicht gefunden: URL prüfen.',
      405 => 'Methode nicht erlaubt: GET/POST/PUT prüfen.',
      408 || 504 => 'Der Server antwortet zu langsam – später erneut versuchen.',
      409 => 'Konflikt: Der Eintrag existiert schon oder wurde inzwischen geändert.',
      415 => 'Falsches Format: Content-Type (z. B. application/json) prüfen.',
      422 => 'Inhalt wurde abgelehnt: Pflichtfelder bzw. Format im Body prüfen.',
      429 => 'Zu viele Anfragen: seltener ausführen oder später erneut versuchen.',
      >= 500 => 'Fehler beim Server – meist vorübergehend, später erneut versuchen.',
      _ => '',
    };

/// Führt eine HTTP-Anfrage aus. Wirft [HttpCallException] bei Status ≥ 400.
Future<HttpCallResult> httpCall({
  required String method,
  required Uri url,
  Map<String, String> headers = const {},
  String? body,
  Duration timeout = const Duration(seconds: 45),
  bool throwOnError = true,
}) async {
  if (!url.isScheme('http') && !url.isScheme('https')) {
    throw HttpCallException(0, 'Ungültige Adresse „$url“', hint: 'Die Adresse muss mit https:// beginnen.');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final sw = Stopwatch()..start();
  try {
    final req = await client.openUrl(method.toUpperCase(), url);
    req.headers.set(HttpHeaders.userAgentHeader, 'Junels/1 (+https://github.com/2442io/junels)');
    req.headers.set(HttpHeaders.acceptHeader, 'application/json, text/plain;q=0.9, */*;q=0.5');
    for (final e in headers.entries) {
      if (e.key.trim().isNotEmpty) req.headers.set(e.key.trim(), e.value);
    }
    final b = body ?? '';
    if (b.isNotEmpty) {
      if (!headers.keys.any((k) => k.toLowerCase() == 'content-type')) {
        final t = b.trimLeft();
        req.headers.contentType = t.startsWith('{') || t.startsWith('[')
            ? ContentType.json
            : (t.contains('=') && !t.contains(' ') ? ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8') : ContentType.text);
      }
      final bytes = utf8.encode(b);
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close().timeout(timeout);
    final bytes = await res.fold<List<int>>(<int>[], (a, c) => a..addAll(c)).timeout(timeout);
    final text = utf8.decode(bytes, allowMalformed: true);
    final hs = <String, String>{};
    res.headers.forEach((k, v) => hs[k] = v.join(', '));
    final r = HttpCallResult(res.statusCode, text, hs, sw.elapsed);
    if (throwOnError && res.statusCode >= 400) {
      final short = text.trim().replaceAll(RegExp(r'\s+'), ' ');
      throw HttpCallException(res.statusCode, 'HTTP ${res.statusCode}${short.isEmpty ? '' : ': ${short.length > 200 ? '${short.substring(0, 200)}…' : short}'}',
          hint: httpStatusHint(res.statusCode), body: text);
    }
    return r;
  } on TimeoutException {
    throw HttpCallException(408, 'Zeitüberschreitung nach ${timeout.inSeconds} s', hint: httpStatusHint(408));
  } on SocketException catch (e) {
    throw HttpCallException(0, 'Server nicht erreichbar (${e.message})', hint: 'Internetverbindung und Adresse prüfen.');
  } on HandshakeException catch (e) {
    throw HttpCallException(0, 'Sichere Verbindung fehlgeschlagen ($e)', hint: 'Zertifikat des Servers prüfen.');
  } finally {
    client.close(force: true);
  }
}

/// Liest einen Wert aus JSON per Pfad, z. B. „items.0.title“ oder „data.temp“.
Object? jsonPath(Object? json, String path) {
  Object? cur = json;
  for (final part in path.split('.').where((p) => p.isNotEmpty)) {
    if (cur is Map) {
      cur = cur[part];
    } else if (cur is List) {
      final i = int.tryParse(part);
      if (i == null || i < 0 || i >= cur.length) return null;
      cur = cur[i];
    } else {
      return null;
    }
  }
  return cur;
}

// ========================================================================= OAuth 2

/// Einstellungen eines OAuth-2.0-Zugangs (Authorization Code mit PKCE oder Client Credentials).
class OAuth2Config {
  OAuth2Config({
    required this.authEndpoint,
    required this.tokenEndpoint,
    required this.clientId,
    this.clientSecret,
    this.scopes = '',
    this.extraAuthParams = const {},
  });
  final String authEndpoint;
  final String tokenEndpoint;
  final String clientId;
  final String? clientSecret;
  final String scopes;
  final Map<String, String> extraAuthParams;
}

class OAuth2Exception implements Exception {
  OAuth2Exception(this.message);
  final String message;
  @override
  String toString() => message;
}

class OAuth2 {
  static String _b64url(List<int> b) => base64Url.encode(b).replaceAll('=', '');

  /// OpenID-Connect-Metadaten eines Anbieters (z. B. https://accounts.google.com oder https://sso.2442.io).
  static Future<Map<String, String>> discover(String issuer) async {
    var base = issuer.trim();
    if (!base.startsWith('http')) base = 'https://$base';
    base = base.replaceFirst(RegExp(r'/+$'), '');
    final url = base.endsWith('/.well-known/openid-configuration') ? base : '$base/.well-known/openid-configuration';
    final r = await httpCall(method: 'GET', url: Uri.parse(url), timeout: const Duration(seconds: 15));
    final j = jsonDecode(r.body);
    if (j is! Map) throw OAuth2Exception('Keine OpenID-Konfiguration unter $url');
    return {
      if (j['authorization_endpoint'] != null) 'auth': j['authorization_endpoint'].toString(),
      if (j['token_endpoint'] != null) 'token': j['token_endpoint'].toString(),
      if (j['userinfo_endpoint'] != null) 'userinfo': j['userinfo_endpoint'].toString(),
    };
  }

  static Future<Map<String, dynamic>> _token(String endpoint, Map<String, String> form) async {
    final r = await httpCall(
      method: 'POST',
      url: Uri.parse(endpoint),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: Uri(queryParameters: form).query,
      throwOnError: false,
      timeout: const Duration(seconds: 25),
    );
    Map<String, dynamic> j;
    try {
      j = (jsonDecode(r.body) as Map).cast<String, dynamic>();
    } catch (_) {
      j = Uri.splitQueryString(r.body);
    }
    if (r.status >= 400 || j['error'] != null) {
      throw OAuth2Exception('Anmeldung abgelehnt: ${j['error_description'] ?? j['error'] ?? 'HTTP ${r.status}'}');
    }
    return j;
  }

  static Map<String, String> _store(Map<String, dynamic> tok, {String? oldRefresh}) {
    final access = tok['access_token']?.toString() ?? '';
    if (access.isEmpty) throw OAuth2Exception('Kein Zugriffstoken erhalten.');
    final exp = int.tryParse('${tok['expires_in'] ?? ''}');
    return {
      'access_token': access,
      if ((tok['refresh_token'] ?? oldRefresh) != null) 'refresh_token': (tok['refresh_token'] ?? oldRefresh).toString(),
      if (exp != null) 'expires_at': DateTime.now().add(Duration(seconds: exp - 30)).toIso8601String(),
      if (tok['id_token'] != null) 'id_token': tok['id_token'].toString(),
    };
  }

  /// Anmeldung im Browser (Authorization Code + PKCE, Rückleitung auf 127.0.0.1).
  static Future<Map<String, String>> login(
    OAuth2Config c, {
    required Future<void> Function(Uri url) openBrowser,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirect = 'http://127.0.0.1:${server.port}/';
      final rnd = Random.secure();
      final verifier = _b64url(List.generate(48, (_) => rnd.nextInt(256)));
      final challenge = _b64url(sha256(ascii.encode(verifier)));
      final state = _b64url(List.generate(16, (_) => rnd.nextInt(256)));
      final base = Uri.parse(c.authEndpoint);
      final authUrl = base.replace(queryParameters: {
        ...base.queryParameters,
        'response_type': 'code',
        'client_id': c.clientId,
        'redirect_uri': redirect,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        if (c.scopes.trim().isNotEmpty) 'scope': c.scopes.trim(),
        ...c.extraAuthParams,
      });
      final code = Completer<String>();
      server.listen((req) async {
        final q = req.uri.queryParameters;
        final ok = q['state'] == state && q['code'] != null;
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html;
        req.response.write('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
            '<body style="font-family:sans-serif;text-align:center;padding:40px">'
            '<h2>${ok ? '✅ Angemeldet' : (q['error'] != null ? '❌ Anmeldung abgebrochen' : '…')}</h2>'
            '<p>${ok ? 'Du kannst zu Junels zurückkehren.' : (q['error_description'] ?? q['error'] ?? '')}</p></body>');
        await req.response.close();
        if (code.isCompleted) return;
        if (ok) {
          code.complete(q['code']!);
        } else if (q['error'] != null) {
          code.completeError(OAuth2Exception('Anmeldung abgebrochen: ${q['error_description'] ?? q['error']}'));
        }
      });
      await openBrowser(authUrl);
      final authCode = await code.future.timeout(timeout, onTimeout: () => throw OAuth2Exception('Anmeldung nicht abgeschlossen (Zeit abgelaufen).'));
      final tok = await _token(c.tokenEndpoint, {
        'grant_type': 'authorization_code',
        'code': authCode,
        'redirect_uri': redirect,
        'client_id': c.clientId,
        'code_verifier': verifier,
        if (c.clientSecret != null && c.clientSecret!.isNotEmpty) 'client_secret': c.clientSecret!,
      });
      return _store(tok);
    } finally {
      await server.close(force: true);
    }
  }

  /// Maschinen-Zugang ohne Browser (Client Credentials).
  static Future<Map<String, String>> clientCredentials(OAuth2Config c) async {
    final tok = await _token(c.tokenEndpoint, {
      'grant_type': 'client_credentials',
      'client_id': c.clientId,
      if (c.clientSecret != null && c.clientSecret!.isNotEmpty) 'client_secret': c.clientSecret!,
      if (c.scopes.trim().isNotEmpty) 'scope': c.scopes.trim(),
    });
    return _store(tok);
  }

  /// Zugriffstoken mit dem refresh_token erneuern.
  static Future<Map<String, String>> refresh(OAuth2Config c, String refreshToken) async {
    final tok = await _token(c.tokenEndpoint, {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': c.clientId,
      if (c.clientSecret != null && c.clientSecret!.isNotEmpty) 'client_secret': c.clientSecret!,
    });
    return _store(tok, oldRefresh: refreshToken);
  }

  static bool expired(Map<String, String> tokens) {
    final e = DateTime.tryParse(tokens['expires_at'] ?? '');
    return e != null && DateTime.now().isAfter(e);
  }
}
