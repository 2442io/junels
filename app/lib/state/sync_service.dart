// Abgleich von Chats, Gedächtnis, Prompts, Profilen, MCP-Servern und Wissensbasis
// zwischen den eigenen Geräten – über den eigenen Server (PHP) oder direkt im WLAN.

import 'usage_stats.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../version.dart';
import 'app_controller.dart';
import 'memory_store.dart';
import 'native_files.dart';
import 'skills.dart';
import 'vault.dart';
import 'voice_service.dart' show appLog;

/// Was abgeglichen wird.
enum SyncCategory {
  chats('chat', 'Chats'),
  memory('mem', 'Gedächtnis'),
  prompts('prompt', 'Meine Prompts'),
  profiles('profile', 'Profile'),
  mcp('mcp', 'MCP-Server'),
  knowledge('kb', 'Wissensbasis'),
  setups('setup', 'Geräte-Setups'),
  designs('design', 'Eigene Designs'),
  skills('skill', 'Skills');

  const SyncCategory(this.prefix, this.label);
  final String prefix;
  final String label;
}

/// Datenschutz-Stufen: was das Konto speichern darf (immer Ende-zu-Ende verschlüsselt).
class PrivacyLevel {
  const PrivacyLevel(this.level, this.title, this.text, this.categories, this.icon);
  final int level;
  final String title;
  final String text;
  final Set<String> categories;
  final String icon;

  static const all = [
    PrivacyLevel(0, 'Nur dieses Gerät', 'Nichts verlässt das Gerät. Kein Konto, kein Abgleich.', {}, '🔒'),
    PrivacyLevel(1, 'Konto ohne Daten', 'Mit SSO angemeldet – nur deine Identität. Es werden keine Daten gespeichert.', {}, '🪪'),
    PrivacyLevel(2, 'Einstellungen', 'Geräte-Setups, Prompt-Vorlagen, Skills, Agenten-Profile, Designs und MCP-Server. Keine Inhalte.',
        {'setup', 'design', 'prompt', 'skill', 'profile', 'mcp'}, '⚙️'),
    PrivacyLevel(3, '+ Gedächtnis & Wissen', 'Zusätzlich, was sich der Agent über dich merkt, und deine Wissensbasis.',
        {'setup', 'design', 'prompt', 'skill', 'profile', 'mcp', 'mem', 'kb'}, '🧠'),
    PrivacyLevel(4, 'Alles', 'Zusätzlich alle Chats – volle Übergabe zwischen deinen Geräten.',
        {'setup', 'design', 'prompt', 'skill', 'profile', 'mcp', 'mem', 'kb', 'chat'}, '☁️'),
  ];
}

class SyncConfig {
  SyncConfig({
    this.level = -1,
    this.ssoName = '',
    this.ssoEmail = '',
    this.serverUrl = '',
    this.auto = true,
    this.lanHost = false,
    Set<String>? categories,
    this.deviceName = '',
    this.deviceId = '',
    this.shareStats = true,
  }) : categories = categories ?? SyncCategory.values.map((c) => c.prefix).toSet();

  /// Datenschutz-Stufe 0–4 (-1 = eigene Auswahl der Kategorien, wie bisher)
  int level;
  String ssoName;
  String ssoEmail;
  String serverUrl;
  bool auto; // beim Start und alle 15 Minuten mit dem Server abgleichen
  bool lanHost; // dieses Gerät im WLAN bereitstellen
  Set<String> categories;
  String deviceName;

  /// Zufällige Kennung dieses Geräts (für die Geräteliste auf dem Server)
  String deviceId;

  /// Auswertung (nur Zahlen) im Admin-Bereich zeigen
  bool shareStats;

  Map<String, Object> toJson() => {
        'serverUrl': serverUrl,
        'auto': auto,
        'lanHost': lanHost,
        'categories': categories.toList(),
        'deviceName': deviceName,
        if (deviceId.isNotEmpty) 'deviceId': deviceId,
        'shareStats': shareStats,
        'level': level,
        if (ssoName.isNotEmpty) 'ssoName': ssoName,
        if (ssoEmail.isNotEmpty) 'ssoEmail': ssoEmail,
      };
  factory SyncConfig.fromJson(Map<String, dynamic> j) => SyncConfig(
        serverUrl: j['serverUrl'] as String? ?? '',
        auto: j['auto'] as bool? ?? true,
        lanHost: j['lanHost'] as bool? ?? false,
        categories: (j['categories'] as List?)?.cast<String>().toSet(),
        deviceName: j['deviceName'] as String? ?? '',
        deviceId: j['deviceId'] as String? ?? '',
        shareStats: j['shareStats'] as bool? ?? true,
        level: (j['level'] as num?)?.toInt() ?? -1,
        ssoName: j['ssoName'] as String? ?? '',
        ssoEmail: j['ssoEmail'] as String? ?? '',
      );
}

