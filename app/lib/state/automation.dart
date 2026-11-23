// Watchlist und Prozesse: speichern, nach Zeitplan prüfen bzw. ausführen,
// Ergebnisse als Push-Nachricht und im Chat „Automatik“ ablegen.
//
// Prozesse: Vorab-Prüfung, Live-Status je Baustein, Stoppen, verständliche Fehler
// mit Hinweis – und auf Wunsch repariert der Agent den Baustein selbst.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';

import '../data/models.dart';
import 'activity_log.dart';
import 'app_controller.dart';
import 'notifications.dart';
import 'connections.dart';
import 'voice_service.dart' show appLog;

String _two(int v) => v.toString().padLeft(2, '0');

// ===================================================================== Watchlist

class WatchlistService {
  WatchlistService(this.app);
  final AppController app;
  final List<WatchItem> items = [];
  final WatchChecker _checker = WatchChecker();

  /// Gerade geprüfter Eintrag (für die Anzeige).
  String? checkingId;
  bool _busy = false;

  File get _file => File('${app.storage.root.path}/watchlist.json');

  int get unseen => items.fold(0, (s, i) => s + i.unseen);

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final j = jsonDecode(await _file.readAsString()) as List;
      items
        ..clear()
        ..addAll([for (final x in j) WatchItem.fromJson((x as Map).cast())]);
    } catch (e) {
      appLog('Watchlist', 'Laden fehlgeschlagen: $e', error: true);
    }
  }

  Future<void> save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final i in items) i.toJson()]));
    await tmp.rename(_file.path);
  }

  Future<void> upsert(WatchItem item, {bool checkNow = true}) async {
    final i = items.indexWhere((x) => x.id == item.id);
    if (i >= 0) {
      items[i] = item;
    } else {
      items.insert(0, item);
      unawaited(app.logActivity(Activity(
          kind: 'internet',
          title: 'Watchlist: „${item.title}“ angelegt',
          detail: item.target,
          approval: 'Du hast den Eintrag angelegt und damit den Abruf erlaubt')));
    }
    await save();
    app.refreshUi();
    unawaited(app.syncAutomationAlarms());
    if (checkNow) unawaited(check(item));
  }

  Future<void> remove(WatchItem item) async {
    items.removeWhere((x) => x.id == item.id);
    await save();
    app.refreshUi();
  }

  Future<void> markSeen(WatchItem item) async {
    var changed = false;
    for (final e in item.events) {
      if (!e.seen) {
        e.seen = true;
        changed = true;
      }
    }
    if (changed) {
      await save();
      app.refreshUi();
    }
  }

  /// Vorschau ohne Speichern („Testen“ im Dialog).
  Future<WatchPreview> preview(WatchItem item) => _checker.preview(item);

  /// Beschreibung („Prompt“) → Suchanfrage wie bei Google. Ohne Modell: Stichwörter.
  Future<String> deriveQuery(String description) async {
    final d = description.trim();
    if (d.isEmpty) return '';
    String q = '';
    try {
      q = await app.automationText(
          'Formuliere aus diesem Beobachtungswunsch EINE kurze Suchanfrage für Google News (3–8 Wörter). '
          'Nutze bei Bedarf Google-Operatoren: "genaue Phrase", -ausschließen, OR, site:domain. '
          'Antworte nur mit der Suchanfrage, ohne Erklärung.\n\nWunsch: $d',
          maxTokens: 60);
    } catch (_) {}
    q = q.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
    q = q.replaceAll(RegExp(r'^(suchanfrage|query)\s*:\s*', caseSensitive: false), '').replaceAll(RegExp(r'^[`„“]+|[`„“]+$'), '').trim();
    if (q.isEmpty || q.length > 160) q = keywordsOf(d);
    return q;
  }

  /// Einfache Stichwörter aus einem Satz (Rückfall ohne Modell).
  static String keywordsOf(String text) {
    const stop = {
      'der', 'die', 'das', 'und', 'oder', 'ein', 'eine', 'einen', 'zu', 'zum', 'zur', 'für', 'von', 'mit', 'mir', 'mich', 'ich',
      'neue', 'neuen', 'neuer', 'neues', 'alle', 'immer', 'wenn', 'sobald', 'bitte', 'melde', 'sag', 'informiere', 'über',
      'auf', 'im', 'in', 'an', 'es', 'gibt', 'etwas', 'was', 'wie', 'den', 'dem', 'des', 'bei', 'nach', 'aus', 'nur', 'keine', 'kein',
    };
    final words = text
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s.-]', unicode: true), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 2 && !stop.contains(w.toLowerCase()))
        .take(7)
        .toList();
    return words.join(' ');
  }

  /// Nächster fälliger Zeitpunkt (für den Android-Wecker).
  DateTime? get nextDue {
    DateTime? best;
    for (final i in items.where((i) => i.enabled)) {
      final d = i.lastCheck == null ? DateTime.now() : i.lastCheck!.add(Duration(minutes: i.intervalMinutes));
      if (best == null || d.isBefore(best)) best = d;
    }
    return best;
  }

  /// Prüft alle fälligen Einträge (und erstellt fällige Wochenrückblicke).
  Future<void> checkDue() async {
    final now = DateTime.now();
    for (final i in List.of(items)) {
      if (i.due(now)) await check(i);
      if (i.enabled && i.digestDue(now)) await weeklyDigest(i, now: now);
    }
  }

  /// Wochenrückblick: ein Absatz statt vieler Einzeltreffer.
  Future<WatchEvent?> weeklyDigest(WatchItem item, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    final evs = item.digestEvents();
    item.lastDigest = t;
    if (evs.isEmpty) {
      await save();
      return null;
    }
    final links = mergeDuplicates([for (final e in evs) ...e.links]);
    final list = links.take(25).map((l) => '- ${l['title']}${l['sources'] != null ? ' (auch: ${l['sources']})' : ''}').join('\n');
    var text = await app.automationText(
        'Wochenrückblick zur Beobachtung „${item.title}“. Neue Meldungen dieser Woche:\n$list\n\n'
        'Schreibe EINEN Absatz (4–6 Sätze) auf Deutsch: Was waren die wichtigsten Entwicklungen, was hängt zusammen, '
        'was ist bemerkenswert? Keine Aufzählung, keine Einleitung.',
        maxTokens: 400);
    text = text.trim();
    if (text.isEmpty) text = links.take(8).map((l) => '• ${l['title']}').join('\n');
    final ev = WatchEvent(
      time: t,
      kind: 'digest',
      title: 'Wochenrückblick „${item.title}“ (${links.length} Meldung${links.length == 1 ? '' : 'en'})',
      detail: text,
      links: links.take(12).toList(),
    );
    item.events.insert(0, ev);
    for (final e in evs) {
      e.seen = true; // im Rückblick enthalten
    }
    await save();
    app.refreshUi();
    if (item.notify) {
      unawaited(app.notifyUser(NotifyKind.info, ev.title, text.length > 220 ? '${text.substring(0, 220)}…' : text,
          target: 'watch:${item.id}', source: 'watch:${item.id}'));
    }
    final input = '${ev.title}\n\n$text\n\n${ev.links.map((l) => '- ${l['title']}: ${l['link']}').join('\n')}';
    for (final wf in app.flows.flows) {
      if (wf.enabled && item.flowId == wf.id) unawaited(app.flows.run(wf, input: input, event: ev.kind));
    }
    return ev;
  }

  /// Einzelnen Eintrag als gelesen/ungelesen markieren.
  Future<void> setSeen(WatchItem item, WatchEvent e, bool seen) async {
    e.seen = seen;
    await save();
    app.refreshUi();
  }

  /// Beschreibungs-Modus: Der Agent prüft, welche neuen Treffer wirklich passen.
  Future<void> _filterRelevant(WatchItem item, WatchEvent ev) async {
    if (ev.links.isEmpty) return;
    final list = [for (var i = 0; i < ev.links.length; i++) '${i + 1}. ${ev.links[i]['title']}${ev.links[i]['note'] == null ? '' : ' – ${ev.links[i]['note']}'}'];
    final r = await app.automationText(
        'Beobachtungswunsch: "${item.target}"\n\nNeue Treffer:\n${list.join('\n')}\n\n'
        'Welche Treffer passen wirklich zum Wunsch? Antworte nur mit den Nummern, durch Komma getrennt (z. B. 1,3). '
        'Passt keiner, antworte 0.',
        maxTokens: 40);
    if (r.trim().isEmpty) return; // kein Modell: alles behalten
    final keep = {for (final m in RegExp(r'\d+').allMatches(r)) int.parse(m.group(0)!)};
    if (keep.length == 1 && keep.first == 0) {
      ev.links.clear();
      return;
    }
    final kept = [for (var i = 0; i < ev.links.length; i++) if (keep.contains(i + 1)) ev.links[i]];
    if (kept.isEmpty) return; // Antwort nicht verstanden: lieber alles zeigen
    ev.links
      ..clear()
      ..addAll(kept);
  }

  Future<void> check(WatchItem item) async {
    if (_busy) return;
    _busy = true;
    checkingId = item.id;
    app.refreshUi();
    try {
      final r = await _checker.check(item);
      var ev = r.event;
      if (r.error != null) appLog('Watchlist', '${item.title}: ${r.error}', error: true);
      if (ev != null && item.kind == WatchKind.topic && item.promptMode) {
        await _filterRelevant(item, ev);
        if (ev.links.isEmpty) {
          item.events.remove(ev);
          appLog('Watchlist', '${item.title}: neue Treffer, aber keiner passt zur Beschreibung');
          ev = null;
        } else {
          ev.detail = ev.links.take(5).map((f) => '• ${f['title']}').join('\n');
        }
      }
      if (ev != null && ev.kind == 'quiet') {
        // nur für den Wochenrückblick gesammelt – keine Meldung
        appLog('Watchlist', '${item.title}: ${ev.title} (für den Rückblick gesammelt)');
        ev = null;
      }
      if (ev != null) {
        appLog('Watchlist', '${item.title}: ${ev.title}');
        if (item.summarize && ev.kind != 'alert') {
          final sum = await app.automationText(
              'Die beobachtete ${item.kind == WatchKind.page ? 'Webseite' : 'Suche zum Thema'} „${item.title}“ hat Neues:\n\n'
              '${ev.detail}\n\n${ev.links.take(8).map((l) => '- ${l['title']}').join('\n')}\n\n'
              'Fasse in 2–3 Sätzen auf Deutsch zusammen, was neu ist und warum es relevant sein könnte. Keine Einleitung.');
          if (sum.trim().isNotEmpty) ev.detail = '${sum.trim()}\n\n${ev.detail}';
        }
        if (item.notify) {
          final body = ev.detail.replaceAll(RegExp(r'\s+'), ' ').trim();
          unawaited(app.notifyUser(ev.kind == 'alert' ? NotifyKind.warnung : NotifyKind.info, ev.title,
              body.length > 220 ? '${body.substring(0, 220)}…' : body,
              target: 'watch:${item.id}', source: 'watch:${item.id}'));
        }
        final input = '${ev.title}\n\n${ev.detail}\n\n${ev.links.map((l) => '- ${l['title']}: ${l['link']}').join('\n')}';
        // Prozesse, die auf diesen Eintrag warten
        for (final wf in app.flows.flows) {
          final t = wf.trigger;
          if (!wf.enabled || t == null || t.str('mode') != 'watch') continue;
          final owned = item.flowId == wf.id;
          final legacy = t.config['watchInline'] != true && item.flowId == null && (t.str('watchId').isEmpty || t.str('watchId') == item.id);
          if (owned || legacy) unawaited(app.flows.run(wf, input: input, event: ev.kind));
        }
      }
      await save();
    } finally {
      _busy = false;
      checkingId = null;
      app.refreshUi();
    }
  }

  /// Auslöser „Beobachten“ eines Prozesses → zugehöriger Watchlist-Eintrag.
  WatchItem? forFlow(String flowId) => items.where((i) => i.flowId == flowId).firstOrNull;

  /// Hält den Eintrag eines Prozesses mit seinem Auslöser im Gleichklang (anlegen, ändern, entfernen).
  Future<void> syncFlow(Workflow wf) async {
    final t = wf.trigger;
    final existing = forFlow(wf.id);
    final wanted = t != null && t.str('mode') == 'watch' && t.config['watchInline'] == true && t.str('watchTarget').trim().isNotEmpty;
    if (!wanted) {
      if (existing != null) {
        items.remove(existing);
        await save();
      }
      return;
    }
    final kind = t.str('watchKind', 'page') == 'topic' ? WatchKind.topic : WatchKind.page;
    var target = t.str('watchTarget').trim();
    if (kind == WatchKind.page && !target.startsWith('http')) target = 'https://$target';
    final interval = (t.config['interval'] as num?)?.toInt() ?? 60;
    final prompt = t.config['promptMode'] == true && kind == WatchKind.topic;
    final recent = t.config['recentOnly'] == true;
    final item = existing ?? WatchItem(id: 'wf-${wf.id}', kind: kind, title: wf.name, target: target, notify: false, summarize: false, flowId: wf.id);
    final alertOp = t.str('alertOp');
    final alertValue = (t.config['alertValue'] as num?)?.toDouble();
    final changed = existing == null ||
        item.target != target ||
        item.kind != kind ||
        item.promptMode != prompt ||
        item.alertOp != alertOp ||
        item.alertValue != alertValue;
    if (item.alertOp != alertOp || item.alertValue != alertValue || item.target != target) {
      item
        ..alertArmed = true
        ..symbol = t.str('symbol');
    }
    item
      ..alertOp = alertValue == null ? '' : alertOp
      ..alertValue = alertValue
      ..valueLabel = t.str('valueLabel')
      ..digest = t.str('digest');
    item
      ..kind = kind
      ..title = wf.name
      ..target = target
      ..intervalMinutes = interval < 1 ? 1 : interval
      ..promptMode = prompt
      ..recentOnly = recent
      ..enabled = wf.enabled
      ..notify = false
      ..summarize = false
      ..flowId = wf.id;
    if (prompt) {
      final q = t.str('watchQuery').trim();
      item.query = q.isNotEmpty ? q : keywordsOf(target);
    } else {
      item.query = '';
    }
    if (changed && existing != null) {
      // neu beginnen: die nächste Prüfung (spätestens in 30 s) merkt sich den Ausgangsstand
      item
        ..fingerprint = null
        ..snapshot = ''
        ..lastCheck = null
        ..seenLinks.clear();
    }
    if (existing == null) items.insert(0, item);
    await save();
    unawaited(app.syncAutomationAlarms());
  }
}

