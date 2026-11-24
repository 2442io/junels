// Selbsttest: Junels prüft sich selbst auf dem Gerät – Speicher, Modell, Internet, Kalender, Zeitpläne,
// Werkzeuge, Skills, Watchlist, Prozesse, Sync. Läuft nach jedem Update automatisch und meldet Probleme.

import 'dart:async';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';

import '../data/models.dart';
import '../version.dart';
import 'app_controller.dart';
import 'device_bridge.dart';
import 'guide.dart';
import 'notifications.dart';

enum CheckState { ok, warn, fail, skip }

class CheckResult {
  CheckResult(this.area, this.name, this.state, this.detail, this.ms);
  final String area;
  final String name;
  final CheckState state;
  final String detail;
  final int ms;

  String get mark => switch (state) { CheckState.ok => '✓', CheckState.warn => '!', CheckState.fail => '✗', CheckState.skip => '–' };
}

class SelfTest {
  SelfTest(this.app);
  final AppController app;
  final results = <CheckResult>[];

  Future<void> _check(String area, String name, Future<(CheckState, String)> Function() f,
      {Duration timeout = const Duration(seconds: 12)}) async {
    final sw = Stopwatch()..start();
    try {
      final (st, d) = await f().timeout(timeout, onTimeout: () => (CheckState.fail, 'Keine Antwort nach ${timeout.inSeconds} s (hängt)'));
      results.add(CheckResult(area, name, st, d, sw.elapsedMilliseconds));
    } catch (e) {
      results.add(CheckResult(area, name, CheckState.fail, '$e'.replaceFirst('ToolException: ', ''), sw.elapsedMilliseconds));
    }
  }

  void _logic(String name, bool ok, String detail) =>
      results.add(CheckResult('Logik', name, ok ? CheckState.ok : CheckState.fail, ok ? 'ok' : detail, 0));