class SyncService implements SyncSource {
  SyncService(this.app);
  final AppController app;

  SyncConfig config = SyncConfig();
  SyncKeys? _keys;
  SyncEngine? _engine;
  final SyncHub _hub = SyncHub();
  LanSyncHost? _host;
  Timer? _timer;

  final busy = ValueNotifier<bool>(false);
  final status = ValueNotifier<String>('');
  final lastError = ValueNotifier<String?>(null);
  DateTime? lastSync;

  bool get configured => _keys != null;
  bool get hosting => _host?.running ?? false;

  File get _configFile => File('${app.storage.root.path}/sync.json');
  File get _keyFile => File('${app.storage.root.path}/sync_key');

  String get defaultName => Platform.isMacOS ? 'Mac' : (Platform.isAndroid ? 'Android' : Platform.operatingSystem);

  Future<void> init() async {
    try {
      if (await _configFile.exists()) {
        config = SyncConfig.fromJson((jsonDecode(await _configFile.readAsString()) as Map).cast());
      }
      if (await _keyFile.exists()) {
        final hex = (await _keyFile.readAsString()).trim();
        if (hex.length == 64) _setKeys(SyncKeys.fromMaster(_unhex(hex)));
      }
    } catch (e) {
      appLog('Sync', 'Einstellungen nicht lesbar: $e', error: true);
    }
    if (config.deviceName.isEmpty) config.deviceName = defaultName;
    if (config.deviceId.isEmpty) {
      final r = Random.secure();
      config.deviceId = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      unawaited(saveConfig());
    }
    if (configured && config.lanHost) unawaited(startHost());
    _schedule();
    if (configured && config.auto && config.serverUrl.isNotEmpty) {
      unawaited(Future<void>.delayed(const Duration(seconds: 8), () => syncServer(quiet: true)));
    }
  }

  static List<int> _unhex(String h) => [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];

  void _setKeys(SyncKeys k) {
    _keys = k;
    _engine = SyncEngine(keys: k, source: this, stateFile: File('${app.storage.root.path}/sync_state.json'));
    _hub.items.clear();
  }

  Future<void> saveConfig() async {
    await _configFile.writeAsString(jsonEncode(config.toJson()));
    _schedule();
    app.refreshUi();
  }

  /// Sync-Passwort setzen (auf allen Geräten gleich).
  Future<void> setPassphrase(String passphrase) async {
    if (passphrase.trim().length < 8) throw SyncException('Bitte mindestens 8 Zeichen verwenden.');
    busy.value = true;
    status.value = 'Schlüssel wird berechnet …';
    try {
      final master = await compute(_derive, passphrase);
      await _keyFile.writeAsString(master);
      _setKeys(SyncKeys.fromMaster(_unhex(master)));
      if (config.lanHost) {
        await stopHost();
        await startHost();
      }
      status.value = 'Sync-Passwort gespeichert';
      appLog('Sync', 'Sync-Passwort gesetzt');
    } finally {
      busy.value = false;
      app.refreshUi();
    }
  }

  static String _derive(String p) {
    // gleiche Ableitung wie SyncKeys.fromPassphrase, aber nur den Hauptschlüssel zurückgeben
    return hexOf(_pbkdf2Master(p));
  }

  static List<int> _pbkdf2Master(String p) => pbkdf2Master(p);

  Future<void> forget() async {
    await stopHost();
    try {
      await _keyFile.delete();
    } catch (_) {}
    try {
      await File('${app.storage.root.path}/sync_state.json').delete();
    } catch (_) {}
    _keys = null;
    _engine = null;
    status.value = '';
    app.refreshUi();
  }

  void _schedule() {
    _timer?.cancel();
    if (!configured || !config.auto || config.serverUrl.isEmpty) return;
    _timer = Timer.periodic(const Duration(minutes: 15), (_) => syncServer(quiet: true));
  }

