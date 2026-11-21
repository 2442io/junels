// Watchlist und Prozesse: speichern, nach Zeitplan prüfen bzw. ausführen,
// Ergebnisse als Push-Nachricht und im Chat „Automatik“ ablegen.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';

import '../data/models.dart';
import 'activity_log.dart';
import 'app_controller.dart';
import 'background_work.dart';
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

  /// Nächster fälliger Zeitpunkt (für den Android-Wecker).
  DateTime? get nextDue {
    DateTime? best;
    for (final i in items.where((i) => i.enabled)) {
      final d = i.lastCheck == null ? DateTime.now() : i.lastCheck!.add(Duration(minutes: i.intervalMinutes));
      if (best == null || d.isBefore(best)) best = d;
    }
    return best;
  }

  /// Prüft alle fälligen Einträge.
  Future<void> checkDue() async {
    final now = DateTime.now();
    for (final i in List.of(items)) {
      if (i.due(now)) await check(i);
    }
  }

  Future<void> check(WatchItem item) async {
    if (_busy) return;
    _busy = true;
    checkingId = item.id;
    app.refreshUi();
    try {
      final r = await _checker.check(item);
      final ev = r.event;
      if (r.error != null) appLog('Watchlist', '${item.title}: ${r.error}', error: true);
      if (ev != null) {
        appLog('Watchlist', '${item.title}: ${ev.title}');
        if (item.summarize) {
          final sum = await app.automationText(
              'Die beobachtete ${item.kind == WatchKind.page ? 'Webseite' : 'Suche zum Thema'} „${item.title}“ hat Neues:\n\n'
              '${ev.detail}\n\n${ev.links.take(8).map((l) => '- ${l['title']}').join('\n')}\n\n'
              'Fasse in 2–3 Sätzen auf Deutsch zusammen, was neu ist und warum es relevant sein könnte. Keine Einleitung.');
          if (sum.trim().isNotEmpty) ev.detail = '${sum.trim()}\n\n${ev.detail}';
        }
        if (item.notify) {
          final body = ev.detail.replaceAll(RegExp(r'\s+'), ' ').trim();
          unawaited(BackgroundWork.notify(ev.title, body.length > 220 ? '${body.substring(0, 220)}…' : body,
                  conversationId: 'watch:${item.id}')
              .catchError((_) {}));
        }
        // Prozesse, die auf diesen Eintrag warten
        for (final wf in app.flows.flows) {
          final t = wf.trigger;
          if (wf.enabled && t != null && t.str('mode') == 'watch' && (t.str('watchId').isEmpty || t.str('watchId') == item.id)) {
            unawaited(app.flows.run(wf, input: '${ev.title}\n\n${ev.detail}\n\n${ev.links.map((l) => '- ${l['title']}: ${l['link']}').join('\n')}'));
          }
        }
      }
      await save();
    } finally {
      _busy = false;
      checkingId = null;
      app.refreshUi();
    }
  }
}

// ====================================================================== Prozesse

class FlowService {
  FlowService(this.app);
  final AppController app;
  final List<Workflow> flows = [];

  /// Zustand je Prozess und Baustein: running | done | skipped | error
  final Map<String, Map<String, String>> state = {};

