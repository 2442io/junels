// Abgleich zwischen Geräten (Mac ↔ Android) über einen eigenen Server oder im WLAN.
//
// Jedes Element (Chat, Notiz, Prompt …) wird einzeln, verschlüsselt und mit
// Zeitstempel übertragen; bei Konflikten gewinnt die neuere Änderung.
// Der Server (PHP) bzw. der WLAN-Partner ("Hub") sieht nur verschlüsselte Daten.
//
// Protokoll (POST, JSON):
//   → {"v":1, "account":"<hex>", "since":<seq>, "items":[{"k","t","d","b"}]}
//   ← {"seq":<seq>, "items":[{"k","t","d","b","s"}]}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sync_crypto.dart';

class SyncException implements Exception {
  SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SyncItem {
  SyncItem(this.k, this.t, this.d, this.b, [this.s = 0]);
  final String k; // Schlüssel, z. B. "chat:abc"
  final int t; // Änderungszeit (ms)
  final bool d; // gelöscht
  final String b; // verschlüsselter Inhalt (leer bei gelöscht)
  int s; // Folgenummer auf dem Hub

  Map<String, Object> toJson() => {'k': k, 't': t, 'd': d, 'b': b, 's': s};
  factory SyncItem.fromJson(Map<String, dynamic> j) => SyncItem(j['k'] as String, (j['t'] as num).toInt(),
      j['d'] == true || j['d'] == 1, (j['b'] as String?) ?? '', (j['s'] as num?)?.toInt() ?? 0);
}

/// Sammelstelle (WLAN-Partner). Der PHP-Server verhält sich genauso.
class SyncHub {
  SyncHub([this.file]);
  final File? file;
  int seq = 0;
  final Map<String, SyncItem> items = {};

  Future<void> load() async {
    final f = file;
    if (f == null || !await f.exists()) return;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      seq = (j['seq'] as num).toInt();
      for (final i in j['items'] as List) {
        final it = SyncItem.fromJson((i as Map).cast());
        items[it.k] = it;
      }
    } catch (_) {}
  }

  Future<void> save() async {
    final f = file;
    if (f == null) return;
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({'seq': seq, 'items': items.values.map((i) => i.toJson()).toList()}));
    await tmp.rename(f.path);
  }

  Map<String, dynamic> handle(Map<String, dynamic> req, {required String account}) {
    if (req['account'] != account) throw SyncException('Anderes Sync-Passwort auf dem Partnergerät');
    final since = (req['since'] as num?)?.toInt() ?? 0;
    final sent = <String, int>{};
    for (final raw in (req['items'] as List? ?? const [])) {
      final it = SyncItem.fromJson((raw as Map).cast());
      sent[it.k] = it.t;
      final cur = items[it.k];
      if (cur == null || it.t > cur.t) {
        it.s = ++seq;
        items[it.k] = it;
      }
    }
    return {
      'seq': seq,
      'items': [
        for (final i in items.values)
          if (i.s > since && sent[i.k] != i.t) i.toJson(),
      ],
    };
  }
}

/// Datenquelle der App: liefert alle Elemente als JSON und übernimmt empfangene.
abstract class SyncSource {
  /// Schlüssel → JSON-Text aller abzugleichenden Elemente.
  Future<Map<String, String>> exportAll();

  /// Empfangenes Element übernehmen ([json] == null: löschen).
  Future<void> apply(String key, String? json);
}

class SyncResult {
  SyncResult(this.sent, this.received);
  final int sent;
  final int received;
  @override
  String toString() => '$sent gesendet, $received empfangen';
}

class _Endpoint {
  _Endpoint(this.since, this.known, [this.epoch = 0]);
  int since;

  /// Kennung des Datenbestands auf dem Server (ändert sich nach einem Zurücksetzen)
  int epoch;
  final Map<String, int> known; // Schlüssel → zuletzt ausgetauschter Stand
}

class _Entry {
  _Entry(this.h, this.t, this.d);
  String h;
  int t;
  bool d;
  Map<String, Object> toJson() => {'h': h, 't': t, 'd': d};
}

/// Abgleich-Logik eines Geräts.
class SyncEngine {
  SyncEngine({required this.keys, required this.source, this.stateFile, int Function()? clock})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final SyncKeys keys;
  final SyncSource source;
  final File? stateFile;
  final int Function() _clock;

  final Map<String, _Entry> _entries = {};
  final Map<String, _Endpoint> _endpoints = {};
  bool _loaded = false;
  Future<void>? _busy;

