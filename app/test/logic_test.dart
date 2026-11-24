// App-Logik-Tests: laufen bei jedem Build (CI). Ein Fehler hier stoppt die Veröffentlichung.
// Geprüft wird das Verhalten, das im Alltag schon einmal kaputt war.

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_agent/data/models.dart';
import 'package:offline_agent/state/app_controller.dart';
import 'package:offline_agent/state/automation.dart';
import 'package:offline_agent/state/guide.dart';
import 'package:offline_agent/state/notifications.dart';
import 'package:offline_agent/state/skills.dart';
import 'package:offline_agent/state/run_stats.dart';
import 'dart:io';

void main() {
  group('Werkzeug-Pflicht (Präsentation statt Folienliste)', () {
    test('Präsentation', () => expect(AppController.requiredToolFor('Erstelle mir eine Präsentation über Peru'), 'create_presentation'));
    test('Dokument', () => expect(AppController.requiredToolFor('Mach mir ein PDF-Handout zu Wien'), 'create_document'));
    test('Normale Frage ohne Pflicht', () => expect(AppController.requiredToolFor('Wie wird das Wetter morgen?'), isNull));
  });

  group('Begleit-Modus', () {
    test('URL + mach mit mir', () => expect(wantsGuide('Mach das mit mir: https://www.oesterreich.gv.at/de/landingpages/urkunden'), isTrue));
    test('Nur Frage ohne Link', () => expect(wantsGuide('Was ist eine Geburtsurkunde?'), isFalse));
    test('Plan aus Zeilen', () {
      final g = Guide(goal: 'x', url: 'https://a.at')..setPlan('1. Urkunde wählen\n2. Anmelden (du)\n3. Bezahlen');
      expect(g.steps.length, 3);
      expect(g.steps[1].you, isTrue);
      expect(g.steps[2].you, isTrue); // Zahlung macht immer der Mensch
      expect(g.current, 0);
      g.complete(1);
      expect(g.current, 1);
    });
  });

  group('Skills', () {
    final lib = SkillLibrary(File('${Directory.systemTemp.path}/skills_test.json'));
    test('Basis-Skill per /befehl', () => expect(lib.match('/heute')?.$1.name, 'Tagesüberblick'));
    test('Befehl mit Aufgabe', () => expect(lib.match('/praesentation Peru, 8 Folien')?.$2, 'Peru, 8 Folien'));
    test('Eigener Skill automatisch', () {
      lib.upsert(Skill(id: 'u1', name: 'Rechnungen sammeln', when: 'Wenn ich meine Rechnungen vom Monat zusammenstellen will', instructions: '1. x'));
      expect(lib.match('Kannst du meine Rechnungen vom November zusammenstellen?')?.$1.id, 'u1');
      expect(lib.match('Wie wird das Wetter?'), isNull);
    });
    test('SKILL.md hin und zurück', () {
      final s = Skill(id: 'a', name: 'Reise planen', when: 'Wenn ich verreise', instructions: '1. Flüge suchen', tools: ['web_search', 'browser']);
      final back = Skill.fromMarkdown(s.toMarkdown(), id: 'b')!;
      expect(back.name, 'Reise planen');
      expect(back.tools, ['web_search', 'browser']);
      expect(back.command, 'reise-planen');
    });
  });

  group('Benachrichtigungen', () {
    test('Arten erkennen', () {
      expect(NotifyKindX.parse('warnung'), NotifyKind.warnung);
      expect(NotifyKindX.parse('reminder'), NotifyKind.erinnerung);
      expect(NotifyKindX.parse('quatsch'), NotifyKind.info);
    });
    test('Ruhezeit über Mitternacht', () {
      final s = NotifySettings(quiet: true, quietFrom: 22, quietTo: 7);
      expect(s.inQuiet(DateTime(2026, 1, 1, 23)), isTrue);
      expect(s.inQuiet(DateTime(2026, 1, 1, 6)), isTrue);
      expect(s.inQuiet(DateTime(2026, 1, 1, 12)), isFalse);
      expect(s.quietEnd(DateTime(2026, 1, 1, 23)), DateTime(2026, 1, 2, 7));
    });
  });

  group('Vorlagen & Kopien', () {
    test('Kopie-Namen', () {
      expect(copyName('Morgen', {'Morgen (Kopie)'}), 'Morgen (Kopie 2)');
      expect(copyName('Morgen (Kopie)', {}), 'Morgen (Kopie)');
    });
    test('Täglicher Prompt hat nächsten Lauf', () {
      final p = SavedPrompt(id: 'p', title: 'T', text: 'x', schedule: ScheduleKind.daily);
      expect(p.nextAfter(DateTime(2026, 1, 1, 12)), isNotNull);
    });
  });

  group('Überwachung', () {
    test('Laufstatistik: Quote, Dauer, Bausteine, Speichern', () async {
      final dir = await Directory.systemTemp.createTemp('runs');
      final st = RunStats(File('${dir.path}/runs.jsonl'));
      final now = DateTime.now();
      await st.add(RunRecord(source: 'flow', refId: 'a', name: 'A', start: now, ms: 2000, status: 'ok', tokensIn: 100, tokensOut: 50,
          nodes: [NodeStat('Suche', 'agent', 1500, 'done'), NodeStat('Push', 'notify', 500, 'done')]));
      await st.add(RunRecord(source: 'flow', refId: 'a', name: 'A', start: now, ms: 4000, status: 'error', error: 'x',
          nodes: [NodeStat('Suche', 'agent', 3500, 'error')]));
      await st.add(RunRecord(source: 'mcp', refId: 'skill_x', name: 'X', start: now.subtract(const Duration(days: 40)), ms: 1, status: 'ok'));
      final sums = st.summaries(now.subtract(const Duration(days: 7)));
      expect(sums.length, 1);
      expect(sums.first.rate, 0.5);
      expect(sums.first.avgMs, 3000);
      expect(sums.first.tokens, 150);
      expect(sums.first.nodeStats.first.title, 'Suche');
      expect(sums.first.nodeStats.first.errors, 1);
      final again = RunStats(File('${dir.path}/runs.jsonl'));
      await again.load();
      expect(again.records.length, 3);
      expect(again.records.first.nodes.length, 2);
      await dir.delete(recursive: true);
    });
  });
}
