// Zugänge (Verbindungen) für Web-APIs in Prozessen: API-Schlüssel, Bearer-Token,
// Benutzername/Passwort oder OAuth 2.0 / SSO (Google, Microsoft, eigener Anbieter).
// Geheimnisse liegen im Tresor, in connections.json nur die Einstellungen.

import 'dart:convert';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';

import '../data/models.dart';
import 'app_controller.dart';
import 'background_work.dart';
import 'native_files.dart';
import 'vault.dart';
import 'voice_service.dart' show appLog;

enum AuthKind {
  none('Ohne Anmeldung'),
  apiKey('API-Schlüssel'),
  bearer('Bearer-Token'),
  basic('Benutzer & Passwort'),
  oauth('OAuth / SSO (Browser)'),
  clientCredentials('OAuth Client Credentials');

  const AuthKind(this.label);
  final String label;
}

/// Vorlagen für bekannte Anbieter.
class OAuthPreset {
  const OAuthPreset(this.id, this.name, this.auth, this.token, this.scopes, {this.extra = const {}, this.issuer = '', this.help = ''});
  final String id;
  final String name;
  final String auth;
  final String token;
  final String scopes;
  final Map<String, String> extra;
  final String issuer;
  final String help;

  static const all = [
    OAuthPreset('google', 'Google', 'https://accounts.google.com/o/oauth2/v2/auth', 'https://oauth2.googleapis.com/token',
        'openid email https://www.googleapis.com/auth/calendar.readonly',
        extra: {'access_type': 'offline', 'prompt': 'consent'},
        help: 'In der Google Cloud Console unter „APIs & Dienste → Anmeldedaten“ eine OAuth-Client-ID vom Typ '
            '„Desktop-App“ anlegen und Client-ID und -Secret hier eintragen. Scopes je nach API, z. B. '
            'https://www.googleapis.com/auth/gmail.readonly'),
    OAuthPreset('microsoft', 'Microsoft 365', 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
        'https://login.microsoftonline.com/common/oauth2/v2.0/token', 'offline_access User.Read',
        help: 'Im Azure-Portal eine App registrieren (Plattform „Mobil und Desktop“, Umleitung http://localhost) und die '
            'Anwendungs-ID als Client-ID eintragen.'),
    OAuthPreset('github', 'GitHub', 'https://github.com/login/oauth/authorize', 'https://github.com/login/oauth/access_token', 'repo',
        help: 'Unter GitHub → Settings → Developer settings → OAuth Apps eine App mit Callback http://127.0.0.1 anlegen.'),
    OAuthPreset('oidc', 'Eigener SSO (OpenID Connect)', '', '', 'openid profile email',
        help: 'Adresse des Anbieters (Issuer, z. B. https://sso.2442.io) eintragen und „Endpunkte suchen“ tippen. '
            'Als Rückleitung http://127.0.0.1 erlauben.'),
  ];
}

class ApiConnection {
  ApiConnection({
    required this.id,
    required this.name,
    this.kind = AuthKind.none,
    this.baseUrl = '',
    this.headerName = 'Authorization',
    this.keyInQuery = false,
    this.username = '',
    this.preset = '',
    this.issuer = '',
    this.authUrl = '',
    this.tokenUrl = '',
    this.clientId = '',
    this.scopes = '',
    Map<String, String>? extra,
    this.signedInAs = '',
  }) : extra = extra ?? {};

  final String id;
  String name;
  AuthKind kind;

  /// Basisadresse (optional): Bausteine können dann relative Pfade („/v1/items“) nutzen.
  String baseUrl;

  /// API-Schlüssel: Name des Headers (z. B. „X-API-Key“) bzw. des Parameters bei [keyInQuery].
  String headerName;
  bool keyInQuery;
  String username;

  String preset;
  String issuer;
  String authUrl;
  String tokenUrl;
  String clientId;
  String scopes;
  final Map<String, String> extra;

  /// Anzeige nach der Anmeldung (z. B. E-Mail aus dem id_token).
  String signedInAs;

