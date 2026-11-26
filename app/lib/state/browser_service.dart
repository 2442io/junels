// Eingebauter Browser (WebView), den der Agent bedient und der Nutzer live sieht.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'background_work.dart';
import 'voice_service.dart' show appLog;

class BrowserService extends ChangeNotifier implements BrowserDriver {
  BrowserService({required this.confirmer, required this.currentChat, this.outDir});

  /// Ordner für heruntergeladene Dateien (Rechnungen …)
  final Directory Function()? outDir;

  /// Meldet, wenn der Nutzer übernehmen soll (Text) bzw. fertig ist (null) – für Web-Jobs (Push, Status).
  void Function(String? message)? onHandOver;

  // ------------------------------------------------------------ Vormachen (Aufnahme)

  bool recording = false;
  String recordStart = '';
  final List<Map<String, dynamic>> recorded = [];

  /// Aufnahme starten: Seite öffnen, Junels merkt sich Klicks, Eingaben und Auswahl
  Future<void> startRecording(Uri start, {required String conversation}) async {
    recorded.clear();
    recording = true;
    recordStart = start.toString();
    conversationId = conversation;
    dismissed = false;
    expanded = true;
    activity = 'nimmt auf – mach es einfach vor';
    notifyListeners();
    final first = _c == null;
    controller;
    if (first) await Future<void>.delayed(const Duration(milliseconds: 1200));
    await open(start);
    await _injectRecorder();
  }

  /// Aufnahme beenden → rohe Ereignisse
  List<Map<String, dynamic>> stopRecording() {
    recording = false;
    activity = '';
    final out = List<Map<String, dynamic>>.of(recorded);
    notifyListeners();
    return out;
  }

  Future<void> _injectRecorder() async {
    if (!recording || _c == null) return;
    try {
      await _c!.runJavaScript(browserRecordJs);
    } catch (_) {}
  }

  /// Während eines Web-Jobs gehört der Browser fest zu diesem Chat („Ergebnisse“)
  String? pinned;

  /// Browser einem Chat zuordnen (z. B. „Ergebnisse“ für Web-Jobs), ohne ihn aufzuklappen
  Future<void> showFor(String conversation, {bool pin = false}) async {
    final first = _c == null;
    controller;
    if (pin) pinned = conversation;
    conversationId = conversation;
    dismissed = false;
    notifyListeners();
    if (first) await Future<void>.delayed(const Duration(milliseconds: 1200));
  }

  // ------------------------------------------------------------ Herunterladen