// ====================================================================== Prozesse

/// Was beim Vorab-Check geprüft wurde.
class PreflightCheck {
  PreflightCheck(this.label, {this.ok = true, this.warn = false, this.detail = '', this.nodeId, this.fix});
  final String label;
  final bool ok;

  /// Hinweis, aber kein Hindernis.
  final bool warn;
  final String detail;
  final String? nodeId;

  /// Mögliche Behebung (z. B. 'internet', 'login:<serverId>', 'conn:<id>', 'node').
  final String? fix;
}

/// Fehler eines Bausteins mit Hinweis für Menschen.
class FlowError {
  FlowError(this.message, this.hint, {this.fix});
  final String message;
  final String hint;

  /// Automatisch behebbar ohne Agent (z. B. 'internet' = Internet erlauben).
  final String? fix;
}

class _Cancelled implements Exception {
  @override
  String toString() => 'Vom Nutzer gestoppt';
}

class FlowService {
  FlowService(this.app);
  final AppController app;
  final List<Workflow> flows = [];

  /// Zustand je Prozess und Baustein: pending | running | done | skipped | error | stopped
  final Map<String, Map<String, String>> state = {};

  /// Ergebnis je Baustein des letzten Laufs.
  final Map<String, Map<String, String>> outputs = {};

  /// Fehler je Baustein des letzten Laufs.
  final Map<String, Map<String, FlowError>> errors = {};

