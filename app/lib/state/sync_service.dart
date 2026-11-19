// Abgleich von Chats, Gedächtnis, Prompts, Profilen, MCP-Servern und Wissensbasis
// zwischen den eigenen Geräten – über den eigenen Server (PHP) oder direkt im WLAN.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/foundation.dart';

import '../data/models.dart';
import 'app_controller.dart';
import 'memory_store.dart';
import 'voice_service.dart' show appLog;

/// Was abgeglichen wird.
enum SyncCategory {
  chats('chat', 'Chats'),
  memory('mem', 'Gedächtnis'),
  prompts('prompt', 'Meine Prompts'),
  profiles('profile', 'Profile'),
  mcp('mcp', 'MCP-Server'),
  knowledge('kb', 'Wissensbasis');

  const SyncCategory(this.prefix, this.label);
  final String prefix;
  final String label;
}

class SyncConfig {
  SyncConfig({
    this.serverUrl = '',
    this.auto = true,
    this.lanHost = false,
    Set<String>? categories,
    this.deviceName = '',
  }) : categories = categories ?? SyncCategory.values.map((c) => c.prefix).toSet();

  String serverUrl;
  bool auto; // beim Start und alle 15 Minuten mit dem Server abgleichen
  bool lanHost; // dieses Gerät im WLAN bereitstellen
  Set<String> categories;
  String deviceName;

  Map<String, Object> toJson() => {
        'serverUrl': serverUrl,
        'auto': auto,
        'lanHost': lanHost,
        'categories': categories.toList(),
        'deviceName': deviceName,
      };
  factory SyncConfig.fromJson(Map<String, dynamic> j) => SyncConfig(
        serverUrl: j['serverUrl'] as String? ?? '',
        auto: j['auto'] as bool? ?? true,
        lanHost: j['lanHost'] as bool? ?? false,
        categories: (j['categories'] as List?)?.cast<String>().toSet(),
        deviceName: j['deviceName'] as String? ?? '',
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

  Uri _serverUri() {
    var u = config.serverUrl.trim();
    if (!u.startsWith('http')) u = 'https://$u';
    if (!u.endsWith('.php') && !u.endsWith('/')) u = '$u/';
    if (u.endsWith('/')) u = '${u}junels-sync.php';
    return Uri.parse(u);
  }

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
  Future<void> syncServer({bool quiet = false}) async {
    if (config.serverUrl.trim().isEmpty) {
      lastError.value = 'Keine Server-Adresse eingetragen.';
      return;
    }
    final url = _serverUri();
    await _run('Server', () => _engine!.syncWith('server:${url.host}${url.path}', (q) => syncHttpPost(url, q)),
        quiet: quiet);
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
    }
  }
}