  /// Datei mit der Anmeldung der Seite laden (fetch im Browser), sonst direkt. → Pfad
  Future<String?> download(String url, String name) async {
    final dir = outDir?.call();
    if (dir == null) return null;
    Uint8List? bytes;
    var type = '', disp = '';
    if (_c != null) {
      try {
        await _c!.runJavaScript(_dlStartJs(url));
        final until = DateTime.now().add(const Duration(seconds: 60));
        Map<String, dynamic> st = const {};
        while (DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          st = _dec(await _c!.runJavaScriptReturningResult(_dlStateJs));
          if (st['state'] == 'ok' || st['state'] == 'err') break;
        }
        if (st['state'] == 'ok') {
          type = '${st['type'] ?? ''}';
          disp = '${st['disp'] ?? ''}';
          final len = (st['len'] as num).toInt();
          final b = StringBuffer();
          for (var i = 0; i < len; i += 400000) {
            final part = await _c!.runJavaScriptReturningResult('(function(){return window.__jdl.data.substr($i,400000);})()');
            var p = part is String ? part : '$part';
            if (p.startsWith('"') && p.endsWith('"')) p = jsonDecode(p) as String;
            b.write(p);
          }
          bytes = base64Decode(b.toString());
          await _c!.runJavaScript('window.__jdl=null;');
        } else {
          appLog('Browser', 'Download im Browser: ${st['error'] ?? 'Zeitüberschreitung'}', error: true);
        }
      } catch (e) {
        appLog('Browser', 'Download im Browser: $e', error: true);
      }
    }
    if (bytes == null) {
      // ohne Anmeldung direkt laden (öffentliche/signierte Links)
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
        final req = await client.getUrl(Uri.parse(url));
        final res = await req.close();
        if (res.statusCode >= 400) return null;
        final b = BytesBuilder();
        await for (final chunk in res) {
          b.add(chunk);
          if (b.length > 15 * 1024 * 1024) return null;
        }
        bytes = b.takeBytes();
        type = res.headers.contentType?.mimeType ?? '';
        disp = res.headers.value('content-disposition') ?? '';
        client.close();
      } catch (_) {
        return null;
      }
    }
    var file = RegExp(r'''filename\*?=(?:UTF-8'')?"?([^";]+)''', caseSensitive: false).firstMatch(disp)?.group(1);
    file = file == null ? name : Uri.decodeComponent(file);
    file = file.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), ' ').trim();
    if (file.isEmpty) file = 'Datei';
    if (!file.contains('.')) {
      final isPdf = type.contains('pdf') || (bytes.length > 4 && String.fromCharCodes(bytes.sublist(0, 4)) == '%PDF');
      file = '$file.${isPdf ? 'pdf' : (type.contains('png') ? 'png' : (type.contains('jpeg') ? 'jpg' : 'bin'))}';
    }
    dir.createSync(recursive: true);
    var f = File('${dir.path}/$file');
    for (var i = 2; f.existsSync(); i++) {
      final dot = file.lastIndexOf('.');
      f = File('${dir.path}/${file.substring(0, dot)} ($i)${file.substring(dot)}');
    }
    await f.writeAsBytes(bytes);
    return f.path;
  }

  static Map<String, dynamic> _dec(Object raw) {
    Object? v = raw;
    for (var i = 0; i < 3 && v is String; i++) {
      try {
        v = jsonDecode(v);
      } catch (_) {
        break;
      }
    }
    return v is Map<String, dynamic> ? v : const {};
  }

  static String _dlStartJs(String url) => '''
(function(){window.__jdl={state:'run'};
fetch(${jsonEncode(url)},{credentials:'include'}).then(function(r){if(!r.ok)throw new Error('HTTP '+r.status);
var ct=r.headers.get('content-type')||'';var cd=r.headers.get('content-disposition')||'';
return r.blob().then(function(b){if(b.size>15000000)throw new Error('zu groß');var fr=new FileReader();
fr.onload=function(){var d=String(fr.result);d=d.substring(d.indexOf(',')+1);window.__jdl={state:'ok',type:ct,disp:cd,data:d};};fr.readAsDataURL(b);});
}).catch(function(e){window.__jdl={state:'err',error:String(e)};});})()
''';

  static const _dlStateJs = r'''
(function(){var d=window.__jdl||{};if(d.state!=='ok')return JSON.stringify({state:d.state||'',error:d.error||''});
return JSON.stringify({state:'ok',type:d.type,disp:d.disp,len:d.data.length});})()
''';

  final Future<bool> Function(String title, String detail) confirmer;

  /// Id des gerade offenen Chats – der Browser gehört zu dem Chat, in dem er benutzt wurde.
  final String? Function() currentChat;

  WebViewController? _c;

  /// Chat, zu dem die Browser-Leiste gehört.
  String? conversationId;

  /// Seite aufgeklappt sichtbar (sonst nur die Leiste).
  bool expanded = false;

  /// Leiste für diesen Chat geschlossen.
  bool dismissed = false;

  /// Leiste sichtbar = Browser wurde in diesem Chat benutzt.
  bool get visible => _c != null && !dismissed && conversationId != null && conversationId == currentChat();

  bool get created => _c != null;

  /// Was der Agent gerade tut (für die Leiste).
  String activity = '';
  bool loading = false;
  int progress = 0;
  String url = '';
  String title = '';
  String? error;

  /// Hinweis, wenn der Nutzer selbst übernehmen soll (Captcha, Anmeldung …).
  String? handOverMessage;
  Completer<bool>? _handOver;

  int _navCount = 0;
  int _mark = 0;
  Completer<void>? _loaded;

  bool get hasPage => _c != null && url.isNotEmpty;

  WebViewController get controller => _c ??= _create();

  WebViewController _create() {
    final c = WebViewController();
    unawaited(c.setJavaScriptMode(JavaScriptMode.unrestricted).catchError((Object _) {}));
    // Vormachen: die Seite meldet Klicks und Eingaben über diesen Kanal
    unawaited(c.addJavaScriptChannel('JunelsRec', onMessageReceived: (m) {
      if (!recording) return;
      try {
        final e = (jsonDecode(m.message) as Map).cast<String, dynamic>();
        recorded.add(e);
        notifyListeners();
      } catch (_) {}
    }).catchError((Object _) {}));
    unawaited(c.setNavigationDelegate(NavigationDelegate(
      onPageStarted: (u) {
        _navCount++;
        loading = true;
        error = null;
        url = u;
        notifyListeners();
      },
      onProgress: (p) {
        progress = p;
        notifyListeners();
      },
      onPageFinished: (u) async {
        loading = false;
        url = u;
        try {
          title = await c.getTitle() ?? '';
        } catch (_) {}
        final l = _loaded;
        if (l != null && !l.isCompleted) l.complete();
        if (recording) unawaited(_injectRecorder());
        notifyListeners();
      },
      onWebResourceError: (e) {
        if (e.isForMainFrame ?? true) {
          error = e.description;
          loading = false;
          final l = _loaded;
          if (l != null && !l.isCompleted) l.complete();
          notifyListeners();
        }
      },
      // Nur Webseiten – keine App-Links (intent://, market:// …)
      onNavigationRequest: (r) {
        final s = Uri.tryParse(r.url)?.scheme ?? '';
        return s == 'http' || s == 'https' || s == 'about' || s == 'data' || s == 'blob'
            ? NavigationDecision.navigate
            : NavigationDecision.prevent;
      },
    )).catchError((Object _) {}));
    return c;
  }

  @override
  Future<void> show() async {
    final first = _c == null;
    controller;
    conversationId = pinned ?? currentChat();
    dismissed = false;
    notifyListeners();
    // Die Ansicht muss erst im Fenster hängen (und eine Größe haben), bevor sie lädt
    if (first) await Future<void>.delayed(const Duration(milliseconds: 1200));
  }

  void hide() {
    dismissed = true;
    expanded = false;
    notifyListeners();
  }

  void toggleExpanded() {
    expanded = !expanded;
    notifyListeners();
  }

  void setActivity(String a) {
    activity = a;
    notifyListeners();
  }

  @override
  Future<void> open(Uri u) async {
    appLog('Browser', 'öffne $u');
    activity = 'öffnet ${u.host}';
    _loaded = Completer<void>();
    error = null;
    loading = true;
    url = u.toString();
    notifyListeners();
    await controller.loadRequest(u);
    await _loaded!.future.timeout(const Duration(seconds: 25), onTimeout: () {});
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (error != null) throw ToolException('Seite nicht erreichbar: $error');
  }

  @override
  Future<String> eval(String js) async {
    _mark = _navCount;
    final r = await controller.runJavaScriptReturningResult(js);
    return r is String ? r : jsonEncode(r);
  }

  @override
  Future<void> settle() async {
    // Auf eine ausgelöste Navigation warten (max. 1,5 s bis sie beginnt, 20 s bis sie fertig ist)
    for (var i = 0; i < 15 && _navCount == _mark && !loading; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final until = DateTime.now().add(const Duration(seconds: 20));
    while (loading && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    // Inhalte, die per JavaScript nachgeladen werden
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }

  @override
  Future<void> back() async {
    if (await controller.canGoBack()) {
      _mark = _navCount;
      await controller.goBack();
    }
  }

  Future<void> reload() => controller.reload();

  @override
  Future<bool> confirm(String title, String detail) => confirmer(title, detail);

  @override
  Future<bool> handOver(String message) async {
    dismissed = false;
    expanded = true;
    conversationId ??= currentChat();
    handOverMessage = message;
    final c = _handOver = Completer<bool>();
    onHandOver?.call(message);
    notifyListeners();
    final ok = await c.future.timeout(const Duration(minutes: 20), onTimeout: () => false);
    handOverMessage = null;
    _handOver = null;
    onHandOver?.call(null);
    notifyListeners();
    return ok;
  }

  /// Vom Knopf im Browser-Fenster: Nutzer ist fertig (true) oder bricht ab (false).
  void finishHandOver(bool ok) {
    final c = _handOver;
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  // ------------------------------------------------------------ Warten & melden

  /// Beobachtung der offenen Seite (Warteschlange, Termin frei …). null = keine.
  PageWatch? watch;
  Timer? _watchTimer;

  /// Seite im Browser beobachten, bis [until] erscheint – ohne [until]: bis die Warteschlange vorbei ist
  /// oder sich die Seite deutlich ändert. [onHit] meldet das Ergebnis (Benachrichtigung).
  void startWatch({String until = '', int everySeconds = 20, required void Function(String message) onHit}) {
    stopWatch();
    final w = watch = PageWatch(until: until.trim(), since: DateTime.now(), startUrl: url);
    Future<void> tick() async {
      if (watch != w || _c == null) return;
      try {
        // Normale Seiten (kein Warteraum) neu laden, um Änderungen zu sehen; Warteräume aktualisieren sich selbst
        if (w.checks > 0 && w.reload && w.checks % 2 == 0) {
          await controller.reload();
          await Future<void>.delayed(const Duration(seconds: 5));
          if (watch != w) return;
        }
        final raw = await controller.runJavaScriptReturningResult(_watchJs);
        Object? v = raw;
        for (var i = 0; i < 3 && v is String; i++) {
          try {
            v = jsonDecode(v);
          } catch (_) {
            break;
          }
        }
        if (v is! Map) return;
        final text = '${v['text'] ?? ''}';
        final now = '${v['url'] ?? ''}';
        final low = text.toLowerCase();
        w
          ..checks += 1
          ..last = DateTime.now()
          ..position = _position(text) ?? w.position
          ..waitText = _waitTime(text) ?? w.waitText;
        final head = low.length > 1500 ? low.substring(0, 1500) : low;
        if (w.firstText == null) {
          w.firstText = head;
          w.reload = !(_queueWords.hasMatch(low) || _queueHost.hasMatch(now));
        }
        String? hit;
        if (w.until.isNotEmpty) {
          if (low.contains(w.until.toLowerCase())) hit = '„${w.until}“ ist jetzt auf der Seite.';
        } else {
          final queue = _queueWords.hasMatch(low) || _queueHost.hasMatch(now);
          if (queue) w.sawQueue = true;
          final hostNow = Uri.tryParse(now)?.host ?? '', hostStart = Uri.tryParse(w.startUrl)?.host ?? '';
          if (w.sawQueue && !queue) {
            hit = 'Die Warteschlange ist vorbei – du bist dran!';
          } else if (_yourTurn.hasMatch(low)) {
            hit = 'Du bist an der Reihe!';
          } else if (w.sawQueue && hostNow.isNotEmpty && hostNow != hostStart && !_queueHost.hasMatch(now)) {
            hit = 'Die Seite hat weitergeleitet – du bist durch.';
          } else if (w.position != null && w.position! <= 3) {
            hit = 'Fast dran: Position ${w.position}.';
          } else if (!w.sawQueue && w.checks > 1 && _changed(w.firstText!, head)) {
            hit = 'Die Seite hat sich geändert.';
          }
        }
        if (hit != null) {
          stopWatch();
          onHit(hit);
          return;
        }
        notifyListeners();
      } catch (e) {
        appLog('Browser', 'Beobachten: $e', error: true);
      }
    }

    _watchTimer = Timer.periodic(Duration(seconds: everySeconds.clamp(15, 900)), (_) => tick());
    // App im Hintergrund am Leben halten, solange beobachtet wird
    unawaited(BackgroundWork.begin('watch', 'Junels beobachtet eine Webseite …').catchError((Object _) {}));
    unawaited(tick());
    notifyListeners();
  }

  void stopWatch() {
    if (_watchTimer != null) unawaited(BackgroundWork.end('watch').catchError((Object _) {}));
    _watchTimer?.cancel();
    _watchTimer = null;
    if (watch != null) {
      watch = null;
      notifyListeners();
    }
  }

  static final _queueWords = RegExp(
      r'warteschlange|wartezimmer|warteraum|sie sind in der|ihre position|ihr platz|vor ihnen|waiting room|in line|queue|you are now in|your number|estimated wait|voraussichtliche wartezeit');
  static final _queueHost = RegExp(r'queue-it|queueit|queue\.|waitingroom|waiting-room|crowdhandler', caseSensitive: false);
  static final _yourTurn = RegExp(r"sie sind (jetzt )?an der reihe|you'?re next|it'?s your turn|du bist dran|ihre zeit beginnt");

  /// Deutliche Änderung (nicht nur Uhrzeit/Zähler): Wörter vergleichen.
  static bool _changed(String a, String b) {
    Set<String> w(String s) => RegExp(r'[a-zäöüß]{4,}').allMatches(s).map((m) => m.group(0)!).toSet();
    final x = w(a), y = w(b);
    if (x.isEmpty || y.isEmpty) return false;
    final same = x.intersection(y).length;
    return same / (x.length > y.length ? x.length : y.length) < 0.8;
  }

  static int? _position(String text) {
    final m = RegExp(r'(position|platz|nummer|number in line|your number|vor ihnen|ahead of you|people ahead)[^\d]{0,40}(\d[\d.,]*)',
            caseSensitive: false)
        .firstMatch(text);
    return m == null ? null : int.tryParse(m.group(2)!.replaceAll(RegExp(r'[.,]'), ''));
  }

  static String? _waitTime(String text) {
    final m = RegExp(r'(wartezeit|wait time|estimated wait|noch etwa|noch ca\.?)[^\d]{0,30}(\d+\s*(min|minuten|minutes|std|stunden|hours|sek|seconds)[^\n.]{0,10})',
            caseSensitive: false)
        .firstMatch(text);
    return m?.group(2)?.trim();
  }

  static const _watchJs = r'''
(function(){var b=document.body;var t=(b?(b.innerText||''):'').replace(/\s+/g,' ').trim();
return JSON.stringify({url:location.href,text:t.slice(0,5000)});})()
''';
}

/// Laufende Beobachtung einer Seite.
class PageWatch {
  PageWatch({required this.until, required this.since, required this.startUrl});
  final String until;
  final DateTime since;
  final String startUrl;
  int checks = 0;
  DateTime? last;
  int? position;
  String? waitText;
  String? firstText;
  bool sawQueue = false;
  bool reload = false;

  String get label {
    final parts = <String>[
      if (until.isNotEmpty) 'wartet auf „$until“' else 'beobachtet die Seite',
      if (position != null) 'Position $position',
      if (waitText != null) 'noch $waitText',
    ];
    return parts.join(' · ');
  }
}