  /// Gerade laufender Baustein und Startzeit des Laufs (für die Anzeige).
  final Map<String, String> current = {};
  final Map<String, DateTime> startedAt = {};

  /// Was der laufende Baustein gerade tut (Live-Ansicht).
  final Map<String, String> live = {};

  final Set<String> _running = {};
  final Map<String, Completer<void>> _cancel = {};

  bool isRunning(String id) => _running.contains(id);

  File get _file => File('${app.storage.root.path}/flows.json');

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final j = jsonDecode(await _file.readAsString()) as List;
      flows
        ..clear()
        ..addAll([for (final x in j) Workflow.fromJson((x as Map).cast())]);
    } catch (e) {
      appLog('Prozesse', 'Laden fehlgeschlagen: $e', error: true);
    }
  }

  Future<void> save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final f in flows) f.toJson()]));
    await tmp.rename(_file.path);
    unawaited(app.syncAutomationAlarms());
  }

  Future<void> upsert(Workflow wf) async {
    final i = flows.indexWhere((x) => x.id == wf.id);
    if (i >= 0) {
      flows[i] = wf;
    } else {
      flows.insert(0, wf);
    }
    await save();
    await app.watchlist.syncFlow(wf);
    app.refreshUi();
  }

  /// Kopie eines Prozesses (pausiert, ohne Verlauf) – zum Anpassen statt neu Anlegen.
  Future<Workflow> duplicate(Workflow wf) async {
    final j = wf.toJson()
      ..['id'] = newId()
      ..['name'] = copyName(wf.name, {for (final f in flows) f.name})
      ..remove('lastRun')
      ..remove('lastStatus');
    final copy = Workflow.fromJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>)..enabled = false;
    // Beobachten-Auslöser: eigener Watchlist-Eintrag statt Verweis auf den des Originals
    final t = copy.trigger;
    if (t != null && t.str('mode') == 'watch' && t.config['watchInline'] != true) t.config.remove('watchId');
    await upsert(copy);
    return copy;
  }

  Future<void> remove(Workflow wf) async {
    stop(wf);
    flows.removeWhere((x) => x.id == wf.id);
    state.remove(wf.id);
    outputs.remove(wf.id);
    errors.remove(wf.id);
    final w = app.watchlist.forFlow(wf.id);
    if (w != null) await app.watchlist.remove(w);
    await save();
    app.refreshUi();
  }

  Set<String> get toolNames => {for (final t in app.tools) t.name, for (final t in app.mcpTools) t.name};

  /// Prozess aus einer Beschreibung erzeugen (Modell, sonst einfache Vorlage).
  Future<Workflow> generate(String description) async {
    // „Melde dich, wenn die Nvidia-Aktie unter 120 fällt“ → Beobachtung mit Schwellenwert
    final alert = parseAlertRequest(description);
    if (alert != null && alert.subject.isNotEmpty && RegExp(r'melde|sag|benachrichtig|informier|bescheid|push|wenn|sobald', caseSensitive: false).hasMatch(description)) {
      final url = RegExp(r'https?://\S+').firstMatch(description)?.group(0);
      final wf = watchFlow(
        name: '${alert.subject} ${alert.op == 'below' ? 'unter' : 'über'} ${formatNumber(alert.value)}',
        kind: url != null ? WatchKind.page : WatchKind.topic,
        target: url ?? alert.subject,
        interval: 15,
        summarize: false,
        alertOp: alert.op,
        alertValue: alert.value,
      )..description = description;
      appLog('Prozesse', 'Schwellenwert erkannt: ${wf.name}');
      return wf;
    }
    final id = newId();
    final tools = [for (final t in app.activeTools) (t.name, t.title)];
    final text = await app.automationText(Workflow.generationPrompt(description, tools), grammar: Workflow.jsonGrammar, maxTokens: 1400);
    final wf = Workflow.fromModelJson(text, id: id, toolNames: toolNames) ?? Workflow.fromDescription(description, id: id);
    if (wf.description.isEmpty) wf.description = description;
    if (wf.name == 'Neuer Prozess') wf.name = Workflow.fromDescription(description, id: id).name;
    appLog('Prozesse', 'Erzeugt: ${wf.name} (${wf.nodes.length} Bausteine)');
    return wf;
  }

  /// Prozess „Beobachten“: Auslöser mit Beobachtung → (Zusammenfassen) → Push.
  Workflow watchFlow({
    required String name,
    required WatchKind kind,
    required String target,
    required int interval,
    bool promptMode = false,
    bool recentOnly = false,
    String query = '',
    bool summarize = true,
    bool notify = true,
    String alertOp = '',
    double? alertValue,
    String valueLabel = '',
    String digest = '',
  }) {
    final wf = Workflow(id: newId(), name: name, description: 'Beobachtet ${kind == WatchKind.page ? 'die Seite' : 'das Thema'} „$target“.');
    wf.nodes.add(FlowNode(id: 'n1', type: FlowNodeType.trigger, title: 'Beobachten', config: {
      'mode': 'watch',
      'watchInline': true,
      'watchKind': kind == WatchKind.topic ? 'topic' : 'page',
      'watchTarget': target,
      'interval': interval,
      if (promptMode) 'promptMode': true,
      if (recentOnly) 'recentOnly': true,
      if (query.isNotEmpty) 'watchQuery': query,
      if (alertOp.isNotEmpty && alertValue != null) 'alertOp': alertOp,
      if (alertOp.isNotEmpty && alertValue != null) 'alertValue': alertValue,
      if (valueLabel.isNotEmpty) 'valueLabel': valueLabel,
      if (digest.isNotEmpty) 'digest': digest,
    }));
    var last = 'n1';
    if (summarize) {
      wf.nodes.add(FlowNode(id: 'n2', type: FlowNodeType.agent, title: 'Zusammenfassen', config: {
        'prompt': 'Fasse in 2–3 Sätzen auf Deutsch zusammen, was neu ist und warum es relevant sein könnte. Keine Einleitung.\n\n{{vorher}}',
      }));
      wf.connect(last, 'n2');
      last = 'n2';
    }
    if (notify) {
      wf.nodes.add(FlowNode(id: 'n3', type: FlowNodeType.notify, title: 'Push-Nachricht', config: {'title': name, 'text': '{{vorher}}'}));
      wf.connect(last, 'n3');
    }
    wf.layout();
    return wf;
  }

  /// Fällige Prozesse starten (Zeitplan).
  void checkDue() {
    final now = DateTime.now();
    for (final wf in flows) {
      if (wf.dueAt(now) && !isRunning(wf.id)) {
        unawaited(run(wf));
        return;
      }
    }
  }

  void _set(Workflow wf, String node, String s) {
    (state[wf.id] ??= {})[node] = s;
    if (s == 'running') {
      current[wf.id] = node;
    } else if (current[wf.id] == node) {
      current.remove(wf.id);
    }
    app.refreshUi();
  }

  /// Laufenden Prozess anhalten (bricht den aktuellen Baustein ab).
  void stop(Workflow wf) {
    final c = _cancel[wf.id];
    if (c == null || c.isCompleted) return;
    c.complete();
    // läuft gerade ein Agent-Auftrag dieses Prozesses: Modell anhalten
    if (app.running && app.runningConvId == 'automatik') app.stop();
    appLog('Prozesse', '${wf.name}: gestoppt');
    app.refreshUi();
  }

  // ------------------------------------------------------------ Vorab-Check

  /// Prüft vor dem Start, ob der Prozess laufen kann – ohne etwas auszulösen.
  Stream<PreflightCheck> preflight(Workflow wf) async* {
    final probs = wf.problems(toolNames);
    if (wf.nodes.length < 2) yield PreflightCheck('Mindestens zwei Bausteine', ok: false, detail: 'Hänge an den Auslöser einen Baustein an.');
    if (probs.isEmpty) {
      yield PreflightCheck('Aufbau', detail: '${wf.nodes.length} Bausteine, alle verbunden');
    } else {
      for (final p in probs) {
        final n = wf.nodes.where((x) => p.contains('„${x.title}“')).firstOrNull;
        final loose = p.contains('mit nichts verbunden');
        yield PreflightCheck(p, ok: false, nodeId: n?.id, fix: loose ? 'autoconnect' : 'node');
      }
    }
    final order = wf.order();
    final needsModel = order.any((n) => n.type == FlowNodeType.agent);
    if (needsModel) {
      if (app.canChat) {
        yield PreflightCheck('Sprachmodell bereit', detail: app.loadedModel?.displayName ?? 'KI-Anbieter');
      } else if (app.models.isNotEmpty) {
        yield PreflightCheck('Sprachmodell', warn: true, detail: 'Nicht geladen – wird beim Start automatisch geladen (dauert etwas).');
      } else {
        yield PreflightCheck('Sprachmodell', ok: false, detail: 'Für Agent-Bausteine wird ein Modell oder KI-Anbieter gebraucht (Systemcheck).');
      }
    }
    final net = order.any((n) =>
        n.type == FlowNodeType.http ||
        n.type == FlowNodeType.mcp ||
        (n.type == FlowNodeType.trigger && n.str('mode') == 'watch') ||
        (n.type == FlowNodeType.tool && ([...app.tools, ...app.mcpTools].where((t) => t.name == n.str('tool')).firstOrNull?.requiresNetwork ?? false)));
    if (net && !wf.allowInternet) {
      yield PreflightCheck('Internet', ok: false, detail: 'Bausteine brauchen Internet, der Prozess darf aber nicht hinaus.', fix: 'internet');
    }
    for (final n in order) {
      switch (n.type) {
        case FlowNodeType.trigger:
          if (n.str('mode') == 'watch' && n.config['watchInline'] == true && n.str('watchTarget').trim().isNotEmpty) {
            final w = app.watchlist.forFlow(wf.id) ??
                WatchItem(
                    id: 'probe',
                    kind: n.str('watchKind') == 'topic' ? WatchKind.topic : WatchKind.page,
                    title: wf.name,
                    target: n.str('watchTarget'),
                    query: n.str('watchQuery'),
                    promptMode: n.config['promptMode'] == true,
                    recentOnly: n.config['recentOnly'] == true);
            final p = await app.watchlist.preview(w);
            yield PreflightCheck('„${n.title}“: Beobachtung', ok: p.ok, warn: !p.ok && p.message.contains('keine Treffer'), detail: p.message, nodeId: n.id, fix: p.ok ? null : 'node');
          }
        case FlowNodeType.tool:
          final t = [...app.tools, ...app.mcpTools].where((x) => x.name == n.str('tool')).firstOrNull;
          if (t != null) {
            final missing = [
              for (final p in t.params)
                if (!p.description.contains('optional') && '${((n.config['args'] as Map?) ?? const {})[p.name] ?? ''}'.trim().isEmpty) p.name
            ];
            yield PreflightCheck('„${n.title}“: ${t.title}',
                warn: missing.isNotEmpty, detail: missing.isEmpty ? 'bereit' : 'Leer: ${missing.join(', ')} – evtl. nötig', nodeId: n.id, fix: missing.isEmpty ? null : 'node');
          }
        case FlowNodeType.http:
          yield await _checkHttp(n);
        case FlowNodeType.mcp:
          yield _checkMcp(n);
        case FlowNodeType.agent:
        case FlowNodeType.condition:
        case FlowNodeType.notify:
        case FlowNodeType.save:
          break;
      }
    }
  }

  Future<PreflightCheck> _checkHttp(FlowNode n) async {
    final label = '„${n.title}“: Web-API';
    final connId = n.str('connection');
    final conn = connId.isEmpty ? null : app.connections.byId(connId);
    if (connId.isNotEmpty && conn == null) {
      return PreflightCheck(label, ok: false, detail: 'Der gewählte Zugang existiert nicht mehr.', nodeId: n.id, fix: 'node');
    }
    if (conn != null) {
      try {
        if (conn.kind == AuthKind.oauth && !await app.connections.signedIn(conn)) {
          return PreflightCheck(label, ok: false, detail: 'Zugang „${conn.name}“ ist nicht angemeldet.', nodeId: n.id, fix: 'conn:${conn.id}');
        }
        if (const {AuthKind.apiKey, AuthKind.bearer, AuthKind.basic}.contains(conn.kind) && !await app.connections.hasSecret(conn)) {
          return PreflightCheck(label, ok: false, detail: 'Zugang „${conn.name}“: Schlüssel/Passwort fehlt.', nodeId: n.id, fix: 'conn:${conn.id}');
        }
      } catch (e) {
        return PreflightCheck(label, ok: false, detail: '$e', nodeId: n.id, fix: 'conn:${conn.id}');
      }
    }
    final raw = n.str('url').trim();
    if (raw.contains('{{')) return PreflightCheck(label, warn: true, detail: 'Adresse enthält Platzhalter – wird erst beim Lauf geprüft.', nodeId: n.id);
    final u = _resolveUrl(raw, conn);
    if (u == null || u.host.isEmpty) return PreflightCheck(label, ok: false, detail: 'Ungültige Adresse.', nodeId: n.id, fix: 'node');
    // Nur erreichbar? (keine Anfrage schicken, die etwas verändert)
    try {
      final s = await Socket.connect(u.host, u.hasPort ? u.port : (u.isScheme('https') ? 443 : 80), timeout: const Duration(seconds: 6));
      s.destroy();
      return PreflightCheck(label, detail: '${n.str('method', 'GET')} ${u.host} erreichbar${conn == null ? '' : ' · Zugang „${conn.name}“'}', nodeId: n.id);
    } catch (e) {
      return PreflightCheck(label, ok: false, detail: '${u.host} nicht erreichbar ($e)', nodeId: n.id, fix: 'node');
    }
  }

  PreflightCheck _checkMcp(FlowNode n) {
    final label = '„${n.title}“: MCP';
    final srv = app.mcpServers.where((s) => s.id == n.str('server')).firstOrNull;
    if (srv == null) return PreflightCheck(label, ok: false, detail: 'Server nicht gefunden – im Baustein wählen.', nodeId: n.id, fix: 'node');
    if (!srv.enabled) return PreflightCheck(label, ok: false, detail: '„${srv.name}“ ist ausgeschaltet (Einstellungen → MCP).', nodeId: n.id, fix: 'mcp');
    if (app.mcpNeedsLogin.containsKey(srv.id) && !srv.loggedIn) {
      return PreflightCheck(label, ok: false, detail: '„${srv.name}“ verlangt eine Anmeldung.', nodeId: n.id, fix: 'login:${srv.id}');
    }
    if (!srv.tools.any((t) => t.name == n.str('tool'))) {
      return PreflightCheck(label, ok: false, detail: 'Tool „${n.str('tool')}“ gibt es bei „${srv.name}“ nicht.', nodeId: n.id, fix: 'node');
    }
    return PreflightCheck(label, detail: '${srv.name} · ${n.str('tool')}${srv.loggedIn ? ' · angemeldet' : ''}', nodeId: n.id);
  }

  Uri? _resolveUrl(String raw, ApiConnection? conn) {
    var url = raw.trim();
    if (!url.startsWith('http') && conn != null && conn.baseUrl.isNotEmpty) {
      url = '${conn.baseUrl.replaceFirst(RegExp(r'/+$'), '')}/${url.replaceFirst(RegExp(r'^/+'), '')}';
    } else if (!url.startsWith('http') && url.isNotEmpty) {
      url = 'https://$url';
    }
    return Uri.tryParse(url);
  }

  // ------------------------------------------------------------ Ausführen

  /// Was der Fehler bedeutet und was hilft.
  FlowError _explain(FlowNode n, Object e) {
    final msg = e is HttpCallException ? e.message : '$e'.replaceFirst('Exception: ', '');
    final m = msg.toLowerCase();
    if (e is HttpCallException) {
      return FlowError(msg, e.hint.isEmpty ? 'Adresse, Methode und Zugang prüfen.' : e.hint);
    }
    if (m.contains('nicht ins internet') || m.contains('internet nicht erlaubt')) {
      return FlowError(msg, 'In den Prozess-Einstellungen „Darf ins Internet“ einschalten.', fix: 'internet');
    }
    if (m.contains('nicht gefunden') && n.type == FlowNodeType.tool) {
      return FlowError(msg, 'Das Werkzeug ist nicht aktiv. Im Baustein ein anderes wählen oder es in den Einstellungen einschalten.');
    }
    if (m.contains('kein modell') || m.contains('modell bereit')) {
      return FlowError(msg, 'Im Systemcheck ein Sprachmodell laden oder unter Einstellungen → KI-Anbieter einen Anbieter einrichten.');
    }
    if (m.contains('keine treffer')) {
      return FlowError(msg, 'Suchbegriff anpassen (kürzer, ohne Datum) – oder den Agenten beheben lassen. Ein Agent-Baustein sucht flexibler als ein festes Werkzeug.');
    }
    if (m.contains('timeout') || m.contains('zeitüberschreitung')) {
      return FlowError(msg, 'Der Schritt hat zu lange gedauert – später erneut versuchen oder den Auftrag vereinfachen.');
    }
    if (m.contains('nicht angemeldet') || m.contains('anmeldung') || m.contains('401')) {
      return FlowError(msg, 'Beim Zugang bzw. MCP-Server neu anmelden.');
    }
    if (m.contains('socket') || m.contains('failed host lookup') || m.contains('nicht erreichbar')) {
      return FlowError(msg, 'Keine Verbindung – Internet und Adresse prüfen.');
    }
    return FlowError(msg, switch (n.type) {
      FlowNodeType.agent => 'Auftrag klarer formulieren oder den Agenten reparieren lassen.',
      FlowNodeType.tool => 'Werkzeug-Angaben prüfen.',
      FlowNodeType.mcp => 'Server, Tool und Angaben prüfen.',
      FlowNodeType.http => 'Adresse, Methode und Zugang prüfen.',
      _ => 'Einstellungen des Bausteins prüfen.',
    });
  }

  /// Führt den Prozess aus. [input] ist der Inhalt des Auslösers (z. B. Watchlist-Meldung).
  /// [startAt]: ab diesem Baustein fortsetzen (vorherige Ergebnisse bleiben).
  /// Art des auslösenden Ereignisses (Beobachtung: alert | new | digest …) – bestimmt die Art der Push-Nachricht.
  final Map<String, String> _event = {};

  Future<void> run(Workflow wf, {String input = '', String? startAt, String event = ''}) async {
    if (!_running.add(wf.id)) return;
    _event[wf.id] = event;
    final cancel = _cancel[wf.id] = Completer<void>();
    final order = wf.order();
    final prevOut = Map<String, String>.of(outputs[wf.id] ?? const {});
    final prevState = Map<String, String>.of(state[wf.id] ?? const {});
    final resumeIdx = startAt == null ? -1 : order.indexWhere((n) => n.id == startAt);
    state[wf.id] = {
      for (var i = 0; i < order.length; i++)
        order[i].id: i < resumeIdx && (prevState[order[i].id] == 'done' || prevState[order[i].id] == 'skipped') ? prevState[order[i].id]! : 'pending'
    };
    errors[wf.id] = {};
    final out = outputs[wf.id] = {
      if (resumeIdx > 0)
        for (var i = 0; i < resumeIdx; i++)
          if (prevOut[order[i].id] != null) order[i].id: prevOut[order[i].id]!
    };
    if (resumeIdx > 0 && input.isEmpty) input = prevOut[order.first.id] ?? '';
    // Beobachten-Prozess von Hand gestartet: mit der letzten Meldung arbeiten
    if (input.isEmpty && resumeIdx < 0 && wf.trigger?.str('mode') == 'watch') {
      final ev = app.watchlist.forFlow(wf.id)?.events.firstOrNull;
      if (ev != null) {
        input = '${ev.title}\n\n${ev.detail}\n\n${ev.links.map((l) => '- ${l['title']}: ${l['link']}').join('\n')}';
      }
    }
    final skipped = <String>{
      if (resumeIdx > 0)
        for (var i = 0; i < resumeIdx; i++)
          if (prevState[order[i].id] == 'skipped') order[i].id
    };
    final now = DateTime.now();
    wf.lastRun = now;
    startedAt[wf.id] = now;
    // Jeder Prozess hat seinen eigenen Chat (Kategorie „Routinen“) – nur die Ergebnisse
    final conv = app.routineConversation('flowrun-${wf.id}', '⚙ ${wf.name}');
    final why = resumeIdx > 0 ? 'fortgesetzt' : (input.isEmpty ? 'gestartet' : 'ausgelöst durch Beobachtung');
    final log = ChatEntry(role: 'assistant', via: '${now.day}.${now.month}. ${_two(now.hour)}:${_two(now.minute)} · $why');
    conv.entries.add(log);
    if (conv.entries.length > 40) conv.entries.removeRange(0, conv.entries.length - 40);
    app.refreshUi();
    final sw = Stopwatch()..start();
    var failed = false;
    var stopped = false;
    String last = input;
    try {
      for (var idx = 0; idx < order.length; idx++) {
        final n = order[idx];
        if (idx < resumeIdx) continue;
        if (cancel.isCompleted) {
          stopped = true;
          _set(wf, n.id, 'stopped');
          continue;
        }
        final preds = wf.prev(n.id);
        if (preds.isNotEmpty && preds.every((p) => skipped.contains(p.id))) {
          skipped.add(n.id);
          _set(wf, n.id, 'skipped');
          continue;
        }
        final prevText = preds.isEmpty
            ? input
            : [for (final p in preds) if (!skipped.contains(p.id) && (out[p.id] ?? '').isNotEmpty) out[p.id]!].join('\n\n');
        final d = DateTime.now();
        final vars = <String, String>{
          'vorher': prevText,
          'eingabe': input,
          'datum': '${d.day}.${d.month}.${d.year}',
          'uhrzeit': '${_two(d.hour)}:${_two(d.minute)}',
          for (final e in out.entries) e.key.toLowerCase(): e.value,
        };
        live.remove(wf.id);
        _set(wf, n.id, 'running');
        final step = StepLog(step: log.steps.length + 1)
          ..tool = n.type.label
          ..thought = n.title;
        log.steps.add(step);
        app.refreshUi();
        final t0 = Stopwatch()..start();
        try {
          final work = _exec(wf, n, vars, prevText, input, conv, log, step);
          // Stoppen bricht das Warten sofort ab (der Schritt selbst läuft ggf. im Hintergrund aus)
          final result = await Future.any<String?>([work, cancel.future.then<String?>((_) => throw _Cancelled())]);
          if (result == null) {
            // Bedingung nicht erfüllt
            skipped.add(n.id);
            out[n.id] = prevText;
            step.observation = 'Bedingung nicht erfüllt – die folgenden Bausteine werden übersprungen.';
            _set(wf, n.id, 'skipped');
            continue;
          }
          out[n.id] = result;
          if (result.trim().isNotEmpty) last = result;
          step.observation = n.type == FlowNodeType.trigger && result.isEmpty
              ? 'Gestartet ${vars['datum']} ${vars['uhrzeit']}'
              : (result.length > 1500 ? '${result.substring(0, 1500)} …' : result);
          _set(wf, n.id, 'done');
        } on _Cancelled {
          stopped = true;
          step
            ..observation = 'Gestoppt.'
            ..isError = true;
          _set(wf, n.id, 'stopped');
          skipped.add(n.id);
        } catch (e) {
          failed = true;
          final fe = _explain(n, e);
          (errors[wf.id] ??= {})[n.id] = fe;
          step
            ..observation = 'Fehler: ${fe.message}\nHinweis: ${fe.hint}'
            ..isError = true;
          _set(wf, n.id, 'error');
          appLog('Prozesse', '${wf.name} · ${n.title}: ${fe.message}', error: true);
          // nachfolgende Bausteine nicht mehr ausführen
          skipped.add(n.id);
        } finally {
          step.durationMs = t0.elapsedMilliseconds;
        }
      }
    } finally {
      _running.remove(wf.id);
      _cancel.remove(wf.id);
      current.remove(wf.id);
      startedAt.remove(wf.id);
      live.remove(wf.id);
      wf.lastStatus = stopped ? 'Gestoppt' : (failed ? 'Fehler' : 'Erfolgreich');
      _event.remove(wf.id);
      if (failed && !stopped) {
        final fe = errors[wf.id]?.values.firstOrNull;
        unawaited(app.notifyUser(NotifyKind.warnung, '${wf.name} fehlgeschlagen',
            fe == null ? 'Ein Baustein ist fehlgeschlagen.' : '${fe.message} · ${fe.hint}',
            target: conv.id, source: 'flow:${wf.id}'));
      }
      log
        ..text = stopped
            ? 'Der Prozess „${wf.name}“ wurde gestoppt.'
            : failed
                ? 'Der Prozess „${wf.name}“ wurde mit Fehlern beendet. Details in den Schritten.'
                : (last.trim().isEmpty ? 'Prozess „${wf.name}“ abgeschlossen.' : last.trim())
        ..durationMs = sw.elapsedMilliseconds;
      conv.updated = DateTime.now();
      await app.storage.saveConversation(conv);
      await save();
      unawaited(app.logActivity(Activity(
          kind: 'flow',
          title: 'Prozess „${wf.name}“ ${stopped ? 'gestoppt' : (failed ? 'mit Fehlern beendet' : 'ausgeführt')}',
          detail: '${order.length} Bausteine · ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s',
          approval: 'Von dir angelegt',
          conversationId: conv.id)));
      app.refreshUi();
    }
  }

  /// Einen Baustein ausführen. null = Bedingung nicht erfüllt (Rest überspringen).
  Future<String?> _exec(Workflow wf, FlowNode n, Map<String, String> vars, String prevText, String input, Conversation conv,
      ChatEntry log, StepLog step) async {
    switch (n.type) {
      case FlowNodeType.trigger:
        // Ohne Eingabe bleibt {{vorher}} leer (sonst würde „Gestartet …“ z. B. zur Suchanfrage)
        return input;
      case FlowNodeType.agent:
        var prompt = Workflow.fill(n.str('prompt'), vars);
        if (!n.str('prompt').contains('{{') && prevText.trim().isNotEmpty) prompt = '$prompt\n\nErgebnis des vorigen Schritts:\n$prevText';
        // Live-Ansicht: was der Agent gerade tut (Banner im Editor und Schritt im Verlauf)
        final lines = <String>[];
        void progress(String line) {
          lines.add(line);
          if (lines.length > 14) lines.removeAt(0);
          live[wf.id] = line;
          step.observation = lines.join('\n');
          app.refreshUi();
        }

        return app
            .automationAgent(prompt,
                allowInternet: wf.allowInternet,
                conv: conv,
                entry: log,
                onProgress: progress,
                cancel: _cancel[wf.id]?.future)
            .timeout(const Duration(minutes: 10),
                onTimeout: () => throw Exception('Zeitüberschreitung: Der Agent-Schritt lief über 10 Minuten.'));
      case FlowNodeType.tool:
        final tool = [...app.tools, ...app.mcpTools].where((t) => t.name == n.str('tool')).firstOrNull;
        if (tool == null) throw Exception('Werkzeug „${n.str('tool')}“ nicht gefunden');
        if (tool.requiresNetwork && !wf.allowInternet) throw Exception('Internet nicht erlaubt (Werkzeug ${tool.title})');
        final rawArgs = (n.config['args'] as Map?)?.cast<String, dynamic>() ?? {};
        final args = {for (final e in rawArgs.entries) e.key: e.value is String ? Workflow.fill(e.value as String, vars) : e.value};
        step.args = args;
        var result = await tool
            .run(args, ToolContext(requestNetwork: (_) async => wf.allowInternet, propose: (a) => log.actions.add(a)))
            .timeout(const Duration(seconds: 90));
        if (RegExp(r'^(Websuche ohne Ergebnis|Keine Nachrichten abrufbar|Keine Treffer)').hasMatch(result.trim())) {
          final q = args.values.whereType<String>().where((v) => v.trim().isNotEmpty).join(' ');
          throw Exception('Keine Treffer${q.isEmpty ? ' (Suchbegriff leer)' : ' für „$q“'}');
        }
        log.cards = [
          ...log.cards,
          for (final c in parseResultCards(result)) {...c.toJson(), 'tag': AppController.cardTag(tool.name, args)}
        ].take(40).toList();
        final cut = result.indexOf(moreCardsMarker);
        if (cut >= 0) result = result.substring(0, cut);
        // Hinweise an das Modell („Sag dem Nutzer …“) gehören nicht ins Ergebnis
        return result.replaceAll(RegExp(r'\n?(Die Meldungen sieht der Nutzer|Der Nutzer sieht die Treffer|Sag dem Nutzer)[^\n]*'), '').trim();
      case FlowNodeType.http:
        if (!wf.allowInternet) throw Exception('Internet nicht erlaubt (Web-API)');
        final connId = n.str('connection');
        final conn = connId.isEmpty ? null : app.connections.byId(connId);
        if (connId.isNotEmpty && conn == null) throw Exception('Zugang nicht gefunden – im Baustein neu wählen');
        var uri = _resolveUrl(Workflow.fill(n.str('url'), vars), conn);
        if (uri == null || uri.host.isEmpty) throw Exception('Ungültige Adresse „${n.str('url')}“');
        final headers = <String, String>{};
        final rawH = n.config['headers'];
        if (rawH is Map) {
          for (final e in rawH.entries) {
            headers[e.key.toString()] = Workflow.fill(e.value.toString(), vars);
          }
        } else if (rawH is String) {
          for (final line in rawH.split('\n')) {
            final i = line.indexOf(':');
            if (i > 0) headers[line.substring(0, i).trim()] = Workflow.fill(line.substring(i + 1).trim(), vars);
          }
        }
        if (conn != null) {
          final (h, q) = await app.connections.authFor(conn);
          headers.addAll(h);
          if (q.isNotEmpty) uri = uri.replace(queryParameters: {...uri.queryParameters, ...q});
        }
        final method = n.str('method', 'GET').toUpperCase();
        final body = const {'GET', 'HEAD', 'DELETE'}.contains(method) ? null : Workflow.fill(n.str('body'), vars);
        step.args = {'method': method, 'url': uri.replace(queryParameters: uri.queryParameters.isEmpty ? null : {for (final k in uri.queryParameters.keys) k: '…'}).toString()};
        final r = await httpCall(method: method, url: uri, headers: headers, body: body);
        final path = n.str('extract').trim();
        if (path.isNotEmpty) {
          try {
            final v = jsonPath(jsonDecode(r.body), path);
            if (v == null) throw Exception('„$path“ nicht in der Antwort gefunden');
            return v is String ? v : const JsonEncoder.withIndent('  ').convert(v);
          } on FormatException {
            throw Exception('Antwort ist kein JSON – „Wert auslesen“ leeren');
          }
        }
        return r.pretty.isEmpty ? 'HTTP ${r.status} (ohne Inhalt)' : r.pretty;
      case FlowNodeType.mcp:
        if (!wf.allowInternet) throw Exception('Internet nicht erlaubt (MCP-Server)');
        final tool = app.mcpToolFor(n.str('server'), n.str('tool'));
        if (tool == null) throw Exception('MCP-Tool „${n.str('tool')}“ nicht gefunden – Server verbinden und Tool wählen');
        final rawArgs = (n.config['args'] as Map?)?.cast<String, dynamic>() ?? {};
        final args = <String, dynamic>{
          for (final e in rawArgs.entries)
            if ('${e.value}'.trim().isNotEmpty) e.key: e.value is String ? Workflow.fill(e.value as String, vars) : e.value
        };
        step.args = args;
        var result = await tool.run(args, ToolContext(requestNetwork: (_) async => true)).timeout(const Duration(seconds: 90));
        final cut = result.indexOf(moreCardsMarker);
        if (cut >= 0) result = result.substring(0, cut);
        return result;
      case FlowNodeType.condition:
        final needle = Workflow.fill(n.str('contains'), vars).toLowerCase().trim();
        final hit = needle.isNotEmpty && prevText.toLowerCase().contains(needle);
        final pass = n.config['negate'] == true ? !hit : hit;
        return pass ? prevText : null;
      case FlowNodeType.notify:
        final text = Workflow.fill(n.str('text', '{{vorher}}'), vars).replaceAll(RegExp(r'[*_#>`]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
        final title = Workflow.fill(n.str('title', wf.name), vars);
        // Art: im Baustein gewählt oder automatisch (Grenzwert → Warnung, Beobachtung → Info, sonst Ergebnis)
        final ev = _event[wf.id] ?? '';
        final kind = n.str('kind', 'auto') == 'auto'
            ? (ev == 'alert'
                ? NotifyKind.warnung
                : wf.trigger?.str('mode') == 'watch'
                    ? NotifyKind.info
                    : NotifyKind.ergebnis)
            : NotifyKindX.parse(n.str('kind'));
        await app.notifyUser(kind, title.isEmpty ? wf.name : title, text.length > 240 ? '${text.substring(0, 240)}…' : text,
            target: conv.id, source: 'flow:${wf.id}');
        return prevText;
      case FlowNodeType.save:
        final content = prevText.trim();
        if (n.str('mode', 'memory') == 'document') {
          final doc = app.tools.where((t) => t.name == 'create_document').firstOrNull;
          if (doc == null) throw Exception('Werkzeug „create_document“ nicht verfügbar');
          final title = Workflow.fill(n.str('title', '${wf.name} ${vars['datum']}'), vars);
          return doc.run({'title': title, 'content': content}, ToolContext(onArtifact: (a) {
            conv.artifacts.add(a.toJson());
            if (const {'pdf', 'pptx', 'image'}.contains(a.kind)) log.files.add(a.content);
          }));
        }
        final note = content.length > 600 ? '${content.substring(0, 600)}…' : content;
        await app.memory.add('${n.str('title', wf.name)}: $note', category: 'sonstiges', confirmed: true);
        return 'Im Gedächtnis gespeichert.';
    }
  }

  // ------------------------------------------------------------ Reparieren

  /// Fehler automatisch beheben, die keinen Agenten brauchen. true = erledigt.
  Future<bool> quickFix(Workflow wf, String fix) async {
    switch (fix) {
      case 'internet':
        wf.allowInternet = true;
        await upsert(wf);
        return true;
      case 'autoconnect':
        final n = wf.autoConnect();
        await upsert(wf);
        return n > 0;
    }
    return false;
  }

  /// Der Agent repariert die Einstellungen eines Bausteins anhand der Fehlermeldung.
  /// Gibt eine kurze Beschreibung der Änderung zurück (oder wirft).
  Future<String> agentFix(Workflow wf, FlowNode n, {String? error}) async {
    final err = error ?? errors[wf.id]?[n.id]?.message ?? wf.problems(toolNames).where((p) => p.contains('„${n.title}“')).join(' ');
    final tools = [...app.tools, ...app.mcpTools];
    final toolInfo = n.type == FlowNodeType.tool
        ? '\nVerfügbare Werkzeuge (Name: Parameter): ${tools.take(40).map((t) => '${t.name}: ${t.params.map((p) => p.name).join('/')}').join('; ')}'
        : '';
    final mcpInfo = n.type == FlowNodeType.mcp
        ? '\nMCP-Server: ${app.mcpServers.map((s) => '${s.id} (${s.name}): ${s.tools.map((t) => t.name).take(20).join(', ')}').join('; ')}'
        : '';
    final prev = wf.prev(n.id).map((p) => outputs[wf.id]?[p.id]).whereType<String>().join('\n');
    final text = await app.automationText(
        'Ein Baustein eines Automatisierungs-Prozesses ist fehlgeschlagen. Repariere seine Einstellungen.\n'
        'Prozess: ${wf.name}${wf.description.isEmpty ? '' : ' – ${wf.description}'}\n'
        'Baustein-Typ: ${n.type.name} (${n.type.label}), Titel: ${n.title}\n'
        'Einstellungen (JSON): ${jsonEncode(n.config)}\n'
        'Fehler: $err$toolInfo$mcpInfo\n'
        '${prev.isEmpty ? '' : 'Eingabe vom vorigen Baustein (Auszug): ${prev.length > 600 ? prev.substring(0, 600) : prev}\n'}'
        'Antworte nur mit JSON: {"config": {…vollständige korrigierte Einstellungen…}, "change": "Was du geändert hast, ein Satz auf Deutsch"}',
        grammar: Workflow.jsonGrammar,
        maxTokens: 700);
    final s = text.indexOf('{'), e = text.lastIndexOf('}');
    if (s < 0 || e <= s) throw Exception('Der Agent hat keinen Vorschlag gemacht (Modell geladen?).');
    final j = (jsonDecode(text.substring(s, e + 1)) as Map).cast<String, dynamic>();
    final cfg = (j['config'] as Map?)?.cast<String, dynamic>();
    if (cfg == null || cfg.isEmpty) throw Exception('Der Agent hat keine Einstellungen geliefert.');
    // nur bekannte bzw. sinnvolle Felder übernehmen, Typ-spezifische Pflichtwerte bleiben erhalten
    final before = jsonEncode(n.config);
    n.config.addAll(cfg);
    if (n.type == FlowNodeType.trigger) n.config['mode'] = cfg['mode'] ?? n.config['mode'];
    if (jsonEncode(n.config) == before) throw Exception('Der Agent hat nichts geändert.');
    errors[wf.id]?.remove(n.id);
    await upsert(wf);
    final change = (j['change'] ?? 'Einstellungen angepasst').toString();
    appLog('Prozesse', '${wf.name} · ${n.title}: vom Agenten repariert – $change');
    return change;
  }
}

/// „Name (Kopie)“, „Name (Kopie 2)“ …
String copyName(String name, Set<String> taken) {
  final base = name.replaceAll(RegExp(r'\s*\(Kopie( \d+)?\)$'), '');
  var n = '$base (Kopie)';
  for (var i = 2; taken.contains(n); i++) {
    n = '$base (Kopie $i)';
  }
  return n;
}
