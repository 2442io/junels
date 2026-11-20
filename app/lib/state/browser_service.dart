// Eingebauter Browser (WebView), den der Agent bedient und der Nutzer live sieht.

import 'dart:async';
import 'dart:convert';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'voice_service.dart' show appLog;

class BrowserService extends ChangeNotifier implements BrowserDriver {
  BrowserService({required this.confirmer, required this.currentChat});

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
    conversationId = currentChat();
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
    notifyListeners();
    final ok = await c.future.timeout(const Duration(minutes: 5), onTimeout: () => false);
    handOverMessage = null;
    _handOver = null;
    notifyListeners();
    return ok;
  }

  /// Vom Knopf im Browser-Fenster: Nutzer ist fertig (true) oder bricht ab (false).
  void finishHandOver(bool ok) {
    final c = _handOver;
    if (c != null && !c.isCompleted) c.complete(ok);
  }
}
