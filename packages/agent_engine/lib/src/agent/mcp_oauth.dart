// OAuth-Anmeldung für MCP-Server (MCP-Autorisierung, OAuth 2.1 mit PKCE):
//  1. Server meldet 401 → Metadaten der geschützten Ressource
//     (/.well-known/oauth-protected-resource) → Autorisierungsserver
//  2. Metadaten des Autorisierungsservers (/.well-known/oauth-authorization-server)
//  3. Dynamische Client-Registrierung (RFC 7591) mit Rückleitung auf 127.0.0.1
//  4. Anmeldung im Browser, Code kommt an den lokalen Mini-Server zurück
//  5. Code gegen Token tauschen; später per refresh_token erneuern

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../sync/sync_crypto.dart' show sha256;
import 'mcp.dart';

class McpOAuth {
  /// Wird nach jeder Token-Änderung aufgerufen (zum Speichern).
  static void Function(McpServerConfig config)? onTokens;

  static Future<Map<String, dynamic>?> _getJson(HttpClient c, Uri u) async {
    try {
      final req = await c.getUrl(u);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set('MCP-Protocol-Version', mcpProtocolVersion);
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final j = jsonDecode(await utf8.decodeStream(res));
      return j is Map ? j.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> _postForm(HttpClient c, Uri u, Map<String, String> form) async {
    final req = await c.postUrl(u);
    req.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final body = utf8.encode(Uri(queryParameters: form).query);
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close().timeout(const Duration(seconds: 20));
    final text = await utf8.decodeStream(res);
    Map<String, dynamic> j;
    try {
      j = (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {
      j = Uri.splitQueryString(text);
    }
    if (res.statusCode >= 400 || j['error'] != null) {
      throw McpException('Anmeldung fehlgeschlagen: ${j['error_description'] ?? j['error'] ?? 'HTTP ${res.statusCode}'}');
    }
    return j;
  }

  static String _b64url(List<int> b) => base64Url.encode(b).replaceAll('=', '');

  /// Endpunkte des Autorisierungsservers ermitteln.
  static Future<Map<String, dynamic>> discover(HttpClient c, Uri server, {String? wwwAuthenticate}) async {
    Map<String, dynamic>? prm;
    final hinted = RegExp(r'resource_metadata="([^"]+)"').firstMatch(wwwAuthenticate ?? '')?.group(1);
    final origin = server.replace(path: '', query: null, fragment: null);
    final candidates = [
      if (hinted != null) Uri.parse(hinted),
      if (server.path.isNotEmpty && server.path != '/')
        origin.replace(path: '/.well-known/oauth-protected-resource${server.path}'),
      origin.replace(path: '/.well-known/oauth-protected-resource'),
    ];
    for (final u in candidates) {
      prm = await _getJson(c, u);
      if (prm != null) break;
    }
    final asList = (prm?['authorization_servers'] as List?)?.cast<String>() ?? const [];
    final issuer = Uri.parse(asList.isNotEmpty ? asList.first : origin.toString());
    final iOrigin = issuer.replace(path: '', query: null, fragment: null);
    final ipath = issuer.path == '/' ? '' : issuer.path;
    Map<String, dynamic>? meta;
    for (final u in [
      iOrigin.replace(path: '/.well-known/oauth-authorization-server$ipath'),
      iOrigin.replace(path: '/.well-known/openid-configuration$ipath'),
      if (ipath.isNotEmpty) issuer.replace(path: '$ipath/.well-known/openid-configuration'),
    ]) {
      meta = await _getJson(c, u);
      if (meta != null) break;
    }
    meta ??= {
      'authorization_endpoint': iOrigin.replace(path: '/authorize').toString(),
      'token_endpoint': iOrigin.replace(path: '/token').toString(),
      'registration_endpoint': iOrigin.replace(path: '/register').toString(),
    };
    return {
      ...meta,
      'resource': (prm?['resource'] as String?) ?? server.toString(),
      'scopes': ((prm?['scopes_supported'] as List?) ?? (meta['scopes_supported'] as List?) ?? const []).join(' '),
    };
  }

  /// Anmeldung im Browser. [openBrowser] öffnet die Adresse (in der App mit Hinweis).
  /// Speichert die Tokens in [config.oauth].
  static Future<void> login(
    McpServerConfig config, {
    required Future<void> Function(Uri url) openBrowser,
    String? wwwAuthenticate,
    Duration timeout = const Duration(minutes: 5),
    String clientName = 'Junels',
  }) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final meta = await discover(c, Uri.parse(config.url.trim()), wwwAuthenticate: wwwAuthenticate);
      final redirect = 'http://127.0.0.1:${server.port}/callback';
      final authEp = meta['authorization_endpoint'] as String?;
      final tokenEp = meta['token_endpoint'] as String?;
      final regEp = meta['registration_endpoint'] as String?;
      if (authEp == null || tokenEp == null) throw McpException('Der Server bietet keine Anmeldung an.');
      if (regEp == null) {
        throw McpException('Der Server erlaubt keine automatische App-Registrierung – bitte einen Token als Header eintragen.');
      }
      // Dynamische Registrierung
      final reg = await c.postUrl(Uri.parse(regEp));
      reg.headers.contentType = ContentType.json;
      final regBody = utf8.encode(jsonEncode({
        'client_name': clientName,
        'redirect_uris': [redirect],
        'grant_types': ['authorization_code', 'refresh_token'],
        'response_types': ['code'],
        'token_endpoint_auth_method': 'none',
      }));
      reg.contentLength = regBody.length;
      reg.add(regBody);
      final regRes = await reg.close().timeout(const Duration(seconds: 20));
      final regText = await utf8.decodeStream(regRes);
      if (regRes.statusCode >= 400) throw McpException('App-Registrierung abgelehnt (${regRes.statusCode}): $regText');
      final client = (jsonDecode(regText) as Map).cast<String, dynamic>();
      final clientId = client['client_id'] as String;
      final clientSecret = client['client_secret'] as String?;

      final rnd = Random.secure();
      final verifier = _b64url(List.generate(48, (_) => rnd.nextInt(256)));
      final challenge = _b64url(sha256(ascii.encode(verifier)));
      final state = _b64url(List.generate(16, (_) => rnd.nextInt(256)));
      final scopes = (meta['scopes'] as String?) ?? '';
      final authUrl = Uri.parse(authEp).replace(queryParameters: {
        ...Uri.parse(authEp).queryParameters,
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirect,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'resource': meta['resource'] as String,
        if (scopes.isNotEmpty) 'scope': scopes,
      });

      final code = Completer<String>();
      server.listen((req) async {
        final q = req.uri.queryParameters;
        final ok = req.uri.path == '/callback' && q['state'] == state && q['code'] != null;
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html;
        req.response.write('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
            '<body style="font-family:sans-serif;text-align:center;padding:40px">'
            '<h2>${ok ? '✅ Angemeldet' : '❌ Anmeldung nicht abgeschlossen'}</h2>'
            '<p>${ok ? 'Du kannst zu Junels zurückkehren.' : (q['error_description'] ?? q['error'] ?? '')}</p></body>');
        await req.response.close();
        if (code.isCompleted || req.uri.path != '/callback') return;
        if (ok) {
          code.complete(q['code']!);
        } else if (q['error'] != null) {
          code.completeError(McpException('Anmeldung abgebrochen: ${q['error_description'] ?? q['error']}'));
        }
      });
      await openBrowser(authUrl);
      final authCode = await code.future.timeout(timeout,
          onTimeout: () => throw McpException('Anmeldung nicht abgeschlossen (Zeit abgelaufen).'));
      final tok = await _postForm(c, Uri.parse(tokenEp), {
        'grant_type': 'authorization_code',
        'code': authCode,
        'redirect_uri': redirect,
        'client_id': clientId,
        'code_verifier': verifier,
        'resource': meta['resource'] as String,
        if (clientSecret != null) 'client_secret': clientSecret,
      });
      _store(config, tok, clientId: clientId, clientSecret: clientSecret, tokenEndpoint: tokenEp, resource: meta['resource'] as String);
    } finally {
      await server.close(force: true);
      c.close(force: true);
    }
  }

  static void _store(McpServerConfig config, Map<String, dynamic> tok,
      {String? clientId, String? clientSecret, String? tokenEndpoint, String? resource}) {
    final access = tok['access_token']?.toString();
    if (access == null || access.isEmpty) throw McpException('Kein Zugriffstoken erhalten.');
    final exp = int.tryParse('${tok['expires_in'] ?? ''}');
    config.oauth = {
      ...config.oauth,
      'access_token': access,
      if (tok['refresh_token'] != null) 'refresh_token': tok['refresh_token'].toString(),
      'expires_at': exp == null ? '' : '${DateTime.now().millisecondsSinceEpoch + (exp - 30) * 1000}',
      if (clientId != null) 'client_id': clientId,
      if (clientSecret != null) 'client_secret': clientSecret,
      if (tokenEndpoint != null) 'token_endpoint': tokenEndpoint,
      if (resource != null) 'resource': resource,
    };
    onTokens?.call(config);
  }

  /// Abgelaufenes Token per refresh_token erneuern (still; Fehler → später 401 → neu anmelden).
  static Future<void> ensureFresh(McpServerConfig config) async {
    final o = config.oauth;
    final exp = int.tryParse(o['expires_at'] ?? '');
    if (exp == null || DateTime.now().millisecondsSinceEpoch < exp) return;
    final refresh = o['refresh_token'];
    final ep = o['token_endpoint'];
    if (refresh == null || ep == null) return;
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final tok = await _postForm(c, Uri.parse(ep), {
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
        if (o['client_id'] != null) 'client_id': o['client_id']!,
        if (o['client_secret'] != null) 'client_secret': o['client_secret']!,
        if (o['resource'] != null) 'resource': o['resource']!,
      });
      _store(config, tok);
    } catch (_) {
      config.oauth = {...o, 'access_token': ''};
      onTokens?.call(config);
    } finally {
      c.close(force: true);
    }
  }

  static void logout(McpServerConfig config) {
    config.oauth = {};
    onTokens?.call(config);
  }
}