  /// Alter Einzeldatei-Server (…/junels-sync.php) oder Agent-API hinter der Weiche (Klar-URLs).
  bool get _legacyServer {
    final u = config.serverUrl.trim();
    return u.endsWith('.php') || u.endsWith('/junels/') || u.contains('junels-sync');
  }

  Uri _serverUri() {
    var u = config.serverUrl.trim();
    if (!u.startsWith('http')) u = 'https://$u';
    if (_legacyServer) {
      if (!u.endsWith('.php') && !u.endsWith('/')) u = '$u/';
      if (u.endsWith('/')) u = '${u}junels-sync.php';
      return Uri.parse(u);
    }
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return Uri.parse(u);
  }

  /// Klar-URL der Agent-API: https://…/sync, /login/<port>, /whoami …
  Uri _api(String path) => Uri.parse('${_serverUri()}/$path');

  Future<void> _run(String label, Future<SyncResult> Function() job, {bool quiet = false}) async {
    final eng = _engine;
    if (eng == null) {
      lastError.value = 'Zuerst ein Sync-Passwort festlegen.';
      return;
    }
    if (busy.value) return;
    if (app.running) {
      if (!quiet) lastError.value = 'Bitte warten, bis die Antwort fertig ist.';
      return;
    }
    busy.value = true;
    lastError.value = null;
    status.value = '$label …';
    final sw = Stopwatch()..start();
    try {
      final r = await job();
      lastSync = DateTime.now();
      status.value = '$label: $r (${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s)';
      appLog('Sync', status.value);
      app.refreshUi();
    } catch (e) {
      lastError.value = '$label fehlgeschlagen: $e';
      status.value = '';
      appLog('Sync', lastError.value!, error: true);
    } finally {
      busy.value = false;
    }
  }

  /// Mit dem eigenen Server abgleichen.
  DateTime _statsAt = DateTime(2000);

  Future<void> syncServer({bool quiet = false}) async {
    if (config.serverUrl.trim().isEmpty) {
      lastError.value = 'Keine Server-Adresse eingetragen.';
      return;
    }
    if (config.level == 0 || config.level == 1) return; // Stufe ohne Daten: nichts abgleichen
    final base = _serverUri();
    final url = _legacyServer ? base : _api('sync');
    final token = await Vault.read('sso:token');
    await _run('Server', () => _engine!.syncWith('server:${base.host}${base.path}', (q) async {
          try {
            return await syncHttpPost(url, {
              ...q,
              if (token != null && token.isNotEmpty) 'token': token,
              // Gerät für die Konto-Übersicht (nur Name/System/Version – keine Inhalte)
              if (!_legacyServer)
                'device': {
                  'id': config.deviceId,
                  'name': config.deviceName.isEmpty ? defaultName : config.deviceName,
                  'platform': Platform.operatingSystem,
                  'app': appVersion,
                },
            });
          } on SyncException catch (e) {
            if ('$e'.contains('SSO')) {
              await Vault.delete('sso:token');
              config.ssoName = '';
              await saveConfig();
            }
            rethrow;
          }
        }),
        quiet: quiet);
    // Auswertung (nur Zahlen) für den Admin-Bereich – höchstens alle 6 Stunden
    if (lastError.value == null && DateTime.now().difference(_statsAt) > const Duration(hours: 6)) {
      _statsAt = DateTime.now();
      unawaited(uploadStats());
    }
  }

  // ---------------------------------------------------------------- Konto (SSO) & Datenschutz-Stufe

  bool get ssoSignedIn => config.ssoName.isNotEmpty || config.ssoEmail.isNotEmpty;