  static String hashOf(String json) => hexOf(sha256(utf8.encode(json))).substring(0, 24);

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final f = stateFile;
    if (f == null || !await f.exists()) return;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (j['account'] != keys.account) return; // anderes Passwort → neu beginnen
      (j['entries'] as Map).forEach((k, v) {
        final m = (v as Map).cast<String, dynamic>();
        _entries[k as String] = _Entry(m['h'] as String, (m['t'] as num).toInt(), m['d'] == true);
      });
      (j['endpoints'] as Map).forEach((k, v) {
        final m = (v as Map).cast<String, dynamic>();
        _endpoints[k as String] = _Endpoint((m['since'] as num).toInt(),
            (m['known'] as Map).map((a, b) => MapEntry(a as String, (b as num).toInt())), (m['epoch'] as num?)?.toInt() ?? 0);
      });
    } catch (_) {}
  }

  Future<void> _save() async {
    final f = stateFile;
    if (f == null) return;
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'account': keys.account,
      'entries': _entries.map((k, v) => MapEntry(k, v.toJson())),
      'endpoints': _endpoints.map((k, v) => MapEntry(k, {'since': v.since, 'known': v.known, if (v.epoch != 0) 'epoch': v.epoch})),
    }));
    await tmp.rename(f.path);
  }

  /// Lokale Änderungen seit dem letzten Abgleich erfassen; liefert die aktuellen Inhalte.
  Future<Map<String, String>> _scan() async {
    final now = _clock();
    final current = await source.exportAll();
    current.forEach((k, json) {
      final h = hashOf(json);
      final e = _entries[k];
      if (e == null) {
        _entries[k] = _Entry(h, now, false);
      } else if (e.h != h || e.d) {
        e
          ..h = h
          ..d = false
          ..t = now > e.t ? now : e.t + 1;
      }
    });
    _entries.forEach((k, e) {
      if (!e.d && !current.containsKey(k)) {
        e
          ..d = true
          ..h = ''
          ..t = now > e.t ? now : e.t + 1;
      }
    });
    return current;
  }

  /// Abgleich mit einem Gegenüber. [send] überträgt die Anfrage (HTTP oder direkt an einen Hub).
  Future<SyncResult> syncWith(String endpointId, Future<Map<String, dynamic>> Function(Map<String, dynamic> req) send) {
    final prev = _busy;
    final run = () async {
      if (prev != null) {
        try {
          await prev;
        } catch (_) {}
      }
      return _sync(endpointId, send);
    }();
    _busy = run;
    return run;
  }

  Future<SyncResult> _sync(String endpointId, Future<Map<String, dynamic>> Function(Map<String, dynamic> req) send,
      {bool retried = false}) async {
    await _load();
    final current = await _scan();
    final ep = _endpoints.putIfAbsent(endpointId, () => _Endpoint(0, {}));
    final out = <Map<String, Object>>[];
    final pushed = <String, int>{};
    _entries.forEach((k, e) {
      if (ep.known[k] == e.t) return; // Gegenüber kennt diesen Stand schon
      pushed[k] = e.t;
      out.add(SyncItem(k, e.t, e.d, e.d ? '' : keys.seal(current[k]!)).toJson());
    });
    final resp = await send({'v': 1, 'account': keys.account, 'since': ep.since, 'items': out});
    // Server wurde zurückgesetzt (neuer Datenbestand): alles vergessen, was er „kannte“, und vollständig neu abgleichen
    final epoch = (resp['epoch'] as num?)?.toInt() ?? 0;
    if (epoch != 0 && ep.epoch != 0 && epoch != ep.epoch && !retried) {
      ep
        ..known.clear()
        ..since = 0
        ..epoch = epoch;
      await _save();
      return _sync(endpointId, send, retried: true);
    }
    if (epoch != 0) ep.epoch = epoch;
    ep.known.addAll(pushed);
    var received = 0;
    for (final raw in (resp['items'] as List? ?? const [])) {
      final it = SyncItem.fromJson((raw as Map).cast());
      final e = _entries[it.k];
      if (e != null && e.t >= it.t) continue;
      ep.known[it.k] = it.t;
      String? json;
      if (!it.d) {
        try {
          json = keys.open(it.b);
        } on FormatException catch (err) {
          throw SyncException('Daten nicht lesbar: ${err.message}');
        }
      }
      await source.apply(it.k, json);
      received++;
      // tatsächlichen Stand nach dem Übernehmen merken (sonst gilt er beim nächsten Mal als geändert)
      final after = it.d ? null : (await source.exportAll())[it.k];
      _entries[it.k] = _Entry(after == null ? '' : hashOf(after), it.t, it.d || after == null);
    }
    ep.since = (resp['seq'] as num?)?.toInt() ?? ep.since;
    await _save();
    return SyncResult(out.length, received);
  }

  /// Zustand vergessen (z. B. nach Passwortwechsel).
  Future<void> reset() async {
    _entries.clear();
    _endpoints.clear();
    _loaded = true;
    await _save();
  }
}