  bool get isOAuth => kind == AuthKind.oauth || kind == AuthKind.clientCredentials;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        if (baseUrl.isNotEmpty) 'baseUrl': baseUrl,
        'headerName': headerName,
        if (keyInQuery) 'keyInQuery': true,
        if (username.isNotEmpty) 'username': username,
        if (preset.isNotEmpty) 'preset': preset,
        if (issuer.isNotEmpty) 'issuer': issuer,
        if (authUrl.isNotEmpty) 'authUrl': authUrl,
        if (tokenUrl.isNotEmpty) 'tokenUrl': tokenUrl,
        if (clientId.isNotEmpty) 'clientId': clientId,
        if (scopes.isNotEmpty) 'scopes': scopes,
        if (extra.isNotEmpty) 'extra': extra,
        if (signedInAs.isNotEmpty) 'signedInAs': signedInAs,
      };

  factory ApiConnection.fromJson(Map<String, dynamic> j) => ApiConnection(
        id: j['id'].toString(),
        name: (j['name'] ?? 'Zugang').toString(),
        kind: AuthKind.values.where((k) => k.name == j['kind']).firstOrNull ?? AuthKind.none,
        baseUrl: (j['baseUrl'] ?? '').toString(),
        headerName: (j['headerName'] ?? 'Authorization').toString(),
        keyInQuery: j['keyInQuery'] == true,
        username: (j['username'] ?? '').toString(),
        preset: (j['preset'] ?? '').toString(),
        issuer: (j['issuer'] ?? '').toString(),
        authUrl: (j['authUrl'] ?? '').toString(),
        tokenUrl: (j['tokenUrl'] ?? '').toString(),
        clientId: (j['clientId'] ?? '').toString(),
        scopes: (j['scopes'] ?? '').toString(),
        extra: (j['extra'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())),
        signedInAs: (j['signedInAs'] ?? '').toString(),
      );
}

class ConnectionStore {
  ConnectionStore(this.app);
  final AppController app;
  final List<ApiConnection> items = [];

  /// Zuletzt geladene Tokens (nur im Speicher).
  final Map<String, Map<String, String>> _tokens = {};

  File get _file => File('${app.storage.root.path}/connections.json');

  static String _k(String id, String field) => 'conn:$id:$field';