  /// Alle Prüfungen. [onProgress] meldet Zwischenstände (für die Anzeige).
  Future<List<CheckResult>> run({void Function()? onProgress}) async {
    results.clear();
    void tick() => onProgress?.call();

    // ---- Grundlagen
    await _check('Grundlagen', 'Speicher schreib- und lesbar', () async {
      final f = File('${app.storage.root.path}/.selftest');
      final v = DateTime.now().toIso8601String();
      await f.writeAsString(v);
      final back = await f.readAsString();
      await f.delete();
      return back == v ? (CheckState.ok, app.storage.root.path) : (CheckState.fail, 'Gelesener Inhalt stimmt nicht');
    });
    tick();
    await _check('Grundlagen', 'Sprachmodell', () async {
      final s = app.status;
      return switch (s) {
        EngineStatus.ready => (CheckState.ok, app.loadedModel?.displayName ?? 'bereit'),
        EngineStatus.loading => (CheckState.warn, 'wird gerade geladen'),
        _ => (app.cloudProvider != null ? CheckState.warn : CheckState.fail, 'kein Modell geladen ($s)'),
      };
    });
    await _check('Grundlagen', 'Internet', () async {
      await app.refreshOnline();
      return app.deviceOnline ? (CheckState.ok, 'online') : (CheckState.warn, 'offline – Internet-Werkzeuge pausiert');
    });
    tick();

    // ---- Gerät
    if (Platform.isAndroid || Platform.isMacOS) {
      await _check('Gerät', 'Kalender lesen', () async {
        final now = DateTime.now();
        final events = await app.deviceBridge.calendarList(DateTime(now.year, now.month, now.day), DateTime(now.year, now.month, now.day + 1));
        final cals = await app.deviceBridge.calendarCalendars();
        final google = cals.where((c) => '${c['type']}' == 'com.google' &&
            !'${c['name']}'.toLowerCase().contains(RegExp(r'geburtstag|birthday|feiertag|holiday|kontakte|contacts')));
        final googleEvents = google.fold<int>(0, (a, c) => a + ((c['events'] as num?)?.toInt() ?? 0));
        final calText = cals.isEmpty
            ? ''
            : ' · Kalender: ${cals.map((c) => '${c['name']} (${c['events']}${c['sync'] == true ? '' : ', Sync aus'})').join(', ')}';
        final abos = await DeviceBridge.icsUrls();
        if (abos.isNotEmpty) {
          final soon = await app.deviceBridge.icsEvents(now, now.add(const Duration(days: 7)));
          return soon.isEmpty
              ? (CheckState.warn, 'Kalender-Abo: keine Termine in 7 Tagen – Adresse prüfen$calText')
              : (CheckState.ok, 'Heute ${events.length} Termine · Abo: ${soon.length} in 7 Tagen$calText');
        }
        if (Platform.isAndroid && cals.isNotEmpty && googleEvents == 0) {
          return (CheckState.warn,
              'Heute ${events.length} Termine, aber kein Google-Kalender auf dem Gerät – Kalender-Abo (iCal) eintragen oder Synchronisierung prüfen$calText');
        }
        return (CheckState.ok, 'Heute ${events.length} Termine$calText');
      }, timeout: const Duration(seconds: 15));
      tick();
    }
    await _check('Gerät', 'Benachrichtigungen', () async {
      final s = app.notifySettings;
      final off = s.off.map((k) => k.label).join(', ');
      return (CheckState.ok, 'Postfach ${app.notifier.items.length} Einträge${off.isEmpty ? '' : ' · aus: $off'}${s.quiet ? ' · Ruhezeit ${s.quietFrom}–${s.quietTo} Uhr' : ''}');
    });

    // ---- Zeitpläne
    await _check('Zeitpläne', 'Geplante Prompts', () async {
      final sched = app.prompts.where((p) => p.schedule != ScheduleKind.off).toList();
      if (sched.isEmpty) return (CheckState.ok, 'keine geplant');
      final now = DateTime.now();
      final late = [
        for (final p in sched)
          if (p.nextAfter(p.lastRun ?? now.subtract(const Duration(days: 1))) case final n? when n.isBefore(now.subtract(const Duration(minutes: 30))))
            p.title,
      ];
      final list = sched.map((p) => '${p.title} (${p.scheduleLabel})').join(', ');
      return late.isEmpty
          ? (CheckState.ok, '${sched.length}: $list')
          : (CheckState.warn, 'Überfällig, nicht gelaufen: ${late.join(', ')} – Akku-Optimierung für Junels ausschalten');
    });
    await _check('Zeitpläne', 'Prozesse', () async {
      final failed = [for (final f in app.flows.flows) if (f.lastStatus == 'Fehler') f.name];
      return failed.isEmpty
          ? (CheckState.ok, '${app.flows.flows.length} Prozesse, ${app.flows.flows.where((f) => f.enabled).length} aktiv')
          : (CheckState.warn, 'Zuletzt fehlgeschlagen: ${failed.join(', ')}');
    });
    await _check('Zeitpläne', 'Watchlist', () async {
      final err = [for (final w in app.watchlist.items) if ((w.lastError ?? '').isNotEmpty) w.title];
      return err.isEmpty
          ? (CheckState.ok, '${app.watchlist.items.length} Beobachtungen')
          : (CheckState.warn, 'Fehler bei: ${err.join(', ')}');
    });
    tick();

    // ---- Logik (dieselben Regeln, die der Agent im Chat nutzt)
    _logic('Präsentation wird erkannt', AppController.requiredToolFor('Erstelle mir eine Präsentation über Peru') == 'create_presentation',
        'requiredToolFor liefert ${AppController.requiredToolFor('Erstelle mir eine Präsentation über Peru')}');
    _logic('Begleiten wird erkannt', wantsGuide('Mach das mit mir: https://www.oesterreich.gv.at/x'), 'wantsGuide = false');
    _logic('Skill per /befehl', app.skills.match('/heute')?.$1.command == 'heute', 'kein Skill für /heute');
    _logic('Benachrichtigungs-Arten', NotifyKindX.parse('warnung') == NotifyKind.warnung, 'parse falsch');
    await _check('Logik', 'Rechner-Werkzeug', () async {
      final calc = app.tools.where((t) => t.name == 'calculator').firstOrNull;
      if (calc == null) return (CheckState.skip, 'nicht vorhanden');
      final r = await calc.run({'expression': '17*3+9'}, ToolContext());
      return r.contains('60') ? (CheckState.ok, r) : (CheckState.fail, 'Ergebnis: $r');
    });
    await _check('Logik', 'Datum-Werkzeug', () async {
      final dt = app.tools.where((t) => t.name == 'datetime').firstOrNull;
      if (dt == null) return (CheckState.skip, 'nicht vorhanden');
      final r = await dt.run({}, ToolContext());
      return r.contains('${DateTime.now().year}') ? (CheckState.ok, r.split('\n').first) : (CheckState.fail, r);
    });
    tick();

    // ---- Sync
    await _check('Sync', 'Server', () async {
      final url = app.sync.config.serverUrl.trim();
      if (url.isEmpty) return (CheckState.skip, 'kein Server eingerichtet');
      if (!app.deviceOnline) return (CheckState.skip, 'offline');
      final r = await app.sync.serverHasSso();
      return r == null ? (CheckState.fail, '$url nicht erreichbar') : (CheckState.ok, '$url${r ? ' · SSO' : ''}');
    });
    await _check('Sync', 'Junels als MCP-Server', () async {
      if (!app.settings.mcpServe) return (CheckState.skip, 'ausgeschaltet');
      if (!app.mcpServe.running) return (CheckState.fail, app.mcpServe.error ?? 'läuft nicht');
      final r = await httpCall(
          method: 'POST',
          url: Uri.parse(app.mcpServe.url),
          headers: {'Authorization': 'Bearer ${await app.mcpServe.token()}', 'Content-Type': 'application/json'},
          body: '{"jsonrpc":"2.0","id":1,"method":"tools/list"}',
          timeout: const Duration(seconds: 8));
      final n = RegExp('"name"').allMatches(r.body).length;
      return (CheckState.ok, '${app.mcpServe.url} · $n Werkzeuge');
    });
    // ---- Überwachung
    await _check('Logik', 'Fehlerquote der Prozesse (7 Tage)', () async {
      final runs = [for (final r in app.runStats.since(DateTime.now().subtract(const Duration(days: 7)))) if (r.source == 'flow') r];
      if (runs.isEmpty) return (CheckState.skip, 'keine Läufe');
      final bad = runs.where((r) => r.status == 'error').length;
      final rate = bad / runs.length;
      return (rate > 0.2 ? CheckState.warn : CheckState.ok, '${runs.length} Läufe, $bad mit Fehler');
    });
    tick();
    return results;
  }

  /// Bericht zum Kopieren/Teilen.
  String report() {
    final b = StringBuffer('Junels $appVersion · Selbsttest ${DateTime.now().toString().substring(0, 16)} · ${Platform.operatingSystem}\n');
    String? area;
    for (final r in results) {
      if (r.area != area) {
        area = r.area;
        b.writeln('\n[$area]');
      }
      b.writeln('${r.mark} ${r.name}: ${r.detail}${r.ms > 1500 ? ' (${(r.ms / 1000).toStringAsFixed(1)} s)' : ''}');
    }
    return b.toString();
  }

  int get failed => results.where((r) => r.state == CheckState.fail).length;
  int get warned => results.where((r) => r.state == CheckState.warn).length;
}