/// POST an einen Sync-Server (PHP) oder WLAN-Partner.
Future<Map<String, dynamic>> syncHttpPost(Uri url, Map<String, dynamic> body,
    {Duration timeout = const Duration(seconds: 60)}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.postUrl(url).timeout(timeout);
    final data = utf8.encode(jsonEncode(body));
    req.headers.contentType = ContentType.json;
    req.contentLength = data.length;
    req.add(data);
    final res = await req.close().timeout(timeout);
    final text = await utf8.decodeStream(res).timeout(timeout);
    if (res.statusCode != 200) {
      String msg = text;
      try {
        msg = (jsonDecode(text) as Map)['error']?.toString() ?? text;
      } catch (_) {}
      throw SyncException('Server antwortet ${res.statusCode}: ${msg.length > 200 ? msg.substring(0, 200) : msg}');
    }
    try {
      return (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {
      throw SyncException('Unerwartete Antwort vom Server (kein JSON) – stimmt die Adresse?');
    }
  } on SocketException catch (e) {
    throw SyncException('Keine Verbindung: ${e.message}');
  } on TimeoutException {
    throw SyncException('Zeitüberschreitung');
  } finally {
    client.close(force: true);
  }
}

// ----------------------------------------------------------------- WLAN

const lanSyncPort = 47321;
const lanDiscoveryPort = 47322;

class LanPeer {
  LanPeer(this.address, this.port, this.name);
  final String address;
  final int port;
  final String name;
  Uri get url => Uri.parse('http://$address:$port/junels-sync');
  @override
  String toString() => '$name ($address)';
}

/// Dieses Gerät als Partner im WLAN bereitstellen.
class LanSyncHost {
  LanSyncHost({required this.account, required this.name, required this.onRequest, this.port = lanSyncPort});
  final String account;
  final String name;
  final int port;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> req) onRequest;

  HttpServer? _http;
  RawDatagramSocket? _udp;
  bool get running => _http != null;

  Future<void> start() async {
    if (_http != null) return;
    _http = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
    _http!.listen(_handle);
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, lanDiscoveryPort, reuseAddress: true);
      _udp!.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = _udp?.receive();
        if (d == null) return;
        final msg = utf8.decode(d.data, allowMalformed: true);
        if (msg == 'JUNELS?${account.substring(0, 12)}') {
          _udp?.send(utf8.encode('JUNELS!$port|$name'), d.address, d.port);
        }
      });
    } catch (_) {
      // Suche nicht möglich (Port belegt) – Verbindung per Adresse geht trotzdem
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    Future<void> reply(int code, Object body) async {
      final data = utf8.encode(jsonEncode(body));
      res
        ..statusCode = code
        ..headers.contentType = ContentType.json
        ..contentLength = data.length
        ..add(data);
      await res.close();
    }

    try {
      if (req.uri.path != '/junels-sync') return await reply(404, {'error': 'unbekannt'});
      if (req.method == 'GET') return await reply(200, {'ok': true, 'name': name});
      if (req.method != 'POST') return await reply(405, {'error': 'nur POST'});
      final body = (jsonDecode(await utf8.decodeStream(req)) as Map).cast<String, dynamic>();
      if (body['account'] != account) return await reply(403, {'error': 'Anderes Sync-Passwort auf dem Partnergerät'});
      await reply(200, await onRequest(body));
    } catch (e) {
      try {
        await reply(500, {'error': e.toString()});
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    await _http?.close(force: true);
    _http = null;
    _udp?.close();
    _udp = null;
  }

  /// IPv4-Adressen dieses Geräts im lokalen Netz.
  static Future<List<String>> localAddresses() async {
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return [
        for (final i in ifs)
          for (final a in i.addresses)
            if (!a.isLoopback && !a.isLinkLocal) a.address,
      ];
    } catch (_) {
      return const [];
    }
  }
}

/// Partner im WLAN suchen (UDP-Broadcast).
Future<List<LanPeer>> discoverLanPeers(String account, {Duration wait = const Duration(seconds: 2)}) async {
  final peers = <String, LanPeer>{};
  RawDatagramSocket? s;
  try {
    s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    s.broadcastEnabled = true;
    final ask = utf8.encode('JUNELS?${account.substring(0, 12)}');
    final sub = s.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final d = s?.receive();
      if (d == null) return;
      final m = RegExp(r'^JUNELS!(\d+)\|(.*)$').firstMatch(utf8.decode(d.data, allowMalformed: true));
      if (m != null) peers[d.address.address] = LanPeer(d.address.address, int.parse(m.group(1)!), m.group(2)!);
    });
    for (var i = 0; i < 3; i++) {
      s.send(ask, InternetAddress('255.255.255.255'), lanDiscoveryPort);
      await Future<void>.delayed(wait ~/ 3);
    }
    await sub.cancel();
  } catch (_) {
  } finally {
    s?.close();
  }
  return peers.values.toList();
}