  ApiConnection? byId(String id) => items.where((c) => c.id == id).firstOrNull;

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final j = jsonDecode(await _file.readAsString()) as List;
      items
        ..clear()
        ..addAll([for (final x in j) ApiConnection.fromJson((x as Map).cast())]);
    } catch (e) {
      appLog('Zugänge', 'Laden fehlgeschlagen: $e', error: true);
    }
  }

  Future<void> save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final c in items) c.toJson()]));
    await tmp.rename(_file.path);
  }

  Future<void> upsert(ApiConnection c, {String? secret, String? clientSecret}) async {
    final i = items.indexWhere((x) => x.id == c.id);
    if (i >= 0) {
      items[i] = c;
    } else {
      items.add(c);
    }
    if (secret != null) await Vault.write(_k(c.id, 'secret'), secret.isEmpty ? null : secret);
    if (clientSecret != null) await Vault.write(_k(c.id, 'client_secret'), clientSecret.isEmpty ? null : clientSecret);
    await save();
    app.refreshUi();
  }

  Future<void> remove(ApiConnection c) async {
    items.removeWhere((x) => x.id == c.id);
    _tokens.remove(c.id);
    for (final f in const ['secret', 'client_secret', 'tokens']) {
      await Vault.delete(_k(c.id, f));
    }
    await save();
    app.refreshUi();
  }

  Future<bool> hasSecret(ApiConnection c) async => ((await Vault.read(_k(c.id, 'secret'))) ?? '').isNotEmpty;

  Future<Map<String, String>> _loadTokens(ApiConnection c) async {
    final cached = _tokens[c.id];
    if (cached != null) return cached;
    final raw = await Vault.read(_k(c.id, 'tokens'));
    if (raw == null || raw.isEmpty) return {};
    try {
      final t = (jsonDecode(raw) as Map).map((k, v) => MapEntry(k.toString(), v.toString()));
      _tokens[c.id] = t;
      return t;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveTokens(ApiConnection c, Map<String, String> t) async {
    _tokens[c.id] = t;
    await Vault.write(_k(c.id, 'tokens'), jsonEncode(t));
  }

  Future<bool> signedIn(ApiConnection c) async => (await _loadTokens(c))['access_token']?.isNotEmpty == true;

  Future<OAuth2Config> _oauthConfig(ApiConnection c) async {
    var auth = c.authUrl, token = c.tokenUrl;
    if ((auth.isEmpty || token.isEmpty) && c.issuer.isNotEmpty) {
      final d = await OAuth2.discover(c.issuer);
      auth = d['auth'] ?? auth;
      token = d['token'] ?? token;
      c
        ..authUrl = auth
        ..tokenUrl = token;
      await save();
    }
    if (token.isEmpty || (c.kind == AuthKind.oauth && auth.isEmpty)) {
      throw OAuth2Exception('Anmelde-Endpunkte fehlen (Issuer eintragen oder Adressen angeben).');
    }
    if (c.clientId.trim().isEmpty) throw OAuth2Exception('Client-ID fehlt.');
    return OAuth2Config(
      authEndpoint: auth,
      tokenEndpoint: token,
      clientId: c.clientId.trim(),
      clientSecret: await Vault.read(_k(c.id, 'client_secret')),
      scopes: c.scopes,
      extraAuthParams: c.extra,
    );
  }

  /// Anmeldung im Browser bzw. per Client Credentials. Gibt null oder eine Fehlermeldung zurück.
  Future<String?> signIn(ApiConnection c) async {
    try {
      final cfg = await _oauthConfig(c);
      Map<String, String> t;
      if (c.kind == AuthKind.clientCredentials) {
        t = await OAuth2.clientCredentials(cfg);
      } else {
        await BackgroundWork.begin('oauth-${c.id}', 'Warte auf Anmeldung bei ${c.name} …');
        try {
          t = await OAuth2.login(cfg, openBrowser: (u) => NativeFiles.openUrl(u.toString()));
        } finally {
          await BackgroundWork.end('oauth-${c.id}');
        }
      }
      await _saveTokens(c, t);
      c.signedInAs = _whoFromIdToken(t['id_token']) ?? c.signedInAs;
      await save();
      appLog('Zugänge', '${c.name}: angemeldet');
      app.refreshUi();
      return null;
    } catch (e) {
      appLog('Zugänge', '${c.name}: Anmeldung fehlgeschlagen: $e', error: true);
      return '$e';
    }
  }

  Future<void> signOut(ApiConnection c) async {
    _tokens.remove(c.id);
    await Vault.delete(_k(c.id, 'tokens'));
    c.signedInAs = '';
    await save();
    app.refreshUi();
  }

  static String? _whoFromIdToken(String? jwt) {
    if (jwt == null) return null;
    try {
      final parts = jwt.split('.');
      if (parts.length < 2) return null;
      final j = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map;
      return (j['email'] ?? j['preferred_username'] ?? j['name'] ?? j['sub'])?.toString();
    } catch (_) {
      return null;
    }
  }

  /// Fertige Anfrage-Daten (Header bzw. Abfrage-Parameter) für einen Zugang.
  /// Erneuert abgelaufene OAuth-Tokens automatisch.
  Future<(Map<String, String>, Map<String, String>)> authFor(ApiConnection c) async {
    final headers = <String, String>{};
    final query = <String, String>{};
    switch (c.kind) {
      case AuthKind.none:
        break;
      case AuthKind.apiKey:
        final key = await Vault.read(_k(c.id, 'secret')) ?? '';
        if (key.isEmpty) throw Exception('Zugang „${c.name}“: API-Schlüssel fehlt.');
        final name = c.headerName.trim().isEmpty ? 'X-API-Key' : c.headerName.trim();
        if (c.keyInQuery) {
          query[name] = key;
        } else {
          headers[name] = key;
        }
      case AuthKind.bearer:
        final tok = await Vault.read(_k(c.id, 'secret')) ?? '';
        if (tok.isEmpty) throw Exception('Zugang „${c.name}“: Token fehlt.');
        headers['Authorization'] = tok.toLowerCase().startsWith('bearer ') ? tok : 'Bearer $tok';
      case AuthKind.basic:
        final pw = await Vault.read(_k(c.id, 'secret')) ?? '';
        headers['Authorization'] = 'Basic ${base64.encode(utf8.encode('${c.username}:$pw'))}';
      case AuthKind.oauth:
      case AuthKind.clientCredentials:
        var t = await _loadTokens(c);
        if ((t['access_token'] ?? '').isEmpty) {
          if (c.kind == AuthKind.clientCredentials) {
            final err = await signIn(c);
            if (err != null) throw Exception('Zugang „${c.name}“: $err');
            t = await _loadTokens(c);
          } else {
            throw Exception('Zugang „${c.name}“: nicht angemeldet – in den Zugängen „Anmelden“ tippen.');
          }
        } else if (OAuth2.expired(t)) {
          final cfg = await _oauthConfig(c);
          final rt = t['refresh_token'];
          if (rt != null && rt.isNotEmpty) {
            t = await OAuth2.refresh(cfg, rt);
            await _saveTokens(c, t);
          } else if (c.kind == AuthKind.clientCredentials) {
            t = await OAuth2.clientCredentials(cfg);
            await _saveTokens(c, t);
          } else {
            throw Exception('Zugang „${c.name}“: Anmeldung abgelaufen – bitte neu anmelden.');
          }
        }
        headers['Authorization'] = 'Bearer ${t['access_token']}';
    }
    return (headers, query);
  }

  /// Neuer leerer Zugang.
  ApiConnection create(String name) => ApiConnection(id: newId(), name: name);
}