  /// Unterstützt der Server SSO? (GET liefert {"sso": true})
  /// Prüft eine Adresse: Läuft dort die Junels Agent-API (mit SSO)? null = nicht erreichbar / keine Agent-API.
  static Future<bool?> probeAgentApi(String base) async {
    var u = base.trim();
    if (u.isEmpty) return null;
    if (!u.startsWith('http')) u = 'https://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final r = await (await c.getUrl(Uri.parse('$u/'))).close().timeout(const Duration(seconds: 10));
      final j = jsonDecode(await r.transform(utf8.decoder).join());
      if (j is! Map || j['app'] != 'junels-api') return null;
      return j['sso'] == true;
    } catch (_) {
      return null;
    } finally {
      c.close(force: true);
    }
  }

  /// Findet die Agent-API: die eingetragene Adresse, sonst agent.<domain> (häufiger Fehler: SSO-Adresse
  /// statt Agent-API eingetragen, z. B. sso.2442.io statt agent.2442.io). Stellt die Adresse ggf. um.
  Future<void> _ensureAgentApi() async {
    final cur = config.serverUrl.trim();
    if (await probeAgentApi(cur) == true) return;
    final host = Uri.tryParse(cur.startsWith('http') ? cur : 'https://$cur')?.host ?? '';
    final parts = host.split('.');
    final base = parts.length > 2 ? parts.sublist(parts.length - 2).join('.') : host;
    for (final cand in {'agent.$base', if (parts.length > 2) 'agent.${parts.sublist(1).join('.')}'}) {
      if (cand == host || base.isEmpty) continue;
      if (await probeAgentApi(cand) == true) {
        config.serverUrl = 'https://$cand';
        await saveConfig();
        appLog('Sync', 'Server-Adresse auf $cand umgestellt (dort läuft die Agent-API)');
        status.value = 'Adresse auf $cand umgestellt – dort läuft deine Agent-API.';
        return;
      }
    }
    throw SyncException(host.isEmpty
        ? 'Bitte zuerst die Adresse deiner Agent-API eintragen, z. B. https://agent.2442.io/api'
        : 'Unter $host läuft keine Junels Agent-API. Trag die Adresse deiner Agent-API ein '
            '(z. B. https://agent.2442.io/api) – nicht die Adresse des SSO.');
  }

  Future<bool?> serverHasSso() async {
    if (config.serverUrl.trim().isEmpty) return null;
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      if (_legacyServer) return false; // SSO nur mit der Agent-API hinter der Weiche
      final r = await (await c.getUrl(Uri.parse('${_serverUri()}/'))).close().timeout(const Duration(seconds: 10));
      final j = jsonDecode(await r.transform(utf8.decoder).join()) as Map;
      return j['sso'] == true;
    } catch (_) {
      return null;
    } finally {
      c.close(force: true);
    }
  }

  /// Anmelden: Browser öffnet den eigenen Server → SSO → zurück an 127.0.0.1 (nur dieses Gerät).
  Completer<void>? _ssoPending;

  /// Anmeldung mit SSO: Browser öffnet …/login/app/<prüfwert>, nach dem SSO springt die Seite per
  /// junels://sso/<code> zurück in die App. Der Code gilt nur mit dem geheimen Prüfwert dieses Geräts.
  Future<void> ssoLogin() async {
    if (config.serverUrl.trim().isEmpty) throw SyncException('Bitte zuerst die Server-Adresse eintragen.');
    if (_legacyServer) throw SyncException('SSO gibt es nur mit der Agent-API (Weiche). Trage deren Adresse ein, z. B. https://agent.2442.io/api');
    status.value = 'Prüfe Server …';
    await _ensureAgentApi();
    final rnd = Random.secure();
    final verifier = hexOf(List<int>.generate(32, (_) => rnd.nextInt(256)));
    await Vault.write('sso:verifier', verifier);
    final challenge = hexOf(sha256(utf8.encode(verifier)));
    final pending = _ssoPending = Completer<void>();
    await NativeFiles.openUrl(_api('login/app/$challenge').toString());
    status.value = 'Anmeldung im Browser …';
    try {
      await pending.future.timeout(const Duration(minutes: 10),
          onTimeout: () => throw SyncException('Anmeldung nicht abgeschlossen (Zeit abgelaufen).'));
    } finally {
      if (identical(_ssoPending, pending)) _ssoPending = null;
    }
  }

  /// junels://sso/<code> – kommt auch an, wenn die App inzwischen neu gestartet wurde.
  Future<void> handleLink(Uri link) async {
    final seg = [if (link.host.isNotEmpty) link.host, ...link.pathSegments];
    if (seg.length < 2 || seg[0] != 'sso') return;
    final pending = _ssoPending;
    try {
      final verifier = await Vault.read('sso:verifier');
      if (verifier == null) throw SyncException('Anmeldung nicht gestartet – bitte in Junels „Mit SSO anmelden“ tippen.');
      final r = await syncHttpPost(_api('token'), {'code': seg[1], 'verifier': verifier});
      final token = '${r['token'] ?? ''}';
      if (token.length < 32) throw SyncException('Anmeldung fehlgeschlagen.');
      await Vault.write('sso:token', token);
      await Vault.delete('sso:verifier');
      config
        ..ssoName = '${r['name'] ?? ''}'
        ..ssoEmail = '${r['email'] ?? ''}';
      if (config.level < 1) config.level = 1;
      await saveConfig();
      status.value = 'Angemeldet als ${config.ssoName.isNotEmpty ? config.ssoName : config.ssoEmail}';
      appLog('Sync', 'Mit SSO angemeldet');
      if (pending != null && !pending.isCompleted) pending.complete();
    } catch (e) {
      appLog('Sync', 'SSO: $e', error: true);
      status.value = '$e';
      if (pending != null && !pending.isCompleted) pending.completeError(e);
    }
  }

  Future<void> ssoLogout() async {
    final token = await Vault.read('sso:token');
    if (token != null && config.serverUrl.isNotEmpty) {
      try {
        if (!_legacyServer) await syncHttpPost(_api('logout'), {'token': token});
      } catch (_) {}
    }
    await Vault.delete('sso:token');
    config
      ..ssoName = ''
      ..ssoEmail = '';
    if (config.level > 0) config.level = 0;
    await saveConfig();
  }

  /// Datenschutz-Stufe setzen: bestimmt, welche Kategorien abgeglichen werden.
  Future<void> setLevel(int level) async {
    final l = PrivacyLevel.all[level.clamp(0, 4)];
    config
      ..level = l.level
      ..categories = {...l.categories};
    if (l.level == 0) await stopHost();
    await saveConfig();
  }

  /// Anderes Sync-Passwort auf dem Server hinterlegt (Fehler 403)
  bool get passwordConflict => (lastError.value ?? '').contains('anderes Sync-Passwort');

  /// Konto-Übersicht vom Server: Geräte, Daten je Kategorie, Anmeldungen (ab Agent-API v3; sonst null)
  Future<Map<String, dynamic>?> serverOverview() async {
    if (config.serverUrl.trim().isEmpty || _legacyServer) return null;
    final token = await Vault.read('sso:token');
    if (token == null) return null;
    try {
      final r = await syncHttpPost(_api('status'), {'token': token});
      return r['ok'] == true ? r : null;
    } catch (_) {
      return null;
    }
  }

  /// Auswertung (nur Zahlen, keine Inhalte) an die Agent-API für den Admin-Bereich
  Future<void> uploadStats() async {
    if (!config.shareStats || config.serverUrl.trim().isEmpty || _legacyServer) return;
    final token = await Vault.read('sso:token');
    if (token == null || token.isEmpty) return;
    try {
      final stats = UsageStats.compute(app).toJson(device: config.deviceName.isEmpty ? defaultName : config.deviceName);
      await syncHttpPost(_api('stats'), {'token': token, 'stats': stats});
    } catch (e) {
      appLog('Sync', 'Auswertung nicht übertragen: $e');
    }
  }

  /// Adresse der Konto-Seite im Browser
  Uri get accountPage => _api('admin');

  /// Alle Daten dieses Kontos auf dem Server löschen (z. B. nach dem Senken der Stufe).
  /// Ab Agent-API v5 mit zweitem Faktor: der Server schickt einen Bestätigungslink per E-Mail (Rückgabe: Adresse,
  /// maskiert); gelöscht wird erst nach Klick auf den Link (mit SSO). Ältere Server löschen sofort (Rückgabe null).
  Future<String?> wipeServer() async {
    final token = await Vault.read('sso:token');
    if (_legacyServer) throw SyncException('Löschen auf dem Server gibt es nur mit der Agent-API (Weiche).');
    final r = await syncHttpPost(_api('wipe'), {if (token != null) 'token': token});
    if (r['pending'] == true) {
      final mail = '${r['email'] ?? ''}';
      status.value = 'Bestätigungslink an $mail gesendet – nach dem Bestätigen hier erneut abgleichen.';
      appLog('Sync', 'Zurücksetzen angefordert (E-Mail an $mail)');
      return mail;
    }
    try {
      await File('${app.storage.root.path}/sync_state.json').delete();
    } catch (_) {}
    if (_keys != null) _setKeys(_keys!); // beim nächsten Abgleich alles Erlaubte neu hochladen
    status.value = 'Daten auf dem Server gelöscht';
    appLog('Sync', 'Serverdaten gelöscht');
    return null;
  }

  /// Mit einem Gerät im WLAN abgleichen.
  Future<void> syncLan(String address) async {
    var a = address.trim();
    if (!a.startsWith('http')) a = 'http://$a';
    var uri = Uri.parse(a);
    if (!uri.hasPort || uri.port == 80) uri = uri.replace(port: lanSyncPort);
    uri = uri.replace(path: '/junels-sync');
    await _run('WLAN ${uri.host}', () => _engine!.syncWith('lan:${uri.host}', (q) => syncHttpPost(uri, q)));
  }

  Future<List<LanPeer>> discover() async {
    final k = _keys;
    if (k == null) return const [];
    final own = await LanSyncHost.localAddresses();
    final peers = await discoverLanPeers(k.account);
    return [for (final p in peers) if (!own.contains(p.address)) p];
  }

  // ------------------------------------------------------------- WLAN-Partner

  Future<void> startHost() async {
    final k = _keys;
    if (k == null || hosting) return;
    final hubFile = File('${app.storage.root.path}/sync_hub.json');
    final hub = SyncHub(hubFile);
    await hub.load();
    _host = LanSyncHost(
      account: k.account,
      name: config.deviceName.isEmpty ? defaultName : config.deviceName,
      onRequest: (req) async {
        // eigenen Stand einbringen, Anfrage beantworten, danach Neues übernehmen
        await _engine!.syncWith('hub', (q) async => hub.handle(q, account: k.account));
        final resp = hub.handle(req, account: k.account);
        await hub.save();
        unawaited(Future<void>.delayed(const Duration(milliseconds: 200), () async {
          try {
            final r = await _engine!.syncWith('hub', (q) async => hub.handle(q, account: k.account));
            await hub.save();
            status.value = 'WLAN-Partner hat abgeglichen: ${r.received} übernommen';
            appLog('Sync', status.value);
            app.refreshUi();
          } catch (e) {
            appLog('Sync', 'WLAN-Übernahme fehlgeschlagen: $e', error: true);
          }
        }));
        return resp;
      },
    );
    try {
      await _host!.start();
      appLog('Sync', 'WLAN-Partner bereit (Port $lanSyncPort)');
    } catch (e) {
      _host = null;
      lastError.value = 'WLAN-Partner konnte nicht starten: $e';
      appLog('Sync', lastError.value!, error: true);
    }
    app.refreshUi();
  }

  Future<void> stopHost() async {
    await _host?.stop();
    _host = null;
    app.refreshUi();
  }

  // ----------------------------------------------------------- SyncSource

  bool _on(SyncCategory c) => config.categories.contains(c.prefix);

  static String _memKey(String text) => 'mem:${hexOf(sha256(utf8.encode(text.toLowerCase().trim()))).substring(0, 20)}';

  @override
  Future<Map<String, String>> exportAll() async {
    final out = <String, String>{};
    if (_on(SyncCategory.chats)) {
      for (final c in app.conversations) {
        if (c.entries.isEmpty) continue;
        out['chat:${c.id}'] = jsonEncode(c.toJson());
      }
    }
    if (_on(SyncCategory.memory)) {
      for (final n in app.memory.notes) {
        out[_memKey(n.text)] = jsonEncode(n.toJson());
      }
    }
    if (_on(SyncCategory.prompts)) {
      for (final p in app.prompts) {
        out['prompt:${p.id}'] = jsonEncode(p.toJson()..remove('lastRun'));
      }
    }
    if (_on(SyncCategory.profiles)) {
      for (final p in app.profiles) {
        out['profile:${p.id}'] = jsonEncode(p.toJson());
      }
    }
    if (_on(SyncCategory.mcp)) {
      for (final s in app.mcpServers) {
        out['mcp:${s.id}'] = jsonEncode(s.toJson());
      }
    }
    if (_on(SyncCategory.knowledge)) {
      for (final s in app.knowledge.sources) {
        out['kb:${s.id}'] = jsonEncode({
          'source': s.toJson(),
          'chunks': [for (final c in app.knowledge.chunks) if (c.sourceId == s.id) c.toJson()],
        });
      }
    }
    if (_on(SyncCategory.setups)) {
      for (final e in app.settings.setups.entries) {
        out['setup:${e.key}'] = jsonEncode(e.value);
      }
    }
    if (_on(SyncCategory.designs)) {
      for (final d in DesignLibrary.user) {
        // Vorlagen-Dateien (Folienmaster) bleiben auf dem Gerät; Farben & Schriften werden abgeglichen
        out['design:${d.id}'] = jsonEncode(d.design.toJson());
      }
    }
    if (_on(SyncCategory.skills)) {
      // eigene Skills und angepasste Basis-Skills
      for (final s in [...app.skills.own, ...app.skills.basis.where((b) => b.edited)]) {
        out['skill:${s.id}'] = jsonEncode(s.toJson());
      }
    }
    return out;
  }

  @override
  Future<void> apply(String key, String? json) async {
    final i = key.indexOf(':');
    final kind = key.substring(0, i);
    final id = key.substring(i + 1);
    final j = json == null ? null : (jsonDecode(json) as Map).cast<String, dynamic>();
    switch (kind) {
      case 'chat':
        if (app.running && app.current?.id == id) return; // gerade aktiv – beim nächsten Mal
        final idx = app.conversations.indexWhere((c) => c.id == id);
        if (j == null) {
          if (idx >= 0) app.conversations.removeAt(idx);
          await app.storage.deleteConversation(id);
          if (app.current?.id == id) app.current = app.conversations.firstOrNull;
        } else {
          final c = Conversation.fromJson(j);
          if (idx >= 0) {
            final wasCurrent = app.current?.id == id;
            app.conversations[idx] = c;
            if (wasCurrent) app.current = c;
          } else {
            app.conversations.add(c);
          }
          app.conversations.sort((a, b) => b.updated.compareTo(a.updated));
          await app.storage.saveConversation(c);
        }
      case 'mem':
        if (j == null) {
          final n = app.memory.notes.where((x) => _memKey(x.text) == key).firstOrNull;
          if (n != null) await app.memory.removeText(n.text);
        } else {
          await app.memory.putSynced(MemoryNote.fromJson(j));
        }
      case 'prompt':
        final idx = app.prompts.indexWhere((p) => p.id == id);
        if (j == null) {
          if (idx >= 0) app.prompts.removeAt(idx);
        } else {
          final p = SavedPrompt.fromJson(j);
          if (idx >= 0) {
            p.lastRun = app.prompts[idx].lastRun;
            app.prompts[idx] = p;
          } else {
            p.lastRun = DateTime.now(); // nicht sofort nachholen
            app.prompts.add(p);
          }
        }
        await app.promptsChangedExternally();
      case 'profile':
        final idx = app.profiles.indexWhere((p) => p.id == id);
        if (j == null) {
          if (idx >= 0 && app.profiles.length > 1) app.profiles.removeAt(idx);
        } else {
          final p = AgentProfile.fromJson(j);
          if (idx >= 0) {
            app.profiles[idx] = p;
          } else {
            app.profiles.add(p);
          }
        }
        await app.storage.saveProfiles(app.profiles);
      case 'mcp':
        final idx = app.mcpServers.indexWhere((s) => s.id == id);
        if (j == null) {
          if (idx >= 0) app.mcpServers.removeAt(idx);
        } else {
          final s = McpServerConfig.fromJson(j);
          if (idx >= 0) {
            app.mcpServers[idx] = s;
          } else {
            app.mcpServers.add(s);
          }
        }
        await app.storage.saveMcpServers(app.mcpServers);
      case 'kb':
        if (j == null) {
          app.knowledge.removeSource(id);
        } else {
          app.knowledge.putRaw(
            KnowledgeSource.fromJson((j['source'] as Map).cast()),
            [for (final c in j['chunks'] as List) KnowledgeChunk.fromJson((c as Map).cast())],
          );
        }
        await app.knowledge.save();
      case 'setup':
        if (j == null) {
          app.settings.setups.remove(id);
        } else {
          app.settings.setups[id] = j;
        }
        await app.storage.saveSettings(app.settings);
      case 'design':
        if (j == null) {
          DesignLibrary.user.removeWhere((u) => u.id == id);
          await app.saveDesigns();
        } else {
          final keep = DesignLibrary.byId(id)?.templatePath;
          DesignLibrary.user.removeWhere((u) => u.id == id);
          DesignLibrary.user.add(UserDesign(design: SlideDesign.fromJson(j), templatePath: keep));
          await app.saveDesigns();
        }
      case 'skill':
        if (j == null) {
          final s = app.skills.byId(id);
          if (s != null) s.builtin ? app.skills.reset(s) : app.skills.remove(s);
        } else {
          final s = Skill.fromJson({...j, 'id': id, if (id.startsWith('b-')) 'builtin': true});
          app.skills.upsert(s);
        }
    }
  }
}