  /// Ergebnis je Baustein des letzten Laufs.
  final Map<String, Map<String, String>> outputs = {};
  final Set<String> _running = {};

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
    app.refreshUi();
  }

  Future<void> remove(Workflow wf) async {
    flows.removeWhere((x) => x.id == wf.id);
    state.remove(wf.id);
    outputs.remove(wf.id);
    await save();
    app.refreshUi();
  }

  Set<String> get toolNames => {for (final t in app.tools) t.name, for (final t in app.mcpTools) t.name};

  /// Prozess aus einer Beschreibung erzeugen (Modell, sonst einfache Vorlage).
  Future<Workflow> generate(String description) async {
    final id = newId();
    final tools = [for (final t in app.activeTools) (t.name, t.title)];
    final text = await app.automationText(Workflow.generationPrompt(description, tools), grammar: Workflow.jsonGrammar, maxTokens: 1400);
    final wf = Workflow.fromModelJson(text, id: id, toolNames: toolNames) ?? Workflow.fromDescription(description, id: id);
    if (wf.description.isEmpty) wf.description = description;
    if (wf.name == 'Neuer Prozess') wf.name = Workflow.fromDescription(description, id: id).name;
    appLog('Prozesse', 'Erzeugt: ${wf.name} (${wf.nodes.length} Bausteine)');
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
    app.refreshUi();
  }

  /// Führt den Prozess aus. [input] ist der Inhalt des Auslösers (z. B. Watchlist-Meldung).
  Future<void> run(Workflow wf, {String input = ''}) async {
    if (!_running.add(wf.id)) return;
    final order = wf.order();
    state[wf.id] = {for (final n in order) n.id: 'pending'};
    final out = outputs[wf.id] = {};
    final skipped = <String>{};
    final now = DateTime.now();
    wf.lastRun = now;
    final conv = app.automationConversation();
    final log = ChatEntry(role: 'assistant', via: 'Prozess · ${wf.name}');
    conv.entries
      ..add(ChatEntry(role: 'user', text: '⚙ Prozess „${wf.name}“ gestartet${input.isEmpty ? '' : ' – ausgelöst durch die Watchlist'}'))
      ..add(log);
    app.refreshUi();
    final sw = Stopwatch()..start();
    var failed = false;
    String last = input;
    try {
      for (final n in order) {
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
        _set(wf, n.id, 'running');
        final step = StepLog(step: log.steps.length + 1)
          ..tool = n.type.label
          ..thought = n.title;
        log.steps.add(step);
        app.refreshUi();
        final t0 = Stopwatch()..start();
        try {
          String result;
          switch (n.type) {
            case FlowNodeType.trigger:
              result = input.isEmpty ? 'Gestartet ${vars['datum']} ${vars['uhrzeit']}' : input;
            case FlowNodeType.agent:
              var prompt = Workflow.fill(n.str('prompt'), vars);
              if (!n.str('prompt').contains('{{') && prevText.trim().isNotEmpty) prompt = '$prompt\n\nErgebnis des vorigen Schritts:\n$prevText';
              result = await app.automationAgent(prompt, allowInternet: wf.allowInternet, conv: conv, entry: log);
            case FlowNodeType.tool:
              final tool = [...app.tools, ...app.mcpTools].where((t) => t.name == n.str('tool')).firstOrNull;
              if (tool == null) throw Exception('Werkzeug „${n.str('tool')}“ nicht gefunden');
              final rawArgs = (n.config['args'] as Map?)?.cast<String, dynamic>() ?? {};
              final args = {for (final e in rawArgs.entries) e.key: e.value is String ? Workflow.fill(e.value as String, vars) : e.value};
              step.args = args;
              result = await tool
                  .run(args, ToolContext(requestNetwork: (_) async => wf.allowInternet, propose: (a) => log.actions.add(a)))
                  .timeout(const Duration(seconds: 90));
              final cut = result.indexOf(moreCardsMarker);
              if (cut >= 0) {
                log.cards = [...log.cards, for (final c in parseResultCards(result)) c.toJson()].take(40).toList();
                result = result.substring(0, cut);
              }
            case FlowNodeType.condition:
              final needle = n.str('contains').toLowerCase().trim();
              final hit = needle.isNotEmpty && prevText.toLowerCase().contains(needle);
              final pass = n.config['negate'] == true ? !hit : hit;
              result = prevText;
              if (!pass) {
                skipped.add(n.id);
                step.observation = 'Bedingung nicht erfüllt – die folgenden Bausteine werden übersprungen.';
                step.durationMs = t0.elapsedMilliseconds;
                _set(wf, n.id, 'skipped');
                continue;
              }
            case FlowNodeType.notify:
              final text = Workflow.fill(n.str('text', '{{vorher}}'), vars).replaceAll(RegExp(r'[*_#>`]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
              final title = Workflow.fill(n.str('title', wf.name), vars);
              await BackgroundWork.notify(title.isEmpty ? wf.name : title, text.length > 240 ? '${text.substring(0, 240)}…' : text,
                  conversationId: conv.id);
              result = prevText;
            case FlowNodeType.save:
              final content = prevText.trim();
              if (n.str('mode', 'memory') == 'document') {
                final doc = app.tools.where((t) => t.name == 'create_document').firstOrNull;
                if (doc == null) throw Exception('Werkzeug „create_document“ nicht verfügbar');
                final title = Workflow.fill(n.str('title', '${wf.name} ${vars['datum']}'), vars);
                result = await doc.run({'title': title, 'content': content},
                    ToolContext(onArtifact: (a) {
                      conv.artifacts.add(a.toJson());
                      if (const {'pdf', 'pptx', 'image'}.contains(a.kind)) log.files.add(a.content);
                    }));
              } else {
                final note = content.length > 600 ? '${content.substring(0, 600)}…' : content;
                await app.memory.add('${n.str('title', wf.name)}: $note', category: 'sonstiges', confirmed: true);
                result = 'Im Gedächtnis gespeichert.';
              }
          }
          out[n.id] = result;
          last = result;
          step.observation = result.length > 1500 ? '${result.substring(0, 1500)} …' : result;
          _set(wf, n.id, 'done');
        } catch (e) {
          failed = true;
          step
            ..observation = 'Fehler: $e'
            ..isError = true;
          _set(wf, n.id, 'error');
          // nachfolgende Bausteine nicht mehr ausführen
          skipped.add(n.id);
        } finally {
          step.durationMs = t0.elapsedMilliseconds;
        }
      }
    } finally {
      _running.remove(wf.id);
      wf.lastStatus = failed ? 'Fehler' : 'Erfolgreich';
      log
        ..text = failed
            ? 'Der Prozess „${wf.name}“ wurde mit Fehlern beendet. Details in den Schritten.'
            : (last.trim().isEmpty ? 'Prozess „${wf.name}“ abgeschlossen.' : last.trim())
        ..durationMs = sw.elapsedMilliseconds;
      conv.updated = DateTime.now();
      await app.storage.saveConversation(conv);
      await save();
      unawaited(app.logActivity(Activity(
          kind: 'flow',
          title: 'Prozess „${wf.name}“ ${failed ? 'mit Fehlern beendet' : 'ausgeführt'}',
          detail: '${order.length} Bausteine · ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s',
          approval: 'Von dir angelegt',
          conversationId: conv.id)));
      app.refreshUi();
    }
  }
}
