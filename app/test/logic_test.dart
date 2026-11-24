// App-Logik-Tests: laufen bei jedem Build (CI). Ein Fehler hier stoppt die Veröffentlichung.
// Geprüft wird das Verhalten, das im Alltag schon einmal kaputt war.

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_agent/data/models.dart';
import 'package:offline_agent/state/app_controller.dart';
import 'package:offline_agent/state/automation.dart';
import 'package:offline_agent/state/guide.dart';
import 'package:offline_agent/state/notifications.dart';
import 'package:offline_agent/state/skills.dart';
import 'package:offline_agent/state/skill_import.dart';
import 'package:agent_engine/agent_engine.dart';
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

  group('Skills importieren', () {
    test('Claude-SKILL.md mit mehrzeiliger Beschreibung und allowed-tools', () {
      const md = '''---
name: pdf-handout
description: >
  Erstellt ein Handout als PDF
  aus einem Thema.
allowed-tools: [WebSearch, Read, Bash]
---

# PDF-Handout

1. Thema recherchieren
2. Gliedern und als PDF ausgeben
''';
      final s = SkillImport.fromText(md, available: evalToolSpecs)!;
      expect(s.name, 'PDF-Handout');
      expect(s.command, 'pdf-handout');
      expect(s.when, 'Erstellt ein Handout als PDF aus einem Thema.');
      expect(s.tools, containsAll(['web_search', 'read_file']));
      expect(s.tools.contains('Bash'), isFalse);
      expect(s.instructions.contains('Thema recherchieren'), isTrue);
    });

    test('ohne Werkzeuge: passende werden vorgeschlagen; Internet/Modell bleiben erhalten', () {
      const md = '''---
name: wetter-check
description: "Prüft das Wetter für den Ausflug und sagt, ob man eine Jacke braucht"
junels-internet: allow
junels-model: cloud
---
Wetter am Zielort abfragen und kurz empfehlen.''';
      final s = SkillImport.fromText(md, available: evalToolSpecs)!;
      expect(s.tools, contains('weather'));
      expect(s.internet, 'allow');
      expect(s.model, 'cloud');
      final back = Skill.fromMarkdown(s.toMarkdown(), id: 'x')!;
      expect(back.internet, 'allow');
      expect(back.model, 'cloud');
      expect(Skill.fromJson(s.toJson()).model, 'cloud');
    });

    test('Markdown ohne Frontmatter und GitHub-Links', () {
      final s = SkillImport.fromText('# Wochenrückblick\nFasst die Woche zusammen.\n\n- Termine ansehen\n- Kurz zusammenfassen', available: evalToolSpecs)!;
      expect(s.name, 'Wochenrückblick');
      expect(s.when, 'Fasst die Woche zusammen.');
      expect(SkillImport.candidates('https://github.com/a/b/blob/main/skills/pdf/SKILL.md').first.toString(),
          'https://raw.githubusercontent.com/a/b/main/skills/pdf/SKILL.md');
      expect(SkillImport.candidates('github.com/a/b/tree/main/skills/pdf').first.toString(),
          'https://raw.githubusercontent.com/a/b/main/skills/pdf/SKILL.md');
      expect(SkillImport.fromText('nur Text ohne Überschrift', available: evalToolSpecs), isNull);
    });

    test('Export entspricht dem Agent-Skills-Standard, Junels-Angaben unter metadata', () {
      final s = Skill(
        id: 'x',
        name: 'Rechnungen: Monat sammeln',
        when: 'Sammelt Rechnungen # aus dem Postfach',
        instructions: '1. Postfach durchsuchen',
        tools: ['mail_inbox', 'web_search', 'create_document'],
        requiredTool: 'create_document',
        internet: 'block',
        model: 'hybrid-onprem',
        meta: {'author': 'christoph'},
      )..addFile('references/REFERENCE.md', '# Kontenplan');
      final md = s.toMarkdown();
      expect(SkillImport.validate(md), isEmpty);
      expect(md, contains('name: rechnungen-monat-sammeln'));
      expect(md, contains('allowed-tools: WebSearch Write'));
      expect(md, contains('  junels.internet: block'));
      expect(md, contains('[references/REFERENCE.md](references/REFERENCE.md)'));
      final back = Skill.fromMarkdown(md, id: 'y')!;
      expect(back.name, 'Rechnungen: Monat sammeln');
      expect(back.when, 'Sammelt Rechnungen # aus dem Postfach');
      expect(back.tools, ['mail_inbox', 'web_search', 'create_document']);
      expect(back.requiredTool, 'create_document');
      expect(back.internet, 'block');
      expect(back.model, 'hybrid-onprem');
      expect(back.meta, {'author': 'christoph'});
      expect(back.instructions.contains('Dateien'), isFalse);
      expect(Skill.fromJson(s.toJson()).files['references/REFERENCE.md'], '# Kontenplan');
      expect(s.brief(), contains('references/REFERENCE.md'));
    });

    test('Standard-Prüfung und allowed-tools mit Klammern', () {
      expect(SkillImport.validate('---\nname: PDF--Tool\ndescription: x\n---\n'), isNotEmpty);
      expect(SkillImport.validate('---\nname: pdf-tool\n---\n'), isNotEmpty);
      expect(SkillImport.validate('---\nname: pdf-tool\ndescription: Macht PDFs\n---\n', dirName: 'pdf-tool'), isEmpty);
      expect(Skill.splitTools('Bash(git:*) Bash(jq:*) Read, WebFetch'), ['Bash(git:*)', 'Bash(jq:*)', 'Read', 'WebFetch']);
      final s = SkillImport.fromText('---\nname: git-check\ndescription: Prüft Repos\nallowed-tools: Bash(git:*) Read WebFetch\n---\nSchritte', available: evalToolSpecs)!;
      expect(s.tools, containsAll(['read_file', 'web_fetch']));
      expect(s.unmapped, ['Bash']);
    });

    test('ZIP: Dateien bleiben erhalten, Export und Re-Import', () {
      final a = Skill(id: 'a', name: 'Kontenplan', when: 'Bucht nach Kontenplan', instructions: 'Kontenplan lesen')
        ..addFile('references/konten.md', '4000 Erlöse')
        ..addFile('scripts/check.py', 'print(1)');
      final b = Skill(id: 'b', name: 'Kontenplan', when: 'Zweiter mit gleichem Namen', instructions: 'x');
      final zip = SkillImport.toZip([a, b]);
      final back = SkillImport.fromZip(zip, available: evalToolSpecs);
      expect(back.length, 2);
      final k = back.firstWhere((x) => x.files.isNotEmpty);
      expect(k.files['references/konten.md'], '4000 Erlöse');
      expect(k.files['scripts/check.py'], 'print(1)');
      expect(back.map((x) => x.specName).toSet(), {'kontenplan', 'kontenplan-2'});
      expect(a.addFile('../etc/passwd', 'x'), isFalse);
      expect(a.addFile('references/gross.md', 'x' * (Skill.maxFileBytes + 1)), isFalse);
    });
  });
}
