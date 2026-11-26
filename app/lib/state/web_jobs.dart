// Web-Jobs: Junels erledigt einen Auftrag selbstständig im eingebauten Browser –
// planen (oder vorgemachten Ablauf abspielen) → Schritt für Schritt ausführen → prüfen → Nachweis.
// Fortschritt als Karte in „Ergebnisse“; Pause, Fortsetzen, Übernehmen.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/foundation.dart';

import '../data/models.dart';
import 'app_controller.dart';
import 'notifications.dart';
import 'skills.dart';
import 'voice_service.dart' show appLog;

class WebJobs extends ChangeNotifier {
  WebJobs(this.app);
  final AppController app;

  final List<WebJob> jobs = [];
  final Map<String, Completer<void>> _stop = {};
  final Set<String> _pause = {};
  final Map<String, Completer<String>> _waiters = {};

  File get _file => File('${app.storage.root.path}/jobs.json');

  WebJob? byId(String id) => jobs.where((j) => j.id == id).firstOrNull;

  /// Läuft gerade ein Job (für den Browser-Hinweis „wartet auf dich“)
  WebJob? get running => jobs.where((j) => j.status == 'läuft' || j.status == 'wartet' || j.status == 'plant').firstOrNull;

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final list = jsonDecode(await _file.readAsString()) as List;
      jobs
        ..clear()
        ..addAll([for (final j in list) WebJob.fromJson((j as Map).cast<String, dynamic>())]);
    } catch (e) {
      appLog('Jobs', 'Laden: $e', error: true);
    }
    // Wenn Junels übernehmen lässt: Status „wartet“ (und Push, wenn der Nutzer gerade woanders ist)
    app.browser.onHandOver = (msg) {
      final j = running;
      if (j == null) return;
      j.status = msg == null ? 'läuft' : 'wartet';
      _touch(j);
      if (msg != null) {
        unawaited(app.notifyUser(NotifyKind.aktion, 'Junels braucht dich kurz', '${j.title}: $msg',
            target: AppController.feedId, source: 'job:${j.id}'));
      }
    };
  }

  Future<void> _save() async {
    try {
      // nur die letzten 60 Jobs behalten
      if (jobs.length > 60) jobs.removeRange(0, jobs.length - 60);
      await _file.writeAsString(jsonEncode([for (final j in jobs) j.toJson()]));
    } catch (_) {}
  }

  void _touch(WebJob j) {
    j.updated = DateTime.now();
    notifyListeners();
    app.refreshUi();
  }

  /// Job anlegen und starten. Die Karte erscheint in „Ergebnisse“.
  /// [params]: Werte für Platzhalter eines vorgemachten Ablaufs.
  WebJob start({required String goal, String title = '', Skill? skill, String output = '', Map<String, String> params = const {}}) {
    final j = WebJob(
      id: newId(),
      title: title.isNotEmpty ? title : (skill?.name ?? (goal.length > 50 ? '${goal.substring(0, 50)}…' : goal)),
      goal: goal,
      skillId: skill?.id,
      output: output.isNotEmpty ? output : (skill?.output ?? ''),
    );
    jobs.add(j);
    final f = app.feed;
    f.entries.add(ChatEntry(role: 'assistant', origin: '🧭 ${j.title}', originId: 'job:${j.id}'));
    app.trimFeed();
    unawaited(app.storage.saveConversation(f));
    unawaited(_save());
    unawaited(_run(j, skill: skill, params: params));
    _touch(j);
    return j;
  }

  /// Für Abläufe: Job starten und auf das Ergebnis warten
  Future<String> runAndWait({required String goal, String title = '', Skill? skill, String output = '', Map<String, String> params = const {}}) {
    final j = start(goal: goal, title: title, skill: skill, output: output, params: params);
    final c = _waiters[j.id] = Completer<String>();
    return c.future;
  }

  void pause(WebJob j) {
    _pause.add(j.id);
    final s = _stop[j.id];
    if (s != null && !s.isCompleted) s.complete();
    _touch(j);
  }

  Future<void> resume(WebJob j) async {
    if (j.active) return;
    _pause.remove(j.id);
    j.problem = '';
    final skill = j.skillId == null ? null : app.skills.byId(j.skillId!);
    unawaited(_run(j, skill: skill, params: const {}, resume: true));
  }

  void cancel(WebJob j) {
    _pause.add(j.id);
    final s = _stop[j.id];
    if (s != null && !s.isCompleted) s.complete();
    j.status = 'abgebrochen';
    app.browser.finishHandOver(false);
    _finishEntry(j, 'Abgebrochen.');
    _touch(j);
    unawaited(_save());
  }

  void remove(WebJob j) {
    if (j.active) cancel(j);
    jobs.remove(j);
    unawaited(_save());
    notifyListeners();
  }

  ChatEntry? _entry(WebJob j) => app.feed.entries.where((e) => e.originId == 'job:${j.id}').lastOrNull;

  void _finishEntry(WebJob j, String text) {
    final e = _entry(j);
    if (e != null) {
      e.text = text;
      unawaited(app.storage.saveConversation(app.feed));
    }
    final w = _waiters.remove(j.id);
    if (w != null && !w.isCompleted) w.complete(text);
  }

  Future<void> _run(WebJob j, {Skill? skill, required Map<String, String> params, bool resume = false}) async {
    final entry = _entry(j) ?? ChatEntry(role: 'assistant');
    try {
      await app.browser.showFor(AppController.feedId, pin: true);
      // 1) Plan: vorgemachter Ablauf oder Planer-Modell
      if (j.steps.isEmpty) {
        j.status = 'plant';
        _touch(j);
        if (skill != null && skill.macro.isNotEmpty) {
          j.macro = true;
          for (final s in skill.macro) {
            j.steps.add(JobStep(s.describe));
          }
          if (skill.instructions.trim().isNotEmpty) j.steps.add(JobStep('Ergebnis zusammenstellen'));
        } else {
          final plan = await _plan(j, skill);
          j.steps.addAll(plan.isEmpty ? [JobStep(j.goal)] : [for (final p in plan) JobStep(p)]);
        }
        await _save();
      }
      // Werte für Platzhalter: Eingabe > gespeicherte Standards
      final values = {...?skill?.macroParams, ...params};
      j.status = 'läuft';
      _touch(j);
      String last = '';
      for (var i = resume ? j.current : 0; i < j.steps.length; i++) {
        if (_pause.contains(j.id)) {
          if (j.status != 'abgebrochen') j.status = 'pausiert';
          _touch(j);
          await _save();
          return;
        }
        j.current = i;
        final step = j.steps[i];
        if (step.status == 'ok') continue;
        step.status = 'läuft';
        _touch(j);
        var (ok, note, answer) = (false, '', '');
        if (j.macro && skill != null && i < skill.macro.length) {
          // Vorgemachter Schritt: abspielen; geht es nicht, springt das Modell ein
          final err = await replayMacroStep(app.browser, skill.macro[i], values, allow: app.siteAllow);
          if (err == null) {
            (ok, note) = (true, 'abgespielt');
          } else {
            answer = await _agentStep(j, entry, skill,
                'Ein vorgemachter Schritt ging nicht ($err). Erledige im Browser (die Seite ist offen) genau diesen Schritt: '
                '${fillPlaceholders(skill.macro[i].describe, values)}.\n'
                'Antworte am Ende in EINER Zeile mit „ERLEDIGT: …“ oder „PROBLEM: …“.');
            (ok, note) = stepOutcome(answer);
            if (ok) note = 'vom Modell erledigt: $note';
          }
        } else {
          final finalStep = i == j.steps.length - 1;
          final prompt = j.macro && skill != null
              ? 'Die Seite ist offen (vorgemachter Ablauf ist durch). ${skill.instructions.trim()}\nAuftrag: ${j.goal}\n'
                  'Beginne mit „ERLEDIGT:“ in der ersten Zeile, danach das vollständige Ergebnis.'
              : jobStepPrompt(j, i);
          answer = await _agentStep(j, entry, skill, prompt, output: finalStep ? j.output : '');
          (ok, note) = stepOutcome(answer);
          if (!ok && !_pause.contains(j.id)) {
            // Prüfen → anders versuchen
            step.note = 'zweiter Versuch: $note';
            _touch(j);
            answer = await _agentStep(j, entry, skill, jobStepPrompt(j, i, retryHint: note), output: finalStep ? j.output : '');
            (ok, note) = stepOutcome(answer);
          }
        }
        if (_pause.contains(j.id)) {
          step.status = 'offen';
          continue; // oben: pausiert/abgebrochen
        }
        step
          ..status = ok ? 'ok' : 'problem'
          ..note = note;
        if (answer.isNotEmpty) last = answer;
        _touch(j);
        await _save();
        if (!ok) {
          j
            ..status = 'problem'
            ..problem = note;
          _touch(j);
          await _save();
          _finishEntry(j, '⚠️ Schritt ${i + 1} ging nicht: $note\n\nDu kannst im Browser nachhelfen und dann „Fortsetzen“ tippen.');
          unawaited(app.notifyUser(NotifyKind.aktion, '${j.title}: braucht dich', 'Schritt ${i + 1}: $note',
              target: AppController.feedId, source: 'job:${j.id}'));
          return;
        }
      }
      // 2) Nachweis: Seite, auf der der Job geendet hat
      try {
        final p = jsonDecode(_unwrap(await app.browser.eval(browserProofJs))) as Map;
        j
          ..proofUrl = '${p['url'] ?? ''}'
          ..proofTitle = '${p['title'] ?? ''}'
          ..proofText = '${p['text'] ?? ''}';
      } catch (_) {}
      final now = DateTime.now();
      final stamp = '${now.day}.${now.month}. ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      final result = stripOutcomeMarker(last).isEmpty ? 'Erledigt.' : stripOutcomeMarker(last);
      j
        ..result = result
        ..status = 'fertig';
      j.files
        ..clear()
        ..addAll(entry.files);
      _touch(j);
      await _save();
      _finishEntry(
          j,
          '$result'
          '${j.proofUrl.isEmpty ? '' : '\n\n---\n**Nachweis:** [${j.proofTitle.isEmpty ? SitePolicy.hostOf(j.proofUrl) : j.proofTitle}](${j.proofUrl}) · Stand $stamp'}');
      unawaited(app.notifyUser(NotifyKind.ergebnis, '${j.title} ist fertig', result.length > 200 ? '${result.substring(0, 200)}…' : result,
          target: AppController.feedId, source: 'job:${j.id}'));
    } catch (e) {
      j
        ..status = 'problem'
        ..problem = '$e';
      _touch(j);
      await _save();
      _finishEntry(j, '⚠️ $e');
    } finally {
      if (running == null) app.browser.pinned = null;
    }
  }

  static String _unwrap(String raw) {
    var v = raw;
    for (var i = 0; i < 2 && v.startsWith('"'); i++) {
      try {
        v = jsonDecode(v) as String;
      } catch (_) {
        break;
      }
    }
    return v;
  }

  /// Planen – mit dem Cloud-Modell, wenn erlaubt (Hybrid/Cloud), sonst lokal
  Future<List<String>> _plan(WebJob j, Skill? skill) async {
    final hint = skill == null || skill.instructions.trim().isEmpty ? '' : '\nAnleitung des Skills:\n${skill.instructions.trim()}';
    final cloud = app.cloudProvider;
    final useCloud = cloud != null && (app.settings.routing == 'cloud' || (app.settings.routing == 'hybrid' && app.settings.hybridTarget == 'cloud'));
    try {
      final text = await app.automationAgent(jobPlanPrompt('${j.goal}$hint'),
          allowInternet: useCloud,
          conv: app.feed,
          entry: ChatEntry(role: 'assistant'),
          provider: useCloud ? cloud.id : '',
          source: 'job',
          noTools: true);
      return parsePlan(text);
    } catch (e) {
      appLog('Jobs', 'Planen: $e', error: true);
      return const [];
    }
  }

  /// Einen Schritt mit dem Agenten (Browser + Web-Werkzeuge) ausführen
  Future<String> _agentStep(WebJob j, ChatEntry entry, Skill? skill, String prompt, {String output = ''}) async {
    final stop = _stop[j.id] = Completer<void>();
    try {
      return await app.automationAgent(prompt,
          allowInternet: true,
          conv: app.feed,
          entry: entry,
          // Anleitung des Skills hilft bei jedem Schritt; das Ausgabeformat gilt nur für den letzten
          skill: skill == null ? null : (skill.copy()..output = ''),
          source: 'job',
          output: output,
          withBrowser: true,
          cancel: stop.future);
    } catch (e) {
      return 'PROBLEM: $e';
    } finally {
      _stop.remove(j.id);
    }
  }
}
