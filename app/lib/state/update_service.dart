// Updates direkt in der App: prüft das GitHub-Release „aktuell“ und lädt die neue
// Version herunter. Das Repository ist privat – darum braucht es einen GitHub-Token
// mit Lesezugriff (nur auf diesem Gerät gespeichert).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart' as pp;

import '../version.dart';
import 'native_files.dart';
import 'voice_service.dart' show appLog;

const _repo = '2442io/junels';

class UpdateInfo {
  UpdateInfo(this.version, this.build, this.notes, this.date, this.assetUrl, this.assetName, this.size);
  final String version;
  final int build;
  final String notes;
  final String date;
  final String assetUrl;
  final String assetName;
  final int size;
}

class UpdateService {
  UpdateService(this.root);
  final Directory root;

  final available = ValueNotifier<UpdateInfo?>(null);
  final progress = ValueNotifier<double?>(null); // Download 0..1
  final status = ValueNotifier<String>('');
  final error = ValueNotifier<String?>(null);
  DateTime? lastCheck;
  String? _token;
  Timer? _timer;
  bool _busy = false;

  File get _tokenFile => File('${root.path}/update_token');
  bool get hasToken => (_token ?? '').isNotEmpty;
  bool get supported => Platform.isAndroid || Platform.isMacOS;
  String get _platform => Platform.isAndroid ? 'android' : 'macos';

  Future<void> init() async {
    try {
      if (await _tokenFile.exists()) _token = (await _tokenFile.readAsString()).trim();
    } catch (_) {}
    if (!supported) return;
    // Öffentliches Repository: kein Token nötig; privat: nur mit Token
    unawaited(Future<void>.delayed(const Duration(seconds: 12), () => check(quiet: true)));
    _timer ??= Timer.periodic(const Duration(hours: 6), (_) => check(quiet: true));
  }

  Future<void> setToken(String token) async {
    _token = token.trim();
    if (_token!.isEmpty) {
      try {
        await _tokenFile.delete();
      } catch (_) {}
      available.value = null;
      return;
    }
    await _tokenFile.writeAsString(_token!);
    _timer ??= Timer.periodic(const Duration(hours: 6), (_) => check(quiet: true));
    await check();
  }

  Future<HttpClientResponse> _get(HttpClient c, Uri url, {bool binary = false, bool auth = true}) async {
    final req = await c.getUrl(url);
    req.followRedirects = false;
    req.headers.set('User-Agent', 'Junels/$appVersion');
    if (auth && hasToken) req.headers.set('Authorization', 'Bearer $_token');
    req.headers.set('Accept', binary ? 'application/octet-stream' : 'application/vnd.github+json');
    final res = await req.close();
    if (res.isRedirect) {
      final loc = res.headers.value('location');
      await res.drain<void>();
      if (loc == null) throw Exception('Weiterleitung ohne Ziel');
      // Download-Server (S3) ohne GitHub-Token aufrufen
      return _get(c, Uri.parse(loc), binary: binary, auth: false);
    }
    return res;
  }

  /// Nach einer neuen Version suchen.
  Future<void> check({bool quiet = false}) async {
    if (!supported || _busy) return;
    _busy = true;
    error.value = null;
    if (!quiet) status.value = 'Suche nach Updates …';
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final res = await _get(c, Uri.parse('https://api.github.com/repos/$_repo/releases/tags/aktuell'));
      final body = await utf8.decodeStream(res);
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw Exception(hasToken ? 'GitHub-Token ungültig oder ohne Leserecht auf $_repo' : 'GitHub hat die Anfrage abgelehnt ($_repo)');
      }
      if (res.statusCode == 404) {
        throw Exception(hasToken
            ? 'Release nicht gefunden – hat der Token Zugriff auf $_repo?'
            : 'Release nicht erreichbar – ist das Repository privat? Dann unten einen GitHub-Token eintragen.');
      }
      if (res.statusCode != 200) throw Exception('GitHub antwortet ${res.statusCode}');
      final rel = jsonDecode(body) as Map<String, dynamic>;
      final assets = (rel['assets'] as List).cast<Map<String, dynamic>>();
      Map<String, dynamic>? find(String name) => assets.where((a) => a['name'] == name).firstOrNull;
      final vAsset = find('version-$_platform.json');
      final app = find(Platform.isAndroid ? 'Junels.apk' : 'Junels.dmg');
      if (vAsset == null || app == null) throw Exception('Release enthält noch keine Versionsangabe');
      final vr = await _get(c, Uri.parse(vAsset['url'] as String), binary: true);
      final v = jsonDecode(await utf8.decodeStream(vr)) as Map<String, dynamic>;
      final build = (v['build'] as num).toInt();
      lastCheck = DateTime.now();
      if (build > (int.tryParse(appBuild) ?? 0)) {
        available.value = UpdateInfo(v['version'] as String, build, v['notes'] as String? ?? '', v['date'] as String? ?? '',
            app['url'] as String, app['name'] as String, (app['size'] as num?)?.toInt() ?? 0);
        status.value = 'Update verfügbar: ${v['version']} (Build $build)';
        appLog('Update', status.value);
      } else {
        available.value = null;
        status.value = 'Junels ist aktuell ($appVersion)';
      }
    } catch (e) {
      if (!quiet) error.value = '$e'.replaceFirst('Exception: ', '');
      appLog('Update', 'Prüfung fehlgeschlagen: $e', error: !quiet);
      if (!quiet) status.value = '';
    } finally {
      c.close(force: true);
      _busy = false;
    }
  }

  /// Neue Version herunterladen und installieren.
  Future<void> install() async {
    final info = available.value;
    if (info == null || progress.value != null) return;
    error.value = null;
    progress.value = 0;
    status.value = 'Lade ${info.assetName} …';
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final dir = Directory('${(await getTemporaryDir()).path}/update')..createSync(recursive: true);
      final file = File('${dir.path}/${info.assetName}');
      final res = await _get(c, Uri.parse(info.assetUrl), binary: true);
      if (res.statusCode != 200) throw Exception('Download fehlgeschlagen (${res.statusCode})');
      final total = res.contentLength > 0 ? res.contentLength : info.size;
      final sink = file.openWrite();
      var got = 0;
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) progress.value = got / total;
      }
      await sink.close();
      status.value = Platform.isAndroid
          ? 'Download fertig – bitte die Installation bestätigen.'
          : 'Download fertig – ziehe Junels im geöffneten Fenster in „Programme“ und starte neu.';
      appLog('Update', '${info.version} heruntergeladen (${(got / 1e6).toStringAsFixed(0)} MB)');
      if (Platform.isAndroid) {
        await NativeFiles.installApk(file.path);
      } else {
        await NativeFiles.open(file.path);
      }
    } catch (e) {
      error.value = '$e'.replaceFirst('Exception: ', '');
      status.value = '';
      appLog('Update', 'Installation fehlgeschlagen: $e', error: true);
    } finally {
      c.close(force: true);
      progress.value = null;
    }
  }

  static Future<Directory> getTemporaryDir() => pp.getTemporaryDirectory();
}
